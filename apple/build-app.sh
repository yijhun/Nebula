#!/usr/bin/env bash
# Build Nebula.app end-to-end: web core -> Xcode project -> .app -> ad-hoc sign.
# Usage: apple/build-app.sh   (run from anywhere)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"

echo "==> [1/4] Building web core (vite)…"
( cd "$ROOT/web-core" && npx vite build && npx vite build --config vite.chat.config.ts )

echo "==> [2/4] Generating Xcode project (xcodegen)…"
( cd "$ROOT/apple" && xcodegen generate )

echo "==> [3/4] Building app (xcodebuild)…"
( cd "$ROOT/apple" && xcodebuild -project Nebula.xcodeproj -scheme Nebula \
    -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet )

APP="$ROOT/apple/build/Build/Products/Release/Nebula.app"
echo "==> [4/5] Ad-hoc signing…"
codesign --force --deep -s - "$APP"

# Losing or crossing files is the worst thing this app can do. A build that
# fails this never replaces the working Nebula.app. (Temp files only.)
echo "==> [5/5] Save, library and reader self-tests, then copying to repo root…"
"$APP/Contents/MacOS/Nebula" --save-selftest
"$APP/Contents/MacOS/Nebula" --library-selftest
"$APP/Contents/MacOS/Nebula" --reader-selftest
rm -rf "$ROOT/Nebula.app"
cp -R "$APP" "$ROOT/Nebula.app"
codesign --force --deep -s - "$ROOT/Nebula.app"

# The second Dock icon: a tiny app that opens the reader's library in
# Nebula (apple/Launcher/main.swift). Kept next to Nebula.app.
echo "==> Building Nebula Papers (the library's Dock icon)…"
PAPERS="$ROOT/apple/build/Nebula Papers.app"
rm -rf "$PAPERS"
mkdir -p "$PAPERS/Contents/MacOS" "$PAPERS/Contents/Resources"
cp "$ROOT/apple/Launcher/Info.plist" "$PAPERS/Contents/Info.plist"
cp "$ROOT/apple/Launcher/PapersIcon.icns" "$PAPERS/Contents/Resources/"
swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$PAPERS/Contents/MacOS/NebulaPapers" "$ROOT/apple/Launcher/main.swift"
codesign --force -s - "$PAPERS"
rm -rf "$ROOT/Nebula Papers.app"
cp -R "$PAPERS" "$ROOT/Nebula Papers.app"
# Re-register both, so nebula:// and the new icon are known at once.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$ROOT/Nebula.app" "$ROOT/Nebula Papers.app" || true

echo "✅ Built: $ROOT/Nebula.app and $ROOT/Nebula Papers.app"
echo "   Open it with:  open \"$ROOT/Nebula.app\""
echo "   Drag both into the Dock: Nebula opens notes, Nebula Papers the paper library."
