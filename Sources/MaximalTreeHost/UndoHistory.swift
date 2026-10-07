import Foundation

/// What the reader can put back.
///
/// Snapshots rather than inverses, because the host owns the whole of what
/// this covers. A placement table is one small value; keeping the version
/// before a change is exact, and costs less thought than writing an inverse
/// for every operation — `Placements.delete` spills a group's contents into
/// every holder it had, and the inverse of that is not one `adopt`.
///
/// It is also the reason this stops where it does. An inverse can be written
/// for anything; a snapshot can only be taken of state you hold. Deleting a
/// file, renaming one on disk, writing to a server — none of that is here,
/// because putting it back is not ours to promise. A greyed-out Undo is a
/// truthful answer. An Undo that appears to work and doesn't is not.
@MainActor
final class UndoHistory {
    struct Entry: Equatable {
        /// What the change was called where it was made — "Move", "Rename".
        /// `undo()` and `redo()` hand it back, which is where a menu wanting to
        /// say "Undo Move" would read it.
        let label: String
        let placements: Placements
    }

    /// Per workspace, because undoing is about the thing in front of you. An
    /// entry belonging to a workspace you have left should not be able to
    /// reach across and change it while you are not looking.
    private var undoable: [UUID: [Entry]] = [:]
    private var redoable: [UUID: [Entry]] = [:]

    /// Deep enough for a session's worth of rearranging, bounded because a
    /// placement table is small but not free and nothing here is worth a
    /// megabyte of forgotten sidebars.
    static let limit = 50

    func canUndo(in workspace: UUID) -> Bool { !(undoable[workspace] ?? []).isEmpty }
    func canRedo(in workspace: UUID) -> Bool { !(redoable[workspace] ?? []).isEmpty }

    /// Remember the state before a change the reader asked for. Anything else
    /// the app does to the table — healing it on load, following what the
    /// graph mounted — is not a change they made and is not theirs to undo.
    func record(_ label: String, before placements: Placements, in workspace: UUID) {
        push(Entry(label: label, placements: placements), to: &undoable, in: workspace)
        // A new change is a new branch: what was undone is no longer ahead.
        redoable[workspace] = nil
    }

    func takeUndo(in workspace: UUID) -> Entry? { undoable[workspace]?.popLast() }
    func takeRedo(in workspace: UUID) -> Entry? { redoable[workspace]?.popLast() }

    func rememberRedo(_ label: String, _ placements: Placements, in workspace: UUID) {
        push(Entry(label: label, placements: placements), to: &redoable, in: workspace)
    }

    /// Undoing does not itself become something to undo — it moves the other
    /// way, so what it replaces goes back on the undo side.
    func rememberUndo(_ label: String, _ placements: Placements, in workspace: UUID) {
        push(Entry(label: label, placements: placements), to: &undoable, in: workspace)
    }

    /// A workspace that no longer exists takes its history with it.
    func forget(_ workspace: UUID) {
        undoable[workspace] = nil
        redoable[workspace] = nil
    }

    private func push(_ entry: Entry, to stack: inout [UUID: [Entry]], in workspace: UUID) {
        var entries = stack[workspace] ?? []
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        stack[workspace] = entries
    }
}
