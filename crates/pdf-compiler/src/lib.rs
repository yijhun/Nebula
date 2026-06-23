//! Notepro PDF compiler — thin Tectonic wrapper.
//!
//! Spike A goal: prove Tectonic can be embedded as a library and compile a
//! .tex (Chinese + math + citation) to a PDF offline, then package as an
//! XCFramework for the Apple shell.
//!
//! This first cut uses Tectonic's high-level `latex_to_pdf` to clear the
//! make-or-break risk (does the engine build and link at all on this setup?).
//! The offline local-bundle + multi-pass driver API + C ABI come next.

use std::ffi::{c_char, c_int, CStr};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use tectonic::config::PersistentConfig;
use tectonic::driver::{OutputFormat, PassSetting, ProcessingSessionBuilder};
use tectonic::status::NoopStatusBackend;
use tectonic_bundles::detect_bundle;

/// Status codes returned across the C ABI (mirrored in the Swift shell).
#[repr(C)]
pub enum NpStatus {
    Ok = 0,
    BadArgs = 1,
    ReadFailed = 2,
    CompileFailed = 3,
    WriteFailed = 4,
}

/// Compile a single .tex file to a PDF written into `out_dir`, using the
/// default (cached) resource bundle. Convenience wrapper over
/// [`compile_with_bundle`].
pub fn compile_file(tex_path: &Path, out_dir: &Path) -> Result<PathBuf, String> {
    compile_with_bundle(tex_path, out_dir, None, false)
}

/// Compile `tex_path` to a PDF in `out_dir` via Tectonic's multi-pass driver.
///
/// - `bundle_src`: a local bundle path/URL (offline) or `None` for the default
///   cached web bundle. Accepts a directory, `.zip`, or indexed-tar bundle.
/// - `only_cached`: never hit the network; require everything be cached/local.
///
/// The driver runs the full TeX/bibtex/rerun loop (`PassSetting::Default`), so
/// `\printbibliography` with biblatex's `backend=bibtex` resolves in-process —
/// no external biber, which is what makes offline compilation possible.
/// `filesystem_root` is set to the input's directory so sibling files
/// (`references.bib`, images) are readable by the engine.
pub fn compile_with_bundle(
    tex_path: &Path,
    out_dir: &Path,
    bundle_src: Option<&str>,
    only_cached: bool,
) -> Result<PathBuf, String> {
    let mut status = NoopStatusBackend::default();

    let config = PersistentConfig::open(false)
        .map_err(|e| format!("open Tectonic config: {e}"))?;

    let bundle = match bundle_src {
        Some(src) => detect_bundle(src.to_string(), only_cached, None)
            .map_err(|e| format!("load bundle {src:?}: {e}"))?
            .ok_or_else(|| format!("no bundle found at {src:?}"))?,
        None => config
            .default_bundle(only_cached)
            .map_err(|e| format!("load default bundle: {e}"))?,
    };

    let format_cache_path = config
        .format_cache_path()
        .map_err(|e| format!("format cache: {e}"))?;

    fs::create_dir_all(out_dir).map_err(|e| format!("mkdir {out_dir:?}: {e}"))?;

    let input_dir = tex_path.parent().unwrap_or_else(|| Path::new("."));
    let tex_name = tex_path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| format!("bad tex filename: {tex_path:?}"))?;

    let mut sb = ProcessingSessionBuilder::default();
    sb.bundle(bundle)
        .primary_input_path(tex_path)
        .tex_input_name(tex_name)
        .filesystem_root(input_dir)
        .format_name("latex")
        .format_cache_path(format_cache_path)
        .keep_logs(false)
        .keep_intermediates(false)
        .print_stdout(false)
        .pass(PassSetting::Default)
        // Tectonic defaults build_date to the Unix epoch for reproducible
        // builds, which makes \today render as 1970-01-01. A notes app wants
        // the real date, so stamp "now".
        .build_date(SystemTime::now())
        .output_format(OutputFormat::Pdf)
        .output_dir(out_dir);

    let mut sess = sb
        .create(&mut status)
        .map_err(|e| format!("init processing session: {e}"))?;
    sess.run(&mut status)
        .map_err(|e| format!("LaTeX engine failed: {e}"))?;

    let stem = tex_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");
    let out_path = out_dir.join(format!("{stem}.pdf"));
    if !out_path.exists() {
        return Err(format!(
            "engine reported success but {out_path:?} was not produced"
        ));
    }
    Ok(out_path)
}

// ---------------------------------------------------------------------------
// C ABI — the contract the Swift `PDFService` calls (DESIGN §1 / Phase 4).
// ---------------------------------------------------------------------------

/// Compile `tex_path` to a PDF in `out_dir`.
///
/// `bundle_path` selects the resource bundle: pass a local bundle path/URL
/// (directory, `.zip`, or indexed tar) for offline compilation, or NULL to use
/// Tectonic's default cached bundle.
///
/// All string args are NUL-terminated UTF-8. Returns an `NpStatus` code.
///
/// # Safety
/// Callers must pass valid NUL-terminated C strings (or NULL for `bundle_path`).
#[no_mangle]
pub unsafe extern "C" fn np_pdf_compile(
    tex_path: *const c_char,
    bundle_path: *const c_char,
    out_dir: *const c_char,
) -> c_int {
    if tex_path.is_null() || out_dir.is_null() {
        return NpStatus::BadArgs as c_int;
    }
    let tex = match CStr::from_ptr(tex_path).to_str() {
        Ok(s) => s,
        Err(_) => return NpStatus::BadArgs as c_int,
    };
    let out = match CStr::from_ptr(out_dir).to_str() {
        Ok(s) => s,
        Err(_) => return NpStatus::BadArgs as c_int,
    };
    let bundle: Option<&str> = if bundle_path.is_null() {
        None
    } else {
        match CStr::from_ptr(bundle_path).to_str() {
            Ok(s) => Some(s),
            Err(_) => return NpStatus::BadArgs as c_int,
        }
    };

    match compile_with_bundle(Path::new(tex), Path::new(out), bundle, false) {
        Ok(_) => NpStatus::Ok as c_int,
        Err(e) => {
            eprintln!("np_pdf_compile: {e}");
            NpStatus::CompileFailed as c_int
        }
    }
}
