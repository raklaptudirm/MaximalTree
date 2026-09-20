import AppKit
import MaximalTreeKit

// The plugin's action vocabulary — everything you can *do* to a file from the
// context menu, the menu bar, the palette, and the inspector. Mutations that fit
// the generic vocabulary go through `host.apply` (create, trash); side effects
// that don't (duplicate's IO, the pasteboard, Finder) happen here and report
// through `notify`. Rename is deliberately absent: the host's `core.rename`
// covers any provider supporting `.rename`, including this one.

/// True when every target is filesystem-backed (file or directory).
@MainActor
private func allFileNodes(_ ctx: ActionContext) -> Bool {
    !ctx.selectedNodes.isEmpty && ctx.selectedNodes.allSatisfy { $0.type.raw.hasPrefix("file.") }
}

/// The directory a creation action targets: the selected directory itself, or
/// nil when the selection isn't exactly one directory.
@MainActor
private func targetDirectory(_ ctx: ActionContext) -> NodeID? {
    guard ctx.selectedNodes.count == 1, ctx.selectedNodes[0].type == directoryType
    else { return nil }
    return ctx.selectedNodes[0].id
}

extension FileSystemPlugin {
    @MainActor
    func registerActions(with registry: PluginRegistry) {
        registry.register(action: Action(
            id: "file.newFile",
            title: "New File",
            systemImage: "doc.badge.plus",
            appliesTo: .custom { targetDirectory($0) != nil },
            scope: .container,
            handler: { ctx in
                guard let dir = targetDirectory(ctx) else { return }
                // .txt rather than extensionless: gives the file a real content
                // type, so the editor claims it the moment it's opened.
                ctx.apply(.create(in: dir, name: "untitled.txt", asContainer: false))
            }
        ))

        registry.register(action: Action(
            id: "file.newFolder",
            title: "New Folder",
            systemImage: "folder.badge.plus",
            appliesTo: .custom { targetDirectory($0) != nil },
            scope: .container,
            handler: { ctx in
                guard let dir = targetDirectory(ctx) else { return }
                ctx.apply(.create(in: dir, name: "untitled folder", asContainer: true))
            }
        ))

        registry.register(action: Action(
            id: "file.duplicate",
            title: "Duplicate",
            systemImage: "plus.square.on.square",
            appliesTo: .custom(allFileNodes),
            handler: { ctx in
                let ids = ctx.selection
                let host = ctx.host
                // Copying can be big IO — off the main actor, then report what
                // changed through the same funnel every mutation uses.
                Task {
                    do {
                        let changes = try await Task.detached(priority: .userInitiated) {
                            try FileSystemProvider.duplicate(ids)
                        }.value
                        host.notify(changes)
                    } catch {
                        NSLog("[FileSystemPlugin] duplicate failed: \(error.localizedDescription)")
                    }
                }
            }
        ))

        registry.register(action: Action(
            id: "file.trash",
            title: "Move to Trash",
            systemImage: "trash",
            appliesTo: .custom(allFileNodes),
            handler: { ctx in ctx.apply(.delete(ctx.selection)) }
        ))

        registry.register(action: Action(
            id: "file.copyPath",
            title: "Copy Path",
            systemImage: "document.on.clipboard",
            appliesTo: .custom(allFileNodes),
            handler: { ctx in
                let paths = ctx.selection.compactMap { $0.fileURL?.path }
                guard !paths.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
            }
        ))

        registry.register(action: Action(
            id: "file.reveal",
            title: "Reveal in Finder",
            systemImage: "folder",
            appliesTo: .custom(allFileNodes),
            handler: { ctx in
                let urls = ctx.selection.compactMap(\.fileURL)
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
        ))

        registry.register(action: Action(
            id: "file.openDefault",
            title: "Open with Default App",
            systemImage: "arrow.up.forward.app",
            appliesTo: .type(fileType),
            handler: { ctx in
                for url in ctx.selection.compactMap(\.fileURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        ))
    }
}
