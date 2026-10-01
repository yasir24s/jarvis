#!/bin/bash
# Install the F5 voice clone's assets for native JARVIS (plan D-54) into
# ~/Library/Application Support/JARVIS/voice/, where the jarvis-voice helper loads them:
#
#   f5/model.safetensors, f5/vocab.txt         from ~/jarvis-spikes/models/f5/
#   vocos/model.safetensors, vocos/config.json from ~/jarvis-spikes/models/vocos/
#   reference/reference.wav, reference.txt     from the spike's clips/jarvis_shortref_24k.{wav,txt}
#
# Every file is checked against the size and SHA-256 below, before the copy and after it (the
# voice spike checked the two weight files against Hugging Face). Nothing is downloaded. A file
# already installed with the right size and hash is left alone, so running this again is safe.
# The weights and the voice clip never go into git.
set -euo pipefail

SPIKES="${JARVIS_SPIKES:-$HOME/jarvis-spikes}"
DEST="$HOME/Library/Application Support/JARVIS/voice"
umask 077   # the voice clip is the user's: owner-only folders and files

# destination | source | bytes | sha256
FILES=(
    "f5/model.safetensors|models/f5/model.safetensors|397810919|d609e050cc1eeaee9886db05ac5b9727797bad535158c59820126e70648440ab"
    "f5/vocab.txt|models/f5/vocab.txt|11255|4e173934be56219eb38759fa8d4c48132d5a34454f0c44abce409bcf6a07ec46"
    "vocos/model.safetensors|models/vocos/model.safetensors|54339850|948b676e34bb1f8bbc1589dc651fa22a86df3ae18914afc4818ad5df46856784"
    "vocos/config.json|models/vocos/config.json|403|554a74ddbaa6562191f78a576b73a580ef4a0d40071f627cc343e706f7cb3a98"
    "reference/reference.wav|voice-swift/clips/jarvis_shortref_24k.wav|205484|d0d17e83163f6de8076ef40fa3cd96c3ce76376b07e876474e6b815f9a552986"
    "reference/reference.txt|voice-swift/clips/jarvis_shortref_24k.txt|66|bf1f092c7f4ee44df954f1efe4a2a7507bf493cbb8552715756e028a3c263ecf"
)

# A path under $HOME, as ~/... for messages.
tilde() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# matches <file> <bytes> <sha256>: exit 0 when the file has that size and hash.
matches() {
    [[ -f "$1" ]] || return 1
    [[ "$(stat -f %z "$1")" == "$2" ]] || return 1
    [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$3" ]]
}

for entry in "${FILES[@]}"; do
    IFS='|' read -r rel src bytes sha <<< "$entry"
    target="$DEST/$rel"
    if matches "$target" "$bytes" "$sha"; then
        echo "ok        $rel (already installed)"
        continue
    fi
    from="$SPIKES/$src"
    if ! matches "$from" "$bytes" "$sha"; then
        echo "error: $(tilde "$from") is missing or is not the checked file ($bytes bytes, sha256 $sha)" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$target")"
    tmp="$target.partial"
    cp "$from" "$tmp"
    if ! matches "$tmp" "$bytes" "$sha"; then
        rm -f "$tmp"
        echo "error: the copy of $rel does not match; nothing installed for it" >&2
        exit 1
    fi
    mv -f "$tmp" "$target"
    echo "installed $rel ($bytes bytes)"
done

# Everything the helper loads, checked once more where it will be read.
for entry in "${FILES[@]}"; do
    IFS='|' read -r rel _ bytes sha <<< "$entry"
    matches "$DEST/$rel" "$bytes" "$sha" || { echo "error: $rel failed its final check" >&2; exit 1; }
done
echo "Voice assets ready in $(tilde "$DEST") (6 files checked)"
