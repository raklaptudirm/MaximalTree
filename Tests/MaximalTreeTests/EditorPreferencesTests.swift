import Testing
import Foundation
@testable import MaximalEditorKit
@testable import MaximalTree
import MaximalTreeKit

/// A folder of its own, marked as a project root so no `.editorconfig` above
/// the temporary directory can reach into it.
private struct Project {
    let root: URL

    init(_ config: String) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editorconfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("root = true\n" + config, to: ".editorconfig")
    }

    func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func file(_ path: String) -> URL { root.appendingPathComponent(path) }
}

@Suite struct EditorConfigTests {
    @Test func aProjectSaysHowItIndents() throws {
        let project = try Project("[*]\nindent_style = space\nindent_size = 2\n")
        #expect(Indentation.of(project.file("a.swift")) == Indentation(width: 2, tabs: false))
    }

    /// Later sections win, and a nearer file wins over a farther one.
    @Test func theNearestAndLatestWins() throws {
        let project = try Project("[*]\nindent_size = 2\n[*.swift]\nindent_size = 4\n")
        try project.write("[*.swift]\nindent_size = 3\n", to: "sub/.editorconfig")
        #expect(Indentation.of(project.file("a.swift")).width == 4)
        #expect(Indentation.of(project.file("sub/a.swift")).width == 3)
        #expect(Indentation.of(project.file("sub/a.py")).width == 2)
    }

    /// `root = true` is where the walk stops: what is above it says nothing.
    @Test func rootStopsTheWalk() throws {
        let outer = try Project("[*]\nindent_size = 8\n")
        try outer.write("root = true\n[*.txt]\nindent_style = tab\n", to: "inner/.editorconfig")
        let indentation = Indentation.of(outer.file("inner/a.txt"))
        #expect(indentation.tabs)
        #expect(indentation.width != 8, "a config above the root reached past it")
    }

    @Test func globsMatchTheWayTheFormatSays() {
        #expect(EditorConfig.matches("*.{js,ts}", "src/app.ts"))
        #expect(!EditorConfig.matches("*.{js,ts}", "src/app.swift"))
        #expect(EditorConfig.matches("[Mm]akefile", "Makefile"))
        #expect(EditorConfig.matches("docs/**.md", "docs/a/b.md"))
        #expect(!EditorConfig.matches("docs/*.md", "other/docs/a.md"))
        #expect(EditorConfig.matches("*.md", "deep/down/a.md"), "no slash matches at any depth")
    }

    @Test func aTabSizedIndentTakesTheTabWidth() throws {
        let project = try Project("[*]\nindent_style = tab\nindent_size = tab\ntab_width = 8\n")
        #expect(Indentation.of(project.file("a.c")) == Indentation(width: 8, tabs: true))
    }

    /// Where nothing is said, each language's own habit.
    @Test func languagesHaveTheirHabits() throws {
        let project = try Project("")
        #expect(Indentation.of(project.file("main.go")).tabs)
        #expect(Indentation.of(project.file("Makefile")).tabs)
        #expect(Indentation.of(project.file("app.js")) == Indentation(width: 2, tabs: false))
        #expect(Indentation.of(project.file("a.swift")) == Indentation(width: 4, tabs: false))
    }
}

@MainActor
@Suite struct EditorPreferencesTests {
    /// Preferences in a defaults suite of their own, not the reader's.
    private func preferences() -> (EditorPreferences, UserDefaults) {
        let defaults = UserDefaults(suiteName: "editor-preferences-\(UUID().uuidString)")!
        return (EditorPreferences(defaults: defaults), defaults)
    }

    @Test func sizesStepWithinReasonPerLanguage() {
        let (preferences, _) = preferences()
        #expect(preferences.size(for: "swift") == 15)
        preferences.stepSize(by: 2, for: "swift")
        #expect(preferences.size(for: "swift") == 17)
        #expect(preferences.size(for: "python") == 15, "one language's size moved another's")
        for _ in 0..<40 { preferences.stepSize(by: -1, for: "swift") }
        #expect(preferences.size(for: "swift") == EditorPreferences.sizeRange.lowerBound)
        preferences.resetSize(for: "swift")
        #expect(preferences.size(for: "swift") == 15)
    }

    @Test func theyAreRememberedBetweenRuns() {
        let (preferences, defaults) = preferences()
        preferences.stepSize(by: 3, for: "rust")
        preferences.toggleWrap(for: "markdown")
        let again = EditorPreferences(defaults: defaults)
        #expect(again.size(for: "rust") == 18)
        #expect(again.wraps("markdown"))
        #expect(!again.wraps("rust"))
    }

    /// A file's style: the reader's size and wrapping for its language, the
    /// indentation the file calls for.
    @Test func aStyleIsTheReadersAndTheFiles() {
        let (preferences, _) = preferences()
        preferences.stepSize(by: 1, for: "go")
        let style = preferences.codeStyle(for: URL(fileURLWithPath: "/x/main.go"),
                                          indentation: Indentation(width: 4, tabs: true))
        #expect(style.size == 16)
        #expect(style.indentUnit == "\t")
        #expect(style.editsCode)
    }
}

@MainActor
@Suite struct CodeViewKeyTests {
    /// The keys the code editor declares name actions it registers.
    @Test func theZKeysAreTheCanvasesAndRegistered() {
        let registry = Registry()
        TextEditorPlugin().register(with: registry)
        let ids = Set(registry.actions.map(\.id))
        for key in TextEditorPlugin.viewKeys {
            #expect(ids.contains(key.action), "\(key.sequence) names \(key.action), which isn't registered")
        }
        let canvasKeys = registry.canvases.flatMap(\.keys).map(\.sequence)
        #expect(canvasKeys.contains("z i") && canvasKeys.contains("z w"))
    }
}
