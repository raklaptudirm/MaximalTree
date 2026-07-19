//! C ABI bindings to the typst compiler for MaximalTree.
//!
//! One entry point: compile a UTF-8 source string as though it lived at
//! `<root>/main.typ`, resolving relative files against `root` and `@<ns>/…`
//! packages against `<packages>/<ns>/<name>/<version>`. Returns PDF bytes and
//! structured diagnostics (JSON) — no CLI, no stderr parsing, works on iOS.
//!
//! Diagnostic coordinates match what the Swift side already speaks (typst CLI
//! `short` format): 1-based lines, 0-based columns.

use std::ffi::{c_char, CStr};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use typst::diag::{FileError, FileResult, Severity, SourceDiagnostic};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World, WorldExt};
use typst_kit::fonts::FontStore;
use typst_layout::PagedDocument;

// MARK: Buffers

#[repr(C)]
pub struct TypstBuffer {
    data: *mut u8,
    len: usize,
    cap: usize,
}

impl TypstBuffer {
    fn from_vec(mut v: Vec<u8>) -> Self {
        let buf = TypstBuffer { data: v.as_mut_ptr(), len: v.len(), cap: v.capacity() };
        std::mem::forget(v);
        buf
    }

    fn empty() -> Self {
        TypstBuffer { data: std::ptr::null_mut(), len: 0, cap: 0 }
    }
}

/// # Safety
/// Must only be called once, with a buffer previously returned by this library.
#[no_mangle]
pub unsafe extern "C" fn typst_buffer_free(buf: TypstBuffer) {
    if !buf.data.is_null() {
        drop(Vec::from_raw_parts(buf.data, buf.len, buf.cap));
    }
}

// MARK: Shared state (fonts are expensive to discover — once per process)

fn font_store() -> &'static FontStore {
    static STORE: OnceLock<FontStore> = OnceLock::new();
    STORE.get_or_init(|| {
        let mut store = FontStore::new();
        store.extend(typst_kit::fonts::embedded());
        store.extend(typst_kit::fonts::system());
        store
    })
}

fn library() -> &'static LazyHash<Library> {
    static LIBRARY: OnceLock<LazyHash<Library>> = OnceLock::new();
    LIBRARY.get_or_init(|| LazyHash::new(Library::default()))
}

// MARK: World

struct FfiWorld {
    root: PathBuf,
    packages: PathBuf,
    main: Source,
}

impl FfiWorld {
    fn new(source: String, root: PathBuf, packages: PathBuf) -> Self {
        let vpath = VirtualPath::new("/main.typ").expect("static path is valid");
        let id = FileId::new(RootedPath::new(VirtualRoot::Project, vpath));
        FfiWorld { root, packages, main: Source::new(id, source) }
    }

    /// Resolve a FileId to an on-disk path: package files under the package
    /// directory, everything else under the compilation root.
    fn path_for(&self, id: FileId) -> FileResult<PathBuf> {
        let base = match id.package() {
            Some(spec) => self
                .packages
                .join(spec.namespace.as_str())
                .join(spec.name.as_str())
                .join(spec.version.to_string()),
            None => self.root.clone(),
        };
        id.vpath().resolve(&base).ok_or(FileError::AccessDenied)
    }

    fn read(&self, id: FileId) -> FileResult<Vec<u8>> {
        let path = self.path_for(id)?;
        std::fs::read(&path).map_err(|e| FileError::from_io(e, &path))
    }
}

impl World for FfiWorld {
    fn library(&self) -> &LazyHash<Library> {
        library()
    }

    fn book(&self) -> &LazyHash<FontBook> {
        font_store().book()
    }

    fn main(&self) -> FileId {
        self.main.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main.id() {
            return Ok(self.main.clone());
        }
        let bytes = self.read(id)?;
        let text = String::from_utf8(bytes).map_err(|_| FileError::InvalidUtf8)?;
        Ok(Source::new(id, text))
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        self.read(id).map(Bytes::new)
    }

