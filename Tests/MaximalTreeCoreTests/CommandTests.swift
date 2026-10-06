import Testing
import Foundation
// Built by both runners: on its own by `swift test`, where the core is its own
// module, and in the app's suite, where it is part of MaximalTreeKit.
#if canImport(MaximalTreeCore)
@testable import MaximalTreeCore
#else
@testable import MaximalTreeKit
#endif

/// A command that needs an argument no context could supply — which is the whole
/// reason commands exist.
private struct Rename: Command {
    struct Input: Codable, Sendable, Equatable {
        var target: NodeID
        var name: String
    }
    typealias Output = String
    static let id = "test.rename"

    @MainActor
    func run(_ input: Input, in context: ActionContext) async throws -> Output {
        "\(input.target.uri) -> \(input.name)"
    }
}

/// A command that takes the default argument and says nothing back.
private struct Touch: Command {
    static let id = "test.touch"
    let seen: Seen

    @MainActor
    func run(_ input: NodeTargets, in context: ActionContext) async throws -> NoAnswer {
        seen.record(input)
        return NoAnswer()
    }
}

/// What a command was handed, kept where a test can read it.
private final class Seen: @unchecked Sendable {
    private(set) var targets: [NodeTargets] = []
    private(set) var contexts: [[NodeID]] = []
    func record(_ targets: NodeTargets) { self.targets.append(targets) }
    @MainActor func record(context: ActionContext) { contexts.append(context.targets) }
}

@MainActor
@Suite struct CommandTests {
    private let host = HostContext()
    private func context(_ targets: [NodeID] = []) -> ActionContext {
        ActionContext(host: host, targets: targets)
    }

    private func node(_ uri: String) -> NodeID { NodeID(uri)! }

    // MARK: The typed way in

    @Test func aCommandRunsWithTheArgumentItExpects() async throws {
        let input = Rename.Input(target: node("file:///tmp/a.txt"), name: "b.txt")
        let answer = try await Rename().erased().run(input, in: context())
        #expect(answer as? String == "file:///tmp/a.txt -> b.txt")
    }

    /// A caller handing over the wrong type is a bug, and it says so. A command
    /// that declined in silence would be found by bisecting the interface.
    @Test func anArgumentOfTheWrongTypeIsRefused() async throws {
        let command = Rename().erased()
        await #expect(throws: CommandError.wrongArgument(command: "test.rename")) {
            _ = try await command.run("not what it takes", in: context())
        }
    }

    // MARK: The way in for an argument that arrived as data

    @Test func aCommandRunsFromDataAndAnswersAsData() async throws {
        let answer = try await Rename().erased().run(
            value: .fields(["target": .string("file:///tmp/a.txt"), "name": .string("b.txt")]),
            in: context())
        #expect(answer == .string("file:///tmp/a.txt -> b.txt"))
    }

    /// And says which command turned it down. A keymap with a misspelled field
    /// is otherwise a silent no-op to the person who wrote the keymap.
    @Test func dataThatIsNotTheArgumentIsRefused() async throws {
        let command = Rename().erased()
        let thrown = await #expect(throws: CommandError.self) {
            _ = try await command.run(value: .fields(["name": .number(3)]), in: context())
        }
        guard case .unreadableArgument(let named, let reason)? = thrown else {
            Issue.record("not an unreadable argument: \(String(describing: thrown))")
            return
        }
        #expect(named == "test.rename")
        #expect(reason.contains("target"))
    }

    /// The default argument is the nodes it was invoked on, so a command that
    /// wants only those declares nothing.
    @Test func theDefaultArgumentIsTheNodesItWasInvokedOn() async throws {
        let seen = Seen()
        _ = try await Touch(seen: seen).erased().run(
            value: .fields(["nodes": .list([.string("file:///tmp/a.txt")]), "count": .number(3)]),
            in: context())
        #expect(seen.targets == [NodeTargets(nodes: [node("file:///tmp/a.txt")], count: 3)])
    }

    /// The count is never zero, however it arrived — a handler multiplies by it
    /// without checking, and a keymap is as much a source as code is.
    @Test func theCountIsNeverZero() throws {
        let none = try CommandCoding.decode(NodeTargets.self,
                                            from: .fields(["count": .number(0)]), command: "t")
        #expect(none == NodeTargets(nodes: [], count: 1))
        let absent = try CommandCoding.decode(NodeTargets.self, from: .fields([:]), command: "t")
        #expect(absent.count == 1)
    }

    // MARK: What a value is on the wire

    /// Transparent, not a tagged union: what a keymap or a script writes is
    /// what the command's own argument type expects to read.
    @Test func aValueIsTransparentOnTheWire() throws {
        let data = try JSONEncoder().encode(CommandValue.fields(["name": .string("b.txt")]))
        #expect(String(data: data, encoding: .utf8) == #"{"name":"b.txt"}"#)
    }

    /// The bug this type was shaped to avoid: bridging from `Any` tests `Bool`
    /// before `NSNumber`, so every 0 and 1 arrives as a flag.
    @Test func aNumberIsNotAFlag() throws {
        #expect(try CommandCoding.encode(1, command: "test") == .number(1))
        #expect(try CommandCoding.encode(0, command: "test") == .number(0))
        #expect(try CommandCoding.encode(true, command: "test") == .bool(true))
        #expect(try CommandCoding.encode(false, command: "test") == .bool(false))
    }

    /// An argument doesn't have to be an object. A command that takes a single
    /// string takes a single string, and it has to survive the trip as one.
    @Test func anArgumentThatIsNotAnObjectStillTravels() throws {
        #expect(try CommandCoding.encode("b.txt", command: "t") == .string("b.txt"))
        #expect(try CommandCoding.decode(String.self, from: .string("b.txt"), command: "t") == "b.txt")
        #expect(try CommandCoding.decode(Int.self, from: .number(7), command: "t") == 7)
    }

    @Test func everyKindOfValueSurvivesTheRoundTrip() throws {
        let value = CommandValue.fields([
            "nothing": .nothing,
            "flag": .bool(true),
            "count": .number(-2.5),
            "name": .string("b.txt"),
            "nodes": .list([.string("a"), .number(1), .nothing]),
        ])
        #expect(try CommandCoding.decode(CommandValue.self, from: value, command: "test") == value)
    }

    /// A node is its URI on the wire, so an argument naming one is writable by
    /// hand — and reading it canonicalizes, so a URI from outside the app is
    /// held to the same rule as one built inside it.
    @Test func aNodeTravelsAsItsURI() throws {
        let data = try JSONEncoder().encode([node("file:///tmp/a.txt")])
        #expect(String(data: data, encoding: .utf8) == #"["file:\/\/\/tmp\/a.txt"]"#)

        let loose = try JSONDecoder().decode([NodeID].self,
                                             from: Data(#"["youtube://channel/x/"]"#.utf8))
        #expect(loose == [node("youtube://channel/x")])
    }

    // MARK: What every action carries

    /// An action written as a closure is a command, and it acts on what it is
    /// handed rather than on whatever was selected when it was invoked.
    @Test func anActionActsOnWhatItIsHanded() async throws {
        let seen = Seen()
        let action = Action(id: "test.closure", title: "Closure") { ctx in
            seen.record(context: ctx)
        }
        #expect(action.command.id == "test.closure")

        _ = try await action.command.run(NodeTargets(nodes: [node("file:///tmp/a.txt")]),
                                         in: context([node("file:///tmp/selected.txt")]))
        #expect(seen.contexts == [[node("file:///tmp/a.txt")]])
    }
}
