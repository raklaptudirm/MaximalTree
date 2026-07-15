import Foundation
import AppKit
import SwiftUI
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
        var attrs = Attributes.named(name)
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            if let size = vals.fileSize { attrs["size"] = .int(size) }
            if let mod = vals.contentModificationDate { attrs["modified"] = .date(mod) }
        }
        return Node(id: id, type: isDir ? directoryType : fileType, attributes: attrs, hasChildren: isDir)
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
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        return Page(items: nodes)
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

        registry.register(renderer: TypeRenderer(
            typeID: directoryType,
            canvas: { id, host in AnyView(DirectoryCanvas(nodeID: id).environment(host)) },
            inspector: { id, host in AnyView(FileInspector(nodeID: id).environment(host)) }
        ))
        registry.register(renderer: TypeRenderer(
            typeID: fileType,
            canvas: { id, host in AnyView(FileCanvas(nodeID: id).environment(host)) },
            inspector: { id, host in AnyView(FileInspector(nodeID: id).environment(host)) }
        ))

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
    }
}
