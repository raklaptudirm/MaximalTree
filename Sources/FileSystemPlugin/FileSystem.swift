import AppKit
import SwiftUI
import MaximalTreeKit

/// Entry point and the bundle's `NSPrincipalClass`. Must be Obj-C-discoverable for
/// `Bundle.principalClass` to find it: `@objc(FileSystemPlugin)` pins the unmangled
/// runtime name (Swift would otherwise mangle it to `FileSystem.FileSystemPlugin`),
/// and `NSObject` inheritance is what makes it visible to the Obj-C runtime at all.
@objc(FileSystemPlugin)
final class FileSystemPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        FileSystemCore.register(with: registry)

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

        registerMacActions(with: registry)
    }
}

// What only the Mac can do with a file: put its path on the pasteboard, show
// it in Finder, hand it to another app. The rest is the core's (FileActions).
extension FileSystemPlugin {
    @MainActor
    func registerMacActions(with registry: PluginRegistry) {
        registry.register(action: Action(
            id: "file.copyPath",
            title: "Copy Path",
            systemImage: "document.on.clipboard",
            appliesTo: .custom(allOnDisk),
            run: { ctx in
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
            appliesTo: .custom(allOnDisk),
            run: { ctx in
                let urls = ctx.selection.compactMap(\.fileURL)
                if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
        ))

        registry.register(action: Action(
            id: "file.openDefault",
            title: "Open with Default App",
            systemImage: "arrow.up.forward.app",
            appliesTo: .custom { ctx in
                allOnDisk(ctx) && ctx.selectedNodes.count == ctx.targets.count
                    && ctx.selectedNodes.allSatisfy { $0.type == fileType }
            },
            run: { ctx in
                for url in ctx.selection.compactMap(\.fileURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        ))
    }
}
