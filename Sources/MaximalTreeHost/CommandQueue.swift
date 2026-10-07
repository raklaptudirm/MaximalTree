import Foundation
import MaximalTreeKit

/// One at a time, in the order they were asked for.
///
/// Only what might suspend comes through here. A command that finishes where
/// it was invoked never waits — a key that runs one has always completed
/// before the next keystroke is read, and making it queue would reorder a
/// keymap against itself.
///
/// What this is for is the rest: two writes that interleave leave the graph in
/// an order nobody asked for, and an undo log whose order is not the order
/// things happened in. Serial is the only arrangement in which "undo" means
/// anything.
@MainActor
final class CommandQueue {
    /// The last thing queued. Everything new waits on it, so the chain is the
    /// order of arrival.
    private var tail: Task<Void, Never> = Task {}

    /// A place to put an answer that is only ever written and read on the main
    /// actor — which `Task`'s own result can't be, since `Any` isn't `Sendable`.
    private final class Answer: @unchecked Sendable {
        var result: Result<Any, Error>?
    }

    func serialized(_ work: @escaping @MainActor () async throws -> Any) async throws -> Any {
        let previous = tail
        let answer = Answer()
        let task = Task { @MainActor in
            await previous.value
            do { answer.result = .success(try await work()) }
            catch { answer.result = .failure(error) }
        }
        tail = task
        await task.value
        guard let result = answer.result else {
            throw CancellationError()
        }
        return try result.get()
    }
}

/// A command that failed, on its way to the reader.
struct CommandFailure: Equatable {
    /// What the alert is headed. Most of these are a command that couldn't do
    /// what it was asked; a few are the app telling the reader something about
    /// their data, which deserves to say so.
    var title = "Couldn't Do That"
    let command: String
    let message: String
}
