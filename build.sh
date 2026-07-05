#!/bin/zsh
# Builds PDF Compressor.app into ./dist
set -euo pipefail
cd "$(dirname "$0")"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
[ -d "$SDK" ] || SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-macos14.0

APP="dist/PDF Compressor.app"
BIN=".build/PDFCompressor"

echo "── Compiling…"
mkdir -p .build
swiftc -O -parse-as-library -target $TARGET -sdk "$SDK" \
    Sources/PDFCompressor/*.swift -o "$BIN" 2>&1 | (grep -E "error:" || true)
[ -f "$BIN" ] || { echo "Build failed"; exit 1; }

echo "── Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PDFCompressor"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon (built once, reused afterwards)
if [ ! -f Resources/AppIcon.icns ]; then
    echo "── Rendering icon…"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    swiftc -O -sdk "$SDK" -target $TARGET scripts/makeicon.swift -o .build/makeicon
    .build/makeicon "$ICONSET"
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "── Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✅ Built: $APP"
