import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MaximalTreeKit

// File-scheme identity helpers. Kept in the plugin — the host core never assumes
// URIs are paths; only this provider interprets `file://` structure.
extension NodeID {
    init?(fileURL url: URL) { self.init(url.standardizedFileURL.absoluteString) }
    var fileURL: URL? {
        guard scheme == "file" else { return nil }
        return URL(string: uri)
    }
}

let directoryType = TypeID("file.directory")
let fileType = TypeID("file.file")

/// A `NodeProvider` backed by the local filesystem. Sendable and stateless; all IO
/// runs off the main actor via detached tasks so directory reads never block the UI.
struct FileSystemProvider: NodeProvider {
    let schemes: Set<String> = ["file"]

    func roots() -> [NodeID] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return NodeID(fileURL: home).map { [$0] } ?? []
    }

    func resolve(_ uri: String) -> NodeID? {
        guard let id = NodeID(uri), let url = id.fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return id
    }

    func node(for id: NodeID) async -> Node? {
        guard let url = id.fileURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.makeNode(url: url, id: id)
        }.value
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard let url = id.fileURL else { return Page(items: []) }
        return await Task.detached(priority: .userInitiated) {
            Self.readChildren(url: url)
        }.value
    }

    // MARK: Pure helpers (off-main)

    static func makeNode(url: URL, id: NodeID) -> Node? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return node(url: url, id: id, isDir: isDir.boolValue)
    }

    static func node(url: URL, id: NodeID, isDir: Bool) -> Node {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        var attrs = Attributes()
        var contentType: UTType?
        var anchor: NodeAnchor?
        if let vals = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey,
                      .isSymbolicLinkKey]) {
            if let size = vals.fileSize { attrs["size"] = .int(size) }
            if let mod = vals.contentModificationDate { attrs["modified"] = .date(mod) }
            if let type = vals.contentType {
                attrs["uti"] = .string(type.identifier)
                contentType = type
            }
            // A symlink IS a pointer to another file — phony: opening it opens
            // the destination's node (one identity per real file), the link
            // stays selected in the sidebar.
            if vals.isSymbolicLink == true {
                let resolved = url.resolvingSymlinksInPath()
                if resolved.path != url.path {
                    anchor = NodeID(fileURL: resolved).map { NodeAnchor(node: $0) }
                }
            }
        }
        return Node(id: id,
                    type: isDir ? directoryType : fileType,
                    label: name,
                    icon: isDir ? NodeIcon("folder.fill", tint: .blue)
                                : (languageIcon(for: url) ?? icon(for: contentType)),
                    attributes: attrs,
                    hasChildren: isDir,
                    anchor: anchor)
    }

    /// Content-type-aware icons, so the sidebar reads at a glance.
    static func icon(for uti: UTType?) -> NodeIcon {
        guard let uti else { return NodeIcon("doc", tint: .secondary) }
        if uti.conforms(to: .image)   { return NodeIcon("photo", tint: .purple) }
        if uti.conforms(to: .movie) || uti.conforms(to: .audio) {
            return NodeIcon("play.rectangle", tint: .red)
        }
        if uti.conforms(to: .pdf)        { return NodeIcon("doc.richtext", tint: .red) }
        if uti.conforms(to: .sourceCode) { return NodeIcon("chevron.left.forwardslash.chevron.right", tint: .green) }
        if uti.conforms(to: .text)       { return NodeIcon("doc.text", tint: .secondary) }
        if uti.conforms(to: .archive)    { return NodeIcon("shippingbox", tint: .orange) }
        return NodeIcon("doc", tint: .secondary)
    }

    static func readChildren(url: URL) -> Page<Node> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return Page(items: []) }

        let nodes: [Node] = entries.compactMap { child -> Node? in
            guard let cid = NodeID(fileURL: child) else { return nil }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return node(url: child, id: cid, isDir: isDir)
        }
        .sorted { a, b in
            let ad = a.type == directoryType, bd = b.type == directoryType
            if ad != bd { return ad }   // directories first
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        return Page(items: nodes)
    }
}

enum FileSystemError: LocalizedError {
    case notAFile
    case badDestination
    case invalidName(String)
    var errorDescription: String? {
        switch self {
        case .notAFile: return "Not a filesystem node."
        case .badDestination: return "Invalid destination path."
        case .invalidName(let name): return "\"\(name)\" can't be used as a file name."
        }
    }
}

