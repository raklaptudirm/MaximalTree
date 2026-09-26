import AppKit
import SwiftUI
import MaximalTreeKit

// A chord from an actual key press, and a chord as the menu bar holds one. The
// chord itself is the kit's — plain data any shell can read — and only these
// two translations belong to AppKit and SwiftUI.
extension KeyChord {
    /// What an actual key press amounts to.
    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty
        else { return nil }
        let flags = event.modifierFlags
        let named: String?
        switch event.keyCode {
        case 49: named = "SPC"
        case 36, 76: named = "RET"
        case 48: named = "TAB"
        case 53: named = "ESC"
        case 51: named = "DEL"
        case 123: named = "left"
        case 124: named = "right"
        case 125: named = "down"
        case 126: named = "up"
        // Named for the same reason the arrows are: these are the keys a
        // commanding mode still lets through to scroll with, and a rule about
        // them has to be able to say which they are. Bindable now too.
        case 115: named = "home"
        case 116: named = "pageup"
        case 119: named = "end"
        case 121: named = "pagedown"
        default: named = nil
        }
        let key = named ?? characters.lowercased()
        // Shift is folded in for letters and named keys only. For symbols the
        // character *is* the shifted result — `/` is `/` however it was typed,
        // and recording shift there would stop it matching its own binding.
        let isLetter = key.count == 1 && (key.first?.isLetter ?? false)
        self.init(key,
                  control: flags.contains(.control),
                  option: flags.contains(.option),
                  command: flags.contains(.command),
                  shift: (named != nil || isLetter) && flags.contains(.shift))
    }

    /// The menu bar's form of this chord, or nil for one a menu can't hold.
    ///
    /// Letters stay lowercase with shift as a modifier, which is how a menu
    /// spells ⇧⌘Z; the named keys map to their equivalents one for one.
    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "SPC": equivalent = .space
        case "RET": equivalent = .return
        case "TAB": equivalent = .tab
        case "ESC": equivalent = .escape
        case "DEL": equivalent = .delete
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "home": equivalent = .home
        case "end": equivalent = .end
        case "pageup": equivalent = .pageUp
        case "pagedown": equivalent = .pageDown
        default:
            guard key.count == 1, let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        var modifiers: EventModifiers = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }
}
