import Foundation

/// What a key sequence leads to.
enum KeyBinding: Equatable {
    /// Run this command (see `KeyCommands`).
    case command(String)
    /// More keys to come. The label is what which-key shows for the group.
    case prefix(String)
}

/// A tree of key sequences.
///
/// A trie rather than a flat dictionary because the interesting question isn't
/// only "what does `SPC g s` do" but "I have typed `SPC g`, what now" — which
/// is what makes a leader key learnable instead of something to memorise.
struct Keymap {
    private final class Node {
        var binding: KeyBinding?
        var children: [KeyChord: Node] = [:]
    }

    private let root = Node()

    /// What a sequence resolves to.
    enum Match: Equatable {
        case command(String)
        /// A prefix, with everything that can follow it, in a stable order.
        case prefix(label: String, continuations: [(chord: KeyChord, binding: KeyBinding)])
        case unbound

        static func == (a: Match, b: Match) -> Bool {
            switch (a, b) {
            case (.command(let x), .command(let y)): return x == y
            case (.unbound, .unbound): return true
            case (.prefix(let l1, let c1), .prefix(let l2, let c2)):
                return l1 == l2 && c1.map(\.chord) == c2.map(\.chord)
            default: return false
            }
        }
    }

    /// Every command any sequence in this map names.
    ///
    /// For checking that a key names something real: a binding whose command
    /// nothing runs is a key that silently does nothing, which is worse than
    /// one that isn't bound at all.
    var allCommands: Set<String> {
        var found: Set<String> = []
        var stack = [root]
        while let node = stack.popLast() {
            if case .command(let id) = node.binding { found.insert(id) }
            stack.append(contentsOf: node.children.values)
        }
        return found
    }

    /// Bind a sequence written as `"SPC g s"`. Intermediate chords become
    /// prefixes; `label` names the group they form.
    mutating func bind(_ sequence: String, to command: String, group: String? = nil) {
        let chords = sequence.split(separator: " ").compactMap { KeyChord(parsing: String($0)) }
        guard !chords.isEmpty else { return }
        var node = root
        for (index, chord) in chords.enumerated() {
            if index == chords.count - 1 {
                let leaf = node.children[chord] ?? Node()
                leaf.binding = .command(command)
                node.children[chord] = leaf
                return
            }
            let next = node.children[chord] ?? Node()
            // Don't overwrite a group's name with a later, less specific one.
            if case .prefix = next.binding {} else {
                next.binding = .prefix(group ?? chords[0...index].map(\.description)
                    .joined(separator: " "))
            }
            node.children[chord] = next
            node = next
        }
    }

    /// Name a prefix, so which-key can show something better than the keys.
    mutating func describe(_ sequence: String, as label: String) {
        let chords = sequence.split(separator: " ").compactMap { KeyChord(parsing: String($0)) }
        var node = root
        for chord in chords {
            let next = node.children[chord] ?? Node()
            node.children[chord] = next
            node = next
        }
        node.binding = .prefix(label)
    }

    func lookup(_ chords: [KeyChord]) -> Match {
        var node = root
        for chord in chords {
            guard let next = node.children[chord] else { return .unbound }
            node = next
        }
        if case .command(let id)? = node.binding { return .command(id) }
        guard !node.children.isEmpty else { return .unbound }
        let label: String
        if case .prefix(let name)? = node.binding { label = name } else { label = "" }
        let continuations = node.children
            .compactMap { chord, child -> (KeyChord, KeyBinding)? in
                guard let binding = child.binding else { return nil }
                return (chord, binding)
            }
            .sorted { $0.0.description < $1.0.description }
            .map { (chord: $0.0, binding: $0.1) }
        return .prefix(label: label, continuations: continuations)
    }
}
