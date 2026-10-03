#!/bin/bash
# Batch C part 3: put "JARVIS Memory.webloc" on the user's Desktop, pointing at jarvis://memory.
# Double-clicking it opens JARVIS's Memory window, launching JARVIS first if he is closed (the
# app registers the jarvis URL scheme in Info.plist). Created only if absent: an existing file
# of that name, the user's or ours, is never touched.
#
# JARVIS_DESKTOP overrides the folder (the tests point it at a temp folder).
set -euo pipefail

DESKTOP="${JARVIS_DESKTOP:-$HOME/Desktop}"
SHORTCUT="$DESKTOP/JARVIS Memory.webloc"

if [[ ! -d "$DESKTOP" ]]; then
    echo "Memory shortcut: no Desktop folder at that path; skipped" >&2
    exit 0
fi
if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]]; then
    echo "Memory shortcut: already on the Desktop; left as it is"
    exit 0
fi

TMP="$(mktemp "$DESKTOP/.jarvis-memory-webloc.XXXXXX")"
cat > "$TMP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>jarvis://memory</string>
</dict>
</plist>
PLIST
chmod 644 "$TMP"
# A rename, so the shortcut never exists half-written; -n so a file that appeared meanwhile wins.
mv -n "$TMP" "$SHORTCUT"
rm -f "$TMP"
echo "Memory shortcut: placed on the Desktop"
