import Foundation

/// Where a document's *project* begins.
///
/// Typst refuses to read anything outside the compilation root, so the root
/// decides which imports are legal. Compiling each file against its own
/// directory — the obvious choice, and what this did first — makes
/// `#import "../shared.typ"` fail with "escapes project root", which is a
/// normal way to organize notes: shared definitions above, documents in
/// folders below.
///
/// The root can't simply be widened, though. Relative imports resolve against
/// the *importing file's* directory, so the engine also has to be told where
/// the document sits inside the root (see `mainPath(of:in:)`); otherwise a
/// widened root would break the sibling imports that used to work.
enum TypstProject {
    /// The compilation root for `document`:
    ///
    /// 1. the nearest ancestor holding a `typst.toml` — an explicit statement
    ///    that this directory is the project;
    /// 2. otherwise the mounted workspace root containing it, which is the
    ///    scope the user chose when they added the folder;
    /// 3. otherwise its own directory, which is where this started.
    ///
    /// Never above a mounted root: everything under the root is readable by
    /// the compiled document, and the workspace is the boundary the user drew.
    static func root(for document: URL, mountedRoots: [URL] = []) -> URL {
        let directory = document.deletingLastPathComponent().standardizedFileURL
        let workspace = enclosingRoot(of: directory, in: mountedRoots)

        var candidate = directory
        while true {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("typst.toml").path) {
                return candidate
            }
            // Stop at the workspace (or at the document's own directory when
            // it isn't in one) rather than walking up to the volume.
            if candidate.path == (workspace?.path ?? directory.path) { break }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return workspace ?? directory
    }

    /// Where `document` sits inside `root`, as an absolute virtual path
    /// ("/notes/today.typ"). Falls back to "/main.typ" when the document isn't
    /// under the root at all, which is what unsaved and synthetic sources get.
    static func mainPath(of document: URL, in root: URL) -> String {
        let file = document.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard file.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            return "/main.typ"
        }
        return String(file.dropFirst(base.hasSuffix("/") ? base.count - 1 : base.count))
    }

    /// The innermost mounted root containing `directory`.
    private static func enclosingRoot(of directory: URL, in roots: [URL]) -> URL? {
        roots
            .map(\.standardizedFileURL)
            .filter { root in
                let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
                return directory.path == root.path || directory.path.hasPrefix(base)
            }
            .max { $0.path.count < $1.path.count }
    }
}
