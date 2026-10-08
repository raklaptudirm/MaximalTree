import Foundation

/// Maps files (and raw-block tags) to the syntax highlighter's languages.
///
/// Every value here is a **canonical highlight.js language id** — not an alias
/// and not a guess. That matters: the highlighter silently falls back to
/// *auto-detection* when handed a name it doesn't know, which paints confident
/// but wrong colors. Unknown files return nil instead, and render as plain text.
///
/// Ambiguous extensions are deliberately omitted rather than coin-flipped
/// (`.v` is Verilog, Coq, and V; `.pp` is Pascal and Puppet). `.m` is the one
/// judgement call: Objective-C over MATLAB, because this is a macOS app.
public enum EditorLanguage {
    /// Files identified by their whole name — build files, dotfiles, and
    /// configs that carry no useful extension. Matched case-insensitively,
    /// before the extension table (`CMakeLists.txt` is CMake, not text).
    static let idsByFileName: [String: String] = [
        // Build systems
        "makefile": "makefile", "gnumakefile": "makefile", "justfile": "makefile",
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "cmakelists.txt": "cmake",
        // Ruby-DSL manifests
        "rakefile": "ruby", "gemfile": "ruby", "podfile": "ruby", "fastfile": "ruby",
        "brewfile": "ruby", "vagrantfile": "ruby", "guardfile": "ruby",
        "capfile": "ruby", "thorfile": "ruby", "appraisals": "ruby",
        // Lockfiles that are really TOML/INI
        "cargo.lock": "ini",
        // Shell startup files
        ".bashrc": "bash", ".bash_profile": "bash", ".bash_aliases": "bash",
        ".bash_logout": "bash", ".profile": "bash", ".zshrc": "bash",
        ".zprofile": "bash", ".zshenv": "bash", ".zlogin": "bash", ".kshrc": "bash",
        // Editor/tooling dotfiles
        ".vimrc": "vim", ".gvimrc": "vim",
        ".gitconfig": "ini", ".gitmodules": "ini", ".npmrc": "ini",
        ".editorconfig": "ini", ".curlrc": "ini", ".inputrc": "ini",
        ".clang-format": "yaml", ".clang-tidy": "yaml",
        ".babelrc": "json", ".prettierrc": "json", ".eslintrc": "json",
        // Server configs
        "nginx.conf": "nginx", "httpd.conf": "apache", "apache2.conf": "apache",
        ".htaccess": "apache",
        // Prose-y project files with no grammar. `plaintext` is a real
        // highlight.js language that emits no colors — mapping them here is
        // what makes them *editable* (the text canvas claims anything we can
        // name) without pretending they have syntax.
        "license": "plaintext", "licence": "plaintext", "copying": "plaintext",
        "readme": "plaintext", "changelog": "plaintext", "changes": "plaintext",
        "authors": "plaintext", "contributors": "plaintext", "notice": "plaintext",
        "todo": "plaintext", "install": "plaintext", "news": "plaintext",
        "codeowners": "plaintext",
        ".gitignore": "plaintext", ".gitattributes": "plaintext",
        ".dockerignore": "plaintext", ".npmignore": "plaintext",
        ".prettierignore": "plaintext", ".eslintignore": "plaintext",
    ]

