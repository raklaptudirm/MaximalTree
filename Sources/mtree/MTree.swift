import Foundation
import MaximalTreeKit
import MaximalTreeHost
import FileSystem
import Git
import Typst
import Web
import YouTube
#if canImport(ICloud)
import ICloud
#endif

/// MaximalTree with no window: the same engine and the same plugins' core
/// halves the app runs, asked from a shell.
///
///     mtree ls <uri> [--all]      what is under a node
///     mtree show <uri>            what a node is
///     mtree actions <uri>         what can be done to it
///     mtree run <action> <uri>    do it
///     mtree mount <uri>           keep it among this host's roots
///     mtree roots                 what this host has mounted
///     mtree workspaces            this host's workspaces
///
/// Its workspaces are its own (`--library <file>`, or $MTREE_LIBRARY), never
/// the app's. What the plugins keep — bookmarks, feed names — is shared with
/// the app, as it would be with any other window onto the same things.
@main
struct MTree {
    static let usage = """
        usage: mtree [--library <file>] <command> [arguments]

          ls <uri> [--all]      what is under a node (--all: every page)
          show <uri>            what a node is
          actions <uri>         what can be done to it
          run <action> <uri>    do it
          mount <uri>           keep it among this host's roots
          roots                 what this host has mounted
          workspaces            this host's workspaces
        """

    /// Every plugin with a core half, as a list rather than a scan: a host
    /// like this loads no bundles.
    @MainActor
    static func plugins(_ registry: CoreRegistry) {
        FileSystemCore.register(with: registry)
        GitCore.register(with: registry)
        TypstCore.register(with: registry)
        WebCore.register(with: registry)
        YouTubeCore.register(with: registry)
        #if canImport(ICloud)
        ICloudCore.register(with: registry)
        #endif
    }

    @MainActor
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let library = take("--library", from: &arguments)
            ?? ProcessInfo.processInfo.environment["MTREE_LIBRARY"]
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("maximaltree-cli/workspaces.json").path
        let all = arguments.contains("--all")
        arguments.removeAll { $0 == "--all" }

        guard let command = arguments.first else { fail(usage, code: 2) }
        let rest = Array(arguments.dropFirst())

        let host = HeadlessHost(library: URL(fileURLWithPath: library), plugins: plugins)
        for notice in await host.takeNotices() { warn(notice) }

        do {
            switch (command, rest.count) {
            case ("ls", 1):
                for child in try await host.children(of: rest[0], all: all) {
                    print(row(child))
                }
                if try host.hasMore(under: rest[0]) { print("…") }
            case ("show", 1):
                show(try await host.node(rest[0]))
            case ("actions", 1):
                for action in try await host.actions(for: rest[0]) {
                    print("\(action.id)\t\(action.title)")
                }
            case ("run", 2):
                try await host.run(rest[0], on: rest[1])
            case ("mount", 1):
                try await host.mount(rest[0])
            case ("roots", 0):
                for root in host.roots { print(root.uri) }
            case ("workspaces", 0):
                for workspace in host.workspaces {
                    print("\(workspace.active ? "*" : " ") \(workspace.name)")
                }
            default:
                fail(usage, code: 2)
            }
        } catch {
            fail("mtree: \(error)", code: 1)
        }
        for notice in await host.takeNotices() { warn(notice) }
    }

    /// One line per node: its name, a slash if it has anything under it, and
    /// its address — tab-separated, so `cut -f2` gets the addresses.
    static func row(_ node: Node) -> String {
        "\(node.label)\(node.hasChildren ? "/" : "")\t\(node.id.uri)"
    }

    static func show(_ node: Node) {
        print("\(node.label)\n  \(node.id.uri)\n  type: \(node.type.raw)")
        if let subtitle = node.subtitle { print("  \(subtitle)") }
        for key in node.attributes.keys {
            guard let value = node.attributes[key] else { continue }
            print("  \(key): \(describe(value))")
        }
    }

    static func describe(_ value: Attributes.Value) -> String {
        switch value {
        case .string(let string): string
        case .int(let int): "\(int)"
        case .double(let double): "\(double)"
        case .bool(let bool): "\(bool)"
        case .date(let date): date.formatted(.iso8601)
        }
    }

    /// The value after `flag`, taking both out of `arguments`.
    static func take(_ flag: String, from arguments: inout [String]) -> String? {
        guard let at = arguments.firstIndex(of: flag), at + 1 < arguments.count else { return nil }
        let value = arguments[at + 1]
        arguments.removeSubrange(at...at + 1)
        return value
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("mtree: \(message)\n".utf8))
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }
}
