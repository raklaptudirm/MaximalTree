import Foundation
import MaximalTreeKit

/// iCloud Drive's half that needs no window: the provider, and what can be
/// done to an iCloud item with nothing but the file system — show the drive,
/// bring an item down to this device, let it go back to the cloud.
///
/// What a host with no window registers, and the first thing the Mac plugin
/// does. Choosing a folder to mount needs a panel, so that is the shell's.
enum ICloudCore {
    @MainActor
    static func register(with registry: CoreRegistry, drive: ICloudDrive) {
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
            id: "icloud.download",
            title: "Download Now",
            systemImage: "icloud.and.arrow.down",
            appliesTo: .custom { ctx in all(ctx, in: [.inCloud, .behind]) },
            run: { ctx in try each(ctx, drive: drive, with: drive.download) }
        ))

        registry.register(action: Action(
            id: "icloud.evict",
            title: "Remove Download",
            systemImage: "icloud.slash",
            // Only what is fully here and current. Letting go of something iCloud
            // is still waiting on is how a change made offline gets lost.
            appliesTo: .custom { ctx in all(ctx, in: [.current]) },
            run: { ctx in try each(ctx, drive: drive, with: drive.evict) }
        ))
    }

    /// The iCloud address of a folder, or a refusal that says why — a folder
    /// picker can wander anywhere, and only somewhere inside iCloud has one.
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
