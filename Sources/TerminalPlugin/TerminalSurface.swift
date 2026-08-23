import AppKit
import SwiftUI
import GhosttyKit
import MaximalTreeKit

/// The NSView libghostty renders into.
///
/// The view itself is handed to `ghostty_surface_new` as the platform view:
/// libghostty attaches its Metal layer and drives it from its own render
/// thread. Nothing here draws — this side only forwards what AppKit knows and
/// the terminal can't see for itself: size, backing scale, focus, and input.
final class TerminalSurfaceView: NSView {
    private var surface: ghostty_surface_t?
    /// The shell's working directory, applied when the surface is created.
    var workingDirectory: String?
    /// Typed into the shell as soon as it starts, as though the reader had.
    var initialInput: String?
    /// Which node this surface *is*. libghostty hands back a surface pointer
    /// and nothing else, so this is how a report from the terminal finds its
    /// way to the right node.
    var sessionID: NodeID?

    /// Whether libghostty accepted this view and gave it a surface.
    var hasLiveSurface: Bool { surface != nil }

    override var acceptsFirstResponder: Bool { true }
    /// The terminal's own layer, not a subview's, and it must not be redrawn
    /// by AppKit — libghostty owns its contents.
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        // nonisolated(unsafe): the surface pointer is only ever touched on the
        // main actor, and deinit runs after the last such use — Swift 6 can't
        // see that, and a leaked surface would keep a shell alive forever.
        if let surface = surfaceForTeardown { ghostty_surface_free(surface) }
    }

    /// The surface as an unchecked pointer, for `deinit` alone.
    private nonisolated(unsafe) var surfaceForTeardown: ghostty_surface_t? {
        surface
    }

    /// End this terminal now, rather than whenever the view is released.
    /// Freeing the surface is what stops the shell.
    func teardown() {
        removeFromSuperview()
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    /// Create the surface once the view is in a window — before that there is
    /// no backing scale to give it, and a terminal sized against the wrong
    /// scale renders at the wrong resolution.
    /// Created on first appearance and kept: a surface is a running shell,
    /// so leaving a window (a tab switch, a closed pane) must not end it. Only
    /// `teardown` does that.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard surface == nil, window != nil, let app = GhosttyApp.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(window?.backingScaleFactor ?? 2)

        surface = (workingDirectory ?? "").withCString { directory in
            if workingDirectory != nil { config.working_directory = directory }
            return (initialInput ?? "").withCString { input in
                if initialInput != nil { config.initial_input = input }
                return ghostty_surface_new(app, &config)
            }
        }
        syncSize()
        syncFocus()
        syncColorScheme()
    }

    /// A surface carries its own scheme: one created after the app was told
    /// would otherwise start on the default (light) and stay there until the
    /// system appearance next changed.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncColorScheme()
    }

    private func syncColorScheme() {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface,
                                         GhosttyApp.scheme(for: effectiveAppearance))
    }

    // MARK: Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSize()
    }

    /// libghostty wants *pixels*, and a view is measured in points.
    private func syncSize() {
        guard let surface else { return }
        let pixels = convertToBacking(bounds).size
        ghostty_surface_set_size(surface, UInt32(max(pixels.width, 1)),
                                 UInt32(max(pixels.height, 1)))
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        syncFocus()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        syncFocus()
        return ok
    }

    private func syncFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, window?.firstResponder === self)
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        guard send(event, action: GHOSTTY_ACTION_PRESS) else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = send(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        // A modifier press and release look identical to AppKit; which one it
        // is depends on whether the flag is now set.
        let mods = Self.mods(event.modifierFlags)
        let pressed = mods.rawValue & Self.modBit(for: event.keyCode) != 0
        _ = send(event, action: pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE,
                 text: nil)
    }

    @discardableResult
    private func send(_ event: NSEvent, action: ghostty_input_action_e,
                      text: String? = nil) -> Bool {
        guard let surface else { return false }
        let characters = text ?? event.characters ?? ""
        return characters.withCString { cString in
            var key = ghostty_input_key_s()
            key.action = action
            key.mods = Self.mods(event.modifierFlags)
            key.keycode = UInt32(event.keyCode)
            key.text = characters.isEmpty ? nil : cString
            key.composing = false
            return ghostty_surface_key(surface, key)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
                                     Self.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
                                     Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Ghostty's origin is top-left; AppKit's is bottom-left.
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y,
                                  Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // Bit 0 says the deltas are precise (a trackpad, not a wheel notch),
        // which is what lets the terminal scroll by fractions of a line.
        let precision: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY,
                                     ghostty_input_scroll_mods_t(precision))
    }

    /// Everything the terminal is currently showing.
    ///
    /// The terminal's own idea of its contents, not a screenshot — which is
    /// what makes it possible to check that a program running inside it
    /// behaved, without a person looking at it.
    func visibleText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT,
                                      coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT,
                                          coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                                          x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return nil }
        return String(cString: bytes)
    }

    /// Write text into the terminal as though it were typed — what a paste
    /// does, and what lets a test drive a real shell.
    func send(text: String) {
        guard let surface else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    }

    // MARK: Modifier translation

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(value)
    }

    /// Which modifier a `flagsChanged` key code belongs to, so a press can be
    /// told from a release.
    private static func modBit(for keyCode: UInt16) -> UInt32 {
        switch keyCode {
        case 0x38, 0x3C: return GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: return GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: return GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: return GHOSTTY_MODS_SUPER.rawValue
        case 0x39: return GHOSTTY_MODS_CAPS.rawValue
        default: return 0
        }
    }
}

/// The terminal canvas: a window onto a session, never an owner of one.
///
/// The session's view is hosted inside a plain container and pinned to fill
/// it. Re-parenting rather than rebuilding is what lets a terminal be closed,
/// reopened, split, and moved between tabs while the shell keeps running —
/// the same arrangement the web plugin uses for its WKWebViews.
struct TerminalCanvas: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(session.view, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container {
            attach(session.view, to: container)
        }
    }

    private func attach(_ view: TerminalSurfaceView, to container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Typing should go to the terminal as soon as it is on screen.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    /// The host sizes canvases through SwiftUI; without this the view reports
    /// no intrinsic size and the split collapses it (learned the hard way in
    /// the editor).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 320))
    }
}
