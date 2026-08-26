import AppKit
import MaximalEditorKit

/// Who has the keyboard, and how to hand it over.
///
/// The subtle part: the editor is **not** an `NSTextView`. STTextView is an
/// `NSView` that implements text input itself, so `firstResponder is
/// NSTextView` — the obvious check — is false while the editor is being typed
/// in. That check being wrong is what made the modal layer keep `j` and `k`
/// for the sidebar even when the caret was in the document.
enum KeyFocus {
    /// Whether the keyboard currently belongs to something other than the
    /// app's own chrome.
    ///
    /// Naming the classes doesn't scale: a terminal, a web view, a PDF page —
    /// the views that want keys live in plugins the app can't see, and
    /// checking for `NSTextView` missed even the editor. The rule that does
    /// scale is about *shape*: SwiftUI's chrome is hosting views, and a plugin
    /// canvas puts its own NSView in as first responder. So a focused view
    /// that isn't a hosting view is something with its own idea about the
    /// keyboard, and gets to keep it.
    ///
    /// Anything can also say so outright with `takesKeyboardInput`, which is
    /// the escape hatch for a view that happens to be hosted.
    @MainActor
    static func takesKeys(_ responder: NSResponder?, in window: NSWindow? = NSApp.keyWindow)
        -> Bool {
        if isTextInput(responder) { return true }
        guard let view = responder as? NSView else { return false }   // window, or nothing
        if view === window?.contentView { return false }
        var current: NSView? = view
        while let candidate = current, candidate !== window?.contentView {
            if candidate.takesKeyboardInput { return true }
            current = candidate.superview
        }
        return !isHostingView(view)
    }

    /// SwiftUI's own view backing, which is the app's chrome rather than
    /// anyone's canvas. Matched by name because the classes are internal to
    /// SwiftUI and there is nothing to import.
    @MainActor
    static func isHostingView(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("Hosting")
    }

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

    /// The editor that has the keyboard, if one does.
    @MainActor
    static func focusedEditor(in window: NSWindow? = NSApp.keyWindow)
        -> MaximalEditor.EditorTextView? {
        window?.firstResponder as? MaximalEditor.EditorTextView
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

// The address is the key; nothing reads or writes the value itself.
private nonisolated(unsafe) var takesKeyboardInputKey: UInt8 = 0

public extension NSView {
    /// Say that this view wants the keyboard when it has focus, whatever it
    /// looks like. For views the shape rule can't classify.
    var takesKeyboardInput: Bool {
        get { objc_getAssociatedObject(self, &takesKeyboardInputKey) as? Bool ?? false }
        set {
            objc_setAssociatedObject(self, &takesKeyboardInputKey, newValue,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
