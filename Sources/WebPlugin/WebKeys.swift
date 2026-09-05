import AppKit
import WebKit
import MaximalTreeKit

/// The page's own keys.
///
/// A `WKWebView` subclass rather than an extension on the class itself: the
/// modal layer finds a canvas by walking up from the first responder, and the
/// responder inside a web view is one of WebKit's own subviews — so the thing
/// it walks up to has to be ours to conform.
///
/// Scrolling goes through JavaScript because macOS `WKWebView` keeps its
/// scroll view to itself. That also makes the keys behave the way the page
/// expects: `window.scrollBy` respects scroll-behavior and inner scrollers,
/// where nudging a scroll view would not.
///
/// No repeat counts: `handleKey` isn't given one, and a canvas that wants them
/// has to count digits itself the way the editor does. Scrolling by a fixed
/// step is the honest simple thing until something needs otherwise.
final class WebCanvasView: WKWebView, CanvasKeyHandling {
    /// A line, and most of a screen — the amounts every vim-flavoured browser
    /// extension settled on.
    private static let line = 64
    private static let halfPage = "window.innerHeight / 2"

    static let bindings: [CanvasKeyBinding] = [
        .init("j", title: "Scroll down"),
        .init("k", title: "Scroll up"),
        .init("d", title: "Half page down"),
        .init("u", title: "Half page up"),
        .init("G", title: "Bottom of page"),
        .init("g g", title: "Top of page"),
        .init("H", title: "Back"),
        .init("L", title: "Forward"),
        .init("r", title: "Reload"),
    ]

    var keyBindings: [CanvasKeyBinding] { Self.bindings }

    /// `g` waits for a second key, the way it does everywhere else in the app.
    private var pendingG = false

    func handleKey(_ key: String, control: Bool, mode: KeyMode) -> KeyMode? {
        guard !control else { return nil }
        if pendingG {
            pendingG = false
            guard key == "g" else { return nil }
            scroll(to: "0")
            return mode
        }
        switch key {
        case "j": scroll(by: "\(Self.line)")
        case "k": scroll(by: "-\(Self.line)")
        case "d": scroll(by: Self.halfPage)
        case "u": scroll(by: "-(\(Self.halfPage))")
        case "G": scroll(to: "document.body.scrollHeight")
        case "g": pendingG = true
        case "H": goBack()
        case "L": goForward()
        case "r": reload()
        default: return nil
        }
        return mode
    }

    private func scroll(by amount: String) {
        evaluateJavaScript("window.scrollBy(0, \(amount))")
    }

    private func scroll(to position: String) {
        evaluateJavaScript("window.scrollTo(0, \(position))")
    }
}
