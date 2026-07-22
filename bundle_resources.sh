#!/bin/bash
# Pre-download all resources for a self-contained JARVIS pkg.
# Run once on your development Mac (needs internet + all deps installed).
# Populates pkg/offline-resources/ which build_pkg.sh embeds directly.
#
# The 3B Ollama model is bundled so the default install is fully offline.
# Larger models (7B, 14B, 32B, 72B) are downloaded during install when chosen.
#
# Usage:
#   ./bundle_resources.sh
#   JARVIS_PYTHON=/path/to/python3 ./bundle_resources.sh
set -euo pipefail

JARVIS_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES="$JARVIS_DIR/pkg/offline-resources"
PY="${JARVIS_PYTHON:-$(command -v python3)}"

echo "Using Python: $PY"
echo "Resources → $RESOURCES"
mkdir -p "$RESOURCES"

# ── 0/8  Python installer ────────────────────────────────────────────────────
echo "▶ 0/9  Downloading latest Python installer..."
mkdir -p "$RESOURCES/python"
# Scrape the latest stable Python version from python.org
PYTHON_VER=$(curl -fsSL "https://www.python.org/downloads/" 2>/dev/null | \
  grep -oE 'Download Python [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $3}')
[ -z "$PYTHON_VER" ] && PYTHON_VER="3.13.3"
PYTHON_PKG="python-${PYTHON_VER}-macos11.pkg"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VER}/${PYTHON_PKG}"
echo "   Latest stable Python: $PYTHON_VER"
if [ ! -f "$RESOURCES/python/python-latest.pkg" ]; then
  curl -fL "$PYTHON_URL" -o "$RESOURCES/python/python-latest.pkg"
fi
echo "   $(du -sh "$RESOURCES/python/python-latest.pkg" | cut -f1) Python installer ready."
# Store version so the installer can show it
echo "$PYTHON_VER" > "$RESOURCES/python/version.txt"

# ── 1/9  pip wheels ───────────────────────────────────────────────────────────
echo "▶ 1/9  Downloading pip wheels..."
mkdir -p "$RESOURCES/wheels"
"$PY" -m pip download -q -d "$RESOURCES/wheels" \
  SpeechRecognition pyaudio faster-whisper piper-tts pywebview certifi pillow py2app \
  pyobjc-framework-AVFoundation pyobjc-framework-Cocoa pyobjc-framework-Quartz \
  pyobjc-framework-Vision pyobjc-framework-EventKit claude-agent-sdk
echo "   $(ls "$RESOURCES/wheels" | wc -l | tr -d ' ') wheels downloaded."

# ── 2/8  portaudio dylib ──────────────────────────────────────────────────────
echo "▶ 2/9  Bundling portaudio..."
mkdir -p "$RESOURCES/lib"
for lib in \
  "/opt/homebrew/opt/portaudio/lib/libportaudio.2.dylib" \
  "/opt/homebrew/lib/libportaudio.2.dylib" \
  "/usr/local/opt/portaudio/lib/libportaudio.2.dylib" \
  "/usr/local/lib/libportaudio.2.dylib"; do
  if [ -f "$lib" ]; then
    cp "$lib" "$RESOURCES/lib/libportaudio.2.dylib"
    echo "   Copied from: $lib"
    break
  fi
done
[ -f "$RESOURCES/lib/libportaudio.2.dylib" ] || echo "   WARNING: portaudio not found — run: brew install portaudio"

# ── 3/8  ffmpeg binary ────────────────────────────────────────────────────────
echo "▶ 3/9  Bundling ffmpeg..."
mkdir -p "$RESOURCES/bin"
FFMPEG=$(command -v ffmpeg 2>/dev/null || true)
if [ -n "$FFMPEG" ]; then
  cp "$FFMPEG" "$RESOURCES/bin/ffmpeg"
  FFPROBE=$(command -v ffprobe 2>/dev/null || true)
  [ -n "$FFPROBE" ] && cp "$FFPROBE" "$RESOURCES/bin/ffprobe"
  echo "   Copied: $FFMPEG"
else
  echo "   WARNING: ffmpeg not found — run: brew install ffmpeg"
fi

# ── 4/8  Piper voice model ────────────────────────────────────────────────────
echo "▶ 4/9  Downloading Piper voice model (~70 MB)..."
mkdir -p "$RESOURCES/voices"
BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium"
[ -f "$RESOURCES/voices/en_GB-alan-medium.onnx" ] || \
  curl -fL "$BASE/en_GB-alan-medium.onnx" -o "$RESOURCES/voices/en_GB-alan-medium.onnx"
[ -f "$RESOURCES/voices/en_GB-alan-medium.onnx.json" ] || \
  curl -fL "$BASE/en_GB-alan-medium.onnx.json" -o "$RESOURCES/voices/en_GB-alan-medium.onnx.json"
