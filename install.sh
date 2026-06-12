#!/bin/bash
# JARVIS — fully local, self-hosted installer for macOS (Apple Silicon).
# Brain: Ollama (Metal GPU).  Voice: Piper.  STT: Google online / Whisper offline.
#
# Prerequisites:
#   • Apple Silicon Mac (M1/M2/M3…), macOS 13+
#   • Python 3 from python.org (recommended) — gives the framework build py2app needs.
#     Override which interpreter to use with:  JARVIS_PYTHON=/path/to/python3 ./install.sh
set -e

JARVIS_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${JARVIS_PYTHON:-$(command -v python3)}"
MODEL="${JARVIS_MODEL:-qwen2.5:3b}"
PLIST="$HOME/Library/LaunchAgents/com.jarvis.assistant.plist"
[ -z "$PY" ] && { echo "No python3 found. Install Python 3 from python.org."; exit 1; }
echo "Using Python: $PY"

echo "▶ 1/8  System dependencies (Homebrew)..."
command -v brew >/dev/null || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew list portaudio    >/dev/null 2>&1 || brew install portaudio
brew list ffmpeg       >/dev/null 2>&1 || brew install ffmpeg
brew list --cask ollama-app >/dev/null 2>&1 || brew install --cask ollama   # official app = Metal runner

echo "▶ 2/8  Python packages..."
"$PY" -m pip install -q --upgrade \
    SpeechRecognition pyaudio faster-whisper piper-tts pywebview certifi pillow py2app \
    pyobjc-framework-AVFoundation pyobjc-framework-Cocoa pyobjc-framework-Quartz \
    pyobjc-framework-Vision
echo "   (optional) speaker recognition — this pulls torch and is large:"
"$PY" -m pip install -q resemblyzer || echo "   resemblyzer skipped (speaker-ID disabled until installed)"

echo "▶ 3/8  Start Ollama and pull the local model ($MODEL)..."
open -a Ollama; sleep 5
ollama pull "$MODEL"

echo "▶ 4/8  Piper voice (British male)..."
mkdir -p "$JARVIS_DIR/voices"
BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alan/medium"
[ -f "$JARVIS_DIR/voices/en_GB-alan-medium.onnx" ] || \
    curl -sL "$BASE/en_GB-alan-medium.onnx" -o "$JARVIS_DIR/voices/en_GB-alan-medium.onnx"
[ -f "$JARVIS_DIR/voices/en_GB-alan-medium.onnx.json" ] || \
    curl -sL "$BASE/en_GB-alan-medium.onnx.json" -o "$JARVIS_DIR/voices/en_GB-alan-medium.onnx.json"

echo "▶ 5/8  Cache offline Whisper model..."
"$PY" -c "from faster_whisper import WhisperModel; WhisperModel('base.en', device='cpu', compute_type='int8')"

echo "▶ 6/8  Build the JARVIS.app bundle (grantable mic identity + GUI session)..."
cd "$JARVIS_DIR"
rm -rf build dist
"$PY" setup.py py2app -A >/dev/null
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority array" dist/JARVIS.app/Contents/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority:0 string arm64" dist/JARVIS.app/Contents/Info.plist 2>/dev/null || true
codesign --force --deep --sign - dist/JARVIS.app
"$PY" make_icon.py 2>/dev/null || echo "   (icon step skipped)"

echo "▶ 7/8  Build & install the JARVIS screen saver..."
( cd "$JARVIS_DIR/screensaver"
  SAVER="JarvisReactor.saver"; rm -rf "$SAVER"; mkdir -p "$SAVER/Contents/MacOS"
  clang -fobjc-arc -framework Cocoa -framework ScreenSaver -bundle \
        -o "$SAVER/Contents/MacOS/JarvisReactor" JarvisReactor.m
  cat > "$SAVER/Contents/Info.plist" <<'PL2'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>JarvisReactor</string>
  <key>CFBundleIdentifier</key><string>com.jarvis.screensaver</string>
  <key>CFBundleName</key><string>JARVIS</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSPrincipalClass</key><string>JarvisReactorView</string>
</dict></plist>
PL2
  codesign --force --deep --sign - "$SAVER"
  mkdir -p "$HOME/Library/Screen Savers"
  rm -rf "$HOME/Library/Screen Savers/JarvisReactor.saver"
  cp -R "$SAVER" "$HOME/Library/Screen Savers/"
) || echo "   (screen saver build skipped)"

echo "▶ 8/8  Install always-on LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents" "$JARVIS_DIR/logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.jarvis.assistant</string>
  <key>ProgramArguments</key><array>
    <string>$JARVIS_DIR/dist/JARVIS.app/Contents/MacOS/JARVIS</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PYTHONUNBUFFERED</key><string>1</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$JARVIS_DIR/logs/jarvis.boot.log</string>
  <key>StandardErrorPath</key><string>$JARVIS_DIR/logs/jarvis.boot.err</string>
</dict></plist>
PL
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

cat <<'DONE'

✓ JARVIS is installed and running, and will start at login.

First-run permissions (System Settings ▸ Privacy & Security) — grant to JARVIS / Python:
  • Microphone        — a prompt appears on first launch; click Allow.
  • Screen Recording  — needed for the "what's on my screen" feature.
  • Full Disk Access  — needed to read Messages/Mail/etc.
  • Automation        — prompts appear the first time it controls Music/Reminders/Calendar.
Then pick the JARVIS screen saver in System Settings ▸ Screen Saver (optional).

Control it:   ./jarvisctl {status|restart|stop|logs}
Say "Jarvis" to begin.  Optional ambient song ID: put a free audd.io token in audd_key.txt.
DONE
