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

    func loadAll() {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: pluginsURL, includingPropertiesForKeys: nil) else { return }

        for url in contents where url.pathExtension == "bundle" {
            guard let bundle = Bundle(url: url) else { continue }
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
    }
}