    fn font(&self, index: usize) -> Option<Font> {
        font_store().font(index)
    }

    fn today(&self, _offset: Option<Duration>) -> Option<Datetime> {
        let now = time::OffsetDateTime::now_utc();
        Datetime::from_ymd(now.year(), now.month() as u8, now.day())
    }
}

// MARK: Diagnostics

#[derive(serde::Serialize)]
struct Diagnostic {
    severity: String,
    message: String,
    line: Option<usize>,   // 1-based
    column: Option<usize>, // 0-based
}

fn convert(world: &FfiWorld, diagnostics: &[SourceDiagnostic]) -> Vec<Diagnostic> {
    diagnostics
        .iter()
        .map(|d| {
            let mut line = None;
            let mut column = None;
            if let (Some(id), Some(range)) = (d.span.id(), world.range(d.span)) {
                if let Ok(source) = world.source(id) {
                    line = source.lines().byte_to_line(range.start).map(|l| l + 1);
                    column = source.lines().byte_to_column(range.start);
                }
            }
            Diagnostic {
                severity: match d.severity {
                    Severity::Error => "error".into(),
                    Severity::Warning => "warning".into(),
                },
                message: d.message.to_string(),
                line,
                column,
            }
        })
        .collect()
}

fn emit(diagnostics: &[Diagnostic], out: *mut TypstBuffer) {
    if let Ok(json) = serde_json::to_vec(diagnostics) {
        unsafe { *out = TypstBuffer::from_vec(json) };
    }
}

// MARK: Tokenizer (real parser, for editor highlighting)

#[derive(serde::Serialize)]
struct EditorToken {
    s: usize,           // utf16 start
    l: usize,           // utf16 length
    k: &'static str,    // kind
    #[serde(skip_serializing_if = "Option::is_none")]
    n: Option<usize>,   // heading level
    #[serde(skip_serializing_if = "Option::is_none")]
    a: Option<&'static str>, // alignment
}

/// Walks the real typst syntax tree, emitting editor tokens with UTF-16 ranges
/// (what NSRange speaks). Mode-aware by construction: string literals only exist
/// where the parser says code mode — prose quotation marks are never tokens.
struct EditorTokenizer<'a> {
    src: &'a str,
    utf16: Vec<usize>,  // byte offset → utf16 offset (len+1 entries)
    out: Vec<EditorToken>,
}

impl<'a> EditorTokenizer<'a> {
    fn new(src: &'a str) -> Self {
        let mut utf16 = vec![0usize; src.len() + 1];
        let mut units = 0usize;
        for (i, ch) in src.char_indices() {
            for b in i..i + ch.len_utf8() {
                utf16[b] = units;
            }
            units += ch.len_utf16();
        }
        utf16[src.len()] = units;
        EditorTokenizer { src, utf16, out: Vec::new() }
    }

    fn emit(&mut self, start: usize, len: usize, kind: &'static str,
            level: Option<usize>, alignment: Option<&'static str>) {
        let s = self.utf16[start.min(self.src.len())];
        let e = self.utf16[(start + len).min(self.src.len())];
        if e > s {
            self.out.push(EditorToken { s, l: e - s, k: kind, n: level, a: alignment });
        }
    }

    fn slice(&self, offset: usize, len: usize) -> &str {
        self.src.get(offset..offset + len).unwrap_or("")
    }

