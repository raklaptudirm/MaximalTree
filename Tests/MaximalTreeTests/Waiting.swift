import Testing
import AppKit

// Waiting for something, rather than for a while.
//
// A fixed sleep is a guess about how long the thing takes, and it is wrong in
// both directions: too long on an idle machine, and too short on a loaded one,
// where the test then fails for no reason of its own. So a test waits for the
// thing itself. Where "the thing" is that nothing happens, it waits for the
// code under test to say it is at rest (`GraphStore.outstanding`,
// `AppModel.commandsRunning`, `FinderModel.gathering`, `Coordinator.isSettled`)
// and checks afterwards.
//
// The limit is not a delay. It is how long to give something before calling it
// broken, and only a failing test ever reaches it.

/// Wait until `condition` holds, recording an issue that says `what` never
/// happened if it doesn't within `limit`. Returns whether it held, for a test
/// that can't go on without it. Checked `every` so often — more slowly for a
/// condition that costs something to ask, like running `ps`.
@MainActor @discardableResult
func waitUntil(_ what: Comment, within limit: Duration = .seconds(10),
               every interval: Duration = .milliseconds(5),
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("\(what)", sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: interval)
    }
    return true
}

/// The same, for something on screen: the window is laid out and displayed
/// each time round, as the app's display cycle would, since a test window
/// gets no display cycle of its own.
@MainActor @discardableResult
func waitUntil(_ what: Comment, in window: NSWindow, within limit: Duration = .seconds(10),
               every interval: Duration = .milliseconds(5),
               sourceLocation: SourceLocation = #_sourceLocation,
               _ condition: () -> Bool) async -> Bool {
    await waitUntil(what, within: limit, every: interval, sourceLocation: sourceLocation) {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return condition()
    }
}

/// Everything already queued on the main queue has run — work deferred to
/// "the next turn" included. For checking that something *didn't* happen
/// when the code under test has no way to say it is at rest: what it would
/// have done a turn later, it has now had the chance to do.
@MainActor
func mainQueueDrained() async {
    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
}
