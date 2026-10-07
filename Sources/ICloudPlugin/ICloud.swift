import AppKit
import MaximalTreeKit

/// iCloud Drive in the tree, with the two things you can do only to something
/// in iCloud: bring it down to this Mac, and let it go back to the cloud.
///
/// Everything else — rename, move, trash, reveal, copy the path, open it — it
/// gets by being the file it is. See `ICloudProvider`.
///
/// The Mac's half: the core (`ICloudCore`), and mounting a folder chosen in a
/// panel.
@objc(ICloudPlugin)
final class ICloudPlugin: NSObject, Plugin {
    override init() { super.init() }

    /// Which drive the actions act on. Replaceable so a test can point them at
    /// a temporary one, the same bargain the provider strikes.
    nonisolated(unsafe) static var drive = ICloudDrive.live

    func register(with registry: PluginRegistry) {
        let drive = Self.drive
        ICloudCore.register(with: registry, drive: drive)

        registry.register(action: Action(
            id: "icloud.mountFolder",
            title: "Mount iCloud Folder…",
            systemImage: "folder.badge.plus",
            scope: .workspace,
            run: { ctx in
                guard let url = Self.pickFolder(startingAt: drive.root) else { return }
                let id = try ICloudCore.address(of: url, in: drive)
                ctx.mount(id.uri)
                ctx.host.openURI(id.uri)
            }
        ))
    }

    /// A folder chosen by the reader, starting in iCloud Drive — or nil if
    /// they thought better of it.
    @MainActor
    private static func pickFolder(startingAt start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.message = "Choose a folder in iCloud Drive, or one of your apps' folders there."
        panel.prompt = "Mount"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