    /// Markup-mode walk.
    fn walk(&mut self, node: &typst::syntax::SyntaxNode, offset: usize) {
        use typst::syntax::SyntaxKind as K;
        match node.kind() {
            K::Heading => {
                let mut level = 1;
                let mut child_offset = offset;
                for child in node.children() {
                    if child.kind() == K::HeadingMarker {
                        level = child.len();
                        break;
                    }
                    child_offset += child.len();
                }
                let _ = child_offset;
                self.emit(offset, node.len(), "heading", Some(level), None);
            }
            K::Strong => self.emit(offset, node.len(), "strong", None, None),
            K::Emph => self.emit(offset, node.len(), "emphasis", None, None),
            K::Raw => self.emit(offset, node.len(), "raw", None, None),
            K::Equation => self.emit(offset, node.len(), "math", None, None),
            K::Label => self.emit(offset, node.len(), "tag", None, None),
            K::Ref => self.emit(offset, node.len(), "property", None, None),
            K::Link => self.emit(offset, node.len(), "link", None, None),
            K::Escape | K::Linebreak | K::Shorthand => {
                self.emit(offset, node.len(), "marker", None, None);
            }
            K::LineComment | K::BlockComment => self.emit(offset, node.len(), "comment", None, None),
            K::ListItem | K::EnumItem => {
                self.emit(offset, node.len(), "item", None, None);
                let mut child_offset = offset;
                for child in node.children() {
                    match child.kind() {
                        K::ListMarker | K::EnumMarker => {
                            self.emit(child_offset, child.len(), "marker", None, None);
                        }
                        _ => self.walk(child, child_offset),
                    }
                    child_offset += child.len();
                }
            }
            K::TermItem => {
                self.emit(offset, node.len(), "item", None, None);
                let mut child_offset = offset;
                let mut term_start: Option<usize> = None;
                let mut term_end: Option<usize> = None;
                for child in node.children() {
                    match child.kind() {
                        K::TermMarker => {
                            self.emit(child_offset, child.len(), "marker", None, None);
                        }
                        K::Colon => {
                            if term_end.is_none() {
                                term_end = Some(child_offset);
                            }
                            self.emit(child_offset, child.len(), "marker", None, None);
                        }
                        K::Space => {}
                        _ => {
                            if term_start.is_none() && term_end.is_none() {
                                term_start = Some(child_offset);
                            }
                            self.walk(child, child_offset);
                        }
                    }
                    child_offset += child.len();
                }
                if let (Some(start), Some(end)) = (term_start, term_end) {
                    if end > start {
                        self.emit(start, end - start, "term", None, None);
                    }
                }
            }
            K::FuncCall => {
                if !self.try_decorated_call(node, offset) {
                    self.walk_code(node, offset);
                }
            }
            K::LetBinding | K::SetRule | K::ShowRule | K::ModuleImport | K::ModuleInclude => {
                self.walk_code(node, offset);
            }
            _ if node.children().len() == 0 => {}
            _ => {
                // The `#` introducing embedded code is a sibling of the call it
                // starts — pair them so it styles (and conceals) with its call.
                let mut child_offset = offset;
                let mut pending_hash: Option<(usize, usize)> = None;
                for child in node.children() {
                    match child.kind() {
                        K::Hash => pending_hash = Some((child_offset, child.len())),
                        _ => {
                            if let Some((hash_offset, hash_len)) = pending_hash.take() {
                                let kind = if child.kind() == K::FuncCall
                                    && self.decorated_parts(child, child_offset).is_some()
                                {
                                    "punct"
                                } else {
                                    "function"
                                };
                                self.emit(hash_offset, hash_len, kind, None, None);
                            }
                            self.walk(child, child_offset);
                        }
                    }
                    child_offset += child.len();
                }
            }
        }
    }

