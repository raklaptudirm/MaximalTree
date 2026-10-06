import Testing
import Foundation

/// The core builds with no UI anywhere — which `swift build` on a Mac can't
/// prove on its own, since SwiftUI and AppKit are right there to be imported.
/// So this reads the core's sources and holds them to it: what they may import
/// is Foundation and Observation, and CoreServices only on macOS, for the file
/// watcher.
///
/// Runs in both places the core is built: `swift test`, and the app's suite.
@Suite struct CoreBoundaryTests {
    /// Sources/MaximalTreeCore, found from this file rather than the working
    /// directory, which differs between the two runners.
    private var coreSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // MaximalTreeCoreTests
            .deletingLastPathComponent()            // Tests
            .deletingLastPathComponent()            // the repository
            .appendingPathComponent("Sources/MaximalTreeCore", isDirectory: true)
    }

    private static let allowed: Set<String> = ["Foundation", "Observation", "CoreServices"]

    @Test func theCoreImportsNothingThatDraws() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: coreSources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 5, "found no core sources at \(coreSources.path)")

        var offences: [String] = []
        for file in files {
            let text = try String(contentsOf: coreSources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let module = Self.imported(by: trimmed) else { continue }
                if !Self.allowed.contains(module) { offences.append("\(file): \(trimmed)") }
            }
        }
        #expect(offences.isEmpty, "the core imports what only a UI has: \(offences)")
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
