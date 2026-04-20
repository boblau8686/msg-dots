#!/usr/bin/env bash
#
# Generate Resources/AppIcon.icns from scratch using icon_gen.swift.
#
# macOS `.icns` is just a bundle of PNGs at fixed sizes, produced from an
# .iconset directory via `iconutil`.  We render each size with our Swift
# script and then roll them up.
#
# Sizes required by iconutil:
#   icon_16x16.png        16   icon_16x16@2x.png      32
#   icon_32x32.png        32   icon_32x32@2x.png      64
#   icon_128x128.png     128   icon_128x128@2x.png   256
#   icon_256x256.png     256   icon_256x256@2x.png   512
#   icon_512x512.png     512   icon_512x512@2x.png  1024

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ICONSET="$ROOT/build/AppIcon.iconset"
OUT="$ROOT/Resources/AppIcon.icns"

mkdir -p "$ICONSET"
mkdir -p "$ROOT/Resources"

render() {
    local size="$1" name="$2"
    swift "$HERE/icon_gen.swift" "$size" "$ICONSET/$name" > /dev/null
}

echo "==> rendering PNGs"
render   16 icon_16x16.png
render   32 icon_16x16@2x.png
render   32 icon_32x32.png
render   64 icon_32x32@2x.png
render  128 icon_128x128.png
render  256 icon_128x128@2x.png
render  256 icon_256x256.png
render  512 icon_256x256@2x.png
render  512 icon_512x512.png
render 1024 icon_512x512@2x.png

echo "==> packaging .icns"
iconutil -c icns "$ICONSET" -o "$OUT"

rm -rf "$ICONSET"
echo "✅ built: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
