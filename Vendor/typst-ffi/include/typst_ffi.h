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

/// Compile `source` (NUL-terminated UTF-8) as though it lived at <root>/main.typ.
/// Relative files resolve against `root`; @<ns> packages against
/// <packages>/<ns>/<name>/<version>.
///
/// Returns 0 on success (out_pdf filled), 1 on compile errors (no PDF), 2 on
/// internal error. out_diagnostics receives a JSON array of
/// {severity, message, line (1-based), column (0-based)}.
/// Free both out-buffers with typst_buffer_free.
int32_t typst_compile_pdf(const char *source,
                          const char *root,
                          const char *packages,
                          TypstBuffer *out_pdf,
                          TypstBuffer *out_diagnostics);

void typst_buffer_free(TypstBuffer buf);

#endif
