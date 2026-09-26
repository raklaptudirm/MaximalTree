import Foundation

// MARK: - Commands

/// An invocable with types: an argument it takes, an answer it gives, and an id
/// it answers to.
///
/// The app's operations were closures over a context — fine for a menu item,
/// which has nothing to say beyond "do it to the selection", and not enough for
/// anything a canvas does. Renaming needs a name, inserting needs a position,
/// creating needs to hand back what it created so the caller can focus it, and
/// anything reaching a network needs to be able to fail out loud.
///
/// Addressed by `id` rather than by reference, so the same body serves a key,
/// the palette, a script, and one plugin calling another's verb without
/// linking against it.
public protocol Command {
    /// What it is given. Defaults to the nodes it was invoked on, which is what
    /// nearly every action written before commands wanted.
    associatedtype Input: Codable & Sendable = NodeTargets

    /// What it answers.
    ///
    /// An answer, never an effect. What a command *changed* is reported on the
    /// `NodeChange` funnel — the one `apply`, `notify(_:)`, and a provider's
    /// change stream all feed. That isn't a matter of taste: a change observed
    /// from outside the app has no invoker and so no answer, so behaviour built
    /// on a returned effect works for edits the app made and silently does
    /// nothing for edits it merely noticed, which is the difference the funnel
    /// exists to erase.
    ///
    /// `Codable` is what keeps that honest rather than merely agreed —
    /// `NodeChange` isn't `Codable`, so answering with one doesn't compile.
    associatedtype Output: Codable & Sendable = NoAnswer

    /// How it is addressed. Namespaced by convention: `file.rename`.
    static var id: String { get }

    @MainActor
    func run(_ input: Input, in context: ActionContext) async throws -> Output
}

/// The argument nearly every command takes: what it was invoked on, and how
/// many times it was asked for (a key can carry a count — `5 j` walks five
/// rows).
public struct NodeTargets: Codable, Sendable, Equatable {
    public var nodes: [NodeID]
    public var count: Int

    public init(nodes: [NodeID], count: Int = 1) {
        self.nodes = nodes
        self.count = max(count, 1)
    }

    /// Never zero, however it arrived. A handler can multiply by the count
    /// without checking it — which only holds if the invariant survives being
    /// read out of a keymap as well as being built in code.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([NodeID].self, forKey: .nodes) ?? []
        count = max(try container.decodeIfPresent(Int.self, forKey: .count) ?? 1, 1)
    }
}

/// The answer of a command that has nothing to say.
///
/// `Void` can't be `Codable`, and in any case an absent answer is still a
/// value: it has to survive being written down and read back like any other.
public struct NoAnswer: Codable, Sendable, Equatable {
    public init() {}
}

/// What went wrong before a command's own body ever ran.
public enum CommandError: Error, Equatable {
    /// The argument wasn't the type this command takes. A caller's mistake, and
    /// it throws rather than quietly doing nothing — a command that declines in
    /// silence is one you find by bisecting your own interface.
    case wrongArgument(command: String)
    /// The argument arrived as data that couldn't be read as what the command
    /// takes. Carries both halves of what a caller needs: which command turned
    /// it down, and what the decoder made of it — a keymap with a misspelled
    /// field is otherwise a silent no-op to whoever wrote the keymap.
    case unreadableArgument(command: String, reason: String)
    /// The answer couldn't be written down.
    case unwritableAnswer(command: String, reason: String)
    /// The answer wasn't the type the caller expected. Only a typed caller can
    /// hit this, and only by naming a command whose id belongs to a different
    /// one than the type it asked for.
    case wrongAnswer(command: String)
    /// Nothing is registered under that id.
    case noSuchCommand(command: String)
}

extension CommandError: CustomStringConvertible {
    /// Written for the person who has to act on it, since this is what the
    /// host puts in front of them when a command invoked from a key or a menu
    /// fails — they didn't ask a question, so the answer has to explain itself.
    public var description: String {
        switch self {
        case .wrongArgument(let command):
            return "\(command) was given the wrong kind of argument."
        case .unreadableArgument(let command, let reason):
            return "\(command) couldn't read its argument: \(reason)"
        case .unwritableAnswer(let command, let reason):
            return "\(command) couldn't write down its answer: \(reason)"
        case .wrongAnswer(let command):
            return "\(command) answered with something else than was expected."
        case .noSuchCommand(let command):
            return "There is no command called \(command)."
        }
    }
}

// MARK: - A value crossing the boundary

/// An argument on its way in, or an answer on its way out, as plain data.
///
/// An enum built up from its own cases, never bridged from `Any`. A bridged
/// cast tests `Bool` before `NSNumber` and so reads every 0 and 1 as a flag,
/// which is a bug to find in a parser and a catastrophe to find in the type
/// every operation's arguments travel through.
public enum CommandValue: Sendable, Equatable {
    case nothing
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([CommandValue])
    case fields([String: CommandValue])
}

extension CommandValue: Codable {
    /// Transparent on the wire: `.string("x")` is `"x"` and `.fields([…])` is an
    /// object, not a tagged union. What a keymap or a script writes is what the
    /// command's own `Codable` argument expects to read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .nothing; return }
        // The order of these is not what keeps a 1 from arriving as a flag —
        // the decoder is strict in both directions, so `true` is not a number
        // to it and 1 is not a bool, and swapping these two changes nothing.
        // What keeps it honest is that nothing here bridges from `Any`, and
        // `aNumberIsNotAFlag` is what would notice if that stopped being true.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([CommandValue].self) { self = .list(value); return }
        if let value = try? container.decode([String: CommandValue].self) { self = .fields(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "Not a command value.")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .nothing: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .fields(let value): try container.encode(value)
        }
    }
}

