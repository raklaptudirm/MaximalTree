import Foundation
import AppKit
import STTextView
import STTextKitPlus

/// Facts about where the view went, for when the view goes somewhere nobody
/// asked it to.
///
/// Scroll bugs in a lazily laid-out text view do not reproduce in a window
/// that never draws: headless, TextKit never runs the viewport pass, so the
/// estimate never lags and nothing slides. Twice now the thing that settled
/// one of these was a log from the running app rather than another theory, so
/// this is that log, kept rather than rewritten each time.
///
/// Off unless asked for, and cheap to ask for from a Finder launch:
///
///     defaults write com.maximaltree.app scrollTrace -bool YES
///
/// Writes to `/tmp/maximaltree-scroll.log`. Turn it off with `-bool NO`.
public enum EditorTrace {
    public static let isOn: Bool = {
        if ProcessInfo.processInfo.environment["MT_SCROLL_TRACE"] != nil { return true }
        return UserDefaults.standard.bool(forKey: "scrollTrace")
    }()

    private static let path = "/tmp/maximaltree-scroll.log"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var started = Date()

    /// One line: what happened, and the numbers that tell the mechanisms apart.
    ///
    /// `top` is where the viewport is, `laid` how far TextKit has actually laid
    /// the document out, and `caret` where the cursor's line sits in document
    /// space. A jerk is one of two shapes and these separate them: the viewport
    /// moving (something scrolled) or `laid` collapsing while `top` holds still
    /// (the document slid underneath a stationary scroll offset).
    @MainActor
    public static func note(_ event: String, _ view: NSView?, extra: String = "") {
        guard isOn else { return }
        var fields = ["+\(String(format: "%.3f", Date().timeIntervalSince(started)))s",
                      event]
        if let text = view as? STTextView {
            let visible = text.visibleRect
            fields.append("top=\(round(visible.minY))")
            fields.append("h=\(round(visible.height))")
            fields.append("laid=\(round(text.textLayoutManager.usageBoundsForTextContainer.maxY))")
            fields.append("doc=\(round(text.enclosingScrollView?.documentView?.frame.height ?? 0))")
            let selection = text.textSelection
            fields.append("sel=\(selection.location)+\(selection.length)")
            if let cm = text.textLayoutManager.textContentManager,
               let range = NSTextRange(NSRange(location: selection.location, length: 0), in: cm),
               let frame = text.textLayoutManager.textSegmentFrame(at: range.location,
                                                                   type: .standard) {
                fields.append("caretY=\(round(frame.minY))")
                fields.append(visible.minY <= frame.minY && frame.maxY <= visible.maxY
                              ? "onScreen" : "offScreen")
            } else {
                fields.append("caretY=?")
            }
        }
        if !extra.isEmpty { fields.append(extra) }
        write(fields.joined(separator: " "))
    }

    private static func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
            handle?.seekToEndOfFile()
            handle?.write(Data("\n=== \(Date()) ===\n".utf8))
        }
        handle?.write(Data((line + "\n").utf8))
    }
}
