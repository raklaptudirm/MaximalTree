import Foundation

/// Fuzzy matching, the way a finder wants it.
///
/// Everything typed has to appear, in order, but not together: `mtk` finds
/// `MaximalTreeKit`, `keyc` finds `KeyCapture.swift`. What separates a good
/// finder from a filter is the *ranking* — with a hundred matches the right one
/// has to be first — so this scores a match rather than only deciding one.
///
/// The bonuses are the whole of it. A run of adjacent characters is worth far
/// more than the same characters scattered about, and a character at the start
/// of a word — after a space, a slash, an underscore, or at a camelCase hump —
/// is worth more than one in the middle, because that is how people abbreviate
/// when they type. `git` should find `GitPlugin` before `digitize`.
///
/// Returns where it matched as well as how well, so the view can show the
/// reader why this row is here.
enum Fuzzy {
    struct Match: Equatable {
        let score: Int
        /// Indices into the *text*, for highlighting.
        let matched: [Int]
    }

    /// Score `text` against `query`, or nil when the query doesn't appear.
    /// An empty query matches everything, unranked.
    static func match(_ query: String, _ text: String) -> Match? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return Match(score: 0, matched: []) }
        let haystack = Array(text)
        let lowered = Array(text.lowercased())
        guard haystack.count >= needle.count else { return nil }
        guard let positions = tightest(needle, in: lowered) else { return nil }

        var score = 0
        var previous = -2
        for at in positions {
            let adjacent = at == previous + 1
            score += adjacent ? 8 : 1
            if isBoundary(at: at, in: haystack) { score += 6 }
            if at == 0 { score += 4 }
            // Distance costs, so scattered matches rank below tight ones, but
            // never enough to lose to a worse match entirely.
            if !adjacent, previous >= 0 { score -= min(at - previous - 1, 4) }
            previous = at
        }

        // Shorter things are likelier to be what was meant: `Git` over
        // `GitHubIntegrationSettings` for `git`.
        score += max(0, 12 - (haystack.count - needle.count) / 4)
        return Match(score: score, matched: positions)
    }

    /// Where the query sits most tightly in the text.
    ///
    /// Two passes, because one greedy pass takes the *first* place each
    /// character will go and that is often the worst one: "we" against
    /// "New Web Page" anchors on the `w` of "New" and then reaches across to
    /// an `e`, scoring as a scattered match. It would lose to any file whose
    /// name merely began with "we", which is how a command you were plainly
    /// typing the name of ended up below `weakref_finalize.py`.
    ///
    /// So: go forward to find where a match can first *end*, then come back
    /// from there taking each character as late as it can go. That pulls the
    /// match onto "**We**b" — and the highlighting follows it, which is the
    /// other half of the reader being able to trust the list.
    private static func tightest(_ needle: [Character], in lowered: [Character]) -> [Int]? {
        var next = 0
        var end = -1
        for (index, character) in lowered.enumerated() where next < needle.count {
            if character == needle[next] {
                next += 1
                if next == needle.count { end = index; break }
            }
        }
        guard end >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: needle.count)
        var wanted = needle.count - 1
        var index = end
        while wanted >= 0 {
            if lowered[index] == needle[wanted] {
                positions[wanted] = index
                wanted -= 1
            }
            if index == 0 { break }
            index -= 1
        }
        return wanted < 0 ? positions : nil
    }

    /// Whether this position starts a word — after a separator, or a capital
    /// following a lowercase, which is how camelCase names are read.
    private static func isBoundary(at index: Int, in text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        if previous == " " || previous == "/" || previous == "_" || previous == "-"
            || previous == "." || previous == ":" {
            return true
        }
        return text[index].isUppercase && previous.isLowercase
    }
}
