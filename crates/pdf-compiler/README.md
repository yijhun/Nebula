# pdf_compiler — Tectonic wrapper (Spike A)

Rust crate wrapping [Tectonic](https://tectonic-typesetting.github.io/) as a
library, exposing a C ABI (`np_pdf_compile`) for the Apple shell to compile a
`.tex` → PDF. Built as a `staticlib` for packaging into an XCFramework.

## Status

| Target | State |
|---|---|
| **macOS host** (aarch64-apple-darwin) | ✅ builds, links, compiles the full Spike-A case (中文 + 公式 + 引用) from Rust via the multi-pass driver |
| Multi-pass driver + in-process bibtex | ✅ `compile_with_bundle` runs the TeX/bibtex/rerun loop; `\printbibliography` (biblatex `backend=bibtex`) resolves with **no external biber** — offline-capable |
| Local/offline bundle (`bundle_path`) | ✅ `detect_bundle` accepts a directory / `.zip` / indexed-tar; NULL → default cached bundle |
| C ABI (`np_pdf_compile`) + header | ✅ defined (`include/pdf_compiler.h`), host `libpdf_compiler.a` builds (~54 MB) |
| **iOS** (aarch64-apple-ios / -sim) | ❌ blocked — see below |

### iOS blocker (the plan's #1 risk, now concrete)

`cargo build --target aarch64-apple-ios` fails in `tectonic_bridge_png`'s build
script:

```
pkg-config has not been configured to support cross-compilation.
```

Tectonic's C dependencies — libpng, freetype, harfbuzz, ICU, graphite2 — must be
**cross-compiled for arm64-iOS** and discoverable via a pkg-config sysroot.
Homebrew only provides host (macOS) builds. Two real paths forward:

1. **Static C deps via vcpkg** (upstream Tectonic's cross/static approach):
   install vcpkg, build `freetype harfbuzz icu graphite2 libpng` for an
   arm64-ios triplet, then build with `TECTONIC_DEP_BACKEND=vcpkg`. Fiddly
   (ICU-on-iOS especially), multi-hour, and still needs on-device verification
   in Xcode.
2. **Cloud compile fallback** (plan's documented Plan B): run Tectonic
   server-side, keep the iOS app thin. Removes the on-device TeX toolchain risk
   entirely.

On-device Spike A verification (offline, one-page Chinese+formula+citation PDF)
requires a physical device / simulator in Xcode — outside this CLI environment.

## Build (host)

```bash
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/icu4c/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"
cargo build --release                                  # -> target/release/libpdf_compiler.a
cargo run --example compile -- input.tex ./out         # smoke test -> out/input.pdf
```

## XCFramework packaging (once per-target .a files exist)

```bash
for T in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
  cargo build --release --target "$T"
done
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libpdf_compiler.a     -headers include \
  -library target/aarch64-apple-ios-sim/release/libpdf_compiler.a -headers include \
  -library target/aarch64-apple-darwin/release/libpdf_compiler.a  -headers include \
  -output PDFCompiler.xcframework
```

## Notes

- `build_date` is stamped to "now" so `\today` renders the real date (Tectonic
  otherwise defaults to the Unix epoch → 1970-01-01 for reproducible builds).
- The default bundle is fetched once then served from Tectonic's cache, so
  repeat compiles are offline. For a *self-contained* offline bundle (shipping
  with the app), pass a local bundle via `bundle_path` / `compile_with_bundle`.

## Next increments

- Build the shippable **offline bundle** (DESIGN §4.9 TeX package set) + bundle
  the CJK fonts (`fonts/`), and point `bundle_path` at it instead of the cache.
- iOS: cross-compiled C deps (vcpkg) **or** cloud-compile fallback (see above).