    /// Code-mode walk: contiguous code renders as `function` runs; real string
    /// literals as `string`; content-block brackets as `punctuation` with their
    /// bodies recursed back into markup mode.
    fn walk_code(&mut self, node: &typst::syntax::SyntaxNode, offset: usize) {
        use typst::syntax::SyntaxKind as K;
        if node.children().len() == 0 {
            self.emit(offset, node.len(), "function", None, None);
            return;
        }

        let mut run_start = offset;
        let mut cursor = offset;
        let mut strings: Vec<(usize, usize)> = Vec::new();

        let close_run = |this: &mut Self, start: usize, end: usize| {
            if end > start {
                this.emit(start, end - start, "function", None, None);
            }
        };

        for child in node.children() {
            match child.kind() {
                K::ContentBlock => {
                    close_run(self, run_start, cursor);
                    let mut inner_offset = cursor;
                    for inner in child.children() {
                        match inner.kind() {
                            K::LeftBracket | K::RightBracket => {
                                self.emit(inner_offset, inner.len(), "punct", None, None);
                            }
                            _ => self.walk(inner, inner_offset),
                        }
                        inner_offset += inner.len();
                    }
                    run_start = cursor + child.len();
                }
                K::Str => strings.push((cursor, child.len())),
                K::LineComment | K::BlockComment => {
                    close_run(self, run_start, cursor);
                    self.emit(cursor, child.len(), "comment", None, None);
                    run_start = cursor + child.len();
                }
                K::Raw => {
                    close_run(self, run_start, cursor);
                    self.emit(cursor, child.len(), "raw", None, None);
                    run_start = cursor + child.len();
                }
                _ if child.children().len() > 0 => {
                    close_run(self, run_start, cursor);
                    self.walk_code(child, cursor);
                    run_start = cursor + child.len();
                }
                _ => {}
            }
            cursor += child.len();
        }
        close_run(self, run_start, cursor);

        // Emitted after the runs so their color wins the overlap.
        for (start, len) in strings {
            self.emit(start, len, "string", None, None);
        }
    }

    /// Markup-decorating calls — `#align(<where>)[body]`, `#strike[body]`,
    /// `#underline[body]`. The head (everything before the content block) is
    /// emitted as `punct` so the editor can conceal it, the body carries the
    /// decoration kind, and the body's markup is walked normally so nested
    /// styling still applies. Returns false (caller falls back to the generic
    /// code walk) when the call isn't one of these shapes.
    fn try_decorated_call(&mut self, node: &typst::syntax::SyntaxNode, offset: usize) -> bool {
        use typst::syntax::SyntaxKind as K;
        let Some((body_kind, alignment, block_offset, block)) =
            self.decorated_parts(node, offset) else { return false };

        self.emit(offset, block_offset - offset, "punct", None, None);
        let mut inner_offset = block_offset;
        for inner in block.children() {
            match inner.kind() {
                K::LeftBracket | K::RightBracket => {
                    self.emit(inner_offset, inner.len(), "punct", None, None);
                }
                K::Markup => {
                    self.emit(inner_offset, inner.len(), body_kind, None, alignment);
                    self.walk(inner, inner_offset);
                }
                _ => self.walk(inner, inner_offset),
            }
            inner_offset += inner.len();
        }
        true
    }

    /// Pure classification behind `try_decorated_call`: for a decorating call,
    /// (body kind, alignment, content-block offset, content-block node).
    fn decorated_parts<'n>(
        &self,
        node: &'n typst::syntax::SyntaxNode,
        offset: usize,
    ) -> Option<(&'static str, Option<&'static str>, usize, &'n typst::syntax::SyntaxNode)> {
        use typst::syntax::SyntaxKind as K;
        let mut child_offset = offset;
        let mut callee: Option<&str> = None;
        for child in node.children() {
            if child.kind() == K::Ident {
                callee = Some(self.slice(child_offset, child.len()));
                break;
            }
            child_offset += child.len();
        }
        let body_kind: &'static str = match callee {
            Some("align") => "aligned",
            Some("strike") => "struck",
            Some("underline") => "underlined",
            _ => return None,
        };

        let mut alignment: Option<&'static str> = None;
        let mut block: Option<(usize, &typst::syntax::SyntaxNode)> = None;
        let mut args_offset = offset;
        for child in node.children() {
            if child.kind() == K::Args {
                let mut inner_offset = args_offset;
                for inner in child.children() {
                    if inner.kind() == K::Ident && alignment.is_none() {
                        alignment = match self.slice(inner_offset, inner.len()) {
                            "center" => Some("center"),
                            "right" | "end" => Some("trailing"),
                            "left" | "start" => Some("leading"),
                            _ => None,
                        };
                    }
                    if inner.kind() == K::ContentBlock && block.is_none() {
                        block = Some((inner_offset, inner));
                    }
                    inner_offset += inner.len();
                }
            }
            args_offset += child.len();
        }
        let (block_offset, block) = block?;
        if body_kind == "aligned" && alignment.is_none() {
            return None;
        }
        Some((body_kind, alignment, block_offset, block))
    }
}