    /// The main table: lowercased extension → canonical highlight.js id.
    static let idsByExtension: [String: String] = [
        // C family
        "c": "c", "h": "c",
        "cpp": "cpp", "cxx": "cpp", "cc": "cpp", "c++": "cpp",
        "hpp": "cpp", "hxx": "cpp", "hh": "cpp", "h++": "cpp", "ipp": "cpp",
        "inl": "cpp", "tcc": "cpp",
        "m": "objectivec", "mm": "objectivec",   // Objective-C over MATLAB here
        "cs": "csharp", "csx": "csharp",
        "d": "d",
        // Apple / mobile
        "swift": "swift",
        "kt": "kotlin", "kts": "kotlin",
        "java": "java", "jav": "java",
        "dart": "dart",
        // Systems
        "rs": "rust",
        "go": "go",
        "nim": "nim", "nims": "nim", "nimble": "nim",
        "cr": "crystal",
        "vala": "vala", "vapi": "vala",
        "pony": "pony",
        // Scripting
        "py": "python", "pyw": "python", "pyi": "python", "gyp": "python",
        "rb": "ruby", "rbw": "ruby", "gemspec": "ruby", "podspec": "ruby",
        "pl": "perl", "pm": "perl", "pod": "perl", "t": "perl",
        "php": "php", "phtml": "php", "php3": "php", "php4": "php", "php5": "php",
        "lua": "lua",
        "tcl": "tcl", "tk": "tcl",
        "groovy": "groovy", "gvy": "groovy", "gy": "groovy",
        "gradle": "gradle",
        "hy": "hy",
        "ahk": "autohotkey", "au3": "autoit",
        "applescript": "applescript", "scpt": "applescript",
        // Web languages
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "javascript", "es6": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "typescript",
        "coffee": "coffeescript", "cson": "coffeescript",
        "ls": "livescript", "moon": "moonscript",
        "as": "actionscript",
        // Web markup + styles
        "html": "xml", "htm": "xml", "xhtml": "xml",
        "xml": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "svg": "xml",
        "plist": "xml", "storyboard": "xml", "xib": "xml", "rss": "xml",
        "atom": "xml", "wsdl": "xml", "csproj": "xml", "xaml": "xml",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "styl": "stylus",
        "hbs": "handlebars", "handlebars": "handlebars", "mustache": "handlebars",
        "twig": "twig", "jinja": "django", "jinja2": "django", "j2": "django",
        "haml": "haml", "erb": "erb", "rhtml": "erb",
        "qml": "qml",
        // Functional
        "hs": "haskell", "lhs": "haskell",
        "ml": "ocaml", "mli": "ocaml",
        "re": "reasonml", "rei": "reasonml",
        "fs": "fsharp", "fsi": "fsharp", "fsx": "fsharp",
        "ex": "elixir", "exs": "elixir",
        "erl": "erlang", "hrl": "erlang",
        "elm": "elm",
        "clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure",
        "scm": "scheme", "ss": "scheme", "rkt": "scheme",
        "lisp": "lisp", "cl": "lisp", "lsp": "lisp", "el": "lisp",
        "sml": "sml",
        "scala": "scala", "sc": "scala",
        "hx": "haxe",
        // Scientific / numeric
        "r": "r", "rmd": "markdown",
        "jl": "julia",
        "f": "fortran", "for": "fortran", "f90": "fortran", "f95": "fortran",
        "f03": "fortran", "f08": "fortran",
        "nb": "mathematica", "wl": "mathematica", "wls": "mathematica",
        "do": "stata", "ado": "stata",
        "sas": "sas",
        "q": "q",
        "stan": "stan",
        "gms": "gams",
        // Legacy / enterprise
        "pas": "delphi", "dpr": "delphi", "dfm": "delphi",
        "ada": "ada", "adb": "ada", "ads": "ada",
        "vb": "vbnet", "vbs": "vbscript", "bas": "basic",
        "st": "smalltalk",
        "prolog": "prolog",
        // Shell / ops
        "sh": "bash", "bash": "bash", "zsh": "bash", "ksh": "bash", "ash": "bash",
        "command": "bash",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "bat": "dos", "cmd": "dos",
        "awk": "awk",
        "vim": "vim",
        "nix": "nix",
        "puppet": "puppet",
        "feature": "gherkin",
        "zone": "dns",
        "nginx": "nginx", "apacheconf": "apache",
        "service": "ini", "desktop": "ini",
        // Data / config
        "json": "json", "jsonc": "json", "json5": "json", "geojson": "json",
        "ipynb": "json", "webmanifest": "json",
        "yaml": "yaml", "yml": "yaml",
        "toml": "ini",                      // hljs models TOML as INI
        "ini": "ini", "cfg": "ini", "conf": "ini",
        "properties": "properties", "env": "properties",
        "ldif": "ldif",
        "proto": "protobuf", "thrift": "thrift", "capnp": "capnproto",
        "graphql": "graphql", "gql": "graphql",
        "sql": "sql", "ddl": "sql", "dml": "sql",
        "pgsql": "pgsql", "psql": "pgsql",
        "http": "http", "rest": "http",
        "diff": "diff", "patch": "diff",
        // Documents
        "md": "markdown", "markdown": "markdown", "mdown": "markdown",
        "mkd": "markdown", "mdx": "markdown",
        "tex": "latex", "sty": "latex", "cls": "latex", "ltx": "latex",
        "adoc": "asciidoc", "asciidoc": "asciidoc",
        "txt": "plaintext", "text": "plaintext", "log": "plaintext",
        // Hardware / low level
        "sv": "verilog", "svh": "verilog", "vh": "verilog",
        "vhd": "vhdl", "vhdl": "vhdl",
        "asm": "x86asm", "nasm": "x86asm",
        "ll": "llvm",
        "wat": "wasm", "wast": "wasm",
        "dts": "dts", "dtsi": "dts",
        "gcode": "gcode",
        "step": "step21", "stp": "step21",
        // Graphics / games
        "glsl": "glsl", "vert": "glsl", "frag": "glsl", "geom": "glsl",
        "comp": "glsl", "tesc": "glsl", "tese": "glsl",
        "ino": "arduino", "pde": "processing",
        "scad": "openscad",
        "lsl": "lsl", "mel": "mel", "sqf": "sqf",
        // Grammars
        "ebnf": "ebnf", "abnf": "abnf", "bnf": "bnf",
        // Misc
        "wren": "wren", "monkey": "monkey", "nsi": "nsis", "zep": "zephir",
        "xl": "xl", "tap": "tap", "brainfuck": "brainfuck", "bf": "brainfuck",
    ]

