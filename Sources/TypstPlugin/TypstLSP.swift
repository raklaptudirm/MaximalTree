import Foundation

/// A completion produced by the language server, in editor-ready coordinates:
/// `replaceRange` is UTF-16 (NSRange-ready) against the text the request was
/// made with. Foundation-only so the client stays unit-testable.
struct LSPCompletion: Sendable, Equatable {
    let label: String
    let detail: String?
    let insertText: String
    let replaceRange: NSRange?
}

/// A minimal LSP client for tinymist (the typst language server), speaking
/// JSON-RPC over stdio. Scope is deliberate: document sync + completions —
/// highlighting comes from the bundled parser and diagnostics from the bundled
/// compiler, so the server only supplies what those can't.
///
/// Discovered on PATH-adjacent install locations; every entry point
/// degrades to "no results" when the binary is absent or the server misbehaves.
actor TinymistClient {
    static let shared = TinymistClient()

    /// Well-known install locations (Homebrew, cargo, nix).
    nonisolated static var binaryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/tinymist",
            "/usr/local/bin/tinymist",
            "\(home)/.cargo/bin/tinymist",
            "/etc/profiles/per-user/\(NSUserName())/bin/tinymist",
            "/run/current-system/sw/bin/tinymist",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    nonisolated static var isAvailable: Bool { binaryURL != nil }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var documentVersions: [String: Int] = [:]

    struct ServerUnavailable: Error {}

    // MARK: Public API

    /// Completions at a UTF-16 `offset` into `text` (the buffer's current,
    /// possibly unsaved contents). Never throws — an LSP hiccup must never
    /// break typing.
    func completions(fileURL: URL, text: String, offset: Int) async -> [LSPCompletion] {
        do {
            try await ensureRunning(rootURL: fileURL.deletingLastPathComponent())
            let uri = fileURL.absoluteString
            try syncDocument(uri: uri, text: text)
            let ns = text as NSString
            let response = try await request(
                "textDocument/completion",
                CompletionParams(textDocument: .init(uri: uri),
                                 position: Self.position(ofOffset: offset, in: ns)))
            return Self.parseCompletions(from: response, in: ns)
        } catch {
            return []
        }
    }

    // MARK: Lifecycle

    private func ensureRunning(rootURL: URL) async throws {
        if let process, process.isRunning { return }
        guard let binary = Self.binaryURL else { throw ServerUnavailable() }

        for continuation in pending.values {
            continuation.resume(throwing: ServerUnavailable())
        }
        pending = [:]
        documentVersions = [:]
        buffer = Data()

        let server = Process()
        server.executableURL = binary
        server.arguments = ["lsp"]
        let input = Pipe()
        let output = Pipe()
        server.standardInput = input
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            Task { await self.didRead(data) }
        }
        server.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.didTerminate() }
        }
        try server.run()
        process = server
        stdinHandle = input.fileHandleForWriting

        _ = try await request("initialize", InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            rootUri: rootURL.absoluteString,
            capabilities: ClientCapabilities()))
        try notify("initialized", EmptyParams())
    }

    private func didTerminate() {
        for continuation in pending.values {
            continuation.resume(throwing: ServerUnavailable())
        }
        pending = [:]
        documentVersions = [:]
        process = nil
        stdinHandle = nil
    }

    /// Full-text sync, sent lazily right before each request rather than per
    /// keystroke — the server only needs to be current when asked something.
    private func syncDocument(uri: String, text: String) throws {
        if let version = documentVersions[uri] {
            let next = version + 1
            documentVersions[uri] = next
            try notify("textDocument/didChange", DidChangeParams(
                textDocument: .init(uri: uri, version: next),
                contentChanges: [.init(text: text)]))
        } else {
            documentVersions[uri] = 1
            try notify("textDocument/didOpen", DidOpenParams(
                textDocument: .init(uri: uri, languageId: "typst",
                                    version: 1, text: text)))
        }
    }

    // MARK: JSON-RPC plumbing

    private func request<P: Encodable>(_ method: String, _ params: P) async throws -> Data {
        let id = nextID
        nextID += 1
        try write(RPCRequest(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.expire(id: id)
            }
        }
    }

    private func expire(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: ServerUnavailable())
    }

    private func notify<P: Encodable>(_ method: String, _ params: P) throws {
        try write(RPCNotification(method: method, params: params))
    }

    private func write<T: Encodable>(_ message: T) throws {
        let body = try JSONEncoder().encode(message)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        stdinHandle?.write(frame)
    }

    private func didRead(_ data: Data) {
        buffer.append(data)
        while let body = nextFrameBody() { dispatch(body) }
    }

    /// Content-Length framing. Returns one complete message body, consuming it
    /// (and its header) from the buffer.
    private func nextFrameBody() -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound],
                            as: UTF8.self)
        guard let lengthField = header
            .components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("content-length:") })?
            .dropFirst("content-length:".count)
            .trimmingCharacters(in: .whitespaces),
              let length = Int(lengthField)
        else {
            buffer = Data()   // unparseable stream: resync from scratch
            return nil
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return body
    }

    private func dispatch(_ body: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return }
        switch (envelope.id, envelope.method) {
        case (let id?, nil):
            // Response to one of our requests.
            pending.removeValue(forKey: id)?.resume(returning: body)
        case (let id?, .some):
            // Server-to-client request (workspace/configuration, capability
            // registration, progress creation): acknowledge so it never stalls.
            try? write(RPCNullResponse(id: id))
        default:
            break   // notifications (diagnostics etc.) — compiler already covers them
        }
    }

    // MARK: Position mapping (LSP speaks UTF-16 line/character — so does NSString)

    static func position(ofOffset offset: Int, in text: NSString) -> Position {
        var line = 0
        var lineStart = 0
        let clamped = min(max(offset, 0), text.length)
        var i = 0
        while i < clamped {
            if text.character(at: i) == UInt16(UInt8(ascii: "\n")) {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        return Position(line: line, character: clamped - lineStart)
    }

    static func offset(of position: Position, in text: NSString) -> Int {
        var line = 0
        var i = 0
        while line < position.line && i < text.length {
            if text.character(at: i) == UInt16(UInt8(ascii: "\n")) { line += 1 }
            i += 1
        }
        return min(i + position.character, text.length)
    }

    // MARK: Completion decoding

    static func parseCompletions(from response: Data, in text: NSString) -> [LSPCompletion] {
        guard let decoded = try? JSONDecoder().decode(RPCResponse<CompletionResult>.self,
                                                      from: response),
              let result = decoded.result
        else { return [] }
        return result.items.map { item in
            let raw = item.textEdit?.newText ?? item.insertText ?? item.label
            var range: NSRange?
            if let lspRange = item.textEdit?.range {
                let start = offset(of: lspRange.start, in: text)
                let end = offset(of: lspRange.end, in: text)
                if end >= start { range = NSRange(location: start, length: end - start) }
            }
            return LSPCompletion(label: item.label,
                                 detail: item.detail ?? item.kind.flatMap { kindNames[$0] },
                                 insertText: strippingSnippetSyntax(raw),
                                 replaceRange: range)
        }
    }

    /// `${1:placeholder}` → `placeholder`, `$1`/`$0` → gone. We insert plain
    /// text; tab-stop navigation is a later refinement.
    static func strippingSnippetSyntax(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: #"\$\d+"#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "")
        }
        return result
    }

    private static let kindNames: [Int: String] = [
        1: "text", 2: "method", 3: "function", 4: "constructor", 5: "field",
        6: "variable", 7: "class", 9: "module", 10: "property", 12: "value",
        13: "enum", 14: "keyword", 15: "snippet", 17: "file", 21: "constant",
    ]

    // MARK: Wire types

    struct Position: Codable, Equatable {
        let line: Int
        let character: Int
    }

    private struct Envelope: Decodable {
        let id: Int?
        let method: String?
    }

    private struct RPCRequest<P: Encodable>: Encodable {
        var jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: P
    }

    private struct RPCNotification<P: Encodable>: Encodable {
        var jsonrpc = "2.0"
        let method: String
        let params: P
    }

    private struct RPCNullResponse: Encodable {
        var jsonrpc = "2.0"
        let id: Int
        let result: Int? = nil

        enum CodingKeys: CodingKey { case jsonrpc, id, result }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(jsonrpc, forKey: .jsonrpc)
            try container.encode(id, forKey: .id)
            try container.encodeNil(forKey: .result)   // explicit null, per JSON-RPC
        }
    }

    private struct RPCResponse<R: Decodable>: Decodable { let result: R? }

    private struct InitializeParams: Encodable {
        let processId: Int
        let rootUri: String
        let capabilities: ClientCapabilities
    }

    private struct ClientCapabilities: Encodable {}
    private struct EmptyParams: Encodable {}

    private struct DidOpenParams: Encodable {
        struct Item: Encodable {
            let uri: String
            let languageId: String
            let version: Int
            let text: String
        }
        let textDocument: Item
    }

    private struct DidChangeParams: Encodable {
        struct Identifier: Encodable {
            let uri: String
            let version: Int
        }
        struct Change: Encodable { let text: String }   // full-document sync
        let textDocument: Identifier
        let contentChanges: [Change]
    }

    private struct CompletionParams: Encodable {
        struct Identifier: Encodable { let uri: String }
        let textDocument: Identifier
        let position: Position
    }

    private enum CompletionResult: Decodable {
        case items([CompletionItem])

        var items: [CompletionItem] {
            if case .items(let items) = self { return items }
            return []
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode(CompletionList.self) {
                self = .items(list.items)
            } else {
                self = .items((try? container.decode([CompletionItem].self)) ?? [])
            }
        }
    }

    private struct CompletionList: Decodable { let items: [CompletionItem] }

    private struct CompletionItem: Decodable {
        let label: String
        let detail: String?
        let kind: Int?
        let insertText: String?
        let textEdit: TextEdit?
    }

    /// Tolerates both plain `TextEdit {range, newText}` and
    /// `InsertReplaceEdit {insert, replace, newText}` (we take `replace`).
    private struct TextEdit: Decodable {
        let newText: String
        let range: LSPRange?

        enum CodingKeys: String, CodingKey { case newText, range, replace }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            newText = try container.decode(String.self, forKey: .newText)
            range = (try? container.decode(LSPRange.self, forKey: .range))
                ?? (try? container.decode(LSPRange.self, forKey: .replace))
        }
    }

    private struct LSPRange: Decodable {
        let start: Position
        let end: Position
    }
}
