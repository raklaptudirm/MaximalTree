import Foundation

/// What typing does beyond putting the character in: a new line starts at
/// the right indent, brackets and quotes come in pairs, a closing brace finds
/// its level, and backspace takes an empty pair or a whole indent at once.
///
/// Rules, not a view: text, a selection and what was typed in; the edit and
/// where the caret goes out — or nil, for "just type it". The view asks these
/// first and falls back to its own behaviour, so a rule that declines can
/// never lose a keystroke.
///
/// `code` is whether the text is code. A new line keeps its indent in
/// anything, but the rest — pairing, a brace's level, soft tabs — is for code:
/// in prose a `(` is just a `(`, and an apostrophe is not half a string.
public enum Typing {
    static let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]   // ( [ {
    static let closers: Set<unichar> = [41, 93, 125]
    static let quotes: Set<unichar> = [34, 39, 96]                       // " ' `
    static let colon: unichar = 58

    /// Return pressed.
    ///
    /// The new line starts where this one did. After an opener or a colon it
    /// goes a level deeper; and between a bracket and the one that closes it,
    /// the closer drops to its own line at the outer level, with the caret on
    /// the line between — `{|}` becomes a block to type into.
    public static func newline(in text: String, selection: NSRange,
                               indentUnit: String, code: Bool) -> EditOutcome {
        let ns = text as NSString
        let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var indentEnd = lineStart
        while indentEnd < selection.location, isBlank(ns.character(at: indentEnd)) { indentEnd += 1 }
        let indent = ns.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))

        let before = lastNonBlank(before: selection.location, from: lineStart, in: ns)
        var end = NSMaxRange(selection)
        while end < ns.length, isBlank(ns.character(at: end)) { end += 1 }
        let after: unichar? = end < ns.length ? ns.character(at: end) : nil

        guard code, let before, pairs[before] != nil || before == colon else {
            let inserted = "\n" + indent
            return EditOutcome(edit: (selection, inserted),
                               selection: caret(at: selection.location + utf16(inserted)),
                               mode: .insert)
        }
        let inner = indent + indentUnit
        if let close = pairs[before], after == close {
            // The blanks before the closer go too: it starts its own line.
            let inserted = "\n" + inner + "\n" + indent
            return EditOutcome(
                edit: (NSRange(location: selection.location, length: end - selection.location), inserted),
                selection: caret(at: selection.location + 1 + utf16(inner)), mode: .insert)
        }
        let inserted = "\n" + inner
        return EditOutcome(edit: (selection, inserted),
                           selection: caret(at: selection.location + utf16(inserted)), mode: .insert)
    }

    /// One character typed. Nil to type it as it is.
    public static func typed(_ character: String, in text: String, selection: NSRange,
                             indentUnit: String, code: Bool) -> EditOutcome? {
        guard code, (character as NSString).length == 1 else { return nil }
        let ns = text as NSString
        let typed = (character as NSString).character(at: 0)
        let next: unichar? = NSMaxRange(selection) < ns.length ? ns.character(at: NSMaxRange(selection)) : nil
        let previous: unichar? = selection.location > 0 ? ns.character(at: selection.location - 1) : nil

        // Typing the closer that is already there steps over it, so typing a
        // pair out in full doesn't double its end.
        if selection.length == 0, closers.contains(typed) || quotes.contains(typed), next == typed {
            return EditOutcome(selection: caret(at: selection.location + 1), mode: .insert)
        }

        if let close = pairs[typed] {
            // Around what is selected; or as a pair, where nothing follows
            // that the closer would have to sit in front of.
            if selection.length > 0 {
                let inside = ns.substring(with: selection)
                return EditOutcome(
                    edit: (selection, character + inside + String(utf16CodeUnits: [close], count: 1)),
                    selection: NSRange(location: selection.location + 1, length: selection.length),
                    mode: .insert)
            }
            guard next.map(opensBeforeIt) ?? true else { return nil }
            return EditOutcome(edit: (selection, character + String(utf16CodeUnits: [close], count: 1)),
                               selection: caret(at: selection.location + 1), mode: .insert)
        }

        if quotes.contains(typed) {
            // Not after a word (an apostrophe) or another quote, and not in
            // front of something the quote would open onto.
            guard selection.length == 0,
                  !(previous.map { isWordCharacter($0) || quotes.contains($0) } ?? false),
                  next.map(opensBeforeIt) ?? true else { return nil }
            return EditOutcome(edit: (selection, character + character),
                               selection: caret(at: selection.location + 1), mode: .insert)
        }

        // A closer typed where the line so far is only indent: it closes the
        // block above, so it belongs a level out.
        if closers.contains(typed), selection.length == 0 {
            let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let lead = NSRange(location: lineStart, length: selection.location - lineStart)
            let indent = ns.substring(with: lead)
            guard !indent.isEmpty, indent.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
            let outdented = EditEngine.shift(indent + "x", by: -1, unit: indentUnit).dropLast()
            guard outdented.count < indent.count else { return nil }
            return EditOutcome(edit: (lead, String(outdented) + character),
                               selection: caret(at: lineStart + utf16(String(outdented)) + 1),
                               mode: .insert)
        }
        return nil
    }

    /// Backspace. Nil to delete one character as usual.
    ///
    /// Between an empty pair, both go — the pair was typed as one. In the
    /// indent of a line indented with spaces, back to the previous level — the
    /// indent was typed as one too.
    public static func deleteBackward(in text: String, selection: NSRange,
                                      indentUnit: String, code: Bool) -> EditOutcome? {
        guard code, selection.length == 0, selection.location > 0 else { return nil }
        let ns = text as NSString
        let at = selection.location
        let previous = ns.character(at: at - 1)
        let next: unichar? = at < ns.length ? ns.character(at: at) : nil
        if let next, pairs[previous] == next || (quotes.contains(previous) && next == previous) {
            return EditOutcome(edit: (NSRange(location: at - 1, length: 2), ""),
                               selection: caret(at: at - 1), mode: .insert)
        }
        guard indentUnit != "\t", previous == 32 else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: at, length: 0)).location
        let lead = ns.substring(with: NSRange(location: lineStart, length: at - lineStart))
        guard lead.allSatisfy({ $0 == " " }) else { return nil }
        let width = indentUnit.count
        let remove = (lead.count - 1) % width + 1
        return EditOutcome(edit: (NSRange(location: at - remove, length: remove), ""),
                           selection: caret(at: at - remove), mode: .insert)
    }

    // MARK: -

    /// Whether a bracket or quote typed in front of this should come with
    /// its closer: whitespace, the end of a line, or a closer.
    private static func opensBeforeIt(_ next: unichar) -> Bool {
        isBlank(next) || next == 10 || closers.contains(next) || next == 44 || next == 59   // , ;
    }

    private static func isBlank(_ character: unichar) -> Bool { character == 32 || character == 9 }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func lastNonBlank(before offset: Int, from lineStart: Int, in ns: NSString) -> unichar? {
        var position = offset - 1
        while position >= lineStart, isBlank(ns.character(at: position)) { position -= 1 }
        return position >= lineStart ? ns.character(at: position) : nil
    }

    private static func caret(at offset: Int) -> NSRange { NSRange(location: offset, length: 0) }
    private static func utf16(_ string: String) -> Int { (string as NSString).length }
}
