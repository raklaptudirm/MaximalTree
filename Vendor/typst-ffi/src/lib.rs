//! C ABI bindings to the typst compiler for MaximalTree.
//!
//! One entry point: compile a UTF-8 source string as though it lived at
//! `<root><main_path>` (default `/main.typ`), resolving relative files against
//! the directory that file sits in and `@<ns>/…`
//! packages against `<packages>/<ns>/<name>/<version>`, downloading missing
//! `@preview` packages from Typst Universe through a host-provided fetcher.
//! Returns PDF bytes and
//! structured diagnostics (JSON) — no CLI, no stderr parsing, works on iOS.
//!
//! Diagnostic coordinates follow typst's conventions: 1-based lines,
//! 0-based columns.

use std::any::Any;
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::io::{self, Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration as StdDuration, Instant};

use typst::diag::{FileError, FileResult, PackageError, PackageResult, Severity,
                  SourceDiagnostic};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World, WorldExt};
use typst::syntax::package::PackageSpec;
use typst_kit::downloader::Downloader;
use typst_kit::fonts::FontStore;
use typst_kit::packages::{FsPackages, SystemPackages, UniversePackages};
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

// MARK: Packages

/// The host's package fetcher: download `url` and write it to `dest`, both
/// NUL-terminated UTF-8 paths. Returns 0 on success, 1 when the remote said
/// the resource does not exist (HTTP 404 — typst reads this as "no such
/// package/version" and can then suggest the latest one), and any other value
/// for a failure.
///
/// Downloading happens on the host side on purpose: the app already owns
/// networking (proxies, timeouts, the user's error UI), and keeping HTTP and
/// TLS out of this library is what lets it stay portable. Handing over a file
/// path rather than a buffer keeps both allocators on their own side of the
/// boundary.
pub type TypstFetchFn = extern "C" fn(url: *const c_char, dest: *const c_char) -> i32;

static FETCHER: Mutex<Option<TypstFetchFn>> = Mutex::new(None);

/// Register (or clear, with null) the host's package fetcher. Without one,
/// only packages already on disk resolve.
#[no_mangle]
pub extern "C" fn typst_set_package_fetcher(fetch: Option<TypstFetchFn>) {
    if let Ok(mut slot) = FETCHER.lock() {
        *slot = fetch;
    }
}

/// typst-kit's downloader, implemented over the host callback.
struct HostDownloader;

impl Downloader for HostDownloader {
    fn stream(
        &self,
        key: &dyn Any,
        url: &str,
    ) -> io::Result<(Option<usize>, Box<dyn Read>)> {
        let data = self.download(key, url)?;
        Ok((Some(data.len()), Box::new(Cursor::new(data))))
    }

    fn download(&self, _key: &dyn Any, url: &str) -> io::Result<Vec<u8>> {
        let fetch = FETCHER
            .lock()
            .ok()
            .and_then(|slot| *slot)
            .ok_or_else(|| io::Error::other("no package fetcher registered"))?;

        // Next to the eventual package tree, so the download and the extracted
        // package land on the same volume, and a crash leaves at most a stray
        // temp file inside our own directory.
        let dest = std::env::temp_dir()
            .join(format!("typst-download-{}.tar.gz", unique_tag()));
        let (Ok(url_c), Ok(dest_c)) =
            (CString::new(url), CString::new(dest.to_string_lossy().as_ref()))
        else {
            return Err(io::Error::other("path is not representable"));
        };

        let status = fetch(url_c.as_ptr(), dest_c.as_ptr());
        let result = match status {
            0 => std::fs::read(&dest),
            1 => Err(io::Error::new(io::ErrorKind::NotFound, "not found")),
            _ => Err(io::Error::other("download failed")),
        };
        let _ = std::fs::remove_file(&dest);
        result
    }
}

