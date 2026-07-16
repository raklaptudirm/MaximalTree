import Foundation
import MaximalTreeKit

/// Owns plugin lifecycle. Discovers `.bundle`s in the app's `Contents/PlugIns/`,
/// loads each, and instantiates its `NSPrincipalClass` as a `Plugin`. The plugin
/// and the host share one copy of `MaximalTreeKit` (the app embeds it; plugins link
/// it "Do Not Embed"), so the `Plugin.Type` cast bridges cleanly across the load.
///
/// This is the step-2 loading boundary. Enable/disable, an external user plugins
/// dir, and revocable registrations (the "dynamic plugins" tier) layer on later.
@MainActor
final class PluginHost {
    let registry = Registry()
    private var plugins: [Plugin] = []

    /// Names of bundles that loaded successfully — surfaced for diagnostics.
    private(set) var loaded: [String] = []

    /// Every exit path logs. Silence here is indistinguishable from "never ran", which
    /// is exactly the ambiguity that makes a non-loading plugin painful to diagnose.
    func loadAll() {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else {
            NSLog("[MaximalTree] no PlugIns directory in the app bundle")
            return
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: pluginsURL, includingPropertiesForKeys: nil) else {
            NSLog("[MaximalTree] couldn't read PlugIns at \(pluginsURL.path)")
            return
        }
        NSLog("[MaximalTree] scanning for plugins in \(pluginsURL.path)")

        // Sorted so load order — and therefore any equal-priority renderer tie —
        // is deterministic across launches, not directory-enumeration order.
        let bundles = contents
            .filter { $0.pathExtension == "bundle" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in bundles {
            guard let bundle = Bundle(url: url) else {
                NSLog("[MaximalTree] \(url.lastPathComponent): not a readable bundle")
                continue
            }
            guard bundle.load() else {
                NSLog("[MaximalTree] failed to load \(url.lastPathComponent)")
                continue
            }
            guard let cls = bundle.principalClass as? Plugin.Type else {
                NSLog("[MaximalTree] \(url.lastPathComponent): principal class is not a Plugin")
                continue
            }
            let plugin = cls.init()
            plugin.register(with: registry)
            plugins.append(plugin)
            loaded.append(url.lastPathComponent)
            NSLog("[MaximalTree] loaded plugin \(url.lastPathComponent)")
        }

        NSLog("[MaximalTree] loaded \(loaded.count) plugin(s): \(loaded.joined(separator: ", "))")

        // Every provider is now registered — publish them to the broker plugins were
        // handed during registration, so cross-plugin lookups can resolve.
        registry.hostBroker.install(registry.providers)
    }
}
