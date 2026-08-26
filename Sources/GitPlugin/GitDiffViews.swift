import SwiftUI
import MaximalTreeKit

/// A unified diff, drawn.
///
/// Monospaced with both line-number gutters, because the point of reading a
/// diff is matching it against the file you have open — and coloured by kind
/// rather than by sign alone, since the `+`/`-` column is easy to lose track of
/// halfway down a hunk.
struct DiffView: View {
    let file: GitDiff.File
    var font: Font = .system(.caption, design: .monospaced)

    var body: some View {
        if file.isBinary {
            Label("Binary file — no textual diff", systemImage: "doc.badge.gearshape")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else if file.isEmpty {
            Label("No line changes", systemImage: "equal.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            // Long lines must stay reachable: a diff that silently loses its
            // right-hand side is worse than no diff.
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        hunkHeader(hunk.header)
                        ForEach(hunk.lines) { line in
                            row(line)
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
            }
        }
    }

    private func hunkHeader(_ header: String) -> some View {
        Text(header)
            .font(font)
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6))
    }

    private func row(_ line: GitDiff.Line) -> some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign(line.kind))
                .font(font)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(font)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(background(line.kind))
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(font)
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private func sign(_ kind: GitDiff.Line.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    /// Tinted, not saturated: a hunk is mostly context, and the eye should be
    /// drawn to the few lines that changed without the block becoming a wall
    /// of colour.
    private func background(_ kind: GitDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return .green.opacity(0.14)
        case .removed: return .red.opacity(0.14)
        case .context: return .clear
        }
    }

    /// Wide enough for the longest line, so every row's tint spans the full
    /// width instead of stopping raggedly at its own text.
    private var contentWidth: CGFloat {
        let longest = file.hunks
            .flatMap(\.lines)
            .map(\.text.count)
            .max() ?? 0
        let characters = max(longest, file.hunks.map(\.header.count).max() ?? 0)
        return 110 + CGFloat(characters) * Self.characterWidth
    }

    /// One character of the monospaced caption font, measured once.
    private static let characterWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                               weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()
}

/// `+12 −3`, the shape of a change at a glance.
struct DiffStat: View {
    let file: GitDiff.File

    var body: some View {
        HStack(spacing: 6) {
            if file.additions > 0 {
                Text("+\(file.additions)").foregroundStyle(.green)
            }
            if file.deletions > 0 {
                Text("\u{2212}\(file.deletions)").foregroundStyle(.red)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
}

/// Canvas for a file on one side of the index.
///
/// Which diff is shown follows from which node was opened, rather than from a
/// control inside the canvas: a staged file shows HEAD against the index —
/// what committing would record — and an unstaged one shows the index against
/// the file on disk, what committing would miss. A file staged and then edited
/// again appears in both places, which is the clearest way to say that it has
/// two different sets of changes.
struct WorkingCopyFileCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    @State private var file: GitDiff.File?
    @State private var loaded: NodeID?

    private var isStaged: Bool { GitRef(uri: nodeID.uri)?.kind == .stagedFile }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if loaded != nodeID {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let file {
                ScrollView(.vertical) {
                    DiffView(file: file).padding(.vertical, 4)
                }
            } else {
                ContentUnavailableView(
                    isStaged ? "Nothing Staged" : "No Unstaged Changes",
                    systemImage: "equal.circle",
                    description: Text(explanation))
            }
        }
        .task(id: nodeID) {
            loaded = nil
            file = await Self.load(nodeID)
            loaded = nodeID
        }
    }

    private var explanation: String {
        isStaged
            ? "What committing would record — HEAD against the index."
            : "What committing would miss — the index against the file on disk."
    }

    private var header: some View {
        HStack(spacing: 8) {
            NodeIconView(host.node(nodeID)?.icon).frame(width: 16)
            Text(host.node(nodeID)?.label ?? nodeID.uri)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.head)
            Text(isStaged ? "Staged" : "Unstaged")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer(minLength: 8)
            if let file { DiffStat(file: file) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(explanation)
    }

    static func load(_ nodeID: NodeID) async -> GitDiff.File? {
        guard let ref = GitRef(uri: nodeID.uri), let path = ref.id else { return nil }
        let staged = ref.kind == .stagedFile
        return await Task.detached(priority: .userInitiated) {
            staged
                ? GitDiff.staged(repo: ref.repo, path: path).first
                : GitDiff.unstaged(repo: ref.repo, path: path).first
        }.value
    }
}

/// Canvas for one file inside a commit: what this commit did to it.
///
/// This is where a changed file wants to lead. Before, opening one landed on
/// the generic list canvas, which had nothing to list.
struct CommitFileCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    @State private var file: GitDiff.File?
    @State private var loaded: NodeID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if loaded != nodeID {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let file {
                ScrollView(.vertical) {
                    DiffView(file: file).padding(.vertical, 4)
                }
            } else {
                ContentUnavailableView("No Diff", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Git reported no changes for this file."))
            }
        }
        .task(id: nodeID) {
            loaded = nil
            file = await Self.load(nodeID)
            loaded = nodeID
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NodeIconView(host.node(nodeID)?.icon).frame(width: 16)
            Text(host.node(nodeID)?.label ?? nodeID.uri)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if let file { DiffStat(file: file) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Off-main: `git show` on a large file must not stall the app loop.
    static func load(_ nodeID: NodeID) async -> GitDiff.File? {
        guard let ref = GitRef(uri: nodeID.uri), let (sha, path) = ref.commitAndPath
        else { return nil }
        return await Task.detached(priority: .userInitiated) {
            GitDiff.show(repo: ref.repo, sha: sha, path: path).first
        }.value
    }
}
