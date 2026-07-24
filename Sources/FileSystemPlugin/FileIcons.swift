import Foundation
import UniformTypeIdentifiers
import MaximalTreeKit

// Icons for source, config, and document files.
//
// Content types can't carry this: macOS registers no UTI for most source files
// (Rust, Nix, Elixir, Kotlin, Dockerfile…), so they'd all land on the generic
// document icon. Keyed by extension and filename instead — the same facts the
// editor uses to pick a grammar, but answering a different question, in the
// layer that owns presentation. The FileSystem provider deliberately doesn't
// depend on the editor framework: files look right with no editor installed.
//
// The symbol says what *kind* of thing it is (code, script, config, data); the
// tint says *which* language, using each language's own colour where it has a
// recognizable one. Muted a little so they read on both light and dark rows.
extension FileSystemProvider {

    // MARK: Palette

    private static func code(_ tint: NodeTint) -> NodeIcon {
        NodeIcon("chevron.left.forwardslash.chevron.right", tint: tint)
    }
    private static func script(_ tint: NodeTint) -> NodeIcon { NodeIcon("terminal", tint: tint) }
    private static func data(_ tint: NodeTint) -> NodeIcon { NodeIcon("curlybraces", tint: tint) }
    private static func config(_ tint: NodeTint) -> NodeIcon { NodeIcon("gearshape", tint: tint) }
    private static func markup(_ tint: NodeTint) -> NodeIcon { NodeIcon("chevron.left.slash.chevron.right", tint: tint) }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NodeTint {
        .rgb(red: r, green: g, blue: b)
    }

    // Language colours (their own, nudged toward mid-tones for contrast).
    private static let swiftOrange = rgb(0.94, 0.32, 0.22)
    private static let rustRust = rgb(0.81, 0.45, 0.29)
    private static let goCyan = rgb(0.00, 0.63, 0.77)
    private static let pythonBlue = rgb(0.22, 0.46, 0.67)
    private static let rubyRed = rgb(0.80, 0.20, 0.18)
    private static let jsGold = rgb(0.79, 0.64, 0.15)
    private static let tsBlue = rgb(0.19, 0.47, 0.78)
    private static let javaBrown = rgb(0.69, 0.45, 0.10)
    private static let kotlinViolet = rgb(0.50, 0.32, 0.95)
    private static let cGray = rgb(0.45, 0.45, 0.48)
    private static let cppBlue = rgb(0.10, 0.40, 0.65)
    private static let csharpPurple = rgb(0.45, 0.20, 0.55)
    private static let objcBlue = rgb(0.26, 0.56, 0.95)
    private static let phpIndigo = rgb(0.47, 0.48, 0.71)
    private static let haskellPlum = rgb(0.42, 0.35, 0.58)
    private static let elixirPurple = rgb(0.48, 0.33, 0.55)
    private static let erlangMagenta = rgb(0.72, 0.25, 0.60)
    private static let scalaRed = rgb(0.86, 0.24, 0.20)
    private static let clojureBlue = rgb(0.35, 0.51, 0.85)
    private static let luaNavy = rgb(0.27, 0.36, 0.78)
    private static let dartTeal = rgb(0.00, 0.68, 0.65)
    private static let juliaPurple = rgb(0.58, 0.35, 0.70)
    private static let rBlue = rgb(0.15, 0.43, 0.76)
    private static let perlTeal = rgb(0.05, 0.58, 0.74)
    private static let nixBlue = rgb(0.35, 0.60, 0.82)
    private static let elmSky = rgb(0.36, 0.67, 0.82)
    private static let crystalSlate = rgb(0.35, 0.35, 0.40)
    private static let htmlOrange = rgb(0.89, 0.35, 0.18)
    private static let cssIndigo = rgb(0.38, 0.30, 0.60)

    // MARK: Tables

