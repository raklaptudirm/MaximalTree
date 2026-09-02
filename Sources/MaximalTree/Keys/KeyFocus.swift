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
    /// Whether the keyboard currently belongs to something that takes text:
    /// the editor, a text view, or the field editor behind a text field.
    @MainActor
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        switch responder {
        case is MaximalEditor.EditorTextView: return true
        case is NSTextView, is NSText: return true
        default: return false
        }
    }

    /// The focused canvas that handles keys in normal mode, if there is one.
    /// Walks up, because the view that ends up focused is often nested inside
    /// the one that does the handling.
    @MainActor
    static func focusedCanvas(in window: NSWindow? = NSApp.keyWindow) -> CanvasKeyHandling? {
        var responder: NSResponder? = window?.firstResponder
        while let current = responder {
            if let canvas = current as? CanvasKeyHandling { return canvas }
            responder = (current as? NSView)?.superview
        }
        return nil
    }

    /// The editor that has the keyboard, if one does.
    @MainActor
    static func focusedEditor(in window: NSWindow? = NSApp.keyWindow)
        -> MaximalEditor.EditorTextView? {
        window?.firstResponder as? MaximalEditor.EditorTextView
    }

    /// The first view in a tree that will accept the keyboard — where typing
    /// goes when the canvas isn't an editor. A terminal, a web page.
    @MainActor
    static func firstKeyTaker(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        // A leaf that will take focus: the terminal's surface, a web view.
        // Containers and SwiftUI's own backing views are skipped — they accept
        // focus without doing anything useful with it.
        let name = String(describing: type(of: view))
        if view.acceptsFirstResponder, !(view is NSScrollView), !name.contains("Hosting"),
           view.subviews.isEmpty || view is MaximalEditor.EditorTextView {
            return view
        }
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