/// Tokenize `source` for editor highlighting using the real typst parser.
/// Writes a JSON array of tokens with UTF-16 ranges; returns 0 on success.
///
/// # Safety
/// `source` must be a valid NUL-terminated UTF-8 string; `out_tokens` valid.
#[no_mangle]
pub unsafe extern "C" fn typst_tokens(
    source: *const c_char,
    out_tokens: *mut TypstBuffer,
) -> i32 {
    *out_tokens = TypstBuffer::empty();
    let Ok(source) = CStr::from_ptr(source).to_str() else { return 2 };

    let root = typst::syntax::parse(source);
    let mut tokenizer = EditorTokenizer::new(source);
    tokenizer.walk(&root, 0);

    match serde_json::to_vec(&tokenizer.out) {
        Ok(json) => {
            *out_tokens = TypstBuffer::from_vec(json);
            0
        }
        Err(_) => 2,
    }
}

// MARK: Structure (real parser, for outline/tasks/links)

#[derive(serde::Serialize)]
struct StructureItem {
    kind: &'static str,                 // "section" | "task" | "link"
    #[serde(skip_serializing_if = "Option::is_none")]
    line: Option<usize>,                // 1-based
    #[serde(skip_serializing_if = "Option::is_none")]
    level: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    index: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    done: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    due: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tags: Option<Vec<String>>,
    // The exact UTF-16 edit that toggles this task's done state.
    #[serde(skip_serializing_if = "Option::is_none")]
    ts: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tl: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tr: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<String>,             // link path
}

impl StructureItem {
    fn empty(kind: &'static str) -> Self {
        StructureItem {
            kind, line: None, level: None, title: None, index: None, body: None,
            done: None, due: None, tags: None, ts: None, tl: None, tr: None,
            target: None,
        }
    }
}

struct StructureWalker<'a> {
    src: &'a str,
    utf16: Vec<usize>,
    line_starts: Vec<usize>,
    out: Vec<StructureItem>,
    task_index: usize,
}

impl<'a> StructureWalker<'a> {
    fn new(src: &'a str) -> Self {
        let mut utf16 = vec![0usize; src.len() + 1];
        let mut units = 0usize;
        for (i, ch) in src.char_indices() {
            for b in i..i + ch.len_utf8() {
                utf16[b] = units;
            }
            units += ch.len_utf16();
        }
        utf16[src.len()] = units;

        let mut line_starts = vec![0usize];
        for (i, b) in src.bytes().enumerate() {
            if b == b'\n' {
                line_starts.push(i + 1);
            }
        }
        StructureWalker { src, utf16, line_starts, out: Vec::new(), task_index: 0 }
    }

    fn line_of(&self, byte: usize) -> usize {
        self.line_starts.partition_point(|&start| start <= byte)
    }

    fn slice(&self, offset: usize, len: usize) -> &str {
        self.src.get(offset..offset + len).unwrap_or("")
    }

    /// Inner value of a `Str` node slice (drops the quotes).
    fn string_inner(&self, offset: usize, len: usize) -> String {
        let text = self.slice(offset, len);
        text.strip_prefix('"').and_then(|t| t.strip_suffix('"'))
            .unwrap_or(text).to_string()
    }