    /// Whole-name matches, for files that carry their meaning in the name.
    static let iconsByFileName: [String: NodeIcon] = [
        "makefile": NodeIcon("hammer", tint: .orange),
        "gnumakefile": NodeIcon("hammer", tint: .orange),
        "justfile": NodeIcon("hammer", tint: .orange),
        "cmakelists.txt": NodeIcon("hammer", tint: .orange),
        "dockerfile": NodeIcon("cube", tint: .blue),
        "containerfile": NodeIcon("cube", tint: .blue),
        "cargo.lock": NodeIcon("lock", tint: .secondary),
        "package-lock.json": NodeIcon("lock", tint: .secondary),
        "gemfile.lock": NodeIcon("lock", tint: .secondary),
        "podfile.lock": NodeIcon("lock", tint: .secondary),
        "rakefile": code(rubyRed), "gemfile": code(rubyRed), "podfile": code(rubyRed),
        "fastfile": code(rubyRed), "brewfile": code(rubyRed), "vagrantfile": code(rubyRed),
        "license": NodeIcon("checkmark.seal", tint: .secondary),
        "licence": NodeIcon("checkmark.seal", tint: .secondary),
        "copying": NodeIcon("checkmark.seal", tint: .secondary),
        "readme": NodeIcon("book", tint: .secondary),
        "changelog": NodeIcon("clock.arrow.circlepath", tint: .secondary),
        ".gitignore": NodeIcon("arrow.triangle.branch", tint: .orange),
        ".gitattributes": NodeIcon("arrow.triangle.branch", tint: .orange),
        ".gitmodules": NodeIcon("arrow.triangle.branch", tint: .orange),
        ".dockerignore": NodeIcon("cube", tint: .secondary),
        ".env": NodeIcon("key", tint: .yellow),
        ".editorconfig": config(.secondary), ".gitconfig": config(.secondary),
        ".npmrc": config(.secondary), ".bashrc": script(.green),
        ".zshrc": script(.green), ".bash_profile": script(.green),
        ".zprofile": script(.green), ".profile": script(.green),
        ".vimrc": NodeIcon("v.square", tint: .green),
    ]

