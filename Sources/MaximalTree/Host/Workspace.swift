import Foundation
import MaximalTreeKit

/// Host-owned, persisted state. For v0 that's just the set of mounted root URIs.
/// App-managed (not document-based): stored as JSON in Application Support and the
/// last one is restored on launch. Providers are entirely unaware of this type.
struct Workspace: Codable {
    var name: String
    var rootURIs: [String]

    static let empty = Workspace(name: "Untitled", rootURIs: [])
}

/// Loads/saves the current workspace. Restore resolves each stored root URI back to
/// a live NodeID; roots that no longer resolve degrade to "unavailable" rather than
/// crashing (a root can be renamed/removed while the app is closed — the across-a-
/// launch version of the rename problem, where we got no rename event).
@MainActor
final class WorkspaceStore {
    private let fileURL: URL
    private(set) var workspace: Workspace

    /// - Parameter fileURL: Overridable for tests; defaults to Application Support.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MaximalTree", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("workspace.json")
        }

        if let data = try? Data(contentsOf: self.fileURL),
           let ws = try? JSONDecoder().decode(Workspace.self, from: data) {
            self.workspace = ws
        } else {
            self.workspace = .empty
        }
    }

    /// Resolve stored roots to live NodeIDs. Unresolvable ones are dropped for now
    /// (a later pass can surface them as greyed-out "unavailable" entries instead).
    func resolvedRoots(using providers: [NodeProvider], seedIfEmpty: () -> [NodeID]) -> [NodeID] {
        var resolved: [NodeID] = []
        for uri in workspace.rootURIs {
            guard let id = NodeID(uri), let scheme = id.scheme,
                  let p = providers.first(where: { $0.schemes.contains(scheme) }),
                  let live = p.resolve(uri) else { continue }
            resolved.append(live)
        }
        if resolved.isEmpty { resolved = seedIfEmpty() }
        return resolved
    }

    func save(roots: [NodeID]) {
        workspace.rootURIs = roots.map(\.uri)
        if let data = try? JSONEncoder().encode(workspace) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