    /// Aliases users type in fenced/raw blocks, mapped onto canonical ids.
    /// (`hljs` resolves some of these itself, but normalizing keeps the cache
    /// keyed consistently and lets us reject genuinely unknown tags.)
    static let aliases: [String: String] = [
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "shell",
        "html": "xml", "htm": "xml", "xhtml": "xml", "svg": "xml", "plist": "xml",
        "yml": "yaml", "toml": "ini", "cfg": "ini", "conf": "ini",
        "js": "javascript", "node": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "python3": "python", "rb": "ruby", "rs": "rust",
        "c++": "cpp", "h": "c", "hpp": "cpp", "cxx": "cpp",
        "objective-c": "objectivec", "objc": "objectivec", "obj-c": "objectivec",
        "c#": "csharp", "cs": "csharp", "f#": "fsharp", "fs": "fsharp",
        "vb.net": "vbnet", "vb": "vbnet",
        "kt": "kotlin", "kts": "kotlin", "golang": "go",
        "md": "markdown", "tex": "latex", "adoc": "asciidoc",
        "docker": "dockerfile", "make": "makefile", "bat": "dos", "batch": "dos",
        "ps": "powershell", "ps1": "powershell", "pwsh": "powershell",
        "postgres": "pgsql", "postgresql": "pgsql", "psql": "pgsql",
        "protobuf": "protobuf", "proto": "protobuf",
        "text": "plaintext", "txt": "plaintext", "none": "plaintext",
        "asm": "x86asm", "assembly": "x86asm",
        "el": "lisp", "elisp": "lisp", "emacs-lisp": "lisp",
        "jinja": "django", "jinja2": "django", "j2": "django",
        "hs": "haskell", "ml": "ocaml", "ex": "elixir", "exs": "elixir",
        "erl": "erlang", "clj": "clojure", "jl": "julia", "pl": "perl",
    ]

    /// Pretty labels for ids whose canonical spelling reads poorly. Everything
    /// else is capitalized (`swift` → `Swift`).
    static let displayNames: [String: String] = [
        "cpp": "C++", "csharp": "C#", "fsharp": "F#", "objectivec": "Objective-C",
        "vbnet": "VB.NET", "vbscript": "VBScript", "javascript": "JavaScript",
        "typescript": "TypeScript", "coffeescript": "CoffeeScript",
        "livescript": "LiveScript", "actionscript": "ActionScript",
        "applescript": "AppleScript", "moonscript": "MoonScript",
        "xml": "XML", "css": "CSS", "scss": "SCSS",
        "json": "JSON", "yaml": "YAML", "ini": "INI", "sql": "SQL",
        "pgsql": "PostgreSQL", "graphql": "GraphQL", "http": "HTTP",
        "bash": "Shell", "dos": "Batch", "x86asm": "Assembly",
        "llvm": "LLVM IR", "wasm": "WebAssembly", "glsl": "GLSL", "qml": "QML",
        "dts": "Device Tree", "latex": "LaTeX", "asciidoc": "AsciiDoc",
        "php": "PHP", "r": "R", "q": "Q", "d": "D", "go": "Go", "c": "C",
        "sas": "SAS", "lsl": "LSL", "mel": "MEL", "ebnf": "EBNF",
        "abnf": "ABNF", "bnf": "BNF", "ldif": "LDIF", "csp": "CSP",
        "gcode": "G-code", "step21": "STEP", "dns": "DNS Zone",
        "vhdl": "VHDL", "sml": "Standard ML", "ocaml": "OCaml",
        "reasonml": "ReasonML", "gams": "GAMS", "nsis": "NSIS",
        "openscad": "OpenSCAD", "capnproto": "Cap'n Proto",
    ]