/// Between a command's own argument type and the data form of it.
///
/// Both directions handle a bare `3` or `"x"` as readily as an object: a
/// command that takes one string takes one string, and `anArgumentThatIsNotAn`
/// `ObjectStillTravels` is what would notice if a toolchain ever stopped
/// allowing a JSON value to stand alone.
enum CommandCoding {
    static func decode<T: Decodable>(_ type: T.Type, from value: CommandValue,
                                     command: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
        } catch {
            throw CommandError.unreadableArgument(command: command,
                                                  reason: String(describing: error))
        }
    }

    static func encode<T: Encodable>(_ value: T, command: String) throws -> CommandValue {
        do {
            return try JSONDecoder().decode(CommandValue.self,
                                            from: try JSONEncoder().encode(value))
        } catch {
            throw CommandError.unwritableAnswer(command: command,
                                                reason: String(describing: error))
        }
    }
}

// MARK: - One registry, any command

/// A command with its types packed away, so one registry can hold all of them.
///
/// Two ways in, because there are two kinds of caller. Code that has the
/// command's own argument hands it over as it is — nothing is serialized, and
/// the answer comes back whole. A key, a script, a recorded invocation, or (once
/// plugins are loaded bundles rather than compiled in) anything across a
/// boundary with no shared type, hands over data instead.
public struct AnyCommand {
    public let id: String

    private let typed: @MainActor (Any, ActionContext) async throws -> Any
    private let valued: @MainActor (CommandValue, ActionContext) async throws -> CommandValue
    /// The same body again, for a command that finishes without suspending.
    ///
    /// Not an optimisation. A key that runs one of these has always completed
    /// before the next keystroke is read, and putting it on a queue instead
    /// would reorder a keymap against itself. So the ones that can still run
    /// where they always did, and only what might take time waits its turn.
    private let now: (@MainActor (Any, ActionContext) throws -> Any)?

    init(id: String,
         typed: @escaping @MainActor (Any, ActionContext) async throws -> Any,
         valued: @escaping @MainActor (CommandValue, ActionContext) async throws -> CommandValue,
         now: (@MainActor (Any, ActionContext) throws -> Any)? = nil) {
        self.id = id
        self.typed = typed
        self.valued = valued
        self.now = now
    }

    /// Run it here, without suspending. `nil` means it can't — it has to take
    /// its turn like anything else that might take time.
    @MainActor
    public func runImmediately(_ input: Any, in context: ActionContext) throws -> Any? {
        try now?(input, context)
    }

    /// Run it with the argument it expects, unserialized. `input` must be the
    /// command's own `Input`.
    @MainActor
    public func run(_ input: Any, in context: ActionContext) async throws -> Any {
        try await typed(input, context)
    }

    /// Run it with an argument that arrived as data, and get the answer back the
    /// same way.
    @MainActor
    public func run(value: CommandValue, in context: ActionContext) async throws -> CommandValue {
        try await valued(value, context)
    }
}

public extension Command {
    /// Pack this command's types away.
    ///
    /// On the main actor because that is where a command is registered and
    /// where its body runs: erasing anywhere else would mean handing the
    /// command itself across isolation, and a command is free to hold things
    /// that can't make that trip.
    @MainActor
    func erased() -> AnyCommand { erased(id: Self.id) }

    /// As above, under an id that isn't the type's own — which only the shim
    /// below needs, since an action's id belongs to the action.
    @MainActor
    func erased(id: String) -> AnyCommand {
        AnyCommand(
            id: id,
            typed: { input, context in
                guard let input = input as? Input else {
                    throw CommandError.wrongArgument(command: id)
                }
                return try await run(input, in: context)
            },
            valued: { value, context in
                let input = try CommandCoding.decode(Input.self, from: value, command: id)
                return try CommandCoding.encode(try await run(input, in: context), command: id)
            })
    }
}

public extension AnyCommand {
    /// A command written as a closure over the context, for the many
    /// operations whose whole argument is "the nodes you are pointing at".
    ///
    /// That argument is not discarded, which is the difference between this
    /// and the shim below: an invocation that names its own nodes gets a
    /// context saying so, so `file.delete` with two ids deletes those two
    /// whatever happens to be selected. That is what makes these reachable
    /// from a script and a keymap rather than only from a click.
    ///
    /// Synchronous, so it runs where it was invoked — a key that runs one has
    /// always finished before the next keystroke is read. The overload below
    /// is for a body that has to wait, and that one takes its turn.
    static func running(id: String,
                        _ body: @escaping @MainActor (ActionContext) throws -> Void) -> AnyCommand {
        AnyCommand(
            id: id,
            typed: { input, context in
                try body(context.acting(on: Self.targets(input, id))); return NoAnswer()
            },
            valued: { value, context in
                let input = try CommandCoding.decode(NodeTargets.self, from: value, command: id)
                try body(context.acting(on: input)); return .fields([:])
            },
            now: { input, context in
                try body(context.acting(on: Self.targets(input, id))); return NoAnswer()
            })
    }

    /// The same, for a body that has to wait for something.
    static func running(id: String,
                        _ body: @escaping @MainActor (ActionContext) async throws -> Void) -> AnyCommand {
        AnyCommand(
            id: id,
            typed: { input, context in
                try await body(context.acting(on: Self.targets(input, id))); return NoAnswer()
            },
            valued: { value, context in
                let input = try CommandCoding.decode(NodeTargets.self, from: value, command: id)
                try await body(context.acting(on: input)); return .fields([:])
            })
    }

    private static func targets(_ input: Any, _ id: String) throws -> NodeTargets {
        guard let input = input as? NodeTargets else {
            throw CommandError.wrongArgument(command: id)
        }
        return input
    }
}
