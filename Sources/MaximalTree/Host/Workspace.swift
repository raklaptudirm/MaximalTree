import Foundation
import MaximalTreeKit

/// One named set of root nodes — the unit the user switches between. Host-owned and
/// persisted; providers are entirely unaware of workspaces.
struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var rootURIs: [String]

    init(id: UUID = UUID(), name: String, rootURIs: [String] = []) {
        self.id = id
        self.name = name
        self.rootURIs = rootURIs
    }
}

/// Everything persisted: all workspaces plus which one is active.
struct WorkspaceLibrary: Codable {
    var workspaces: [Workspace]
    var activeID: UUID?
}

/// The app-managed workspace library (not document-based — a deliberate early
/// decision). Invariant: at least one workspace always exists, and `activeID` always
/// points at one of them.
///
/// Restore resolves each stored root URI back to a live NodeID; roots that no longer
/// resolve are dropped rather than crashing (a root can be renamed/removed while the
/// app is closed — the across-a-launch version of the rename problem).
@MainActor
@Observable
final class WorkspaceStore {
    private let fileURL: URL
    private(set) var library: WorkspaceLibrary

    /// True only when no persisted state existed at all (very first launch). The
    /// caller may seed the initial workspace with provider defaults; a workspace the
    /// user deliberately emptied stays empty.
    let wasFreshlyCreated: Bool

    var active: Workspace {
        library.workspaces.first { $0.id == library.activeID } ?? library.workspaces[0]
    }

    /// - Parameter fileURL: Overridable for tests; defaults to Application Support.
    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url

        if let data = try? Data(contentsOf: url),
           let lib = try? JSONDecoder().decode(WorkspaceLibrary.self, from: data),
           !lib.workspaces.isEmpty {
            self.library = lib
            self.wasFreshlyCreated = false
        } else if let migrated = Self.migrateLegacy(besides: url) {
            // Pre-workspaces builds stored a single root set in workspace.json.
            self.library = WorkspaceLibrary(workspaces: [migrated], activeID: migrated.id)
            self.wasFreshlyCreated = false
        } else {
            let main = Workspace(name: "Main")
            self.library = WorkspaceLibrary(workspaces: [main], activeID: main.id)
            self.wasFreshlyCreated = true
        }

        // Heal a dangling activeID rather than trusting the file.
        if !library.workspaces.contains(where: { $0.id == library.activeID }) {
            library.activeID = library.workspaces[0].id
        }
        persist()
    }

    // MARK: Roots of the active workspace

    /// Resolve the active workspace's stored roots to live NodeIDs, dropping any
    /// that no longer resolve.
    func resolvedRoots(using providers: [NodeProvider]) -> [NodeID] {
        active.rootURIs.compactMap { uri in
            guard let id = NodeID(uri), let scheme = id.scheme,
                  let p = providers.first(where: { $0.schemes.contains(scheme) })
            else { return nil }
            return p.resolve(uri)
        }
    }

    /// Record the active workspace's roots (called on every mount/unmount).
    func saveRoots(_ roots: [NodeID]) {
        mutateActive { $0.rootURIs = roots.map(\.uri) }
    }

    // MARK: Library management

    @discardableResult
    func create(named name: String) -> Workspace {
        let workspace = Workspace(name: name)
        library.workspaces.append(workspace)
        persist()
        return workspace
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == id }) else { return }
        library.workspaces[i].name = name
        persist()
    }

    /// Deleting only forgets a root list — the nodes themselves are untouched.
    /// Refuses to delete the last workspace; deleting the active one activates
    /// the first remaining.
    func delete(_ id: UUID) {
        guard library.workspaces.count > 1,
              let i = library.workspaces.firstIndex(where: { $0.id == id }) else { return }
        library.workspaces.remove(at: i)
        if library.activeID == id { library.activeID = library.workspaces[0].id }
        persist()
    }

    func setActive(_ id: UUID) {
        guard library.workspaces.contains(where: { $0.id == id }) else { return }
        library.activeID = id
        persist()
    }

    // MARK: Persistence

    private func mutateActive(_ change: (inout Workspace) -> Void) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == library.activeID })
        else { return }
        change(&library.workspaces[i])
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(library) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func defaultURL() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaximalTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    /// The pre-workspaces format: a single `{name, rootURIs}` in workspace.json
    /// next to where the library now lives.
    private static func migrateLegacy(besides url: URL) -> Workspace? {
        struct Legacy: Codable {
            var name: String
            var rootURIs: [String]
        }
        let legacyURL = url.deletingLastPathComponent().appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        let name = legacy.name == "Untitled" ? "Main" : legacy.name
        return Workspace(name: name, rootURIs: legacy.rootURIs)
    }
}