    fn walk(&mut self, node: &typst::syntax::SyntaxNode, offset: usize) {
        use typst::syntax::SyntaxKind as K;
        match node.kind() {
            K::Heading => {
                let mut level = 1;
                let mut title = String::new();
                let mut child_offset = offset;
                for child in node.children() {
                    match child.kind() {
                        K::HeadingMarker => level = child.len(),
                        K::Markup => {
                            title = self.slice(child_offset, child.len())
                                .trim().to_string();
                        }
                        _ => {}
                    }
                    child_offset += child.len();
                }
                let mut item = StructureItem::empty("section");
                item.line = Some(self.line_of(offset));
                item.level = Some(level);
                item.title = Some(title);
                self.out.push(item);
            }
            K::ModuleImport | K::ModuleInclude => {
                let mut child_offset = offset;
                for child in node.children() {
                    if child.kind() == K::Str {
                        let target = self.string_inner(child_offset, child.len());
                        if !target.starts_with('@') {
                            let mut item = StructureItem::empty("link");
                            item.target = Some(target);
                            self.out.push(item);
                        }
                    }
                    child_offset += child.len();
                }
            }
            K::FuncCall => {
                self.visit_call(node, offset);
                // Recurse: tasks can live inside content blocks of other calls.
                let mut child_offset = offset;
                for child in node.children() {
                    self.walk(child, child_offset);
                    child_offset += child.len();
                }
            }
            _ => {
                let mut child_offset = offset;
                for child in node.children() {
                    self.walk(child, child_offset);
                    child_offset += child.len();
                }
            }
        }
    }

    fn visit_call(&mut self, node: &typst::syntax::SyntaxNode, offset: usize) {
        use typst::syntax::SyntaxKind as K;
        let mut child_offset = offset;
        let mut is_task = false;
        let mut args: Option<(&typst::syntax::SyntaxNode, usize)> = None;
        for child in node.children() {
            match child.kind() {
                K::Ident if child_offset == offset => {
                    is_task = self.slice(child_offset, child.len()) == "task";
                }
                K::Args => args = Some((child, child_offset)),
                _ => {}
            }
            child_offset += child.len();
        }
        if !is_task {
            return;
        }
        let Some((args_node, args_offset)) = args else { return };

        let mut done: Option<(bool, usize, usize)> = None;   // value, byte start, len
        let mut due: Option<String> = None;
        let mut tags: Vec<String> = Vec::new();
        let mut body = String::new();
        let mut after_left_paren: Option<usize> = None;
        let mut has_inner_args = false;

        let mut inner_offset = args_offset;
        for child in args_node.children() {
            match child.kind() {
                K::LeftParen => after_left_paren = Some(inner_offset + child.len()),
                K::RightParen | K::Space | K::Comma => {}
                K::ContentBlock => {
                    let mut block_offset = inner_offset;
                    for block_child in child.children() {
                        if block_child.kind() == K::Markup {
                            body = self.slice(block_offset, block_child.len())
                                .split_whitespace().collect::<Vec<_>>().join(" ");
                        }
                        block_offset += block_child.len();
                    }
                }
                K::Named => {
                    has_inner_args = true;
                    self.visit_named(child, inner_offset, &mut done, &mut due, &mut tags);
                }
                _ => has_inner_args = true,
            }
            inner_offset += child.len();
        }

        if body.chars().count() > 80 {
            body = body.chars().take(79).collect::<String>() + "…";
        }

        let mut item = StructureItem::empty("task");
        item.line = Some(self.line_of(offset));
        item.index = Some(self.task_index);
        self.task_index += 1;
        item.body = Some(if body.is_empty() { "task".into() } else { body });
        item.done = Some(done.map(|(v, _, _)| v).unwrap_or(false));
        item.due = due;
        if !tags.is_empty() {
            item.tags = Some(tags);
        }

        // The exact toggle edit, computed from the AST rather than guessed.
        if let Some((value, start, len)) = done {
            item.ts = Some(self.utf16[start]);
            item.tl = Some(self.utf16[start + len] - self.utf16[start]);
            item.tr = Some(if value { "false".into() } else { "true".into() });
        } else if let Some(insert_at) = after_left_paren {
            item.ts = Some(self.utf16[insert_at]);
            item.tl = Some(0);
            item.tr = Some(if has_inner_args { "done: true, ".into() }
                           else { "done: true".into() });
        } else {
            item.ts = Some(self.utf16[args_offset]);
            item.tl = Some(0);
            item.tr = Some("(done: true)".into());
        }
        self.out.push(item);
    }

