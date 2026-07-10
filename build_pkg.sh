#!/bin/bash
# Build JARVIS-1.0.pkg — self-contained macOS installer with model selection.
#
# Online build (~176 KB pkg, downloads everything during install):
#   ./build_pkg.sh
#
# Offline build (pkg contains all resources, 3B model bundled, zero downloads
# for default install — larger models optionally downloaded if user upgrades):
#   ./bundle_resources.sh   # run once to pre-download everything
#   ./build_pkg.sh          # builds the fat, self-contained pkg
#
# Sign for Gatekeeper-free distribution:
#   SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" ./build_pkg.sh
set -euo pipefail

VERSION="1.1"
JARVIS_DIR="$(cd "$(dirname "$0")" && pwd)"
OFFLINE_RESOURCES="$JARVIS_DIR/pkg/offline-resources"
STAGING="${JARVIS_DIR}/.pkg-staging"
SCRIPTS="${JARVIS_DIR}/pkg/scripts"
PKG_RESOURCES="${JARVIS_DIR}/pkg/resources"
OUTPUT_PKG="${JARVIS_DIR}/JARVIS-${VERSION}.pkg"

OFFLINE=0
[ -d "$OFFLINE_RESOURCES" ] && OFFLINE=1

if [ "$OFFLINE" -eq 1 ]; then
  echo "▶ Offline build — embedding all resources (3B model bundled, zero downloads for default install)"
else
  echo "▶ Online build — lightweight pkg (everything downloaded during install)"
  echo "  Run ./bundle_resources.sh first for a self-contained offline build."
fi

# ── Stage source files ────────────────────────────────────────────────────────
echo "▶ 1/5  Staging source files..."
rm -rf "$STAGING"
JARVIS_INSTALL="$STAGING/Library/Application Support/JARVIS"
mkdir -p "$JARVIS_INSTALL"

rsync -a \
  --exclude='.git' --exclude='.pkg-staging' --exclude='.dmg-staging' \
  --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='voices' --exclude='logs' \
  --exclude='alarms.json' --exclude='knowledge.json' \
  --exclude='voiceprint.npy' --exclude='audd_key.txt' \
  --exclude='.signing' \
  --exclude='*.pkg' --exclude='*.dmg' --exclude='pkg' \
  "$JARVIS_DIR/" "$JARVIS_INSTALL/"

if [ "$OFFLINE" -eq 1 ]; then
  echo "   Embedding offline resources..."
  EMBED="$STAGING/Library/JARVIS-install"
  mkdir -p "$EMBED"
  [ -d "$OFFLINE_RESOURCES/wheels" ]            && cp -aR "$OFFLINE_RESOURCES/wheels"            "$EMBED/"
  [ -d "$OFFLINE_RESOURCES/lib" ]               && cp -aR "$OFFLINE_RESOURCES/lib"               "$EMBED/"
  [ -d "$OFFLINE_RESOURCES/bin" ]               && cp -aR "$OFFLINE_RESOURCES/bin"               "$EMBED/"
  [ -d "$OFFLINE_RESOURCES/voices" ]            && cp -aR "$OFFLINE_RESOURCES/voices"            "$EMBED/"
  [ -d "$OFFLINE_RESOURCES/huggingface-cache" ] && cp -aR "$OFFLINE_RESOURCES/huggingface-cache" "$EMBED/"
  [ -d "$OFFLINE_RESOURCES/ollama" ]            && cp -aR "$OFFLINE_RESOURCES/ollama"            "$EMBED/"
  [ -d "$OFFLINE_RESOURCES/ollama-3b" ]         && cp -aR "$OFFLINE_RESOURCES/ollama-3b"         "$EMBED/"
  [ -d "$OFFLINE_RESOURCES/python" ]            && cp -aR "$OFFLINE_RESOURCES/python"            "$EMBED/"

  if [ -d "$JARVIS_DIR/dist/JARVIS.app" ]; then
    mkdir -p "$JARVIS_INSTALL/dist"
    cp -aR "$JARVIS_DIR/dist/JARVIS.app" "$JARVIS_INSTALL/dist/"
  fi

  echo "   Embedded: $(du -sh "$EMBED" | cut -f1)"
fi

# ── Build model-selector packages ─────────────────────────────────────────────
# Each is a tiny package that just drops a marker file so the postinstall
# knows which model the user chose. Model packages are listed BEFORE the core
# package in distribution.xml, so their payloads land before core's postinstall.
echo "▶ 2/5  Building model-selector and Python packages..."

# Python marker package
PY_VER="latest"
[ -f "$OFFLINE_RESOURCES/python/version.txt" ] && PY_VER=$(cat "$OFFLINE_RESOURCES/python/version.txt")
MS_PY="$JARVIS_DIR/.model-staging-python"
mkdir -p "$MS_PY/Library/Application Support/JARVIS"
touch    "$MS_PY/Library/Application Support/JARVIS/.install-python"
pkgbuild \
  --root "$MS_PY" \
  --identifier "com.jarvis.python" \
  --version "$VERSION" \
  --install-location "/" \
  "$JARVIS_DIR/JARVIS-python.pkg" 2>&1 | grep -v "^write: "
rm -rf "$MS_PY"
echo "   Built: JARVIS-python.pkg  (Python $PY_VER)"

# Model marker packages
for tag in 3b 7b 14b 32b 72b; do
  MS="$JARVIS_DIR/.model-staging-$tag"
  mkdir -p "$MS/Library/Application Support/JARVIS"
  touch    "$MS/Library/Application Support/JARVIS/.model-$tag"
  pkgbuild \
    --root "$MS" \
    --identifier "com.jarvis.model.$tag" \
    --version "$VERSION" \
    --install-location "/" \
    "$JARVIS_DIR/JARVIS-model-$tag.pkg" 2>&1 | grep -v "^write: "
  rm -rf "$MS"
  echo "   Built: JARVIS-model-$tag.pkg"
done

# ── Build core component package ──────────────────────────────────────────────
echo "▶ 3/5  Building core component package..."
pkgbuild \
  --root "$STAGING" \
  --identifier "com.jarvis.core" \
  --version "$VERSION" \
  --scripts "$SCRIPTS" \
  --install-location "/" \
  "$JARVIS_DIR/JARVIS-core.pkg" 2>&1 | grep -v "^write: "

# ── Build distribution package ────────────────────────────────────────────────
echo "▶ 4/5  Building distribution package..."
productbuild \
  --distribution "$JARVIS_DIR/pkg/distribution.xml" \
  --resources    "$PKG_RESOURCES" \
  --package-path "$JARVIS_DIR" \
  ${SIGN_IDENTITY:+--sign "$SIGN_IDENTITY"} \
  "$OUTPUT_PKG"

# ── Cleanup ───────────────────────────────────────────────────────────────────
echo "▶ 5/5  Cleaning up..."
for tag in 3b 7b 14b 32b 72b; do
  rm -f "$JARVIS_DIR/JARVIS-model-$tag.pkg"
done
rm -f "$JARVIS_DIR/JARVIS-python.pkg"
rm -f "$JARVIS_DIR/JARVIS-core.pkg"
rm -rf "$STAGING"

PKG_SIZE=$(du -sh "$OUTPUT_PKG" | cut -f1)
echo ""
echo "✓  Built: $OUTPUT_PKG  ($PKG_SIZE)"
[ "$OFFLINE" -eq 1 ] \
  && echo "   Self-contained — 3B model bundled, larger models download only if upgraded." \
  || echo "   Online installer — downloads all resources during install."
echo ""
echo "Install: open '$OUTPUT_PKG'"