    /// The highlighter language for a file, or nil when we don't know it.
    /// Whole-name matches win over extensions.
    public static func id(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if let byName = idsByFileName[name] { return byName }
        // `.zshrc` and friends: Foundation reports no extension, but the leading
        // dot form is already covered above; this catches `foo.d.ts`-style tails
        // by falling back to the final extension.
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return idsByExtension[ext]
    }

    /// The highlighter language for a fenced/raw-block tag (`rust`, `yml`,
    /// `C++`), or nil when the tag names nothing we can highlight.
    public static func id(forTag tag: String) -> String? {
        let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let alias = aliases[key] { return alias }
        if let byExtension = idsByExtension[key] { return byExtension }
        return key    // already canonical, or unknown — the highlighter rejects it
    }

    /// How a line is commented out in a file, or nil when the language has no
    /// comments (JSON, plain text) or isn't one we know.
    public static func commentSyntax(for url: URL) -> CommentSyntax? {
        // Typst has no highlight.js grammar, so it is known by extension.
        if url.pathExtension.lowercased() == "typ" { return .line("//") }
        return id(for: url).flatMap(commentSyntax(forLanguage:))
    }

    public static func commentSyntax(forLanguage id: String) -> CommentSyntax? {
        if let line = lineComments[id] { return .line(line) }
        if let block = blockComments[id] { return .block(block.open, block.close) }
        return nil
    }

    /// Languages with a line comment, by its marker.
    static let lineComments: [String: String] = {
        var table: [String: String] = [:]
        let slashes = ["c", "cpp", "objectivec", "swift", "javascript", "typescript", "java",
                       "kotlin", "scala", "go", "rust", "csharp", "dart", "php", "groovy",
                       "fsharp", "zig", "d", "glsl", "less", "scss", "protobuf", "gradle",
                       "verilog", "solidity", "processing", "arduino", "typst"]
        let hashes = ["python", "ruby", "bash", "shell", "perl", "r", "yaml", "toml", "elixir",
                      "makefile", "dockerfile", "cmake", "nix", "julia", "coffeescript",
                      "powershell", "crystal", "nim", "tcl", "nginx", "apache", "properties",
                      "graphql", "awk", "fish"]
        let dashes = ["lua", "sql", "haskell", "elm", "ada", "vhdl", "pgsql", "plsql"]
        let semicolons = ["lisp", "scheme", "clojure", "ini", "x86asm", "armasm", "llvm"]
        let percents = ["latex", "tex", "erlang", "matlab", "prolog"]
        for (marker, ids) in [("//", slashes), ("#", hashes), ("--", dashes),
                              (";", semicolons), ("%", percents)] {
            for id in ids { table[id] = marker }
        }
        table["vim"] = "\""
        table["vbnet"] = "'"
        return table
    }()

    /// Languages with only a block comment.
    static let blockComments: [String: (open: String, close: String)] = [
        "xml": ("<!--", "-->"), "html": ("<!--", "-->"), "markdown": ("<!--", "-->"),
        "css": ("/*", "*/"), "ocaml": ("(*", "*)"), "sml": ("(*", "*)"),
    ]

    /// A human label for a language id (`cpp` → `C++`).
    public static func displayName(for id: String) -> String {
        displayNames[id] ?? id.capitalized
    }
}

/// A display name for a file's language ("Swift", "C++", …), nil for plain or
/// unknown types. For header badges and inspectors.
public func editorLanguageName(for url: URL) -> String? {
    EditorLanguage.id(for: url).map(EditorLanguage.displayName(for:))
}

/// How a language comments a line out.
public enum CommentSyntax: Equatable, Sendable {
    /// A marker that runs to the end of the line: `//`, `#`, `--`.
    case line(String)
    /// A pair around what is commented: `<!--` and `-->`, `/*` and `*/`.
    case block(String, String)
}
