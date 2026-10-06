import Foundation

/// One press: a key and the modifiers held with it.
///
/// Written the way Emacs writes them — `SPC`, `g`, `C-w`, `M-x`, `S-TAB` — so
/// a keymap reads like a keymap and can be typed into a config one day rather
/// than assembled out of AppKit enums.
///
/// The one vocabulary for keys, a keymap's and a menu's alike: an action's
/// key equivalent is a chord too, so saying which key does what needs no UI
/// framework, and each shell turns a chord into whatever its own menus and
/// key handling take.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    /// Lowercased for letters, or a name like `SPC`, `RET`, `TAB`, `ESC`.
    public let key: String
    public let control: Bool
    public let option: Bool
    public let command: Bool
    /// Only meaningful for keys that have no shifted character of their own:
    /// `S-TAB` is a chord, `J` is just `J`.
    public let shift: Bool

    public init(_ key: String, control: Bool = false, option: Bool = false,
         command: Bool = false, shift: Bool = false) {
        self.key = key
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    /// Parse `C-x`, `M-RET`, `SPC`, `g`. Returns nil for anything malformed,
    /// so a bad keymap entry is a visible mistake rather than a dead key.
    public init?(parsing text: String) {
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
        let spelling = rest.count == 1 ? rest.lowercased()
                     : Self.namedKeys[rest.uppercased()] ?? rest.uppercased()
        self.init(spelling,
                  control: control, option: option, command: command, shift: shift)
    }

    /// The keys with a name instead of a character, in the spelling a key
    /// press produces.
    ///
    /// Written out because the two halves have to agree: a keymap says `up`
    /// and a press says `up`, and they used not to — parsing uppercased any
    /// name it did not recognise as a letter, so the arrows resolved to `UP`
    /// and no binding for one could ever fire.
    public static let namedKeys: [String: String] = [
        "SPC": "SPC", "RET": "RET", "TAB": "TAB", "ESC": "ESC", "DEL": "DEL",
        "LEFT": "left", "RIGHT": "right", "UP": "up", "DOWN": "down",
        "HOME": "home", "END": "end", "PAGEUP": "pageup", "PAGEDOWN": "pagedown",
    ]

    public var description: String {
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