extension FileSystemProvider: MutatingNodeProvider {
    func supports(_ mutation: GraphMutation) -> Bool {
        switch mutation {
        case .rename(let id, _): return id.fileURL != nil
        case .delete(let ids): return !ids.isEmpty && ids.allSatisfy { $0.fileURL != nil }
        case .move(let ids, let dest):
            guard !ids.isEmpty, ids.allSatisfy({ $0.fileURL != nil }),
                  let destURL = dest.fileURL else { return false }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDir),
                  isDir.boolValue else { return false }
            // No moves into yourself or your own descendant, and no no-op moves
            // to the current parent.
            return ids.allSatisfy { id in
                guard let url = id.fileURL else { return false }
                let source = url.standardizedFileURL.path
                let target = destURL.standardizedFileURL.path
                return target != source
                    && !(target + "/").hasPrefix(source + "/")
                    && url.deletingLastPathComponent().standardizedFileURL.path != target
            }
        case .create(let parent, _, _): return parent.fileURL != nil
        @unknown default: return false
        }
    }

    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] {
        // Do the IO off the main actor.
        try await Task.detached(priority: .userInitiated) {
            try Self.perform(mutation)
        }.value
    }

    static func perform(_ mutation: GraphMutation) throws -> [NodeChange] {
        let fm = FileManager.default
        switch mutation {
        case .rename(let id, let newName):
            guard let url = id.fileURL else { throw FileSystemError.notAFile }
            // The name arrives from a free-form text field: refuse anything that
            // isn't a single path component before it can escape the parent.
            guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".."
            else { throw FileSystemError.invalidName(newName) }
            let parentURL = url.deletingLastPathComponent()
            let dest = parentURL.appendingPathComponent(newName)
            try fm.moveItem(at: url, to: dest)
            guard let newID = NodeID(fileURL: dest) else { throw FileSystemError.badDestination }
            var changes: [NodeChange] = [.renamed(from: id, to: newID)]
            if let parent = NodeID(fileURL: parentURL) { changes.append(.childrenChanged(parent)) }
            return changes

        case .delete(let ids):
            // Trash items independently: a failure mid-batch must not discard the
            // changes for files that ARE already in the Trash, or the host cache
            // keeps showing them. Throw only if nothing succeeded.
            var changes: [NodeChange] = []
            var firstError: Error?
            for id in ids {
                guard let url = id.fileURL else { continue }
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)   // reversible
                    changes.append(.removed(id))
                    if let parent = NodeID(fileURL: url.deletingLastPathComponent()) {
                        changes.append(.childrenChanged(parent))
                    }
                } catch {
                    NSLog("[FileSystemPlugin] trash failed for \(url.path): \(error.localizedDescription)")
                    firstError = firstError ?? error
                }
            }
            if changes.isEmpty, let firstError { throw firstError }
            return changes

        case .move(let ids, let dest):
            guard let destURL = dest.fileURL else { throw FileSystemError.badDestination }
            var changes: [NodeChange] = []
            var touchedParents = Set<NodeID>()
            for id in ids {
                guard let url = id.fileURL else { continue }
                let target = destURL.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: target)
                guard let newID = NodeID(fileURL: target) else { throw FileSystemError.badDestination }
                // Identity is location: a move is a rename, and the host remaps
                // tabs/history/selection from the reported pair.
                changes.append(.renamed(from: id, to: newID))
                if let parent = NodeID(fileURL: url.deletingLastPathComponent()) {
                    touchedParents.insert(parent)
                }
            }
            touchedParents.insert(dest)
            changes += touchedParents.map { .childrenChanged($0) }
            return changes

        case .create(let parent, let name, let asContainer):
            guard let base = parent.fileURL else { throw FileSystemError.badDestination }
            let url = base.appendingPathComponent(uniqueName(name, in: base))
            if asContainer {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                guard fm.createFile(atPath: url.path, contents: Data()) else {
                    throw FileSystemError.badDestination
                }
            }
            return [.childrenChanged(parent)]

        @unknown default:
            return []
        }
    }

    /// Copy each item next to itself under a uniqued name. Not a `GraphMutation`
    /// (duplication isn't generic graph vocabulary — most schemes can't copy), so
    /// the action does the IO here and reports the changes via `notify`.
    static func duplicate(_ ids: [NodeID]) throws -> [NodeChange] {
        let fm = FileManager.default
        var parents = Set<NodeID>()
        for id in ids {
            guard let url = id.fileURL else { continue }
            let directory = url.deletingLastPathComponent()
            let copy = directory.appendingPathComponent(
                uniqueName(url.lastPathComponent, in: directory))
            try fm.copyItem(at: url, to: copy)
            if let parent = NodeID(fileURL: directory) { parents.insert(parent) }
        }
        return parents.map { .childrenChanged($0) }
    }

    /// Finder-style collision handling: "name", "name 2", "name 3", … (the
    /// extension, when present, stays at the end).
    static func uniqueName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(name).path) else {
            return name
        }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)"
                                        : "\(stem) \(counter).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }
}

