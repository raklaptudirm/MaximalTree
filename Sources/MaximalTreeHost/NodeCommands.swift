import Foundation
import MaximalTreeKit

// What the host's own views do to a node, as commands.
//
// The sidebar and the inspector used to write straight to the graph — a
// rename committed, rows dropped on a row — which is the one thing a plugin
// canvas is not allowed to do. As commands they are the engine's: a key, a
// script, `mtree`, or a shell on another machine reaches them by id with an
// argument, and a view only says what was asked for.

/// Give a node a new name, if whoever owns it lets it have one.
struct RenameNode: Command {
    struct Input: Codable, Sendable {
        var node: NodeID
        var name: String
    }

    static let id = "node.rename"

    struct Refused: LocalizedError {
        let label: String
        var errorDescription: String? { "“\(label)” can't be renamed." }
    }

    @MainActor
    func run(_ input: Input, in context: ActionContext) async throws -> NoAnswer {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name, or the one it already has, is not asking for
        // anything — a field committed without a change.
        let current = context.host.node(input.node)?.label
        guard !name.isEmpty, name != current else { return NoAnswer() }
        let rename = GraphMutation.rename(input.node, to: name)
        guard context.canApply(rename) else { throw Refused(label: current ?? input.node.uri) }
        context.apply(rename)
        return NoAnswer()
    }
}

/// Let go of nodes over another node: it moves them into itself, or keeps
/// them as members, as it does with what is dropped on it.
struct DropNodes: Command {
    struct Input: Codable, Sendable {
        var nodes: [NodeID]
        var onto: NodeID
    }

    static let id = "node.drop"

    struct Refused: LocalizedError {
        let label: String
        var errorDescription: String? { "“\(label)” doesn't take that." }
    }

    /// Adoption when the target keeps members, a move when it only contains.
    ///
    /// The target decides, because the target is the one that means something
    /// by the drop. A folder on disk takes a file by moving it there; an
    /// aggregator takes a channel by remembering it, and the channel stays
    /// wherever else it already was. Dropped onto the end of the collection:
    /// a row is "into this", and where among the members is the collection's
    /// own view to offer.
    ///
    /// Asked by a view too, before it accepts a drop — `canApply` on this is a
    /// question, and a view may ask questions.
    static func mutation(dropping ids: [NodeID], onto target: NodeID,
                         accepts: AcceptedChildren?) -> GraphMutation {
        accepts == nil ? .move(ids, into: target) : .adopt(ids, into: target, at: nil)
    }

    @MainActor
    func run(_ input: Input, in context: ActionContext) async throws -> NoAnswer {
        guard !input.nodes.isEmpty else { return NoAnswer() }
        let target = context.host.node(input.onto)
        let drop = Self.mutation(dropping: input.nodes, onto: input.onto, accepts: target?.accepts)
        guard context.canApply(drop) else { throw Refused(label: target?.label ?? input.onto.uri) }
        context.apply(drop)
        return NoAnswer()
    }
}
