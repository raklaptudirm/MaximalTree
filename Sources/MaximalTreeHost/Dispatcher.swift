import Foundation
import Observation
import MaximalTreeKit

/// What a key press is pointing at: a pane means the node it shows, a list the
/// row it has highlighted, nil the selection. A shell's to say.
@MainActor
protocol KeyTargeting: AnyObject {
    func keyTargets() -> [NodeID]?
}

/// What happens when an operation is asked for: which actions apply to what,
/// running them, and telling the reader when one didn't work.
///
/// Every way in comes here — a key, a menu, the finder, a plugin calling
/// `host.perform` — so "what happens when this id is invoked" has one answer.
/// It is the engine's, not the window's: a shell decides what the reader is
/// pointing at, and this decides what that means.
@MainActor
@Observable
final class Dispatcher {
    let host: HostContext
    let registry: CoreContributions

    /// Commands that might suspend, one at a time — see `CommandQueue`.
    let queue = CommandQueue()
    /// Commands invoked from a surface that haven't finished, failures
    /// reported included. Zero means everything asked for so far has been
    /// done or said — what a test waits for instead of a guessed delay.
    @ObservationIgnored private(set) var running = 0

    /// The last command that failed, or the last thing the reader needs to
    /// hear, until they wave it away.
    ///
    /// A key or a menu item has nowhere to put an error: whoever pressed it
    /// asked for something to happen, not for an answer, so the host is the
    /// one that has to say it didn't.
    private(set) var failure: CommandFailure?
    /// What else is waiting to be said, in the order it came. Two things can
    /// go wrong at once — on a launch where nothing can be read, everything
    /// does — and the second must not quietly replace the first.
    @ObservationIgnored private var waiting: [CommandFailure] = []

    /// Who says what a key press acts on — the shell, the one that knows
    /// which surface has the keyboard. With nobody, a key acts on the
    /// selection.
    @ObservationIgnored weak var keyTargeting: KeyTargeting?
    private func keyTargets() -> [NodeID]? { keyTargeting?.keyTargets() }

    init(host: HostContext, registry: CoreContributions) {
        self.host = host
        self.registry = registry
    }

    // MARK: What applies

    /// Actions (from any plugin) that apply to `targets`, defaulting to the
    /// current selection. One registry feeds the menu bar, the palette, the
    /// sidebar context menu, and the inspector.
    func applicableActions(for targets: [NodeID]? = nil) -> [Action] {
        registry.actions.filter { context(for: $0, targets: targets) != nil }
    }

    /// The context an action would run with, or nil if it doesn't apply.
    ///
    /// The one place that asks "does this apply, and to what?". Everything
    /// else — the list of what's applicable, whether a menu item is greyed
    /// out, running one by id, running one from a menu — is that question
    /// asked once and answered differently. It used to be four copies of the
    /// same loop, which is three places for the answer to drift.
    func context(for action: Action, targets: [NodeID]?, count: Int = 1) -> ActionContext? {
        targetVariants(for: targets)
            .first { action.appliesTo.matches(ActionContext(host: host, targets: $0, count: count)) }
            .map { ActionContext(host: host, targets: $0, count: count) }
    }

    /// The nodes as clicked, and as each identity they also are — so a git
    /// repository is offered to the file actions as the directory it is.
    private func targetVariants(for targets: [NodeID]?) -> [[NodeID]] {
        let resolved = targets ?? host.selection
        return ActionTargets.variants(for: resolved) { host.node($0)?.identities ?? [] }
    }

    /// The applicable actions a surface should show, in sections — see
    /// `ActionOrganizer` for what decides the order.
    func actionGroups(for surface: ActionSurfaces, targets: [NodeID]? = nil) -> [ActionGroup] {
        let node = targets?.first ?? host.focusedNode
        return ActionOrganizer.groups(applicableActions(for: targets), for: surface,
                                      preferredOwner: registry.owner(of: node))
    }

    /// One registered action by id, for the surfaces that place a particular
    /// operation deliberately rather than listing whatever applies.
    func action(_ id: String) -> Action? {
        registry.actions.first { $0.id == id }
    }

    /// Whether this action can be run against what is in front of you — what
    /// greys out a menu item, and what keeps the finder from offering it.
    func canRun(_ action: Action, targets: [NodeID]? = nil) -> Bool {
        context(for: action, targets: targets) != nil
    }

    // MARK: Running

    /// Invoke an action against the first set of targets it accepts.
    ///
    /// A node is offered as each identity it also is (see `targetVariants`), so
    /// a git repository can be handed to an action written for directories.
    func perform(_ action: Action, targets: [NodeID]? = nil, count: Int = 1) {
        invoke(action.command,
               in: context(for: action, targets: targets, count: count)
                   ?? ActionContext(host: host, targets: targets, count: count))
    }