echo "   $(du -sh "$RESOURCES/voices" | cut -f1) voice model ready."

# ── 5/8  Whisper base.en ──────────────────────────────────────────────────────
echo "▶ 5/9  Caching Whisper base.en (~150 MB)..."
"$PY" -c "from faster_whisper import WhisperModel; WhisperModel('base.en', device='cpu', compute_type='int8')" 2>&1 | tail -2
mkdir -p "$RESOURCES/huggingface-cache"
for cache_dir in "$HOME/.cache/huggingface/hub" "$HOME/Library/Caches/huggingface/hub"; do
  if [ -d "$cache_dir" ]; then
    rsync -a --delete "$cache_dir/" "$RESOURCES/huggingface-cache/"
    echo "   $(du -sh "$RESOURCES/huggingface-cache" | cut -f1) Whisper cache ready."
    break
  fi
done

# ── 6/8  Ollama app ───────────────────────────────────────────────────────────
echo "▶ 6/9  Downloading Ollama app..."
mkdir -p "$RESOURCES/ollama"
OLLAMA_ZIP="$RESOURCES/ollama/Ollama-darwin.zip"
if [ ! -f "$OLLAMA_ZIP" ]; then
  LATEST_URL=$(curl -fsSL "https://api.github.com/repos/ollama/ollama/releases/latest" \
    | grep '"browser_download_url"' | grep 'Ollama-darwin.zip' | cut -d'"' -f4 | head -1)
  [ -z "$LATEST_URL" ] && LATEST_URL="https://github.com/ollama/ollama/releases/latest/download/Ollama-darwin.zip"
  curl -fL "$LATEST_URL" -o "$OLLAMA_ZIP"
fi
echo "   $(du -sh "$OLLAMA_ZIP" | cut -f1) Ollama app ready."

# ── 7/8  Bundle qwen2.5:3b model (default offline model) ─────────────────────
echo "▶ 7/9  Bundling qwen2.5:3b model blobs (default, ~2 GB)..."
OLLAMA_BIN=$(command -v ollama 2>/dev/null || echo "/opt/homebrew/bin/ollama")
open -a Ollama 2>/dev/null || true
sleep 6
"$OLLAMA_BIN" pull qwen2.5:3b 2>&1 | tail -3

OLLAMA_HOME="${OLLAMA_HOME:-$HOME/.ollama}"
mkdir -p "$RESOURCES/ollama-3b/blobs" "$RESOURCES/ollama-3b/manifests"

# Copy only the blobs referenced by the 3B manifest
MANIFEST="$OLLAMA_HOME/models/manifests/registry.ollama.ai/library/qwen2.5/3b"
if [ -f "$MANIFEST" ]; then
  # Copy manifest
  mkdir -p "$RESOURCES/ollama-3b/manifests/registry.ollama.ai/library/qwen2.5"
  cp "$MANIFEST" "$RESOURCES/ollama-3b/manifests/registry.ollama.ai/library/qwen2.5/3b"
  # Copy blobs referenced in manifest
  export RESOURCES
  "$PY" - <<'PYEOF'
import json, os, shutil, sys
base = os.environ.get('OLLAMA_HOME', os.path.expanduser('~/.ollama'))
resources = os.environ.get('RESOURCES')
manifest_path = f"{base}/models/manifests/registry.ollama.ai/library/qwen2.5/3b"
blobs_src = f"{base}/models/blobs"
blobs_dst = f"{resources}/ollama-3b/blobs"
with open(manifest_path) as f:
    m = json.load(f)
digests = []
if 'config' in m and 'digest' in m['config']:
    digests.append(m['config']['digest'].replace(':', '-'))
for layer in m.get('layers', []):
    if 'digest' in layer:
        digests.append(layer['digest'].replace(':', '-'))
for d in digests:
    src = f"{blobs_src}/{d}"
    dst = f"{blobs_dst}/{d}"
    if os.path.exists(src) and not os.path.exists(dst):
        print(f"  Copying blob: {d[:20]}...")
        shutil.copy2(src, dst)
PYEOF
fi
echo "   $(du -sh "$RESOURCES/ollama-3b" | cut -f1) 3B model blobs ready."

# ── 8/8  Pre-build JARVIS.app ─────────────────────────────────────────────────
echo "▶ 8/9  Building JARVIS.app..."
cd "$JARVIS_DIR"
rm -rf build dist
"$PY" setup.py py2app -A >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority array" \
  dist/JARVIS.app/Contents/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority:0 string arm64" \
  dist/JARVIS.app/Contents/Info.plist 2>/dev/null || true
codesign --force --deep --sign - dist/JARVIS.app
"$PY" make_icon.py 2>/dev/null || true
echo "   JARVIS.app built."

echo ""
echo "✓  Resources ready: $(du -sh "$RESOURCES" | cut -f1) total"
echo "   Run ./build_pkg.sh to create the self-contained installer."
