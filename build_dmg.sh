#!/bin/bash
# Build JARVIS-1.0.dmg — wraps the self-contained pkg in a disk image.
# The pkg must already have offline resources embedded (run build_pkg.sh after bundle_resources.sh).
#
# Usage:
#   ./bundle_resources.sh   # download everything once
#   ./build_pkg.sh          # builds fat pkg with resources embedded
#   ./build_dmg.sh          # wraps it in a DMG for distribution
set -euo pipefail

VERSION="1.0"
JARVIS_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG="$JARVIS_DIR/JARVIS-${VERSION}.pkg"
DMG_STAGING="$JARVIS_DIR/.dmg-staging"
OUTPUT_DMG="$JARVIS_DIR/JARVIS-${VERSION}.dmg"

if [ ! -f "$PKG" ]; then
  echo "ERROR: $PKG not found. Run ./build_pkg.sh first."
  exit 1
fi

PKG_SIZE=$(du -sh "$PKG" | cut -f1)
echo "▶ Wrapping $PKG ($PKG_SIZE) into DMG..."

rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp "$PKG" "$DMG_STAGING/"

cat > "$DMG_STAGING/README.txt" <<EOF
JARVIS Offline Installer
========================

Double-click JARVIS-${VERSION}.pkg to install.
No internet connection required — everything is bundled.

After installation, grant permissions in:
  System Settings > Privacy & Security
    • Microphone
    • Screen Recording  (for "what's on screen" features)
    • Full Disk Access  (for reading Mail / Messages)
    • Automation        (for controlling Music, Reminders, Calendar)

Say "Jarvis" to begin.

To uninstall:
  bash "/Library/Application Support/JARVIS/uninstall-jarvis.sh"
EOF

rm -f "$OUTPUT_DMG"
hdiutil create \
  -volname "JARVIS" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$OUTPUT_DMG"

rm -rf "$DMG_STAGING"

echo ""
echo "✓  Built: $OUTPUT_DMG  ($(du -sh "$OUTPUT_DMG" | cut -f1))"
