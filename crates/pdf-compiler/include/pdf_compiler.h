/* pdf_compiler.h — C ABI for the Notepro Tectonic wrapper.
 * Linked by the Apple shell (Swift PDFService) via the XCFramework.
 * Keep in sync with src/lib.rs (np_pdf_compile / NpStatus). */
#ifndef NOTEPRO_PDF_COMPILER_H
#define NOTEPRO_PDF_COMPILER_H

#ifdef __cplusplus
extern "C" {
#endif

/* Status codes (mirror of Rust enum NpStatus). */
typedef enum {
    NP_OK = 0,
    NP_BAD_ARGS = 1,
    NP_READ_FAILED = 2,
    NP_COMPILE_FAILED = 3,
    NP_WRITE_FAILED = 4
} NpStatus;

/* Compile `tex_path` to a PDF written into `out_dir`.
 * `bundle_path` may be NULL (default bundle) or a local bundle for offline use.
 * All strings are NUL-terminated UTF-8. Returns an NpStatus code. */
int np_pdf_compile(const char *tex_path,
                   const char *bundle_path,
                   const char *out_dir);

#ifdef __cplusplus
}
#endif

#endif /* NOTEPRO_PDF_COMPILER_H */