    /// Extension → icon. Anything absent falls back to the content-type rules.
    static let iconsByExtension: [String: NodeIcon] = [
        // Apple
        "swift": NodeIcon("swift", tint: swiftOrange),
        "m": code(objcBlue), "mm": code(objcBlue), "h": code(cGray),
        "playground": NodeIcon("swift", tint: swiftOrange),
        // Systems
        "c": code(cGray),
        "cpp": code(cppBlue), "cc": code(cppBlue), "cxx": code(cppBlue),
        "hpp": code(cppBlue), "hh": code(cppBlue), "hxx": code(cppBlue),
        "rs": code(rustRust),
        "go": code(goCyan),
        "zig": code(swiftOrange),
        "d": code(rustRust),
        "nim": code(jsGold), "cr": code(crystalSlate),
        "vala": code(csharpPurple),
        // Managed / JVM / .NET
        "java": code(javaBrown), "jav": code(javaBrown),
        "kt": code(kotlinViolet), "kts": code(kotlinViolet),
        "scala": code(scalaRed), "sc": code(scalaRed),
        "groovy": code(cppBlue), "gvy": code(cppBlue),
        "gradle": NodeIcon("hammer", tint: .green),
        "cs": code(csharpPurple), "csx": code(csharpPurple),
        "fs": code(csharpPurple), "fsi": code(csharpPurple), "fsx": code(csharpPurple),
        "vb": code(csharpPurple),
        "dart": code(dartTeal),
        // Scripting
        "py": code(pythonBlue), "pyw": code(pythonBlue), "pyi": code(pythonBlue),
        "rb": code(rubyRed), "rbw": code(rubyRed), "gemspec": code(rubyRed),
        "podspec": code(rubyRed),
        "php": code(phpIndigo), "phtml": code(phpIndigo),
        "pl": code(perlTeal), "pm": code(perlTeal),
        "lua": code(luaNavy),
        "tcl": code(.orange),
        // Web
        "js": code(jsGold), "mjs": code(jsGold), "cjs": code(jsGold),
        "jsx": code(jsGold), "es6": code(jsGold),
        "ts": code(tsBlue), "mts": code(tsBlue), "cts": code(tsBlue),
        "tsx": code(tsBlue),
        "coffee": code(javaBrown),
        "html": markup(htmlOrange), "htm": markup(htmlOrange), "xhtml": markup(htmlOrange),
        "vue": markup(.green), "svelte": markup(htmlOrange),
        "css": NodeIcon("paintbrush", tint: cssIndigo),
        "scss": NodeIcon("paintbrush", tint: rgb(0.80, 0.40, 0.55)),
        "sass": NodeIcon("paintbrush", tint: rgb(0.80, 0.40, 0.55)),
        "less": NodeIcon("paintbrush", tint: tsBlue),
        "styl": NodeIcon("paintbrush", tint: .green),
        "hbs": markup(javaBrown), "twig": markup(.green), "erb": markup(rubyRed),
        "haml": markup(rubyRed), "jinja": markup(.red), "j2": markup(.red),
        // Functional
        "hs": code(haskellPlum), "lhs": code(haskellPlum),
        "ex": code(elixirPurple), "exs": code(elixirPurple),
        "erl": code(erlangMagenta), "hrl": code(erlangMagenta),
        "clj": code(clojureBlue), "cljs": code(clojureBlue), "cljc": code(clojureBlue),
        "edn": data(clojureBlue),
        "ml": code(.orange), "mli": code(.orange),
        "re": code(.red), "rei": code(.red),
        "elm": code(elmSky),
        "scm": code(.red), "rkt": code(.red), "lisp": code(.red), "el": code(purpleish),
        "sml": code(.orange),
        "hx": code(.orange),
        // Scientific
        "r": code(rBlue), "rmd": NodeIcon("book", tint: rBlue),
        "jl": code(juliaPurple),
        "ipynb": NodeIcon("book", tint: .orange),
        "f90": code(csharpPurple), "f95": code(csharpPurple), "f": code(csharpPurple),
        "nb": NodeIcon("function", tint: .red), "wl": NodeIcon("function", tint: .red),
        "sas": NodeIcon("chart.bar", tint: .blue),
        "do": NodeIcon("chart.bar", tint: .blue),
        // Shell / ops
        "sh": script(.green), "bash": script(.green), "zsh": script(.green),
        "ksh": script(.green), "command": script(.green), "fish": script(.green),
        "ps1": script(tsBlue), "psm1": script(tsBlue), "psd1": script(tsBlue),
        "bat": script(.secondary), "cmd": script(.secondary),
        "awk": script(.green), "vim": NodeIcon("v.square", tint: .green),
        "nix": code(nixBlue),
        "tf": config(purpleish), "tfvars": config(purpleish),
        "dockerfile": NodeIcon("cube", tint: .blue),
        // Data / config
        "json": data(jsGold), "jsonc": data(jsGold), "json5": data(jsGold),
        "geojson": data(.green), "webmanifest": data(jsGold),
        "yaml": NodeIcon("list.bullet.indent", tint: .red),
        "yml": NodeIcon("list.bullet.indent", tint: .red),
        "toml": config(rustRust), "ini": config(.secondary),
        "cfg": config(.secondary), "conf": config(.secondary),
        "properties": config(.secondary), "env": NodeIcon("key", tint: .yellow),
        "plist": data(.secondary),
        "xml": markup(.orange), "xsd": markup(.orange), "xsl": markup(.orange),
        "svg": NodeIcon("photo", tint: .purple),
        "proto": data(tsBlue), "thrift": data(.red), "capnp": data(.orange),
        "graphql": NodeIcon("point.3.connected.trianglepath.dotted", tint: rgb(0.88, 0.19, 0.58)),
        "gql": NodeIcon("point.3.connected.trianglepath.dotted", tint: rgb(0.88, 0.19, 0.58)),
        "sql": NodeIcon("cylinder", tint: tsBlue),
        "pgsql": NodeIcon("cylinder", tint: tsBlue),
        "csv": NodeIcon("tablecells", tint: .green),
        "tsv": NodeIcon("tablecells", tint: .green),
        "http": NodeIcon("network", tint: .green), "rest": NodeIcon("network", tint: .green),
        "diff": NodeIcon("plus.forwardslash.minus", tint: .orange),
        "patch": NodeIcon("plus.forwardslash.minus", tint: .orange),
        "log": NodeIcon("list.bullet.rectangle", tint: .secondary),
        // Documents
        "md": NodeIcon("text.alignleft", tint: .secondary),
        "markdown": NodeIcon("text.alignleft", tint: .secondary),
        "mdx": NodeIcon("text.alignleft", tint: jsGold),
        "tex": NodeIcon("function", tint: .green),
        "typ": NodeIcon("text.alignleft", tint: .blue),
        "adoc": NodeIcon("text.alignleft", tint: .secondary),
        // Hardware / low level
        "asm": NodeIcon("cpu", tint: .secondary), "nasm": NodeIcon("cpu", tint: .secondary),
        "ll": NodeIcon("cpu", tint: .blue),
        "wat": NodeIcon("cpu", tint: purpleish), "wast": NodeIcon("cpu", tint: purpleish),
        "sv": NodeIcon("cpu", tint: .green), "vhd": NodeIcon("cpu", tint: .green),
        "vhdl": NodeIcon("cpu", tint: .green),
        "dts": NodeIcon("cpu", tint: .orange), "dtsi": NodeIcon("cpu", tint: .orange),
        // Graphics
        "glsl": NodeIcon("cube.transparent", tint: .purple),
        "frag": NodeIcon("cube.transparent", tint: .purple),
        "vert": NodeIcon("cube.transparent", tint: .purple),
        "metal": NodeIcon("cube.transparent", tint: .purple),
        "scad": NodeIcon("cube.transparent", tint: .yellow),
    ]

    private static let purpleish = rgb(0.49, 0.35, 0.75)

    /// The icon for a file, or nil to fall back to content-type rules
    /// (images, media, PDFs, archives — where UTIs actually work well).
    static func languageIcon(for url: URL) -> NodeIcon? {
        if let byName = iconsByFileName[url.lastPathComponent.lowercased()] { return byName }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return iconsByExtension[ext]
    }
}