    /// Run an operation by id, from a key or from a plugin.
    ///
    /// Applicable ones only, so a key bound to something that doesn't apply
    /// here does nothing rather than something surprising — which is also how
    /// the explorer motions stay the sidebar's own.
    func runCommand(_ id: String, count: Int = 1) {
        let targets = keyTargets()
        if let action = action(id) {
            guard canRun(action, targets: targets) else { return }
            perform(action, targets: targets, count: count)
            return
        }
        // A command registered without presentation: nothing lists it, so
        // there is no predicate to ask — being invoked by id is the whole of
        // how it is reached.
        guard let command = registry.command(id) else { return }
        invoke(command, in: ActionContext(host: host, targets: targets, count: count))
    }

    /// Run an operation by id with an argument that arrived as data — what a
    /// finder item carries, and what a keymap or a script will carry.
    ///
    /// Applicability is not asked here: a command reached this way names what
    /// it acts on rather than taking whatever is in front of the reader, so
    /// there is no selection for a predicate to have an opinion about.
    func runCommand(_ id: String, with argument: CommandValue) {
        guard let command = registry.command(id) else { return }
        let context = ActionContext(host: host, targets: keyTargets())
        later(reportingAs: id) { try await command.run(value: argument, in: context) }
    }

    /// Run a command from a surface — a key, a menu, the palette.
    ///
    /// Nothing is handed back, because nothing asked for anything back, and a
    /// failure goes to the reader rather than to the caller. One that finishes
    /// where it stands does so; one that might take time takes its turn.
    func invoke(_ command: AnyCommand, in context: ActionContext) {
        let input = NodeTargets(nodes: context.targets, count: context.count)
        do {
            if try command.runImmediately(input, in: context) != nil { return }
        } catch {
            report(error, from: command.id)
            return
        }
        later(reportingAs: command.id) { try await command.run(input, in: context) }
    }

    /// Run a command with its argument from a surface — a name committed, rows
    /// dropped — and tell the reader if it didn't work, as a key's command
    /// does. The view says what was asked for; whether and how is the
    /// command's.
    func invoke<C: Command>(_ command: C.Type, _ input: C.Input) {
        guard let registered = registry.command(C.id) else {
            report(CommandError.noSuchCommand(command: C.id), from: C.id)
            return
        }
        let context = ActionContext(host: host, targets: nil)
        later(reportingAs: C.id) { try await registered.run(input, in: context) }
    }

    /// Run a command by id and wait for its answer — the door for a caller
    /// that wants the result, and takes the failure with it.
    func run(commandID id: String, input: Any) async throws -> Any {
        guard let command = registry.command(id) else {
            throw CommandError.noSuchCommand(command: id)
        }
        let context = action(id).flatMap { self.context(for: $0, targets: nil) }
            ?? ActionContext(host: host, targets: nil)
        if let answer = try command.runImmediately(input, in: context) { return answer }
        return try await queue.serialized { try await command.run(input, in: context) }
    }

    /// Take a turn in the queue, and say so if it fails.
    private func later(reportingAs id: String,
                       _ work: @escaping @MainActor () async throws -> Any) {
        running += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { running -= 1 }
            do {
                _ = try await queue.serialized(work)
            } catch {
                report(error, from: id)
            }
        }
    }

    // MARK: Telling the reader

    /// What the reader is told, in the order of who took the trouble to say it.
    ///
    /// A command's own `LocalizedError` comes first, because a plugin that
    /// wrote a sentence for this moment meant it to be read. `String(describing:)`
    /// is the floor, and it shows: `refused("no such channel")` is a Swift
    /// value, not something to put in front of anybody. Anything reaching that
    /// floor is a command that should have described itself.
    func report(_ error: Error, from command: String) {
        let message = (error as? CommandError)?.description
            ?? (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        show(CommandFailure(command: command, message: message))
    }

    /// Say something about the reader's data that no command failed to do.
    func notice(_ notice: Notice) {
        show(CommandFailure(title: notice.title, command: notice.source, message: notice.message))
    }

    func dismissFailure() {
        failure = nil
        guard !waiting.isEmpty else { return }
        // On the next turn rather than this one, so the alert being dismissed
        // is taken down before the next is put up in its place.
        Task { @MainActor [weak self] in self?.showWaiting() }
    }

    private func show(_ failure: CommandFailure) {
        if self.failure == nil { self.failure = failure } else { waiting.append(failure) }
    }

    private func showWaiting() {
        guard failure == nil, !waiting.isEmpty else { return }
        failure = waiting.removeFirst()
    }
}
