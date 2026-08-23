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
