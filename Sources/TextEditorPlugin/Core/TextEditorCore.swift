import Foundation
import MaximalTreeKit

/// The text editor's half that needs no window: what a language knows about
/// code, from every language server installed here.
///
/// Typst's server is typst's to register, so it is left to it; the rest are
/// here, since a source file is this editor's whatever its language. Anything
/// registered before these — a plugin with its own service for its language —
/// is asked first.
public enum TextEditorCore {
    @MainActor
    public static func register(with registry: CoreRegistry) {
        #if os(macOS) || os(Linux)
        for server in LanguageServer.installed() where server.config.name != "tinymist" {
            registry.register(languageService: server)
        }
        #endif
    }
}