/// A tag unique to this download, so concurrent compiles never share a temp
/// file. Process id and a counter are enough — this never leaves our machine.
fn unique_tag() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    format!("{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Failed lookups, so a package that can't be had doesn't re-hit the network
/// on every keystroke — a live preview recompiles constantly. Remembered
/// briefly rather than forever: a failure is often just "the wifi was off a
/// second ago", and the fix should be to try again, not to relaunch.
static FAILURES: Mutex<Option<HashMap<String, (Instant, PackageError)>>> = Mutex::new(None);
const RETRY_AFTER: StdDuration = StdDuration::from_secs(30);

fn remembered_failure(key: &str) -> Option<PackageError> {
    let mut guard = FAILURES.lock().ok()?;
    let map = guard.as_mut()?;
    match map.get(key) {
        Some((at, error)) if at.elapsed() < RETRY_AFTER => Some(error.clone()),
        Some(_) => {
            map.remove(key);
            None
        }
        None => None,
    }
}

fn remember_failure(key: String, error: &PackageError) {
    if let Ok(mut guard) = FAILURES.lock() {
        guard
            .get_or_insert_with(HashMap::new)
            .insert(key, (Instant::now(), error.clone()));
    }
}

/// Make `spec` available under `packages`, downloading it from Typst Universe
/// if we don't have it yet. Already-present packages (including everything in
/// the `@local` namespace) never reach the network.
fn obtain_package(packages: &Path, spec: &PackageSpec) -> PackageResult<()> {
    let key = spec.to_string();
    if let Some(error) = remembered_failure(&key) {
        return Err(error);
    }
    // Data and cache are the same tree here: the FFI's contract is that every
    // package lives at <packages>/<ns>/<name>/<version>, whether the user put
    // it there or we downloaded it.
    let store = SystemPackages::from_parts(
        Some(FsPackages::new(packages)),
        Some(FsPackages::new(packages)),
        UniversePackages::new(HostDownloader),
    );
    match store.obtain(spec) {
        Ok(_) => Ok(()),
        Err(error) => {
            remember_failure(key, &error);
            Err(error)
        }
    }
}

// MARK: World

struct FfiWorld {
    root: PathBuf,
    packages: PathBuf,
    main: Source,
}

impl FfiWorld {
    /// `main_path` is where the source sits *inside* the root, e.g.
    /// `/notes/today.typ`. It matters as much as the root does: relative
    /// imports resolve against the importing file's own directory, so a file
    /// compiled as `/main.typ` would resolve `./sibling.typ` at the root
    /// rather than next to itself.
    fn new(source: String, root: PathBuf, packages: PathBuf, main_path: &str) -> Self {
        let vpath = VirtualPath::new(main_path)
            .or_else(|_| VirtualPath::new("/main.typ"))
            .expect("static path is valid");
        let id = FileId::new(RootedPath::new(VirtualRoot::Project, vpath));
        FfiWorld { root, packages, main: Source::new(id, source) }
    }

    /// Resolve a FileId to an on-disk path: package files under the package
    /// directory, everything else under the compilation root.
    fn path_for(&self, id: FileId) -> FileResult<PathBuf> {
        let path = id.get();
        let base = match path.root() {
            VirtualRoot::Package(spec) => self.package_dir(spec)?,
            VirtualRoot::Project => self.root.clone(),
        };
        path.vpath().realize(&base).map_err(|_| FileError::AccessDenied)
    }

    /// Where a package's files live, fetching the package first if it isn't
    /// installed yet. Reporting a package error (rather than letting the read
    /// fail) is what turns the useless "file typst.toml is missing" into
    /// "package not found" / "failed to download package".
    fn package_dir(&self, spec: &PackageSpec) -> FileResult<PathBuf> {
        let dir = self
            .packages
            .join(spec.namespace.as_str())
            .join(spec.name.as_str())
            .join(spec.version.to_string());
        if dir.is_dir() {
            return Ok(dir);
        }
        obtain_package(&self.packages, spec).map_err(FileError::Package)?;
        Ok(dir)
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
    a: Option<String>,  // alignment, or embedded-code language
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
            level: Option<usize>, alignment: Option<&str>) {
        let s = self.utf16[start.min(self.src.len())];
        let e = self.utf16[(start + len).min(self.src.len())];
        if e > s {
            self.out.push(EditorToken {
                s, l: e - s, k: kind, n: level,
                a: alignment.map(String::from),
            });
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
            K::Raw => self.walk_raw(node, offset),
            K::Equation => {
                // Block equations (`$ x $` — space inside both dollars, same
                // check as ast::Equation::block) center in the preview.
                let count = node.children().len();
                let kind_at = |i: usize| node.children().nth(i).map(|n| n.kind());
                let block = count >= 4
                    && kind_at(1) == Some(K::Space)
                    && kind_at(count - 2) == Some(K::Space);
                self.emit(offset, node.len(), "math", None,
                          if block { Some("block") } else { None });
                let mut child_offset = offset;
                for child in node.children() {
                    if child.kind() == K::Dollar {
                        self.emit(child_offset, child.len(), "punct", None, None);
                    }
                    child_offset += child.len();
                }
            }
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
                    self.walk_raw(child, cursor);
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

    /// Raw blocks/spans: fences and the language tag emit as concealable `punct`,
    /// and the embedded code gets its own syntax highlighting — typst via a real
    /// reparse, common languages via a small lexer (comments/strings/numbers/
    /// keywords), unknown languages strings+numbers only.
    fn walk_raw(&mut self, node: &typst::syntax::SyntaxNode, offset: usize) {
        use typst::syntax::SyntaxKind as K;
        self.emit(offset, node.len(), "raw", None, None);

        let mut child_offset = offset;
        let mut lang: Option<String> = None;
        let mut inner_start: Option<usize> = None;
        let mut inner_end = offset;
        for child in node.children() {
            match child.kind() {
                K::RawDelim => self.emit(child_offset, child.len(), "punct", None, None),
                K::RawLang => {
                    lang = Some(self.slice(child_offset, child.len()).to_lowercase());
                    self.emit(child_offset, child.len(), "punct", None, None);
                }
                _ => {
                    if inner_start.is_none() {
                        inner_start = Some(child_offset);
                    }
                    inner_end = child_offset + child.len();
                }
            }
            child_offset += child.len();
        }
        if let (Some(start), Some(lang)) = (inner_start, lang) {
            if inner_end > start {
                self.highlight_embedded(&lang, start, inner_end - start);
            }
        }
    }

    fn highlight_embedded(&mut self, lang: &str, start: usize, len: usize) {
        let src: &'a str = self.src;
        let Some(inner) = src.get(start..start + len) else { return };
        match lang {
            // Typst code gets the real parser, like everything else here.
            "typ" | "typst" => {
                let root = typst::syntax::parse(inner);
                self.walk(&root, start);
            }
            // Foreign languages aren't this crate's business: hand the region and
            // its language to the editor, which highlights it with a real
            // highlighting library.
            _ => self.emit(start, len, "embed", None, Some(lang)),
        }
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
    main_path: *const c_char,
    packages: *const c_char,
    out_pdf: *mut TypstBuffer,
    out_diagnostics: *mut TypstBuffer,
) -> i32 {
    *out_pdf = TypstBuffer::empty();
    *out_diagnostics = TypstBuffer::empty();

    let (Ok(source), Ok(root), Ok(main_path), Ok(packages)) = (
        CStr::from_ptr(source).to_str(),
        CStr::from_ptr(root).to_str(),
        CStr::from_ptr(main_path).to_str(),
        CStr::from_ptr(packages).to_str(),
    ) else {
        return 2;
    };

    let world = FfiWorld::new(
        source.to_string(),
        Path::new(root).to_path_buf(),
        Path::new(packages).to_path_buf(),
        main_path,
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

/// The y of the first text item in the frame tree, in page coordinates.
/// Frames position text items *at their baselines*, and the caller's document
/// leads with a zero-width transparent strut at full text size — so the first
/// text item's y IS the paragraph's main baseline, whatever shape the equation
/// takes. (Group baselines are useless here: page frames arrive flattened,
/// with text items as direct children.)
fn find_baseline(frame: &typst::layout::Frame, y: typst::layout::Abs) -> Option<typst::layout::Abs> {
    use typst::layout::FrameItem;
    for (pos, item) in frame.items() {
        match item {
            FrameItem::Text(_) => return Some(y + pos.y),
            FrameItem::Group(group) => {
                if let Some(baseline) = find_baseline(&group.frame, y + pos.y) {
                    return Some(baseline);
                }
            }
            _ => {}
        }
    }
    None
}

/// Compile `source` and rasterize its FIRST page to PNG at `pixel_per_pt`
/// (typst's native renderer — what `typst compile --format png` uses).
/// `out_info` receives JSON `{w, h, b}` in points: page size and the baseline
/// of the first baseline-bearing frame (the text line), measured from the top —
/// what an editor needs to sit a rendered equation exactly on its own baseline.
/// Returns 0 on success, 1 on compile errors, 2 on internal error.
///
/// # Safety
/// All pointers must be valid; strings NUL-terminated UTF-8. Free both
/// out-buffers with typst_buffer_free.
#[no_mangle]
pub unsafe extern "C" fn typst_render_png(
    source: *const c_char,
    root: *const c_char,
    main_path: *const c_char,
    packages: *const c_char,
    pixel_per_pt: f64,
    page_index: i32,
    out_png: *mut TypstBuffer,
    out_info: *mut TypstBuffer,
) -> i32 {
    *out_png = TypstBuffer::empty();
    *out_info = TypstBuffer::empty();

    let (Ok(source), Ok(root), Ok(main_path), Ok(packages)) = (
        CStr::from_ptr(source).to_str(),
        CStr::from_ptr(root).to_str(),
        CStr::from_ptr(main_path).to_str(),
        CStr::from_ptr(packages).to_str(),
    ) else {
        return 2;
    };

    let world = FfiWorld::new(
        source.to_string(),
        Path::new(root).to_path_buf(),
        Path::new(packages).to_path_buf(),
        main_path,
    );

    let result = typst::compile::<PagedDocument>(&world);
    let Ok(document) = result.output else { return 1 };
    let Some(page) = document.pages().get(page_index.max(0) as usize) else { return 1 };

    let options = typst_render::RenderOptions {
        pixel_per_pt: typst::utils::Scalar::new(pixel_per_pt),
        ..Default::default()
    };
    let pixmap = typst_render::render(page, &options);
    let Ok(png) = pixmap.encode_png() else { return 2 };

    let size = page.frame.size();
    let baseline = find_baseline(&page.frame, typst::layout::Abs::zero())
        .unwrap_or(size.y);
    let info = format!(
        "{{\"w\":{},\"h\":{},\"b\":{},\"pages\":{}}}",
        size.x.to_pt(), size.y.to_pt(), baseline.to_pt(), document.pages().len()
    );

    *out_png = TypstBuffer::from_vec(png);
    *out_info = TypstBuffer::from_vec(info.into_bytes());
    0
}

/// Render the whole document to one SVG (pages stacked, small gap). Returns 0
/// on success, 1 on compile errors, 2 on internal failure.
///
/// # Safety
/// All strings must be valid NUL-terminated UTF-8; `out_svg` must be valid.
#[no_mangle]
pub unsafe extern "C" fn typst_render_svg(
    source: *const c_char,
    root: *const c_char,
    main_path: *const c_char,
    packages: *const c_char,
    out_svg: *mut TypstBuffer,
) -> i32 {
    *out_svg = TypstBuffer::empty();

    let (Ok(source), Ok(root), Ok(main_path), Ok(packages)) = (
        CStr::from_ptr(source).to_str(),
        CStr::from_ptr(root).to_str(),
        CStr::from_ptr(main_path).to_str(),
        CStr::from_ptr(packages).to_str(),
    ) else {
        return 2;
    };

    let world = FfiWorld::new(
        source.to_string(),
        Path::new(root).to_path_buf(),
        Path::new(packages).to_path_buf(),
        main_path,
    );

    let result = typst::compile::<PagedDocument>(&world);
    let Ok(document) = result.output else { return 1 };

    let svg = typst_svg::svg_merged(&document, &typst_svg::SvgOptions::default(),
                                    typst::layout::Abs::pt(8.0));
    *out_svg = TypstBuffer::from_vec(svg.into_bytes());
    0
}
