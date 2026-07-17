import Foundation

/// One compiler message, parsed from `--diagnostic-format short` output:
/// `<file>:<line>:<col>: <severity>: <message>` (location optional).
/// Lines are 1-based and columns 0-based, as typst reports them.
struct TypstDiagnostic: Equatable, Identifiable, Sendable {
    enum Severity: String, Sendable {
        case error, warning
    }

    let severity: Severity
    let line: Int?
    let column: Int?
    let message: String

    var id: String { "\(line ?? 0):\(column ?? 0):\(severity.rawValue):\(message)" }
}

/// Wraps the `typst` CLI. Compiles the *buffer* (not the saved file) by piping it
/// through stdin with `--root` at the document's directory, so live preview shows
/// unsaved edits while relative imports/images/reads still resolve.
enum TypstCompiler {
    struct Output: Sendable {
        let pdf: Data?
        let diagnostics: [TypstDiagnostic]
    }

    /// A GUI app doesn't inherit a login shell's PATH, so probe the places package
    /// managers actually install typst (Homebrew, Nix profiles, cargo).
    static let executable: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/etc/profiles/per-user/\(NSUserName())/bin/typst",   // nix-darwin per-user
            "/run/current-system/sw/bin/typst",                   // nix-darwin system
            "\(home)/.nix-profile/bin/typst",
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            "\(home)/.cargo/bin/typst",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    static var isAvailable: Bool { executable != nil }

    /// Compile `source` as though it were the contents of `documentURL`.
    static func compile(source: String, documentURL: URL) async -> Output {
        await Task.detached(priority: .userInitiated) {
            compileSync(source: source, documentURL: documentURL)
        }.value
    }

    static func compileSync(source: String, documentURL: URL) -> Output {
        guard let executable else {
            return Output(pdf: nil, diagnostics: [
                TypstDiagnostic(severity: .error, line: nil, column: nil,
                                message: "typst is not installed")
            ])
        }

        let root = documentURL.deletingLastPathComponent()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typst-preview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["compile", "--diagnostic-format", "short",
                             "--root", root.path, "-", outURL.path]
        process.currentDirectoryURL = root

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        do { try process.run() } catch {
            return Output(pdf: nil, diagnostics: [
                TypstDiagnostic(severity: .error, line: nil, column: nil,
                                message: "couldn't run typst: \(error.localizedDescription)")
            ])
        }

        stdinPipe.fileHandleForWriting.write(Data(source.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let diagnostics = parseDiagnostics(String(decoding: stderrData, as: UTF8.self))
        return Output(pdf: try? Data(contentsOf: outURL), diagnostics: diagnostics)
    }

    /// Parse `--diagnostic-format short` lines. Tolerates messages without a
    /// location (`error: no such file`) and skips anything that isn't a diagnostic.
    static func parseDiagnostics(_ stderr: String) -> [TypstDiagnostic] {
        let pattern = /^(?:(?<file>[^:\n]+):(?<line>\d+):(?<col>\d+):\s*)?(?<sev>error|warning):\s?(?<msg>.*)$/
        return stderr.split(separator: "\n").compactMap { rawLine in
            guard let match = String(rawLine).wholeMatch(of: pattern),
                  let severity = TypstDiagnostic.Severity(rawValue: String(match.sev))
            else { return nil }
            return TypstDiagnostic(
                severity: severity,
                line: match.line.flatMap { Int($0) },
                column: match.col.flatMap { Int($0) },
                message: String(match.msg)
            )
        }
    }
}
