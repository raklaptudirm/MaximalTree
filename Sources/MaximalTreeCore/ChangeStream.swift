import Foundation
#if os(macOS)
import CoreServices
#endif

// MARK: - Change streaming

/// A provider that can watch its universe for changes made *outside* the app —
/// another program editing files, a git commit landing, a server mutating.
///
/// The host opens one stream per mounted root the provider owns and feeds every
/// yielded batch into the same `NodeChange` funnel as `notify(_:)`, so external
/// edits refresh caches, sidebars, and open state exactly like the app's own
/// writes. Streams end when the host cancels the consuming task (unmount,
/// workspace switch); implementations should stop their watchers from the
/// stream's `onTermination`.
///
/// Prefer the conservative changes: `.childrenChanged` on a parent and
/// `.modified` on a survivor. Only emit `.removed`/`.renamed` when certain —
/// they tear down open tabs and history, and external event APIs rarely give
/// reliable rename pairing.
public protocol ChangeStreamingProvider: NodeProvider {
    /// A stream of change batches under `root`, or nil when this root can't be
    /// watched. Batches should be coalesced (the built-in watcher does this).
    func changes(under root: NodeID) -> AsyncStream<[NodeChange]>?
}

#if os(macOS)

// MARK: - File tree watcher (FSEvents)

/// A recursive watcher for one directory tree, for providers whose universe
/// lives on disk (the FileSystem provider, the typst agenda). Wraps FSEvents:
/// events are file-level, coalesced by `latency`, and delivered on a private
/// queue — bridge into an `AsyncStream` and let `onTermination` call `stop()`.
public final class FileTreeWatcher: @unchecked Sendable {
    /// One coalesced file-system event.
    public struct Event: Sendable {
        public let path: String
        /// The kernel dropped events — everything under `path` may have changed.
        public let mustRescanSubtree: Bool
    }

    private let onEvents: @Sendable ([Event]) -> Void
    private let queue = DispatchQueue(label: "com.maximaltree.filetreewatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init?(path: String, latency: TimeInterval = 0.5,
                 onEvents: @escaping @Sendable ([Event]) -> Void) {
        self.onEvents = onEvents

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FileTreeWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                .takeUnretainedValue() as? [String] else { return }
            var events: [Event] = []
            for index in 0..<min(count, paths.count) {
                let rescan = eventFlags[index]
                    & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                events.append(Event(path: paths[index], mustRescanSubtree: rescan))
            }
            watcher.onEvents(events)
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer))
        else { return nil }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Idempotent; also called from deinit. After this returns no further
    /// events are delivered.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}

#else

// MARK: - File tree watcher (none)

/// Where there is no FSEvents, nothing is watched: `init` fails, which is what
/// a provider already handles for a path that can't be watched — its stream
/// finishes at once, and the tree is brought up to date by refreshing instead.
/// A real one (inotify on Linux) is for when a host runs there for real.
public final class FileTreeWatcher: @unchecked Sendable {
    public struct Event: Sendable {
        public let path: String
        public let mustRescanSubtree: Bool
    }

    public init?(path: String, latency: TimeInterval = 0.5,
                 onEvents: @escaping @Sendable ([Event]) -> Void) {
        return nil
    }

    public func stop() {}
}

#endif
