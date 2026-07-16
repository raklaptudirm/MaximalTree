import SwiftUI
import AppKit
import Quartz          // QLPreviewView
import MaximalTreeKit

/// Canvas for a directory: a Finder-like icon grid. Single click selects (driving
/// the inspector and actions), double click opens — matching what fingers already
/// expect from Finder.
struct DirectoryCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 16)]

    var body: some View {
        let children = host.children(of: nodeID)
        Group {
            if children.isEmpty {
                if host.cachedChildren(of: nodeID) == nil {
                    ProgressView()                       // still loading
                } else {
                    ContentUnavailableView("Empty Folder", systemImage: "folder")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(children, id: \.self) { cid in
                            item(cid)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(host.node(nodeID)?.label ?? "")
    }

    @ViewBuilder
    private func item(_ cid: NodeID) -> some View {
        let node = host.node(cid)
        let selected = host.selection.contains(cid)
        VStack(spacing: 6) {
            NodeIconView(node?.icon)
                .font(.system(size: 34))
            Text(node?.label ?? cid.uri)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Double-tap attached first so it wins; the single-tap select that fires on
        // a double's first click is harmless (Finder selects then opens, too).
        .onTapGesture(count: 2) { host.open(cid) }
        .onTapGesture { host.select([cid]) }
    }
}

/// Canvas for a leaf file: a live Quick Look preview (text, images, PDFs, media, …).
/// This is the canvas "escape hatch" in action — a plugin dropping a raw AppKit view
/// into the center pane.
struct FileCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    var body: some View {
        Group {
            if let url = nodeID.fileURL {
                QuickLookPreview(url: url)
            } else {
                ContentUnavailableView("No Preview", systemImage: "doc")
            }
        }
        .navigationTitle(host.node(nodeID)?.label ?? "")
    }
}

/// Wraps `QLPreviewView` for SwiftUI. Rebinds its item when the focused file changes
/// so the same view is reused across navigation rather than recreated per node.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        }
    }
}

/// Inspector shared by files and directories: node metadata, file stats, and any
/// forward references (empty for the filesystem provider today).
struct FileInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let node = host.node(nodeID)
        Form {
            Section("Node") {
                // Editable: committing a new name applies a rename mutation. The
                // inspector doubles as the manipulation surface.
                TextField("Name", text: $draftName)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                LabeledContent("Type", value: node?.type.raw ?? "—")
                if let uti = node?.uti { LabeledContent("Content Type", value: uti) }
                if let url = nodeID.fileURL {
                    LabeledContent("Location") {
                        HStack(spacing: 4) {
                            Text(url.deletingLastPathComponent().path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.path, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy full path")
                        }
                    }
                }
            }
            if let size = sizeString(node) {
                Section("File") {
                    LabeledContent("Size", value: size)
                    if let modified = modifiedString(node) {
                        LabeledContent("Modified", value: modified)
                    }
                }
            }
            let related = host.related(of: nodeID)
            if !related.isEmpty {
                Section("References") {
                    ForEach(related) { r in
                        Button(r.label) { host.openURI(r.target) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftName = host.node(nodeID)?.label ?? "" }
        .onChange(of: nodeID) { draftName = host.node(nodeID)?.label ?? "" }
        .onChange(of: host.node(nodeID)?.label) { _, newValue in
            if !nameFocused { draftName = newValue ?? "" }   // don't clobber while editing
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != host.node(nodeID)?.label else { return }
        host.apply(.rename(nodeID, to: trimmed))
    }

    private func sizeString(_ node: Node?) -> String? {
        guard case .int(let bytes)? = node?.attributes["size"] else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func modifiedString(_ node: Node?) -> String? {
        guard case .date(let date)? = node?.attributes["modified"] else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
