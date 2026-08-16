// C ABI for the typst compiler bindings (see Vendor/typst-ffi).
#ifndef TYPST_FFI_H
#define TYPST_FFI_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} TypstBuffer;

/// Downloads `url` and writes it to `dest` (both NUL-terminated UTF-8).
/// Returns 0 on success, 1 when the remote reports the resource does not exist
/// (HTTP 404), and any other value for a failure.
typedef int32_t (*TypstFetchFn)(const char *url, const char *dest);

/// Register the host's package fetcher, or pass NULL to clear it. Missing
/// @preview packages are downloaded from Typst Universe through this callback;
/// without one, only packages already on disk resolve. HTTP lives on the host
/// side so this library stays free of networking and TLS.
void typst_set_package_fetcher(TypstFetchFn fetch);

/// Compile `source` (NUL-terminated UTF-8) as though it lived at
/// <root><main_path> — e.g. root "/work", main_path "/notes/today.typ". Pass
/// "/main.typ" when the source has no real location. Relative imports resolve
/// against the directory holding that file, and never outside `root`; @<ns>
/// packages resolve against <packages>/<ns>/<name>/<version>, downloading
/// missing @preview packages when a fetcher is registered.
///
/// Returns 0 on success (out_pdf filled), 1 on compile errors (no PDF), 2 on
/// internal error. out_diagnostics receives a JSON array of
/// {severity, message, line (1-based), column (0-based)}.
/// Free both out-buffers with typst_buffer_free.
int32_t typst_compile_pdf(const char *source,
                          const char *root,
                          const char *main_path,
                          const char *packages,
                          TypstBuffer *out_pdf,
                          TypstBuffer *out_diagnostics);

/// Tokenize `source` (NUL-terminated UTF-8) for editor highlighting using the
/// real typst parser. Writes a JSON array of tokens with UTF-16 ranges:
/// {s, l, k, n? (heading level), a? (alignment)}. Returns 0 on success.
int32_t typst_tokens(const char *source, TypstBuffer *out_tokens);

/// Extract document structure (sections, tasks with UTF-16 toggle edits, links)
/// using the real typst parser. Writes a JSON array; returns 0 on success.
int32_t typst_structure(const char *source, TypstBuffer *out);

/// Render one page of the compiled document to PNG at `pixel_per_pt`.
/// out_info receives JSON {w, h, b (baseline), pages} in points. Returns 0 on
/// success, 1 on compile error / page out of range, 2 on internal error.
int32_t typst_render_png(const char *source,
                         const char *root,
                         const char *main_path,
                         const char *packages,
                         double pixel_per_pt,
                         int32_t page_index,
                         TypstBuffer *out_png,
                         TypstBuffer *out_info);

/// Render the whole compiled document to a single SVG (pages stacked).
/// Returns 0 on success, 1 on compile error, 2 on internal error.
int32_t typst_render_svg(const char *source,
                         const char *root,
                         const char *main_path,
                         const char *packages,
                         TypstBuffer *out_svg);

void typst_buffer_free(TypstBuffer buf);

#endif
