import Testing
import Foundation

/// The core builds with no UI anywhere — which `swift build` on a Mac can't
/// prove on its own, since SwiftUI and AppKit are right there to be imported.
/// So this reads the core's sources and holds them to it: what they may import
/// is Foundation and Observation, and CoreServices only on macOS, for the file
/// watcher.
///
/// The host's engine is held to the same, plus the SDK it is built on. On the
/// Mac it is compiled into the app, one module with the views, so an import is
/// the only thing that could let UI in unnoticed there; a reference to one of
/// the app's own views is caught by `swift test` instead, which builds the
/// engine alone.
///
/// Runs in both places the core is built: `swift test`, and the app's suite.
@Suite struct CoreBoundaryTests {
    /// A folder under Sources, found from this file rather than the working
    /// directory, which differs between the two runners.
    private func sources(_ folder: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // MaximalTreeCoreTests
            .deletingLastPathComponent()            // Tests
            .deletingLastPathComponent()            // the repository
            .appendingPathComponent("Sources/\(folder)", isDirectory: true)
    }

    /// Every import in `folder` that isn't one of `allowed`, by file.
    private func offences(in folder: String, allowed: Set<String>) throws -> [String] {
        let directory = sources(folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 5, "found no sources at \(directory.path)")

        var offences: [String] = []
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let module = Self.imported(by: trimmed) else { continue }
                if !allowed.contains(module) { offences.append("\(file): \(trimmed)") }
            }
        }
        return offences
    }

    @Test func theCoreImportsNothingThatDraws() throws {
        let offences = try offences(in: "MaximalTreeCore",
                                    allowed: ["Foundation", "Observation", "CoreServices"])
        #expect(offences.isEmpty, "the core imports what only a UI has: \(offences)")
    }

    @Test func theHostEngineImportsNothingThatDraws() throws {
        let offences = try offences(in: "MaximalTreeHost",
                                    allowed: ["Foundation", "Observation", "MaximalTreeKit"])
        #expect(offences.isEmpty, "the host's engine imports what only a UI has: \(offences)")
    }

    /// The module a line imports, if it is an import: `import X`,
    /// `@testable import X`, `@_exported import X`, `import struct X.Y`.
    static func imported(by line: String) -> String? {
        let words = line.split(separator: " ").map(String.init)
        guard let at = words.firstIndex(of: "import"), at + 1 < words.count,
              words[..<at].allSatisfy({ $0.hasPrefix("@") }) else { return nil }
        let kinds: Set = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"]
        let target = kinds.contains(words[at + 1]) && at + 2 < words.count ? words[at + 2] : words[at + 1]
        return String(target.split(separator: ".").first ?? "")
    }

    @Test func importsAreRecognised() {
        #expect(Self.imported(by: "import SwiftUI") == "SwiftUI")
        #expect(Self.imported(by: "@_exported import AppKit") == "AppKit")
        #expect(Self.imported(by: "import struct UIKit.UIColor") == "UIKit")
        #expect(Self.imported(by: "let x = 1 // import SwiftUI") == nil)
    }
}
