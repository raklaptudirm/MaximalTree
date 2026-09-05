import SwiftUI
import MaximalTreeKit

/// Rich canvas for a commit: message, author/date, sha, and clickable changed files.
struct CommitCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let node = host.node(nodeID)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(gitString(node, "subject") ?? node?.label ?? "Commit")
                    .font(.title2).bold()
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    if let author = gitString(node, "author") {
                        Label(author, systemImage: "person")
                    }
                    if let date = gitDate(node) {
                        Label(date, systemImage: "clock")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let sha = gitString(node, "sha") {
                    Text(sha)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                let files = host.children(of: nodeID)
                if files.isEmpty {
                    Text("No file changes").foregroundStyle(.secondary)
                } else {
                    Text("Changed Files").font(.headline)
                    ForEach(files, id: \.self) { fid in
                        ChangedFileRow(nodeID: fid)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// One changed file in a commit: the row, and its diff in a drawer.
///
/// The drawer is what makes a commit readable in one place — most of reviewing
/// a commit is skimming a few files, and that shouldn't cost a navigation each
/// time. Opening the row still leads to the file's own canvas for a proper
/// read; the arrow is the glance.
///
/// The diff is fetched when the drawer is first opened, never before: a commit
/// touching fifty files would otherwise run fifty `git show`s to draw a list.
private struct ChangedFileRow: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    @State private var expanded = false
    @State private var file: GitDiff.File?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide diff" : "Show diff")

                Button {
                    host.open(nodeID)
                } label: {
                    HStack(spacing: 8) {
                        NodeIconView(host.node(nodeID)?.icon).frame(width: 16)
                        Text(host.node(nodeID)?.label ?? nodeID.uri).lineLimit(1)
                        Spacer(minLength: 8)
                        if let file { DiffStat(file: file) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if expanded {
                Group {
                    if loading {
                        ProgressView().controlSize(.small).padding(.vertical, 6)
                    } else if let file {
                        DiffView(file: file)
                    } else {
                        Text("No diff for this file")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .task(id: expanded) {
            guard expanded, file == nil, !loading else { return }
            loading = true
            file = await CommitFileCanvas.load(nodeID)
            loading = false
        }
    }
}

/// Generic canvas for git containers and leaves: lists children (Branches, Commits,
/// commit list, …) and any forward references.
struct GitListCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let children = host.children(of: nodeID)
        let related = host.related(of: nodeID)
        Group {
            if children.isEmpty && related.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "arrow.triangle.branch")
            } else {
                List {
                    if !children.isEmpty {
                        Section(host.node(nodeID)?.label ?? "") {
                            ForEach(children, id: \.self) { cid in
                                row(cid)
                            }
                            // Provider reported more history (Page.next) — the host
                            // appends each page to the cached child list.
                            if host.hasMoreChildren(nodeID) {
                                Button {
                                    host.loadMoreChildren(of: nodeID)
                                } label: {
                                    Label("Load More…", systemImage: "ellipsis.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !related.isEmpty {
                        Section("References") {
                            ForEach(related) { r in
                                Button(r.label) { host.openURI(r.target) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A commit row gets an author + relative-date subtitle; other kinds stay plain.
    @ViewBuilder
    private func row(_ cid: NodeID) -> some View {
        let node = host.node(cid)
        Button {
            host.open(cid)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                NodeIconView(node?.icon).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node?.label ?? cid.uri).lineLimit(1)
                    if let subtitle = commitSubtitle(node) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func commitSubtitle(_ node: Node?) -> String? {
        guard let author = gitString(node, "author") else { return nil }
        if case .date(let date)? = node?.attributes["date"] {
            return "\(author) — \(date.formatted(.relative(presentation: .named)))"
        }
        return author
    }
}

/// Inspector section for any git node: attributes + clickable references.
struct GitInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        let node = host.node(nodeID)
        Form {
            Section("Git") {
                LabeledContent("Name", value: node?.label ?? "—")
                if let sha = gitString(node, "sha") { LabeledContent("SHA", value: sha) }
                if let author = gitString(node, "author") { LabeledContent("Author", value: author) }
                if let date = gitDate(node) { LabeledContent("Date", value: date) }
                if let status = gitString(node, "status") { LabeledContent("Status", value: status) }
            }
            RepositorySection(nodeID: nodeID)
            CommitBox(nodeID: nodeID)
            GitFailureNotice()
        }
        .formStyle(.grouped)
    }
}

// MARK: - attribute helpers

private func gitString(_ node: Node?, _ key: String) -> String? {
    if case .string(let value)? = node?.attributes[key] { return value }
    return nil
}

private func gitDate(_ node: Node?) -> String? {
    if case .date(let date)? = node?.attributes["date"] {
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    return nil
}


/// Where a commit message is written.
///
/// In the inspector because a canvas is content and a plugin has no window of
/// its own to put a sheet on — and because the message has to outlive the view
/// anyway: you type it, stage one more file, and it is still there.
///
/// Committing itself is `git.commit`, the same action the menu and the finder
/// offer; this is only the text field it reads.
private struct CommitBox: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var state = GitUIState.shared

    var body: some View {
        if let repo = GitActions.repo(of: nodeID),
           GitRefKindIsRepoScope(nodeID) {
            Section("Commit") {
                TextEditor(text: Binding(
                    get: { state.message(for: repo) },
                    set: { state.setMessage($0, for: repo) }))
                    .font(.body.monospaced())
                    .frame(minHeight: 68)
                Button {
                    host.perform("git.commit")
                } label: {
                    Label("Commit", systemImage: "checkmark.seal")
                }
                .disabled(state.message(for: repo)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// The last thing git refused to do.
///
/// A write can fail for reasons only git knows — nothing staged, a rejected
/// push, a conflicted pull — and those messages are the whole of what makes
/// the failure actionable. Without somewhere to put them the command simply
/// appeared to do nothing.
private struct GitFailureNotice: View {
    @State private var state = GitUIState.shared

    var body: some View {
        if let failure = state.failure {
            Section(failure.operation + " failed") {
                Text(failure.message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Dismiss") { state.clearFailure() }
            }
        }
    }
}

/// Whether this node stands for the repository rather than one file in it.
@MainActor
private func GitRefKindIsRepoScope(_ id: NodeID) -> Bool {
    guard let ref = GitRef(uri: id.uri) else { return false }
    switch ref.kind {
    case .repo, .staged, .unstaged, .branches, .commits: return true
    default: return false
    }
}


/// Where the repository stands, for any node inside it.
///
/// Shown throughout rather than only on the repo row: "am I ahead of the
/// remote" is the question you have while looking at a commit or a changed
/// file, not while looking at the repository's own row.
private struct RepositorySection: View {
    let nodeID: NodeID
    @State private var status: GitStatus?
    @State private var remote: String?

    var body: some View {
        content.task(id: nodeID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let status, status.branch != nil {
            Section("Repository") {
                LabeledContent("Branch", value: status.branch ?? "—")
                if let upstream = status.upstream {
                    LabeledContent("Upstream", value: upstream)
                }
                if status.ahead > 0 || status.behind > 0 {
                    LabeledContent("Diverged",
                                   value: "\(status.ahead) ahead, \(status.behind) behind")
                }
                if let remote { LabeledContent("Remote", value: remote) }
                LabeledContent("Changes", value: status.isClean
                               ? "None"
                               : "\(status.staged.count) staged, \(status.unstaged.count) unstaged")
            }
        }
    }

    /// Read off the main actor: git talks to the disk, and an inspector that
    /// waited for it would stall every selection change.
    private func load() async {
        guard let repo = GitActions.repo(of: nodeID) else { return }
        let read = await Task.detached { () -> (GitStatus, String?) in
            (GitStatus.read(repo),
             Git.run(repo, ["remote", "get-url", "origin"])?
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        status = read.0
        remote = read.1?.isEmpty == true ? nil : read.1
    }
}
