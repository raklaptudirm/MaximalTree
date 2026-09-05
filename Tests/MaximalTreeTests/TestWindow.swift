import AppKit

/// A window for tests: real, laid out, and invisible.
///
/// Several suites need a genuine window — TextKit lays out lazily and does
/// nothing useful for a view that isn't in one, which is why they call
/// `orderFrontRegardless()` rather than merely building a window. That is also
/// what made running the tests throw windows in front of whatever you were
/// doing.
///
/// Placing them off-screen was the obvious answer and does not work: AppKit
/// moves a window that would land on no display back onto one, and not through
/// `constrainFrameRect`, so overriding that changes nothing. A window asked for
/// at (-30000, -30000) arrived at (240, 784).
///
/// So it is ordered in where it likes and made transparent instead. Alpha is
/// compositing only — layout and text measurement are unaffected, which is the
/// whole reason these windows exist — and it cannot take the keyboard or a
/// click.
final class TestWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style,
                   backing: backing, defer: flag)
        alphaValue = 0
        ignoresMouseEvents = true
        // Nothing on screen, so nothing worth a shadow to draw either.
        hasShadow = false
    }

    /// Never key or main, so nothing a test does takes the keyboard from the
    /// app in front. The suites that need a focused view set the first
    /// responder directly, which works regardless.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import Testing

/// The suite is meant to run without taking over the machine.
@MainActor
@Suite struct TestVisibilityTests {
    @Test func aTestWindowShowsNothing() {
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                styleMask: [.titled, .resizable],
                                backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        // Ordered front the way the suites that need layout do it.
        window.orderFrontRegardless()
        window.layoutIfNeeded()

        #expect(window.alphaValue == 0, "a test window is drawing on screen")
        #expect(window.ignoresMouseEvents)
        // And it is still the size it asked for, so layout is unaffected.
        #expect(window.frame.width == 400)
    }

    @Test func aTestWindowNeverTakesTheKeyboard() {
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        #expect(!window.isKeyWindow)
    }

    /// The host app is this app, so a plain test run used to put a full window
    /// in front of whatever was being worked on.
    @Test func theTestHostStaysOutOfTheWay() {
        #expect(NSApp.activationPolicy() == .accessory)
        // Nothing of the app's own is drawing: the scene still builds a
        // window, and it is ordered off as it appears.
        let showing = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }
        #expect(showing.isEmpty, "still on screen: \(showing.map(\.title))")
    }
}
