import AppKit
import MaximalTreeKit

/// iCloud Drive in the tree, with the two things you can do only to something
/// in iCloud: bring it down to this Mac, and let it go back to the cloud.
///
/// Everything else — rename, move, trash, reveal, copy the path, open it — it
/// gets by being the file it is. See `ICloudProvider`.
@objc(ICloudPlugin)
final class ICloudPlugin: NSObject, Plugin {
    override init() { super.init() }

    /// Which drive the actions act on. Replaceable so a test can point them at
    /// a temporary one, the same bargain the provider strikes.
    nonisolated(unsafe) static var drive = ICloudDrive.live

    func register(with registry: PluginRegistry) {
        let drive = Self.drive
        registry.register(provider: ICloudProvider(drive: drive, broker: registry.broker))

        registry.register(action: Action(
            id: "icloud.show",
            title: "Show iCloud Drive",
            systemImage: "icloud",
            scope: .workspace,
            run: { ctx in
                ctx.mount(ICloudDrive.rootURI)
                ctx.host.openURI(ICloudDrive.rootURI)
            }
        ))

        registry.register(action: Action(
            id: "icloud.mountFolder",
            title: "Mount iCloud Folder…",
            systemImage: "folder.badge.plus",
            scope: .workspace,
            run: { ctx in
                guard let url = Self.pickFolder(startingAt: drive.root) else { return }
                let id = try Self.address(of: url, in: drive)
                ctx.mount(id.uri)
                ctx.host.openURI(id.uri)
            }
        ))

        registry.register(action: Action(
            id: "icloud.download",
            title: "Download Now",
            systemImage: "icloud.and.arrow.down",
            appliesTo: .custom { ctx in Self.all(ctx, in: [.inCloud, .behind]) },
            run: { ctx in try Self.each(ctx, drive: drive, with: drive.download) }
        ))

        registry.register(action: Action(
            id: "icloud.evict",
            title: "Remove Download",
            systemImage: "icloud.slash",
            // Only what is fully here and current. Letting go of something iCloud
            // is still waiting on is how a change made offline gets lost.
            appliesTo: .custom { ctx in Self.all(ctx, in: [.current]) },
            run: { ctx in try Self.each(ctx, drive: drive, with: drive.evict) }
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

    /// The iCloud address of a folder, or a refusal that says why — the folder
    /// panel can wander anywhere, and only somewhere inside iCloud has one.
    static func address(of url: URL, in drive: ICloudDrive) throws -> NodeID {
        guard let id = drive.id(for: url), drive.isShown(id) else { throw NotInICloud(url: url) }
        return id
    }

    struct NotInICloud: LocalizedError {
        let url: URL
        var errorDescription: String? {
            "“\(url.lastPathComponent)” isn’t in iCloud Drive, so it can’t be mounted as an "
                + "iCloud folder. Mount Root… mounts it as an ordinary folder instead."
        }
    }

    /// Whether every target is an iCloud item in one of `states`.
    @MainActor
    static func all(_ ctx: ActionContext, in states: Set<DownloadState>) -> Bool {
        !ctx.targets.isEmpty && ctx.selectedNodes.count == ctx.targets.count
            && ctx.selectedNodes.allSatisfy { node in
                node.id.scheme == "icloud"
                    && ICloudProvider.state(of: node).map(states.contains) == true
            }
    }

    /// Do `operation` to each target, and say which rows to redraw.
    ///
    /// The first failure stops it and reaches the reader. What already
    /// succeeded is still reported, so the rows that did change show it.
    @MainActor
    static func each(_ ctx: ActionContext, drive: ICloudDrive,
                     with operation: (URL) throws -> Void) throws {
        var changed: [NodeChange] = []
        defer { if !changed.isEmpty { ctx.notify(changed) } }
        for id in ctx.targets {
            guard let url = drive.url(for: id) else { continue }
            try operation(url)
            changed.append(.modified(id))
        }
    }
}
