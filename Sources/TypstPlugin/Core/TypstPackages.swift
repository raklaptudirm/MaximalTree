import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession, outside Apple's Foundation
#endif
import TypstFFI

/// Fetches typst packages for the compiler.
///
/// The engine resolves `@preview/foo:1.2.3` under its packages directory and,
/// when it isn't there, asks us to download it from Typst Universe. HTTP lives
/// here rather than inside the Rust library on purpose: the app already owns
/// networking, and keeping TLS out of the compiler is what lets that library
/// stay portable (it's also the only compile path that can exist on iOS).
///
/// The engine hands over a destination path instead of taking bytes back, so
/// neither side has to free the other's memory.
enum TypstPackages {
    /// Wire the fetcher into the engine. Called once at plugin registration —
    /// before any compile, since the first one may already need a package.
    static func install() {
        typst_set_package_fetcher(fetcher)
    }

    /// 0 = downloaded, 1 = the registry says it doesn't exist (404, which the
    /// engine turns into "no such package/version" and a suggestion of the
    /// latest one), 2 = anything else went wrong.
    private static let fetcher: @convention(c)
        (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { urlPtr, destPtr in
            guard let urlPtr, let destPtr,
                  let url = URL(string: String(cString: urlPtr))
            else { return 2 }
            return download(url, to: URL(fileURLWithPath: String(cString: destPtr)))
        }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// Synchronous by contract: the engine calls this mid-compile and can't
    /// continue without the package. Compiles always run off the main actor
    /// (`Task.detached`), so the wait costs a background thread, not the UI.
    static func download(_ url: URL, to destination: URL) -> Int32 {
        final class Result: @unchecked Sendable { var status: Int32 = 2 }
        let result = Result()
        let finished = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: url) { data, response, _ in
            defer { finished.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            guard http.statusCode != 404 else {
                result.status = 1
                return
            }
            guard (200..<300).contains(http.statusCode), let data else { return }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: destination)
                result.status = 0
            } catch {
                result.status = 2
            }
        }
        task.resume()
        finished.wait()
        return result.status
    }
}
