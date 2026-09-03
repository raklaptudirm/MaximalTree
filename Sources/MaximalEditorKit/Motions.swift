import Foundation

// Where the boundaries are: word edges, line ends, the first non-blank. What
// a motion *selects* is worked out from these, so `w` is only as good as
// `wordForward` — and `wd` only as good as `w`.

extension EditEngine {
    func lineStart(at offset: Int, in ns: NSString) -> Int {
        ns.lineRange(for: NSRange(location: min(offset, ns.length), length: 0)).location
    }

    /// The end of the line's *text*, before the newline — where `$` sits, and
    /// where a line ends for `D`.
    func lineEnd(at offset: Int, in ns: NSString) -> Int {
        let line = ns.lineRange(for: NSRange(location: min(offset, ns.length), length: 0))
        var end = NSMaxRange(line)
        if end > line.location, ns.character(at: end - 1) == 10 { end -= 1 }
        return end
    }

    func firstNonBlank(ofLineAt offset: Int, in ns: NSString) -> Int {
        let start = lineStart(at: offset, in: ns)
        let end = lineEnd(at: offset, in: ns)
        var position = start
        while position < end, isSpace(ns.character(at: position)) { position += 1 }
        return position
    }

    func leadingWhitespace(ofLineAt offset: Int, in ns: NSString) -> String {
        let start = lineStart(at: offset, in: ns)
        return ns.substring(with: NSRange(location: start,
                                          length: firstNonBlank(ofLineAt: offset, in: ns) - start))
    }

    /// Move by whole lines, keeping the column where it can — the thing that
    /// makes `j` feel right rather than jumping to the start of each line.
    func line(from offset: Int, by delta: Int, in ns: NSString) -> Int {
        guard delta != 0 else { return offset }
        let column = offset - lineStart(at: offset, in: ns)
        var current = offset
        for _ in 0..<abs(delta) {
            if delta > 0 {
                let end = NSMaxRange(ns.lineRange(for: NSRange(location: current, length: 0)))
                guard end < ns.length else { break }
                current = end
            } else {
                let start = lineStart(at: current, in: ns)
                guard start > 0 else { break }
                current = lineStart(at: start - 1, in: ns)
            }
        }
        return min(lineStart(at: current, in: ns) + column, lineEnd(at: current, in: ns))
    }

    func offset(ofLine index: Int, in ns: NSString) -> Int {
        var position = 0
        for _ in 0..<index {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: position, length: 0)))
            guard end < ns.length else { return position }
            position = end
        }
        return position
    }

    func lastLineStart(in ns: NSString) -> Int {
        guard ns.length > 0 else { return 0 }
        // A trailing newline doesn't make an extra line to go to.
        let end = ns.character(at: ns.length - 1) == 10 ? max(ns.length - 1, 0) : ns.length
        return lineStart(at: max(end - 1, 0), in: ns)
    }

    // MARK: Words

    /// Vim's word rules: runs of word characters, runs of punctuation, and
    /// whitespace between them. Punctuation being its own kind of word is why
    /// `w` stops at the `(` in `foo(bar)`.
    private enum CharClass { case word, punctuation, space }

    private func classify(_ character: unichar) -> CharClass {
        if isSpace(character) { return .space }
        let scalar = UnicodeScalar(character) ?? " "
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { return .word }
        return .punctuation
    }

    func isSpace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10
    }

    func wordForward(from offset: Int, in ns: NSString) -> Int {
        var position = offset
        guard position < ns.length else { return position }
        let start = classify(ns.character(at: position))
        if start != .space {
            while position < ns.length, classify(ns.character(at: position)) == start {
                position += 1
            }
        }
        while position < ns.length, classify(ns.character(at: position)) == .space {
            position += 1
        }
        return position
    }

    func wordBackward(from offset: Int, in ns: NSString) -> Int {
        var position = offset
        guard position > 0 else { return 0 }
        position -= 1
        while position > 0, classify(ns.character(at: position)) == .space { position -= 1 }
        let kind = classify(ns.character(at: position))
        while position > 0, classify(ns.character(at: position - 1)) == kind { position -= 1 }
        return position
    }

    func wordEnd(from offset: Int, in ns: NSString) -> Int {
        var position = offset
        guard position < ns.length - 1 else { return min(offset, max(ns.length - 1, 0)) }
        position += 1
        while position < ns.length, classify(ns.character(at: position)) == .space { position += 1 }
        guard position < ns.length else { return ns.length - 1 }
        let kind = classify(ns.character(at: position))
        while position + 1 < ns.length, classify(ns.character(at: position + 1)) == kind {
            position += 1
        }
        return position
    }
}
