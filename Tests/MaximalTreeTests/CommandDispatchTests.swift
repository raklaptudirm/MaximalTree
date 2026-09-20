import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// What happened, in the order it happened.
private final class Log: @unchecked Sendable {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    var count: Int { entries.count }
}

/// A command that suspends in the middle, so two of them running at once would
/// be visible in the log as an interleaving.
private struct Slow: Command {
    static let id = "test.slow"
    let log: Log

    @MainActor
    func run(_ input: NodeTargets, in context: ActionContext) async throws -> NoAnswer {
        log.append("start")
        for _ in 0..<5 { await Task.yield() }
        log.append("end")
        return NoAnswer()
    }
}

/// A command that answers, so the typed door has something to hand back.
private struct Echo: Command {
    static let id = "test.echo"

    @MainActor
    func run(_ input: String, in context: ActionContext) async throws -> String {
        "echo: \(input)"
    }
}

private struct Fails: Command {
    static let id = "test.fails"
    struct Broke: Error {}

    @MainActor
    func run(_ input: NodeTargets, in context: ActionContext) async throws -> NoAnswer {
        throw Broke()
    }
}

/// A command that says what went wrong in words meant to be read.
private struct Explains: Command {
    static let id = "test.explains"
    struct Empty: LocalizedError {
        var errorDescription: String? { "The channel has no videos yet." }
    }

    @MainActor
    func run(_ input: NodeTargets, in context: ActionContext) async throws -> NoAnswer {
        throw Empty()
    }
}

/// One id space, two doors: a surface invokes and the host reports what went
/// wrong, a caller invokes and takes the failure with the answer.
@MainActor
@Suite struct CommandDispatchTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.start()
        return model
    }

    /// Let everything already queued finish.
    private func settle() async { for _ in 0..<200 { await Task.yield() } }

    private func context(_ model: AppModel) -> ActionContext {
        ActionContext(host: model.host, targets: [])
    }

    // MARK: Where a command runs

    /// An action written as a closure still runs where it was invoked. A key
    /// that runs one has always finished before the next keystroke is read, and
    /// queueing it would reorder a keymap against itself.
    @Test func anActionWrittenAsAClosureRunsWhereItStands() throws {
        let model = try makeModel()
        let log = Log()
        model.pluginHost.registry.register(action: Action(id: "test.now", title: "Now") { _ in
            log.append("ran")
        })
        model.runCommand("test.now")
        #expect(log.entries == ["ran"], "it did not finish before returning")
    }

    /// And one that might take time waits its turn. Two writes that interleave
    /// leave an undo log whose order is not the order things happened in.
    @Test func commandsThatSuspendRunOneAtATime() async throws {
        let model = try makeModel()
        let log = Log()
        let command = Slow(log: log).erased()

        model.invoke(command, in: context(model))
        model.invoke(command, in: context(model))
        await settle()

        #expect(log.entries == ["start", "end", "start", "end"],
                "they ran into each other: \(log.entries)")
    }

    // MARK: The door a surface uses

    /// The reader pressed a key; they asked for something to happen, not for an
    /// answer. So the host is what tells them it didn't.
    @Test func aFailureFromASurfaceReachesTheReader() async throws {
        let model = try makeModel()
        model.pluginHost.registry.register(Fails())

        model.runCommand("test.fails")
        await settle()

        #expect(model.commandFailure?.command == "test.fails")
        model.dismissCommandFailure()
        #expect(model.commandFailure == nil)
    }

    /// A command that wrote a sentence for this moment gets it read out. The
    /// fallback is `String(describing:)`, which puts a Swift value in front of
    /// the reader — a floor, not an answer.
    @Test func aCommandThatExplainsItselfIsQuoted() async throws {
        let model = try makeModel()
        model.pluginHost.registry.register(Explains())

        model.runCommand("test.explains")
        await settle()

        #expect(model.commandFailure?.message == "The channel has no videos yet.")
    }

    /// A command registered without a title is reached the one way it can be.
    @Test func aCommandWithNoPresentationRunsByID() async throws {
        let model = try makeModel()
        let log = Log()
        model.pluginHost.registry.register(Slow(log: log))

        model.runCommand("test.slow")
        await settle()

        #expect(log.entries == ["start", "end"])
    }

    @Test func anIDNobodyRegisteredDoesNothing() async throws {
        let model = try makeModel()
        model.runCommand("test.nothing")
        await settle()
        #expect(model.commandFailure == nil, "it complained about a key that is simply unbound")
    }

    // MARK: The door a caller uses

    @Test func aCallerGetsTheAnswerBack() async throws {
        let model = try makeModel()
        model.pluginHost.registry.register(Echo())
        let answer = try await model.host.perform(Echo.self, "hello")
        #expect(answer == "echo: hello")
    }

    /// And the failure, rather than the host putting it in front of the reader.
    @Test func aCallerTakesTheFailureWithIt() async throws {
        let model = try makeModel()
        model.pluginHost.registry.register(Fails())

        await #expect(throws: Fails.Broke.self) {
            _ = try await model.host.perform(Fails.self, NodeTargets(nodes: []))
        }
        #expect(model.commandFailure == nil, "it was reported to the reader as well")
    }

    @Test func askingForACommandNobodyRegisteredThrows() async throws {
        let model = try makeModel()
        await #expect(throws: CommandError.noSuchCommand(command: "test.echo")) {
            _ = try await model.host.perform(Echo.self, "hello")
        }
    }
}
