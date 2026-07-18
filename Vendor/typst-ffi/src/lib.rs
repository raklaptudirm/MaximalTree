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
