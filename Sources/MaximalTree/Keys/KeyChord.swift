import AppKit

/// One press: a key and the modifiers held with it.
///
/// Written the way Emacs writes them — `SPC`, `g`, `C-w`, `M-x`, `S-TAB` — so
/// a keymap reads like a keymap and can be typed into a config one day rather
/// than assembled out of AppKit enums.
struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    /// Lowercased for letters, or a name like `SPC`, `RET`, `TAB`, `ESC`.
    let key: String
    let control: Bool
    let option: Bool
    let command: Bool
    /// Only meaningful for keys that have no shifted character of their own:
    /// `S-TAB` is a chord, `J` is just `J`.
    let shift: Bool

    init(_ key: String, control: Bool = false, option: Bool = false,
         command: Bool = false, shift: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    /// Parse `C-x`, `M-RET`, `SPC`, `g`. Returns nil for anything malformed,
    /// so a bad keymap entry is a visible mistake rather than a dead key.
    init?(parsing text: String) {
        var rest = text
        var control = false, option = false, command = false, shift = false
        while rest.count > 2, rest.dropFirst().first == "-" {
            switch rest.first {
            case "C": control = true
            case "M": option = true          // Meta is Option on this keyboard
            case "s": command = true         // super
            case "S": shift = true
            default: return nil
            }
            rest = String(rest.dropFirst(2))
        }
        guard !rest.isEmpty else { return nil }
        // A bare capital is a shifted letter: `G` and `S-g` are the same
        // press, and folding them together is what keeps `G` from clobbering
        // the `g` prefix it would otherwise share a node with.
        if rest.count == 1, let letter = rest.first, letter.isUppercase, letter.isLetter {
            self.init(rest.lowercased(), control: control, option: option,
                      command: command, shift: true)
            return
        }
        self.init(rest.count == 1 ? rest.lowercased() : rest.uppercased(),
                  control: control, option: option, command: command, shift: shift)
    }

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

    var description: String {
        var text = ""
        if control { text += "C-" }
        if option { text += "M-" }
        if command { text += "s-" }
        // A shifted letter reads as a capital, which is how a keymap writes it.
        if shift, key.count == 1, key.first?.isLetter == true {
            return text + key.uppercased()
        }
        if shift { text += "S-" }
        return text + key
    }
}
