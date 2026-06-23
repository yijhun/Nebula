#!/usr/bin/env bash
# Build Notepro.app end-to-end: web core -> Xcode project -> .app -> ad-hoc sign.
# Usage: apple/build-app.sh   (run from anywhere)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"

echo "==> [1/4] Building web core (vite)…"
( cd "$ROOT/web-core" && npx vite build )

echo "==> [2/4] Generating Xcode project (xcodegen)…"
( cd "$ROOT/apple" && xcodegen generate )

echo "==> [3/4] Building app (xcodebuild)…"
( cd "$ROOT/apple" && xcodebuild -project Notepro.xcodeproj -scheme Notepro \
    -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet )

APP="$ROOT/apple/build/Build/Products/Release/Notepro.app"
echo "==> [4/4] Ad-hoc signing + copying to repo root…"
codesign --force --deep -s - "$APP"
rm -rf "$ROOT/Notepro.app"
cp -R "$APP" "$ROOT/Notepro.app"
codesign --force --deep -s - "$ROOT/Notepro.app"

echo "✅ Built: $ROOT/Notepro.app"
echo "   Open it with:  open \"$ROOT/Notepro.app\""
