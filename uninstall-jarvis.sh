#!/bin/bash
# Uninstall JARVIS from this Mac.
set -euo pipefail

JARVIS_DIR="/Library/Application Support/JARVIS"
PLIST="$HOME/Library/LaunchAgents/com.jarvis.assistant.plist"

echo "▶ Stopping LaunchAgent..."
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "▶ Removing app symlink..."
rm -f "/Applications/JARVIS.app"

echo "▶ Removing screensaver..."
rm -rf "$HOME/Library/Screen Savers/JarvisReactor.saver"

echo "▶ Removing JARVIS source and data..."
sudo rm -rf "$JARVIS_DIR"

echo ""
echo "✓  JARVIS uninstalled."
echo "   To remove Homebrew packages installed by JARVIS:"
echo "     brew uninstall portaudio ffmpeg"
echo "     brew uninstall --cask ollama"
