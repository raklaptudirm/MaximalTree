import Foundation

// MARK: - Language intelligence

/// What a language knows about its own code: what could go here, what this
/// is, where it was defined, what refers to it, what a file declares, how it
/// should be formatted, and what is wrong with it.
///
/// Contributed, not built in. A plugin registers one for the languages it
/// knows (`CoreRegistry.register(languageService:)`) — a language server
/// through `LanguageServer`, or anything else that can answer. Every answer
/// has a default that says nothing, so a service implements what it can and
/// is asked only for that.
///
/// Positions are UTF-16 offsets into the text the question was asked about,
/// as the editor counts; answers about other files come as line and
/// character, since only their own text could turn those into offsets.
public protocol LanguageService: Sendable {
    /// Whether this service answers for the file at `url`.
    func serves(_ url: URL) -> Bool

    func completions(in document: CodeDocument, at offset: Int) async -> [CodeCompletion]
    /// A description of what is at `offset`, as plain text or Markdown.
    func hover(in document: CodeDocument, at offset: Int) async -> String?
    func definition(in document: CodeDocument, at offset: Int) async -> [CodeLocation]
    func references(in document: CodeDocument, at offset: Int) async -> [CodeLocation]
    /// What the file declares, nested as it is in the file.
    func symbols(in document: CodeDocument) async -> [CodeSymbol]
    /// The edits that format the whole document.
    func formatting(of document: CodeDocument, indent: Int, tabs: Bool) async -> [CodeEdit]
    /// Every edit, in every file, that renames what is at `offset` to `name`.
    func rename(in document: CodeDocument, at offset: Int, to name: String) async -> [URL: [CodeEdit]]
    /// What is wrong with the document as it stands.
    func diagnostics(in document: CodeDocument) async -> [CodeDiagnostic]
}

public extension LanguageService {
    func completions(in document: CodeDocument, at offset: Int) async -> [CodeCompletion] { [] }
    func hover(in document: CodeDocument, at offset: Int) async -> String? { nil }
    func definition(in document: CodeDocument, at offset: Int) async -> [CodeLocation] { [] }
    func references(in document: CodeDocument, at offset: Int) async -> [CodeLocation] { [] }
    func symbols(in document: CodeDocument) async -> [CodeSymbol] { [] }
    func formatting(of document: CodeDocument, indent: Int, tabs: Bool) async -> [CodeEdit] { [] }
    func rename(in document: CodeDocument, at offset: Int, to name: String) async -> [URL: [CodeEdit]] { [:] }
    func diagnostics(in document: CodeDocument) async -> [CodeDiagnostic] { [] }
}

/// A file as the editor has it — possibly unsaved, which is the point: a
/// question is about the text in front of the reader, not the text on disk.
public struct CodeDocument: Sendable, Equatable {
    public var url: URL
    public var text: String

    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

/// A place in a file as line and character — UTF-16 code units into the
/// line, as the language server protocol counts and as `NSString` does.
public struct CodePosition: Sendable, Hashable, Codable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    /// Where this is in `text`, clamped to it.
    public func offset(in text: String) -> Int {
        let ns = text as NSString
        var line = 0, index = 0
        while line < self.line, index < ns.length {
            if ns.character(at: index) == 10 { line += 1 }
            index += 1
        }
        return min(index + character, ns.length)
    }

    /// The position of a UTF-16 offset into `text`.
    public init(offset: Int, in text: String) {
        let ns = text as NSString
        let clamped = min(max(offset, 0), ns.length)
        var line = 0, lineStart = 0
        for index in 0..<clamped where ns.character(at: index) == 10 {
            line += 1
            lineStart = index + 1
        }
        self.init(line: line, character: clamped - lineStart)
    }
}

public struct CodeRange: Sendable, Hashable, Codable {
    public var start: CodePosition
    public var end: CodePosition

    public init(start: CodePosition, end: CodePosition) {
        self.start = start
        self.end = end
    }

    /// The range in `text`, as the editor measures one.
    public func range(in text: String) -> NSRange {
        let from = start.offset(in: text), to = end.offset(in: text)
        return NSRange(location: from, length: max(to - from, 0))
    }
}

public struct CodeLocation: Sendable, Hashable {
    public var url: URL
    public var range: CodeRange

    public init(url: URL, range: CodeRange) {
        self.url = url
        self.range = range
    }
}

public struct CodeCompletion: Sendable, Equatable {
    public var label: String
    /// A word about what it is — its type, or what kind of thing.
    public var detail: String?
    public var insertText: String
    /// What it replaces in the document asked about; nil for the word being typed.
    public var replaceRange: NSRange?

    public init(label: String, detail: String? = nil, insertText: String, replaceRange: NSRange? = nil) {
        self.label = label
        self.detail = detail
        self.insertText = insertText
        self.replaceRange = replaceRange
    }
}

public struct CodeSymbol: Sendable, Equatable {
    public var name: String
    /// What kind of thing it is, in a word: "struct", "function", "property".
    public var kind: String
    public var detail: String?
    /// All of it — its body included.
    public var range: CodeRange
    /// Its name, where the reader would put the cursor to mean it.
    public var selectionRange: CodeRange
    public var children: [CodeSymbol]

    public init(name: String, kind: String, detail: String? = nil, range: CodeRange,
                selectionRange: CodeRange, children: [CodeSymbol] = []) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }
}

public struct CodeEdit: Sendable, Equatable {
    public var range: CodeRange
    public var newText: String

    public init(range: CodeRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    /// `edits` applied to `text`, last first so earlier ranges stay true.
    public static func apply(_ edits: [CodeEdit], to text: String) -> String {
        let ordered = edits.map { ($0.range.range(in: text), $0.newText) }
            .sorted { $0.0.location > $1.0.location }
        let result = NSMutableString(string: text)
        for (range, newText) in ordered { result.replaceCharacters(in: range, with: newText) }
        return result as String
    }
}

public struct CodeDiagnostic: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case error = 1, warning, information, hint
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var range: CodeRange
    public var severity: Severity
    public var message: String
    /// Who said so: "swiftc", "clang", "typst".
    public var source: String?

    public init(range: CodeRange, severity: Severity, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }
}