/// Entry point and the bundle's `NSPrincipalClass`. Must be Obj-C-discoverable for
/// `Bundle.principalClass` to find it: `@objc(FileSystemPlugin)` pins the unmangled
/// runtime name (Swift would otherwise mangle it to `FileSystem.FileSystemPlugin`),
/// and `NSObject` inheritance is what makes it visible to the Obj-C runtime at all.
@objc(FileSystemPlugin)
final class FileSystemPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(provider: FileSystemProvider())

        registry.registerCanvas(forType: directoryType) { id, host in
            AnyView(DirectoryCanvas(nodeID: id).environment(host))
        }
        // Baseline (priority 0) canvas for any file — Quick Look. A more specific
        // plugin (e.g. the text editor) can register a higher-priority canvas that
        // matches a narrower content type and win.
        registry.registerCanvas(forType: fileType) { id, host in
            AnyView(FileCanvas(nodeID: id).environment(host))
        }
        // One inspector section for anything filesystem-backed.
        registry.register(inspector: InspectorContribution(
            matches: { $0.type.raw.hasPrefix("file.") }) { id, host in
                AnyView(FileInspector(nodeID: id).environment(host))
        })

        registerActions(with: registry)   // see FileActions.swift
    }
}

// MARK: - External change stream (FSEvents)

/// Watch mounted directory roots for edits made by *other* apps (Finder,
/// terminals, editors) and feed them into the host's change funnel — the same
/// path our own saves take, so external edits refresh listings, outlines
/// (contributed children re-fetch), and inspector stats automatically.
extension FileSystemProvider: ChangeStreamingProvider {
    func changes(under root: NodeID) -> AsyncStream<[NodeChange]>? {
        guard root.scheme == "file", let rootURL = root.fileURL else { return nil }
        let rootPath = rootURL.path
        return AsyncStream { continuation in
            let watcher = FileTreeWatcher(path: rootPath) { events in
                let changes = FileSystemProvider.nodeChanges(for: events, rootPath: rootPath)
                if !changes.isEmpty { continuation.yield(changes) }
            }
            guard let watcher else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in watcher.stop() }
        }
    }

    /// Map raw file events to the conservative change vocabulary: the parent's
    /// listing changed, and — when the path still exists — the node itself was
    /// modified. Never `.removed`/`.renamed`: FSEvents can't pair renames
    /// reliably, and a wrong removal tears down open tabs.
    static func nodeChanges(for events: [FileTreeWatcher.Event],
                            rootPath: String) -> [NodeChange] {
        var changes: [NodeChange] = []
        var parents = Set<NodeID>()
        var modified = Set<NodeID>()
        for event in events {
            guard !isInsideHiddenDirectory(event.path, underRoot: rootPath) else { continue }
            let url = URL(fileURLWithPath: event.path)
            if event.mustRescanSubtree {
                // The kernel coalesced — refetch this whole directory's listing.
                if let id = NodeID(fileURL: url), parents.insert(id).inserted {
                    changes.append(.childrenChanged(id))
                }
                continue
            }
            if let parentID = NodeID(fileURL: url.deletingLastPathComponent()),
               parents.insert(parentID).inserted {
                changes.append(.childrenChanged(parentID))
            }
            if FileManager.default.fileExists(atPath: event.path),
               let id = NodeID(fileURL: url), modified.insert(id).inserted {
                changes.append(.modified(id))
            }
        }
        return changes
    }

    /// Listings skip hidden files, so churn inside dot-directories (`.git` is
    /// the loud one) is invisible anyway — don't let it thrash the caches.
    static func isInsideHiddenDirectory(_ path: String, underRoot rootPath: String) -> Bool {
        guard path.hasPrefix(rootPath) else { return false }
        return path.dropFirst(rootPath.count)
            .split(separator: "/")
            .contains { $0.hasPrefix(".") }
    }
}
