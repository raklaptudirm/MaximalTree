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

private let directoryType = TypeID("file.directory")
private let fileType = TypeID("file.file")

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
        if let vals = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey]) {
            if let size = vals.fileSize { attrs["size"] = .int(size) }
            if let mod = vals.contentModificationDate { attrs["modified"] = .date(mod) }
            if let type = vals.contentType {
                attrs["uti"] = .string(type.identifier)
                contentType = type
            }
        }
        return Node(id: id,
                    type: isDir ? directoryType : fileType,
                    label: name,
                    icon: isDir ? NodeIcon("folder.fill", tint: .blue) : icon(for: contentType),
                    attributes: attrs,
                    hasChildren: isDir)
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
    var errorDescription: String? {
        switch self {
        case .notAFile: return "Not a filesystem node."
        case .badDestination: return "Invalid destination path."
        }
    }
}

extension FileSystemProvider: MutatingNodeProvider {
    func supports(_ mutation: GraphMutation) -> Bool {
        switch mutation {
        case .rename(let id, _): return id.fileURL != nil
        case .delete(let ids): return !ids.isEmpty && ids.allSatisfy { $0.fileURL != nil }
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

        @unknown default:
            return []
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

        registry.register(action: Action(
            id: "file.reveal",
            title: "Reveal in Finder",
            systemImage: "folder",
            appliesTo: .custom { ctx in
                !ctx.selectedNodes.isEmpty && ctx.selectedNodes.allSatisfy { $0.type.raw.hasPrefix("file.") }
            },
            handler: { ctx in
                let urls = ctx.selection.compactMap { URL(string: $0.uri) }
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
        ))

        // File-only, to demonstrate the palette/menu filtering by predicate.
        registry.register(action: Action(
            id: "file.openDefault",
            title: "Open with Default App",
            systemImage: "arrow.up.forward.app",
            appliesTo: .type(fileType),
            handler: { ctx in
                for url in ctx.selection.compactMap({ URL(string: $0.uri) }) {
                    NSWorkspace.shared.open(url)
                }
            }
        ))

        registry.register(action: Action(
            id: "file.trash",
            title: "Move to Trash",
            systemImage: "trash",
            appliesTo: .custom { ctx in
                !ctx.selection.isEmpty && ctx.selectedNodes.allSatisfy { $0.type.raw.hasPrefix("file.") }
            },
            handler: { ctx in ctx.host.apply(.delete(ctx.selection)) }
        ))
    }
}
