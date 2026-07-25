# highlight.js (vendored)

`highlight.min.js` is [highlight.js](https://highlightjs.org) v11.11.1, BSD-3-Clause
(see `LICENSE`), bundling ~190 language grammars.

MaximalEditorKit runs it directly in a `JSContext` (`SyntaxEngine`) rather than
through a wrapper library, because we want highlight.js's **semantic class names**
(`hljs-keyword`, `hljs-string`, …) mapped onto `EditorTokenKind` — the editor's own
token vocabulary — instead of pre-rendered theme colours. That means the palette in
`EditorHighlighting.swift` themes code and typst markup consistently, appearance
switches repaint without re-tokenizing, and each snippet is highlighted once
instead of once per appearance.

To update: drop in a newer `highlight.min.js` from the same distribution
(the "common" or "all languages" build) and re-run the test suite — the language
table in `EditorLanguage.swift` is validated against whatever this file registers.
