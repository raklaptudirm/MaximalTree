import AppKit
import GhosttyKit

/// The one libghostty app instance, shared by every terminal surface.
///
/// libghostty models a whole *application* — config, font discovery, the
/// renderer and IO threads — and surfaces are created against it. That's a
/// poor fit for a plugin that can be loaded and unloaded, so the app is
/// created once, lazily, on first use and never torn down: freeing it while a
/// surface still lives would take the renderer thread with it.
@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var failure: String?
    /// Kept, not discarded after `ghostty_app_new`: a soft reload re-derives
    /// from *this* config, and without it a colour-scheme change has nothing
    /// to re-apply.
    private(set) var config: ghostty_config_t?
    private var appearanceObserver: NSKeyValueObservation?
    /// The background of the configuration libghostty has actually applied.
    ///
    /// Not the same thing as the background in `config`: a conditional theme
    /// (`theme = dark:…, light:…`) is resolved by the *app* against the colour
    /// scheme, and the result only ever comes back through a config-change
    /// notification. Reading our own handle shows the unresolved defaults.
    private(set) var appliedBackground: NSColor?
    /// How many times the configuration has been re-applied at libghostty's
    /// request. The colour scheme reaches the theme through exactly this, so
    /// it is the link worth being able to see.
    private(set) var configReloads = 0

    private init() {
        Self.scrubHostEnvironment()

        // Ghostty finds its shell-integration scripts and terminfo relative to
        // its own executable, which here is the *host* app — so point it at
        // the copies inside this plugin's bundle instead. Without them a shell
        // never emits the escape sequences that report its title and working
        // directory, and a terminal node can't follow what it is doing.
        //
        // Read only by release builds of libghostty, which is what
        // Scripts/build-ghostty.sh produces.
        if let resources = Bundle(for: TerminalPlugin.self)
            .url(forResource: "ghostty", withExtension: nil) {
            setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        }

        // argv[0] only: this is a plugin inside another app, so libghostty
        // must not go looking at our host's command line for its own flags.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("maximaltree")]
        defer { argv.forEach { free($0) } }
        guard ghostty_init(UInt(argv.count), &argv) == 0 else {
            failure = "libghostty failed to initialize"
            return
        }

        guard let config = Self.loadConfig() else {
            failure = "libghostty failed to read its configuration"
            return
        }
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        // libghostty's threads call this when the app has work pending; the
        // tick itself has to happen on the thread that owns the UI.
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let app = GhosttyApp.shared.app else { return }
                    ghostty_app_tick(app)
                }
            }
        }
        // What a surface says about itself. A terminal that renames its own
        // node when a program sets the title, and follows the shell's `cd`,
        // is the whole point of surfaces being nodes rather than views.
        runtime.action_cb = { _, target, action in
            // Asked for by the app itself, not by a surface — and the reason a
            // colour-scheme change ever reaches the theme. Handled before the
            // surface lookup below, which an app-targeted action never passes.
            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                // Read it here: the config belongs to libghostty and may not
                // outlive this call.
                let background = GhosttyApp.color("background",
                                                  in: action.action.config_change.config)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        GhosttyApp.shared.configApplied(background: background)
                    }
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                let soft = action.action.reload_config.soft
                let surface = target.tag == GHOSTTY_TARGET_SURFACE
                    ? target.target.surface : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        GhosttyApp.shared.reloadConfig(soft: soft, surface: surface)
                    }
                }
                return true
            }

            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface)
            else { return false }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata)
                .takeUnretainedValue()

            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                let title = action.action.set_title.title.map { String(cString: $0) }
                MainActor.assumeIsolated {
                    TerminalSessions.shared.surfaceReported(view: view, title: title,
                                                            directory: nil)
                }
                return true
            case GHOSTTY_ACTION_COLOR_CHANGE:
                // The terminal telling us what it settled on — which is how a
                // theme resolving light or dark becomes observable from here
                // rather than only on screen.
                let change = action.action.color_change
                guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return true }
                let color = NSColor(srgbRed: CGFloat(change.r) / 255,
                                    green: CGFloat(change.g) / 255,
                                    blue: CGFloat(change.b) / 255, alpha: 1)
                MainActor.assumeIsolated {
                    TerminalSessions.shared.surfaceReported(view: view, background: color)
                }
                return true
            case GHOSTTY_ACTION_MOUSE_SHAPE:
                // An I-beam over text, a hand over a link: the terminal knows
                // what the pointer is on, and only the view can show it.
                let shape = action.action.mouse_shape
                MainActor.assumeIsolated { view.setMouseShape(shape) }
                return true
            case GHOSTTY_ACTION_OPEN_URL:
                let payload = action.action.open_url
                guard let url = payload.url.map({ String(cString: $0) }),
                      let target = URL(string: url)
                else { return false }
                MainActor.assumeIsolated { NSWorkspace.shared.open(target) }
                return true
            case GHOSTTY_ACTION_PWD:
                let pwd = action.action.pwd.pwd.map { String(cString: $0) }
                MainActor.assumeIsolated {
                    TerminalSessions.shared.surfaceReported(view: view, title: nil,
                                                            directory: pwd)
                }
                return true
            default:
                // Windows, tabs, splits, quit confirmation: things a surface
                // living inside a canvas has no say over.
                return false
            }
        }
        // The terminal asking for the clipboard — a paste, or an OSC 52 read.
        // The answer goes back through complete_clipboard_request rather than
        // a return value, since a host may need to ask the user first.
        runtime.read_clipboard_cb = { userdata, location, state in
            guard let userdata else { return false }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata)
                .takeUnretainedValue()
            let text = MainActor.assumeIsolated { GhosttyApp.readClipboard(location) }
            MainActor.assumeIsolated { view.completeClipboardRequest(text, state: state) }
            return true
        }
        // Reading the clipboard into the *terminal* can be a security matter:
        // a paste carrying a newline runs whatever it holds. libghostty asks
        // when it judges the content unsafe.
        runtime.confirm_read_clipboard_cb = { userdata, text, state, _ in
            guard let userdata, let text else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata)
                .takeUnretainedValue()
            let contents = String(cString: text)
            MainActor.assumeIsolated { view.confirmUnsafePaste(contents, state: state) }
        }
        runtime.write_clipboard_cb = { _, location, contents, count, _ in
            guard let contents, count > 0 else { return }
            var text = ""
            for index in 0..<Int(count) {
                guard let data = contents[index].data else { continue }
                text += String(cString: data)
            }
            MainActor.assumeIsolated { GhosttyApp.writeClipboard(text, to: location) }
        }
        // The shell exited, or something asked the terminal to close. A
        // surface with nothing running behind it is not a terminal any more,
        // so the node goes too — leaving it would be a row that looks alive
        // and answers nothing.
        runtime.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let id = view.sessionID else { return }
                    TerminalSessions.shared.close(id)
                }
            }
        }

        guard let app = ghostty_app_new(&runtime, config) else {
            failure = "libghostty failed to create its app"
            return
        }
        self.app = app

        // Ghostty resolves a `theme = dark:…, light:…` config against the
        // scheme its *host* reports, and assumes light until told otherwise —
        // so a terminal rendered the light theme on a dark desktop. `.initial`
        // reports the current appearance immediately; the observer keeps it
        // right when the system flips.
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance, options: [.new, .initial]
        ) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GhosttyApp.shared.syncColorScheme() }
            }
        }
    }

    /// Variables that belong to whoever launched *us*, not to the user's
    /// shell.
    ///
    /// A terminal inherits the host process's environment, and a host is
    /// often started by something with opinions: an IDE, a build tool, an
    /// agent. `GIT_EDITOR=true` is the one that bites — set by tools so git
    /// never blocks waiting on an editor, it makes `git commit` inside the
    /// terminal run `/usr/bin/true`, which returns immediately having written
    /// nothing, so git aborts on an empty message and no editor is ever seen.
    ///
    /// Only overrides that name a *program to run on the host's behalf* are
    /// removed. EDITOR and VISUAL are left alone: those are the user's.
    static let hostOnlyVariables = [
        "GIT_EDITOR",           // git commit / rebase message editor
        "GIT_SEQUENCE_EDITOR",  // the same trick for rebase todo lists
    ]

    /// Remove them from this process, which is what every shell spawned from
    /// here inherits.
    static func scrubHostEnvironment() {
        for name in hostOnlyVariables { unsetenv(name) }
    }

    // MARK: Clipboard

    /// macOS has one pasteboard; ghostty also models a "selection" clipboard,
    /// which X11 has and macOS doesn't. Both map to the general pasteboard so
    /// a terminal asking for either gets something sensible.
    static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard { .general }

    static func readClipboard(_ location: ghostty_clipboard_e) -> String {
        pasteboard(location).string(forType: .string) ?? ""
    }

    static func writeClipboard(_ text: String, to location: ghostty_clipboard_e) {
        guard !text.isEmpty else { return }
        let board = pasteboard(location)
        board.declareTypes([.string], owner: nil)
        board.setString(text, forType: .string)
    }

    /// Read the user's config the way ghostty itself would.
    private static func loadConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        return config
    }

    /// Re-apply the configuration.
    ///
    /// libghostty asks for this rather than doing it: telling it the colour
    /// scheme changed only records the fact and requests a *soft* reload, and
    /// the theme it resolves — `theme = dark:…, light:…` — is derived when
    /// that reload is applied. A host that ignores the request keeps whatever
    /// theme it started with, which is how a terminal stayed light on a dark
    /// desktop even after being told the scheme.
    func reloadConfig(soft: Bool, surface: ghostty_surface_t?) {
        guard let app else { return }
        configReloads += 1
        if !soft {
            // The files themselves may have changed.
            if let old = config { ghostty_config_free(old) }
            config = Self.loadConfig()
        }
        guard let config else { return }
        if let surface {
            ghostty_surface_update_config(surface, config)
        } else {
            ghostty_app_update_config(app, config)
        }
    }

    func configApplied(background: NSColor?) {
        appliedBackground = background
    }

    /// A colour out of a configuration, e.g. `background`.
    static func color(_ key: String, in config: ghostty_config_t?) -> NSColor? {
        guard let config else { return nil }
        var value = ghostty_config_color_s()
        let found = key.withCString { name in
            ghostty_config_get(config, &value, name, UInt(strlen(name)))
        }
        guard found else { return nil }
        return NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255,
                       blue: CGFloat(value.b) / 255, alpha: 1)
    }

    /// Tell libghostty which appearance the app is wearing.
    func syncColorScheme() {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, Self.scheme(for: NSApp.effectiveAppearance))
    }

    /// An appearance can be vibrant or high-contrast as well as light or dark,
    /// so ask AppKit which of the two it is closest to rather than comparing
    /// names.
    static func scheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }
}
