import Foundation

// MARK: - The reader's own data, on disk

/// A file holding something only the reader has: their workspaces, their
/// bookmarks, what they named a feed. Not a cache — nothing else has a copy, and
/// nothing can fetch it again.
///
/// So it is read under one rule, the same everywhere it applies: **a file that is
/// there but can't be read is never written over.** It is moved aside, beside
/// itself, and whoever opened it says so; the reader starts fresh and can put the
/// old one back. A newer build's format, a branch with a different schema, a file
/// someone edited by hand — all of those read as "can't be read", and every one
/// of them used to be answered by quietly replacing it with an empty one.
///
/// If even moving it aside fails, it stays exactly where it is and the caller must
/// not save at all — a session that can't be kept is a smaller loss than the file.
public enum UserDataFile {
    /// Frozen: these are the three things that can be true of a file, and every
    /// caller has to decide each one. An `@unknown default` would let some
    /// future case drop quietly into "start fresh" — the very thing this exists
    /// to stop.
    @frozen
    public enum Reading<Value> {
        case read(Value)
        /// Nothing was there. Starting fresh loses nothing.
        case missing
        /// It was there and couldn't be read. `keptAt` is where it was moved to,
        /// untouched — or nil if it couldn't be moved, in which case it is still
        /// at its own path and nothing may be written there.
        case unreadable(keptAt: URL?, reason: String)
    }

    public static func read<Value: Decodable>(_ type: Value.Type, from url: URL,
                                              decoder: JSONDecoder = JSONDecoder()) -> Reading<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .read(try decoder.decode(Value.self, from: Data(contentsOf: url)))
        } catch {
            return .unreadable(keptAt: setAside(url), reason: String(describing: error))
        }
    }

    /// Write `value` in place of whatever is there, atomically, making the
    /// directory if it doesn't exist yet. Throws — a save that didn't happen is
    /// something the reader needs to hear about, not a log line.
    public static func write<Value: Encodable>(_ value: Value, to url: URL,
                                               encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Move an unreadable file out of the way, under a name that says what it is
    /// and when it was found: `workspaces.unreadable-2026-10-06T10-15-30.json`.
    /// Never over another set-aside file — the second of two bad launches must not
    /// destroy what the first one kept.
    static func setAside(_ url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: "-")
        for attempt in 0..<1000 {
            let suffix = attempt == 0 ? "" : "-\(attempt + 1)"
            let name = "\(stem).unreadable-\(stamp)\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
            let destination = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            } catch {
                return nil
            }
        }
        return nil
    }
}
