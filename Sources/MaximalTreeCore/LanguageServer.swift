import Foundation

// MARK: - Language servers

/// A language server the app knows how to run: what it is called, which files
/// it serves and as what, and what marks the top of a project it understands.
public struct LanguageServerConfig: Sendable, Hashable {
    public var name: String
    public var executable: String
    public var arguments: [String]
    /// File extension → the language id the server is told a file is.
    public var languageIDs: [String: String]
    /// Files whose presence marks a project's root, nearest first.
    public var rootMarkers: [String]

    public init(name: String, executable: String, arguments: [String] = [],
                languageIDs: [String: String], rootMarkers: [String]) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.languageIDs = languageIDs
        self.rootMarkers = rootMarkers
    }

    /// The servers this app knows, in order of preference for a file two of
    /// them could serve.
    public static let known: [LanguageServerConfig] = [
        LanguageServerConfig(name: "sourcekit-lsp", executable: "sourcekit-lsp",
                             languageIDs: ["swift": "swift"],
                             rootMarkers: ["Package.swift", ".git"]),
        LanguageServerConfig(name: "tinymist", executable: "tinymist", arguments: ["lsp"],
                             languageIDs: ["typ": "typst"], rootMarkers: ["typst.toml", ".git"]),
        LanguageServerConfig(name: "rust-analyzer", executable: "rust-analyzer",
                             languageIDs: ["rs": "rust"], rootMarkers: ["Cargo.toml", ".git"]),
        LanguageServerConfig(name: "gopls", executable: "gopls",
                             languageIDs: ["go": "go"], rootMarkers: ["go.mod", ".git"]),
        LanguageServerConfig(name: "pyright", executable: "pyright-langserver", arguments: ["--stdio"],
                             languageIDs: ["py": "python"],
                             rootMarkers: ["pyproject.toml", "setup.py", ".git"]),
        LanguageServerConfig(name: "typescript-language-server",
                             executable: "typescript-language-server", arguments: ["--stdio"],
                             languageIDs: ["ts": "typescript", "tsx": "typescriptreact",
                                           "js": "javascript", "jsx": "javascriptreact"],
                             rootMarkers: ["tsconfig.json", "package.json", ".git"]),
        LanguageServerConfig(name: "clangd", executable: "clangd",
                             languageIDs: ["c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
                                           "hpp": "cpp", "hh": "cpp", "m": "objective-c",
                                           "mm": "objective-cpp"],
                             rootMarkers: ["compile_commands.json", ".git"]),
    ]

    /// Where the server is installed, if it is: the search path, and the
    /// places installers put things — an app started from the Dock gets a
    /// search path of four directories, none of them those.
    public func installedAt() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let places = path + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin",
                             "\(home)/go/bin", "\(home)/.local/bin",
                             "/etc/profiles/per-user/\(user)/bin", "/run/current-system/sw/bin", "/usr/bin"]
        return places.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func serves(_ url: URL) -> Bool { languageIDs[url.pathExtension.lowercased()] != nil }

    /// The top of the project `url` is in: the nearest folder above it holding
    /// a root marker, trying each marker in order — or the file's own folder.
    func root(of url: URL) -> URL {
        let start = url.deletingLastPathComponent()
        for marker in rootMarkers {
            var directory = start
            while true {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) {
                    return directory
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return start
    }
}

#if os(macOS) || os(Linux)

/// A `LanguageService` that is a language server, run as a process and spoken
/// to over stdio: the Language Server Protocol.
///
/// One process per project root, started the first time a file in it is
/// asked about. A document is sent to the server only when a question needs
/// it to be current — not on every keystroke. Every answer degrades to "none"
/// when the server is missing, slow, or confused: a language server is help,
/// and help that fails must never get in the way.
public final class LanguageServer: LanguageService, @unchecked Sendable {
    public let config: LanguageServerConfig
    private let executable: URL
    private let lock = NSLock()
    private var connections: [String: ServerConnection] = [:]

    /// Nil when the server isn't installed here.
    public init?(_ config: LanguageServerConfig) {
        guard let executable = config.installedAt() else { return nil }
        self.config = config
        self.executable = executable
    }

    /// Every known server that is installed here.
    public static func installed() -> [LanguageServer] {
        LanguageServerConfig.known.compactMap(LanguageServer.init)
    }

    public func serves(_ url: URL) -> Bool { config.serves(url) }

    private func connection(for url: URL) -> ServerConnection {
        let root = config.root(of: url)
        return lock.withLock {
            if let existing = connections[root.path] { return existing }
            let made = ServerConnection(executable: executable, arguments: config.arguments, root: root)
            connections[root.path] = made
            return made
        }
    }

    /// Send the document, then ask; nil on any failure.
    private func ask(_ method: String, about document: CodeDocument,
                     _ params: [String: Any] = [:]) async -> Any? {
        let connection = connection(for: document.url)
        let languageID = config.languageIDs[document.url.pathExtension.lowercased()] ?? ""
        do {
            try await connection.sync(document, languageID: languageID)
            var full = params
            full["textDocument"] = ["uri": document.url.absoluteString]
            return try await LSP.result(of: connection.request(method, params: LSP.encode(full)))
        } catch {
            return nil
        }
    }

    private func position(_ offset: Int, in document: CodeDocument) -> [String: Any] {
        let position = CodePosition(offset: offset, in: document.text)
        return ["line": position.line, "character": position.character]
    }

    // MARK: LanguageService

    public func completions(in document: CodeDocument, at offset: Int) async -> [CodeCompletion] {
        let result = await ask("textDocument/completion", about: document,
                               ["position": position(offset, in: document)])
        return LSP.completions(from: result, in: document.text)
    }

    public func hover(in document: CodeDocument, at offset: Int) async -> String? {
        LSP.hover(from: await ask("textDocument/hover", about: document,
                                  ["position": position(offset, in: document)]))
    }

    public func definition(in document: CodeDocument, at offset: Int) async -> [CodeLocation] {
        LSP.locations(from: await ask("textDocument/definition", about: document,
                                      ["position": position(offset, in: document)]))
    }

    public func references(in document: CodeDocument, at offset: Int) async -> [CodeLocation] {
        LSP.locations(from: await ask("textDocument/references", about: document,
                                      ["position": position(offset, in: document),
                                       "context": ["includeDeclaration": true]]))
    }

    public func symbols(in document: CodeDocument) async -> [CodeSymbol] {
        LSP.symbols(from: await ask("textDocument/documentSymbol", about: document))
    }

    public func formatting(of document: CodeDocument, indent: Int, tabs: Bool) async -> [CodeEdit] {
        LSP.edits(from: await ask("textDocument/formatting", about: document,
                                  ["options": ["tabSize": indent, "insertSpaces": !tabs]]))
    }

    public func rename(in document: CodeDocument, at offset: Int, to name: String) async -> [URL: [CodeEdit]] {
        LSP.workspaceEdit(from: await ask("textDocument/rename", about: document,
                                          ["position": position(offset, in: document), "newName": name]))
    }

    public func diagnostics(in document: CodeDocument) async -> [CodeDiagnostic] {
        let connection = connection(for: document.url)
        let languageID = config.languageIDs[document.url.pathExtension.lowercased()] ?? ""
        guard (try? await connection.sync(document, languageID: languageID)) != nil else { return [] }
        return await connection.diagnostics(for: document.url.absoluteString, waiting: .seconds(5))
    }
}

/// One running server, for one project root.
actor ServerConnection {
    private let executable: URL
    private let arguments: [String]
    private let root: URL

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var versions: [String: Int] = [:]
    private var sent: [String: String] = [:]
    /// What the server last said is wrong with each document, and how many
    /// times it has said so — so a question can wait for a newer answer.
    private var published: [String: (count: Int, diagnostics: [CodeDiagnostic])] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    struct Unavailable: Error {}

    init(executable: URL, arguments: [String], root: URL) {
        self.executable = executable
        self.arguments = arguments
        self.root = root
    }

    /// Make the server's copy of `document` current — opening it the first
    /// time, sending it whole when it has changed, nothing when it hasn't.
    func sync(_ document: CodeDocument, languageID: String) async throws {
        try await start()
        let uri = document.url.absoluteString
        guard sent[uri] != document.text else { return }
        if let version = versions[uri] {
            versions[uri] = version + 1
            try notify("textDocument/didChange", [
                "textDocument": ["uri": uri, "version": version + 1],
                "contentChanges": [["text": document.text]],
            ])
        } else {
            versions[uri] = 1
            try notify("textDocument/didOpen", [
                "textDocument": ["uri": uri, "languageId": languageID, "version": 1,
                                 "text": document.text],
            ])
        }
        sent[uri] = document.text
    }

    /// What the server says is wrong with `uri` — a newer answer than the one
    /// it had when asked, if one comes within `limit`.
    func diagnostics(for uri: String, waiting limit: Duration) async -> [CodeDiagnostic] {
        let before = published[uri]?.count ?? 0
        let deadline = ContinuousClock.now + limit
        while (published[uri]?.count ?? 0) == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return published[uri]?.diagnostics ?? []
    }

    // MARK: Lifecycle

    private func start() async throws {
        if let process, process.isRunning { return }
        for continuation in pending.values { continuation.resume(throwing: Unavailable()) }
        pending = [:]
        versions = [:]
        sent = [:]
        buffer = Data()

        let server = Process()
        server.executableURL = executable
        server.arguments = arguments
        server.currentDirectoryURL = root
        let stdin = Pipe(), stdout = Pipe()
        server.standardInput = stdin
        server.standardOutput = stdout
        server.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            Task { await self.read(data) }
        }
        server.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.stopped() }
        }
        try server.run()
        process = server
        input = stdin.fileHandleForWriting

        _ = try await request("initialize", params: LSP.encode([
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": root.absoluteString,
            "capabilities": [
                "textDocument": [
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "publishDiagnostics": [:] as [String: Any],
                ],
            ],
        ]), timeout: .seconds(30))
        try notify("initialized", [:])
    }

    private func stopped() {
        for continuation in pending.values { continuation.resume(throwing: Unavailable()) }
        pending = [:]
        process = nil
        input = nil
    }

    // MARK: JSON-RPC

    /// The whole response to a request, as JSON.
    func request(_ method: String, params: Data, timeout: Duration = .seconds(10)) async throws -> Data {
        let id = nextID
        nextID += 1
        var message = Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":"#.utf8)
        message.append(params)
        message.append(Data("}".utf8))
        try write(message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: Unavailable())
    }

    private func notify(_ method: String, _ params: [String: Any]) throws {
        var message = Data(#"{"jsonrpc":"2.0","method":"\#(method)","params":"#.utf8)
        message.append(try LSP.encode(params))
        message.append(Data("}".utf8))
        try write(message)
    }

    private func write(_ body: Data) throws {
        guard let input else { throw Unavailable() }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        try input.write(contentsOf: frame)
    }

    private func read(_ data: Data) {
        buffer.append(data)
        while let body = LSP.nextFrame(from: &buffer) { dispatch(body) }
    }

    private func dispatch(_ body: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        let id = message["id"] as? Int
        let method = message["method"] as? String
        switch (id, method) {
        case (let id?, nil):
            pending.removeValue(forKey: id)?.resume(returning: body)
        case (let id?, _?):
            // A request from the server — configuration, registration,
            // progress. Answered with nothing, so it never waits on us.
            try? write(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#.utf8))
        case (nil, "textDocument/publishDiagnostics"):
            guard let params = message["params"] as? [String: Any],
                  let uri = params["uri"] as? String else { return }
            let diagnostics = LSP.diagnostics(from: params["diagnostics"])
            published[uri] = ((published[uri]?.count ?? 0) + 1, diagnostics)
        default:
            break
        }
    }
}

#endif

// MARK: - The protocol's shapes

/// Reading and writing what language servers send, apart from any process, so
/// it can be tested on its own. Results arrive in several shapes for the same
/// question — a location or a list of them or a list of links — and each is
/// read here into one.
enum LSP {
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// The `result` of a response, or nil for an error or a null.
    static func result(of response: Data) -> Any? {
        guard let message = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              message["error"] == nil else { return nil }
        let result = message["result"]
        return result is NSNull ? nil : result
    }

    /// One whole message body, taken off the front of `buffer` with its header.
    static func nextFrame(from buffer: inout Data) -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let field = header.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(field.dropFirst("content-length:".count)
                                    .trimmingCharacters(in: .whitespaces))
        else {
            buffer = Data()      // nothing to read it by: start again from what comes next
            return nil
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return body
    }

    static func position(_ any: Any?) -> CodePosition? {
        guard let object = any as? [String: Any],
              let line = object["line"] as? Int, let character = object["character"] as? Int
        else { return nil }
        return CodePosition(line: line, character: character)
    }

    static func range(_ any: Any?) -> CodeRange? {
        guard let object = any as? [String: Any],
              let start = position(object["start"]), let end = position(object["end"]) else { return nil }
        return CodeRange(start: start, end: end)
    }

    static func completions(from result: Any?, in text: String) -> [CodeCompletion] {
        let items = (result as? [String: Any])?["items"] as? [[String: Any]]
            ?? result as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let edit = item["textEdit"] as? [String: Any]
            let raw = edit?["newText"] as? String ?? item["insertText"] as? String ?? label
            let replace = range(edit?["range"]) ?? range(edit?["replace"])
            return CodeCompletion(
                label: label,
                detail: item["detail"] as? String ?? (item["kind"] as? Int).flatMap { completionKinds[$0] },
                insertText: (item["insertTextFormat"] as? Int) == 2 || raw.contains("$")
                    ? plainText(ofSnippet: raw) : raw,
                replaceRange: replace.map { $0.range(in: text) })
        }
    }

    /// `${1:placeholder}` → `placeholder`, `$1` and `$0` → nothing. Inserted
    /// as text; stepping between the placeholders is for later.
    static func plainText(ofSnippet snippet: String) -> String {
        var result = snippet
        for (pattern, template) in [(#"\$\{\d+:([^}]*)\}"#, "$1"), (#"\$\d+"#, "")] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: template)
        }
        return result
    }

    static func hover(from result: Any?) -> String? {
        guard let object = result as? [String: Any] else { return nil }
        func text(_ any: Any?) -> String? {
            if let string = any as? String { return string }
            if let marked = any as? [String: Any] { return marked["value"] as? String }
            if let list = any as? [Any] {
                let parts = list.compactMap(text)
                return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
            }
            return nil
        }
        return text(object["contents"]).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func locations(from result: Any?) -> [CodeLocation] {
        let list: [[String: Any]] = result as? [[String: Any]]
            ?? (result as? [String: Any]).map { [$0] } ?? []
        return list.compactMap { entry in
            // A Location, or a LocationLink pointing at one.
            let uri = entry["uri"] as? String ?? entry["targetUri"] as? String
            guard let uri, let url = URL(string: uri),
                  let range = range(entry["range"]) ?? range(entry["targetSelectionRange"])
                      ?? range(entry["targetRange"]) else { return nil }
            return CodeLocation(url: url, range: range)
        }
    }

    static func symbols(from result: Any?) -> [CodeSymbol] {
        guard let list = result as? [[String: Any]] else { return [] }
        func symbol(_ entry: [String: Any]) -> CodeSymbol? {
            guard let name = entry["name"] as? String else { return nil }
            let kind = (entry["kind"] as? Int).flatMap { symbolKinds[$0] } ?? "symbol"
            // A DocumentSymbol has its own ranges; a SymbolInformation has a location.
            let location = entry["location"] as? [String: Any]
            guard let full = range(entry["range"]) ?? range(location?["range"]) else { return nil }
            return CodeSymbol(name: name, kind: kind, detail: entry["detail"] as? String,
                              range: full, selectionRange: range(entry["selectionRange"]) ?? full,
                              children: (entry["children"] as? [[String: Any]] ?? []).compactMap(symbol))
        }
        return list.compactMap(symbol)
    }

    static func edits(from result: Any?) -> [CodeEdit] {
        (result as? [[String: Any]] ?? []).compactMap { entry in
            guard let range = range(entry["range"]), let text = entry["newText"] as? String else { return nil }
            return CodeEdit(range: range, newText: text)
        }
    }

    static func workspaceEdit(from result: Any?) -> [URL: [CodeEdit]] {
        guard let object = result as? [String: Any] else { return [:] }
        var byFile: [URL: [CodeEdit]] = [:]
        for (uri, edits) in object["changes"] as? [String: Any] ?? [:] {
            if let url = URL(string: uri) { byFile[url, default: []] += self.edits(from: edits) }
        }
        for change in object["documentChanges"] as? [[String: Any]] ?? [] {
            guard let document = change["textDocument"] as? [String: Any],
                  let uri = document["uri"] as? String, let url = URL(string: uri) else { continue }
            byFile[url, default: []] += edits(from: change["edits"])
        }
        return byFile
    }

    static func diagnostics(from any: Any?) -> [CodeDiagnostic] {
        (any as? [[String: Any]] ?? []).compactMap { entry in
            guard let range = range(entry["range"]), let message = entry["message"] as? String else { return nil }
            return CodeDiagnostic(
                range: range,
                severity: (entry["severity"] as? Int).flatMap(CodeDiagnostic.Severity.init) ?? .error,
                message: message, source: entry["source"] as? String)
        }
    }

    static let completionKinds: [Int: String] = [
        1: "text", 2: "method", 3: "function", 4: "constructor", 5: "field", 6: "variable",
        7: "class", 8: "interface", 9: "module", 10: "property", 12: "value", 13: "enum",
        14: "keyword", 15: "snippet", 17: "file", 21: "constant", 22: "struct",
    ]

    static let symbolKinds: [Int: String] = [
        1: "file", 2: "module", 3: "namespace", 4: "package", 5: "class", 6: "method",
        7: "property", 8: "field", 9: "constructor", 10: "enum", 11: "interface",
        12: "function", 13: "variable", 14: "constant", 15: "string", 16: "number",
        17: "boolean", 18: "array", 19: "object", 20: "key", 21: "null", 22: "enum member",
        23: "struct", 24: "event", 25: "operator", 26: "type parameter",
    ]
}