    fn visit_named(&mut self, node: &typst::syntax::SyntaxNode, offset: usize,
                   done: &mut Option<(bool, usize, usize)>,
                   due: &mut Option<String>, tags: &mut Vec<String>) {
        use typst::syntax::SyntaxKind as K;
        let mut name = "";
        let mut seen_name = false;
        let mut child_offset = offset;
        for child in node.children() {
            match child.kind() {
                K::Ident if !seen_name => {
                    name = self.slice(child_offset, child.len());
                    seen_name = true;
                    child_offset += child.len();
                    continue;
                }
                K::Bool if name == "done" => {
                    let value = self.slice(child_offset, child.len()) == "true";
                    *done = Some((value, child_offset, child.len()));
                }
                K::Str if name == "due" => {
                    *due = Some(self.string_inner(child_offset, child.len()));
                }
                K::Array | K::Parenthesized if name == "tags" => {
                    let mut item_offset = child_offset;
                    for item in child.children() {
                        if item.kind() == K::Str {
                            tags.push(self.string_inner(item_offset, item.len()));
                        }
                        item_offset += item.len();
                    }
                }
                _ => {}
            }
            child_offset += child.len();
        }
    }
}

/// Extract document structure (sections, tasks with toggle edits, links) using the
/// real typst parser. Writes a JSON array; returns 0 on success.
///
/// # Safety
/// `source` must be a valid NUL-terminated UTF-8 string; `out` valid.
#[no_mangle]
pub unsafe extern "C" fn typst_structure(
    source: *const c_char,
    out: *mut TypstBuffer,
) -> i32 {
    *out = TypstBuffer::empty();
    let Ok(source) = CStr::from_ptr(source).to_str() else { return 2 };

    let root = typst::syntax::parse(source);
    let mut walker = StructureWalker::new(source);
    walker.walk(&root, 0);

    match serde_json::to_vec(&walker.out) {
        Ok(json) => {
            *out = TypstBuffer::from_vec(json);
            0
        }
        Err(_) => 2,
    }
}

// MARK: Entry point

/// Compile `source` rooted at `root`. Returns 0 on success (`out_pdf` filled),
/// 1 on compile errors (`out_diagnostics` filled, no PDF), 2 on internal error.
/// Both out-buffers must be freed with `typst_buffer_free`.
///
/// # Safety
/// All pointer arguments must be valid; strings must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn typst_compile_pdf(
    source: *const c_char,
    root: *const c_char,
    packages: *const c_char,
    out_pdf: *mut TypstBuffer,
    out_diagnostics: *mut TypstBuffer,
) -> i32 {
    *out_pdf = TypstBuffer::empty();
    *out_diagnostics = TypstBuffer::empty();

    let (Ok(source), Ok(root), Ok(packages)) = (
        CStr::from_ptr(source).to_str(),
        CStr::from_ptr(root).to_str(),
        CStr::from_ptr(packages).to_str(),
    ) else {
        return 2;
    };

    let world = FfiWorld::new(
        source.to_string(),
        Path::new(root).to_path_buf(),
        Path::new(packages).to_path_buf(),
    );

    let result = typst::compile::<PagedDocument>(&world);
    let mut diagnostics = convert(&world, &result.warnings);

    match result.output {
        Ok(document) => match typst_pdf::pdf(&document, &typst_pdf::PdfOptions::default()) {
            Ok(pdf) => {
                *out_pdf = TypstBuffer::from_vec(pdf);
                emit(&diagnostics, out_diagnostics);
                0
            }
            Err(errors) => {
                diagnostics.extend(convert(&world, &errors));
                emit(&diagnostics, out_diagnostics);
                1
            }
        },
        Err(errors) => {
            diagnostics.extend(convert(&world, &errors));
            emit(&diagnostics, out_diagnostics);
            1
        }
    }
}
