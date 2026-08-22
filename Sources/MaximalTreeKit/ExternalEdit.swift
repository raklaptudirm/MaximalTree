import Foundation

/// What an editor should do when its file changes underneath it.
///
/// Files move without the app's help — another editor saves, a `git checkout`
/// lands, a sync client pulls. An open document should follow along, but never
/// at the cost of typing the reader hasn't saved.
///
/// The decision is made by *comparing contents*, never by timing. That matters
/// because the app's own writes come back through the same watcher: saving a
/// file produces a file-system event a moment later, by which time the reader
/// may have typed more. A time window would call that a conflict; comparing
/// against the baseline that was last read or written recognises it as an echo
/// of our own save.
public enum ExternalEdit {
    /// Posted by the host when a node's bytes changed outside the app. The
    /// nonce makes a second change to the same node observable.
    public struct Notice: Equatable, Sendable {
        public let node: NodeID
        public let nonce: UUID

        public init(node: NodeID) {
            self.node = node
            self.nonce = UUID()
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing happened that the reader needs to know about: the file is
        /// unreadable, or it still holds exactly what we last read or wrote.
        case unchanged
        /// Take the file's contents — there are no unsaved edits to lose.
        case reload(String)
        /// The file *and* the buffer have both moved on. Only the reader can
        /// say which one wins.
        case conflict(String)
        /// The file now holds precisely what's on screen — someone saved the
        /// same bytes we already had. Keep the text; it simply isn't unsaved
        /// any more.
        case adoptAsSaved(String)
    }

    /// - Parameters:
    ///   - onDisk: the file's current contents, or nil if it couldn't be read.
    ///   - buffer: what the editor is showing.
    ///   - saved: what was last read from or written to the file.
    public static func outcome(onDisk: String?, buffer: String, saved: String) -> Outcome {
        guard let onDisk else { return .unchanged }
        // The file is as we last left it: this is the echo of our own save
        // arriving, not somebody else's edit — whatever has been typed since.
        if onDisk == saved { return .unchanged }
        if onDisk == buffer { return .adoptAsSaved(onDisk) }
        return buffer == saved ? .reload(onDisk) : .conflict(onDisk)
    }
}
