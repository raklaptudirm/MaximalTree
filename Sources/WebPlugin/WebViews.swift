import SwiftUI
import WebKit
import MaximalTreeKit

// MARK: - Canvas

/// The page itself, and nothing else — the address bar and controls live in the
/// inspector and Actions (per the canvas-is-content rule). The one concession is
/// a thin top progress sliver while a page loads, the web equivalent of a status
/// dot.
struct WebCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host

    private var session: WebSession { WebSessionStore.shared.session(for: nodeID) }

    var body: some View {
        WebViewContainer(webView: session.webView)
            .overlay(alignment: .top) {
                if session.isLoading {
                    ProgressView(value: session.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            // Keep the window subtitle honest as the user follows links: the node
            // is fixed, but the live title/URL isn't.
            .onChange(of: session.title) { _, _ in syncLabel() }
            .onChange(of: session.url) { _, _ in syncLabel() }
    }

    /// Reflect the live page into the node record so the tab and subtitle track it.
    private func syncLabel() {
        guard var node = host.node(nodeID) else { return }
        let live = session.title.isEmpty
            ? session.url.map(WebProvider.label(for:)) ?? node.label
            : session.title
        guard live != node.label else { return }
        node.label = live
        host._ingest(node)
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
                }
            }
        }
        .formStyle(.grouped)
        // Seed the field from the live URL, and keep it current as long as the
        // user isn't editing it.
        .onAppear { address = session.url?.absoluteString ?? "" }
        .onChange(of: session.url) { _, newValue in
            if !addressFocused { address = newValue?.absoluteString ?? "" }
        }
    }
}
