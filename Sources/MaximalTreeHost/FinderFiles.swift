import Foundation
import MaximalTreeKit

/// The finder's file walk.
///
/// Deliberately not through the graph. `HostContext.children(of:)` serves the
/// *cache* and merely requests a load, so walking it reads empty for anything
/// not already expanded in the sidebar and stops at the first unvisited
/// directory — the finder offered a handful of files and looked like it was
/// refusing to filter. A finder walk is a disk walk, which is why the terminal
/// ones shell out to `fd`.
///
/// Free of the main actor so it can run off it, and free of the app so it can
/// be tested against a real directory.
enum FinderFiles {
    /// Files under `roots`, capped. You are typing to narrow it down anyway,
    /// and the cap is far past what any query leaves standing.
    static func items(under roots: [URL], limit: Int = 20000) -> [FinderItem] {
        var found: [FinderItem] = []
        for root in roots where found.count < limit {
            guard let walk = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            let base = root.standardizedFileURL.path
            while let url = walk.nextObject() as? URL, found.count < limit {
                let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if directory {
                    // Build output and dependency trees hold more files than
                    // everything else together and are never what anyone is
                    // looking for.
                    if isSpoil(url.lastPathComponent) { walk.skipDescendants() }
                    continue
                }
                found.append(FinderItem(
                    // The uri itself, so a file the sidebar is also showing
                    // collapses to one row rather than appearing twice.
                    id: url.absoluteString,
                    title: url.lastPathComponent,
                    subtitle: relativePath(of: url, under: base),
                    systemImage: "doc",
                    effect: .open(url.absoluteString)))
            }
        }
        return found
    }

    static func isSpoil(_ name: String) -> Bool {
        name.hasPrefix(".") || ["node_modules", "DerivedData", ".build", "build",
                                "target", "Pods", "dist", "vendor"].contains(name)
    }

    /// Where a file sits inside its root, which is what tells two files of the
    /// same name apart — and what a second word in the query can match.
    static func relativePath(of url: URL, under base: String) -> String {
        let path = url.deletingLastPathComponent().standardizedFileURL.path
        guard path.hasPrefix(base) else { return path }
        let inside = String(path.dropFirst(base.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return inside.isEmpty ? URL(fileURLWithPath: base).lastPathComponent : inside
    }
}
