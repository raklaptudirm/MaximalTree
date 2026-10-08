import Foundation
import Observation

/// How one level of indentation is written in a file.
public struct Indentation: Equatable, Sendable {
    public var width: Int
    public var tabs: Bool

    public init(width: Int, tabs: Bool) {
        self.width = width
        self.tabs = tabs
    }

    /// What a project's `.editorconfig` says for this file, or the language's
    /// own habit when it says nothing. Reads the disk: ask off the main actor.
    public static func of(_ url: URL) -> Indentation {
        let fallback = defaultFor(url)
        guard let config = EditorConfig.properties(for: url) else { return fallback }
        let tabs = config["indent_style"].map { $0 == "tab" } ?? fallback.tabs
        let size = config["indent_size"] == "tab" ? config["tab_width"] : config["indent_size"]
        return Indentation(width: size.flatMap(Int.init) ?? config["tab_width"].flatMap(Int.init)
                                      ?? fallback.width,
                           tabs: tabs)
    }

    /// A language's own habit: tabs where the language or its tools insist,
    /// two where its community settled on two, four otherwise.
    static func defaultFor(_ url: URL) -> Indentation {
        let language = EditorLanguage.id(for: url) ?? ""
        if ["go", "makefile"].contains(language) { return Indentation(width: 4, tabs: true) }
        let two: Set = ["javascript", "typescript", "json", "yaml", "html", "xml", "css", "scss",
                        "less", "ruby", "nix", "lua", "dart", "elixir", "haskell", "elm", "ocaml"]
        return Indentation(width: two.contains(language) ? 2 : 4, tabs: false)
    }
}

/// How code is shown, as the reader set it, per language: how big, and
/// whether long lines wrap.
///
/// Per language because that is how the wish comes — Markdown wrapped, Swift
/// not; a dense language a size up. Remembered between runs in the defaults:
/// a preference about this machine's screen, not something only the reader
/// has, so nothing is lost if it goes.
@MainActor
@Observable
public final class EditorPreferences {
    public static let shared = EditorPreferences()

    /// The size code starts at — the prose editor's standard.
    public static let standardSize: CGFloat = 15
    /// Small enough to see a whole function, large enough to read across a room.
    public static let sizeRange: ClosedRange<CGFloat> = 9...28

    @ObservationIgnored private let defaults: UserDefaults
    private var sizes: [String: Double]
    private var wraps: [String: Bool]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sizes = defaults.dictionary(forKey: Self.sizesKey) as? [String: Double] ?? [:]
        wraps = defaults.dictionary(forKey: Self.wrapsKey) as? [String: Bool] ?? [:]
    }

    private static let sizesKey = "editor.sizeByLanguage"
    private static let wrapsKey = "editor.wrapByLanguage"

    /// Files the highlighter doesn't know share one setting.
    private func key(_ language: String?) -> String { language ?? "" }

    public func size(for language: String?) -> CGFloat {
        sizes[key(language)].map { CGFloat($0) } ?? Self.standardSize
    }

    /// A point bigger or smaller, within reason.
    public func stepSize(by delta: CGFloat, for language: String?) {
        let next = min(max(size(for: language) + delta, Self.sizeRange.lowerBound),
                       Self.sizeRange.upperBound)
        sizes[key(language)] = Double(next)
        defaults.set(sizes, forKey: Self.sizesKey)
    }

    public func resetSize(for language: String?) {
        sizes[key(language)] = nil
        defaults.set(sizes, forKey: Self.sizesKey)
    }

    public func wraps(_ language: String?) -> Bool { wraps[key(language)] ?? false }

    public func toggleWrap(for language: String?) {
        wraps[key(language)] = !wraps(language)
        defaults.set(wraps, forKey: Self.wrapsKey)
    }

    /// The code style for a file: the reader's size and wrapping for its
    /// language, and the indentation the file itself calls for.
    public func codeStyle(for url: URL?, indentation: Indentation) -> EditorStyle {
        let language = url.flatMap(EditorLanguage.id(for:))
        return .code(size: size(for: language), wrapLines: wraps(language),
                     indentSpaces: indentation.width, indentWithTabs: indentation.tabs)
    }
}

/// A project's `.editorconfig`, read the way editors read it: every file from
/// the nearest `root = true` down to the file's own folder, later sections and
/// nearer files winning. https://editorconfig.org
public enum EditorConfig {
    /// The properties that apply to `url`, lowercased, or nil when no
    /// `.editorconfig` says anything about it.
    public static func properties(for url: URL) -> [String: String]? {
        var files: [URL] = []
        var directory = url.deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(".editorconfig")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                files.append(candidate)
                if parse(text).root { break }
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        var result: [String: String] = [:]
        // Farthest first, so nearer files override.
        for file in files.reversed() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let base = file.deletingLastPathComponent().standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1))
                                                      : url.lastPathComponent
            for section in parse(text).sections where matches(section.glob, relative) {
                result.merge(section.properties) { _, new in new }
            }
        }
        return result.isEmpty ? nil : result
    }

    struct Parsed {
        var root = false
        var sections: [(glob: String, properties: [String: String])] = []
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        var current: (glob: String, properties: [String: String])?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let current { parsed.sections.append(current) }
                current = (String(line.dropFirst().dropLast()), [:])
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if current == nil { if key == "root" { parsed.root = value == "true" } }
            else { current?.properties[key] = value }
        }
        if let current { parsed.sections.append(current) }
        return parsed
    }

    /// Whether a section's glob takes this path, relative to its file. A glob
    /// without a slash matches the name at any depth, as the format says.
    static func matches(_ glob: String, _ relative: String) -> Bool {
        var pattern = ""
        var index = glob.startIndex
        var inBraces = false
        while index < glob.endIndex {
            let character = glob[index]
            switch character {
            case "*":
                let next = glob.index(after: index)
                if next < glob.endIndex, glob[next] == "*" {
                    pattern += ".*"
                    index = next
                } else {
                    pattern += "[^/]*"
                }
            case "?": pattern += "[^/]"
            case "{": pattern += "("; inBraces = true
            case "}": pattern += ")"; inBraces = false
            case "," where inBraces: pattern += "|"
            case "[", "]": pattern.append(character)
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = glob.index(after: index)
        }
        let anchored = glob.contains("/") ? "^/?" + pattern + "$" : "(^|/)" + pattern + "$"
        return relative.range(of: anchored, options: .regularExpression) != nil
    }
}
