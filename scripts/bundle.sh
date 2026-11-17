#!/bin/bash
# Builds Kveikur.app from the SwiftPM executable and ad-hoc signs it.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Kveikur.app"

cd "$ROOT"
swift build -c "$CONFIG" --product Kveikur
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Kveikur"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kveikur"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"; fi

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
