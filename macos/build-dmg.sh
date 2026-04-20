#!/usr/bin/env bash
#
# Build a drag-to-Applications style DMG from dist/QuoteMessage.app.
#
# Usage:  ./build-dmg.sh                     # expects ./build.sh to have run
#         ./build-dmg.sh --build             # run ./build.sh --universal first
#         ./build-dmg.sh --build --arm64     # arm64-only (faster, dev builds)
#
# Output: ./dist/QuoteMessage-<version>.dmg
#
# The DMG layout:
#   ┌───────────────────────────────────────┐
#   │                                       │
#   │   ┌────────┐       ┌──────────────┐   │
#   │   │        │       │              │   │
#   │   │   Q    │  →    │ Applications │   │
#   │   │QuoteMessage│      │              │   │
#   │   └────────┘       └──────────────┘   │
#   └───────────────────────────────────────┘
#
# Technique: build a read-WRITE DMG first, mount it, drive Finder via
# AppleScript to set icon positions + window size, then convert to a
# compressed read-only DMG for distribution.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# ---- optional: rebuild first ---------------------------------------------
# Default is a universal binary (arm64 + x86_64) so one DMG serves both
# Apple-silicon and Intel Macs.  Pass extra build flags after --build to
# override (e.g. `./build-dmg.sh --build --arm64` for local dev).
if [[ "${1:-}" == "--build" ]]; then
    shift
    if [[ $# -gt 0 ]]; then
        ./build.sh "$@"
    else
        ./build.sh --universal
    fi
fi

APP="${HERE}/dist/QuoteMessage.app"
if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found — run ./build.sh first (or pass --build)" >&2
    exit 1
fi

# Pull version out of Info.plist so the DMG file name tracks releases.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "${APP}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")

VOLNAME="QuoteMessage"
STAGING=$(mktemp -d -t quotemessage-dmg)
RW_DMG="${HERE}/dist/.tmp-rw.dmg"
FINAL_DMG="${HERE}/dist/QuoteMessage-${VERSION}.dmg"

# Make sure Finder isn't holding the old mount; ignore failures.
hdiutil detach "/Volumes/${VOLNAME}" -force 2>/dev/null || true
rm -f "$RW_DMG" "$FINAL_DMG"

echo "==> staging .app and Applications shortcut"
cp -R "$APP" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

echo "==> creating read-write DMG"
# UDRW = read-write so we can mutate layout; size auto-sized from source.
hdiutil create -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -ov -format UDRW \
    "$RW_DMG" >/dev/null

echo "==> mounting and applying Finder layout"
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")
DEVICE=$(echo "$MOUNT_INFO" | awk 'NR==1 {print $1}')
MOUNT_POINT=$(echo "$MOUNT_INFO" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')

# Give Finder a beat to register the volume.
sleep 1

# Drive Finder via AppleScript: icon view, no toolbar/sidebar, big icons,
# .app on the left, Applications on the right, arrow-ish layout.
# (No custom background image — keeping this self-contained; drop one in
#  at .background/ and set `set background picture of ...` if wanted.)
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 900, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set position of item "QuoteMessage.app" of container window to {130, 140}
        set position of item "Applications" of container window to {370, 140}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Make sure .DS_Store is flushed before unmount.
sync
sleep 1

echo "==> detaching"
hdiutil detach "$DEVICE" -force >/dev/null

echo "==> converting to compressed read-only DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 \
    -o "$FINAL_DMG" >/dev/null

rm -f "$RW_DMG"
rm -rf "$STAGING"

SIZE=$(du -h "$FINAL_DMG" | awk '{print $1}')
echo ""
echo "✅ built: $FINAL_DMG  (${SIZE})"
echo ""
echo "分发时直接上传这个 .dmg；用户双击后会看到 QuoteMessage 图标 → 拖到 Applications 即可。"
