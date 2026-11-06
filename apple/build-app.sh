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
echo "==> [5/5] Save self-test, then copying to repo root…"
"$APP/Contents/MacOS/Nebula" --save-selftest
rm -rf "$ROOT/Nebula.app"
cp -R "$APP" "$ROOT/Nebula.app"
codesign --force --deep -s - "$ROOT/Nebula.app"

echo "✅ Built: $ROOT/Nebula.app"
echo "   Open it with:  open \"$ROOT/Nebula.app\""
