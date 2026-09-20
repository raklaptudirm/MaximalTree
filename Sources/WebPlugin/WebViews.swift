import SwiftUI
import WebKit
import MaximalTreeKit

// MARK: - Canvas

/// The page itself, and nothing else — the address bar and controls live in the
/// inspector and Actions (per the canvas-is-content rule). The concessions are
/// status, not controls: a thin top progress sliver while loading, and a load-
/// failure banner. ⌘L presents the location prompt here (the canvas is where
/// the keyboard lives).
struct WebCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var locationDraft = ""
    private let uiState = WebUIState.shared

    private var session: WebSession { WebSessionStore.shared.session(for: nodeID) }

    private var showingLocationPrompt: Binding<Bool> {
        Binding(
            get: { uiState.locationPromptTarget == nodeID },
            set: { if !$0 { uiState.locationPromptTarget = nil } }
        )
    }

    var body: some View {
        WebViewContainer(webView: session.webView)
            .overlay(alignment: .top) {
                if session.isLoading {
                    ProgressView(value: session.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = session.loadError {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                        Text(error).lineLimit(2)
                        Spacer()
                        Button("Retry") { session.reload() }
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.thinMaterial)
                }
            }
            .alert("Open Location", isPresented: showingLocationPrompt) {
                TextField("Search or enter address", text: $locationDraft)
                Button("Go") { session.load(locationDraft) }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: uiState.locationPromptTarget) { _, target in
                if target == nodeID {
                    locationDraft = session.url?.absoluteString ?? ""
                }
            }
            // Keep the node record honest as the user follows links: the node is
            // fixed, but the live title/URL/site aren't.
            .onChange(of: session.title) { _, _ in syncNodeRecord() }
            .onChange(of: session.url) { _, _ in syncNodeRecord() }
    }

    /// Reflect the live page into the node record — label from the title, icon
    /// from the site's favicon — so the sidebar, tab, and subtitle track it.
    private func syncNodeRecord() {
        // Say that the record changed, not what it changed to. The provider
        // reads the live session when it is asked, so the sidebar, the tab and
        // the subtitle all get the page's own title from the one place that
        // knows it — and they get it whether or not this canvas is on screen.
        guard let node = host.node(nodeID) else { return }
        let live = session.title.isEmpty
            ? session.url.map(WebProvider.label(for:)) ?? node.label
            : session.title
        if live != node.label { host.notify([.modified(nodeID)]) }

        guard let webHost = session.url?.host else { return }
        Task { @MainActor in
            guard let favicon = await WebSessionStore.shared.favicon(for: webHost),
                  host.node(nodeID)?.icon?.imageData != favicon else { return }
            // The icon belongs to the site, so anything else listing it gains
            // one too — a bookmark to this host is drawn from the provider,
            // which now has the icon on disk. Runs once per node per icon.
            host.notify([.modified(nodeID), .childrenChanged(WebProvider.bookmarksID)])
        }
    }
}

/// Hosts the session's `WKWebView` (owned by the session, not the view tree) as
/// the pane's content, pinned to fill.
private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container {
            webView.removeFromSuperview()
            attach(webView, to: container)
        }
    }

    private func attach(_ webView: WKWebView, to container: NSView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - Inspector

/// The browser's controls: the address bar (the primary way to navigate), a
/// toolbar row, and the live page info. The host appends the plugin's Actions
/// below this.
struct WebInspector: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var session: WebSession { WebSessionStore.shared.session(for: nodeID) }

    var body: some View {
        Form {
            Section("Address") {
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { session.load(address) }

                HStack {
                    Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!session.canGoBack)
                        .help("Back")
                    Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!session.canGoForward)
                        .help("Forward")
                    if session.isLoading {
                        Button { session.stop() } label: { Image(systemName: "xmark") }
                            .help("Stop")
                    } else {
                        Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Reload")
                    }
                    Spacer()
                    bookmarkToggle
                    Button { session.load(address) } label: { Image(systemName: "arrow.right.circle") }
                        .help("Go")
                }
                .buttonStyle(.borderless)
            }

            Section("Page") {
                if !session.title.isEmpty {
                    LabeledContent("Title", value: session.title)
                }
                if let url = session.url {
                    LabeledContent("URL") {
                        Text(url.absoluteString)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let host = url.host() {
                        LabeledContent("Host", value: host)
                    }
                    // Whether it *is* secure, not whether the scheme says so:
                    // a page loaded over https that pulls something over http
                    // is not, and the padlock is the thing people read.
                    LabeledContent("Connection") {
                        Label(session.isSecure ? "Secure" : "Not secure",
                              systemImage: session.isSecure ? "lock.fill" : "lock.open")
                            .foregroundStyle(session.isSecure ? AnyShapeStyle(.secondary)
                                                             : AnyShapeStyle(Color.orange))
                    }
                }
                if session.zoomPercent != 100 {
                    LabeledContent("Zoom", value: "\(session.zoomPercent)%")
                }
            }

            FindSection(session: session)
        }
        .formStyle(.grouped)
        // Seed the field from the live URL, and keep it current as long as the
        // user isn't editing it.
        .onAppear { address = session.url?.absoluteString ?? "" }
        .onChange(of: session.url) { _, newValue in
            if !addressFocused { address = newValue?.absoluteString ?? "" }
        }
    }

    /// Star state reflects the *live* URL, mirroring the ⌘D / Remove actions.
    @ViewBuilder
    private var bookmarkToggle: some View {
        let current = session.url?.absoluteString
        let bookmarked = current.map(BookmarkStore.shared.contains) ?? false
        Button {
            guard let current else { return }
            if bookmarked {
                BookmarkStore.shared.remove(url: current)
            } else {
                let title = session.title.isEmpty
                    ? session.url.map(WebProvider.label(for:)) ?? current
                    : session.title
                BookmarkStore.shared.add(url: current, title: title)
            }
            host.notify([.modified(WebProvider.bookmarksID),
                         .childrenChanged(WebProvider.bookmarksID)])
        } label: {
            Image(systemName: bookmarked ? "star.fill" : "star")
                .foregroundStyle(bookmarked ? .yellow : .secondary)
        }
        .disabled(current == nil)
        .help(bookmarked ? "Remove bookmark" : "Bookmark this page")
    }
}


/// Finding text on the page.
///
/// The search text lives on the session, not here: it outlives this view — you
/// search, scroll, come back — and the next/previous actions have to be able
/// to reach it, which a view's state cannot offer them.
private struct FindSection: View {
    let session: WebSession
    @State private var query = ""

    var body: some View {
        Section("Find") {
            TextField("Find on page", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.find(query) }
            if session.searchFoundNothing {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button { session.find(query, forward: false) } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match")
                Button { session.find(query, forward: true) } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next match")
                Spacer()
            }
            .buttonStyle(.borderless)
            .disabled(query.isEmpty)
        }
        .onAppear { query = session.searchText }
    }
}
