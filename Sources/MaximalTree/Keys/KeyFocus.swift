import AppKit
import MaximalEditorKit
import MaximalTreeKit

/// Who has the keyboard, and how to hand it over.
///
/// The subtle part: the editor is **not** an `NSTextView`. STTextView is an
/// `NSView` that implements text input itself, so `firstResponder is
/// NSTextView` — the obvious check — is false while the editor is being typed
/// in. That check being wrong is what made the modal layer keep `j` and `k`
/// for the sidebar even when the caret was in the document.
enum KeyFocus {
    /// The editor that has the keyboard, if one does.
    @MainActor
    static func focusedEditor(in window: NSWindow? = NSApp.keyWindow)
        -> MaximalEditor.EditorTextView? {
        window?.firstResponder as? MaximalEditor.EditorTextView
    }

    /// Whether this view is somewhere typing could usefully go.
    ///
    /// A leaf that will take focus: the terminal's surface, a web view.
    /// Containers and SwiftUI's own backing views are skipped — they accept
    /// focus without doing anything useful with it.
    @MainActor
    static func isKeyTaker(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        return view.acceptsFirstResponder && !(view is NSScrollView) && !name.contains("Hosting")
            && (view.subviews.isEmpty || view is MaximalEditor.EditorTextView)
    }

    /// The first view in a tree that will accept the keyboard — where typing
    /// goes when the canvas isn't an editor. A terminal, a web page.
    @MainActor
    static func firstKeyTaker(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if isKeyTaker(view) { return view }
        for subview in view.subviews {
            if let found = firstKeyTaker(in: subview) { return found }
        }
        return nil
    }

    /// The first editor in a view tree — where "focus the editor" goes.
    @MainActor
    static func firstEditor(in view: NSView?) -> MaximalEditor.EditorTextView? {
        guard let view else { return nil }
        if let editor = view as? MaximalEditor.EditorTextView { return editor }
        for subview in view.subviews {
            if let found = firstEditor(in: subview) { return found }
        }
        return nil
    }
}
