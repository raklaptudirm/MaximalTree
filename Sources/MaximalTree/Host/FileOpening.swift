import Foundation
import MaximalTreeKit

/// Where a file opened from outside the app belongs.
///
/// Double-clicking a file in the Finder is a question the app has to answer
/// before it can show anything: is this part of something you already work in,
/// or is it a stray? A file inside a mounted root belongs to that root's
/// workspace and should open *there*, with the sidebar and the rest of the
/// project around it. A file that no workspace mounts has no project to open
/// in, and gets a window of its own.
///
/// Decided from the roots rather than from what happens to be open, because
/// roots persist: a project you mounted last month still claims its files on a
/// cold launch, when nothing is open at all.
enum FileOpening {
    /// The workspace that mounts `url`, if one does.
    ///
    /// The *innermost* one wins. Roots nest — a repository mounted inside a
    /// mounted home directory — and the nearer root is the more specific
    /// answer, the same rule the sidebar and the Typst compiler root already
    /// use.
    static func owner(of url: URL, in workspaces: [Workspace]) -> Workspace? {
        let path = url.standardizedFileURL.path
        var best: (workspace: Workspace, depth: Int)?

        for workspace in workspaces {
            for root in workspace.rootURIs {
                for rootPath in directories(named: root) where contains(rootPath, path) {
                    if best == nil || rootPath.count > best!.depth {
                        best = (workspace, rootPath.count)
                    }
                }
            }
        }
        return best?.workspace
    }

    /// The directories a root URI names, if it names any.
    ///
    /// A workspace does not only mount `file://` roots. A repository is mounted
    /// as `git://repo?repo=/path/to/repo` and a terminal as
    /// `terminal://session/<id>?cwd=/path`: the same directory seen through a
    /// different provider, and a file inside one is just as much part of that
    /// workspace. Matching `file://` alone sent every file in a git-mounted
    /// project to a window of its own, past the project it plainly belongs to.
    ///
    /// Read generically rather than per scheme, because the host doesn't know
    /// what `git://` is and shouldn't have to learn: a root names a place if
    /// it is a file URL, or if one of its query values is an absolute path.
    /// New providers get this for free as long as they say where they are.
    private static func directories(named root: String) -> [String] {
        guard let url = URL(string: root) else { return [] }
        if url.isFileURL { return [url.standardizedFileURL.path] }
        // Percent-decoded by `queryItems`, so a path with spaces arrives whole.
        return (URLComponents(string: root)?.queryItems ?? []).compactMap { item in
            guard let value = item.value, value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
    }

    /// Whether `path` is `root` or sits beneath it.
    ///
    /// Compared on path boundaries, so `/src/app` doesn't claim `/src/apple`.
    private static func contains(_ root: String, _ path: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
