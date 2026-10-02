#!/bin/bash
# Install the F5 voice clone's assets for native JARVIS (plan D-54) into
# ~/Library/Application Support/JARVIS/voice/, where the jarvis-voice helper loads them:
#
#   f5/model.safetensors, f5/vocab.txt         from ~/jarvis-spikes/models/f5/
#   vocos/model.safetensors, vocos/config.json from ~/jarvis-spikes/models/vocos/
#   reference/reference.wav, reference.txt     from the spike's clips/jarvis_shortref_24k.{wav,txt}
#   references/dry/, references/dry-wpe/       from clips/jarvis_dry_24k.* and jarvis_dry_wpe_24k.*
#
# The two references/ (V1 part 3) are the driest stretch of ~/jarvis/voices/jarvis_en.wav (23.57
# to 28.23 s, the fastest energy decay after word endings of the 3 to 6 s windows between
# pauses), as cut and as dereverberated by WPE. JARVIS speaks with one only when the
# voiceReference setting names it.
#
# Every file is checked against the size and SHA-256 below, before the copy and after it (the
# voice spike checked the two weight files against Hugging Face). Nothing is downloaded. A file
# already installed with the right size and hash is left alone, so running this again is safe.
# The weights and the voice clip never go into git.
#
# Then (V1 part 1) the clone renders JARVIS's acknowledgements, the short lines he says the
# moment a typed message is sent, into acknowledgements/<reference>/<name>.wav for each of the
# three references (default, dry, dry-wpe), with the jarvis-voice
# helper of the built app (or VoiceHelper's release build, or $JARVIS_VOICE_HELPER). Without a
# helper this step is skipped; run the script again once the app is built. Lines already
# rendered with the same settings, reference and list are left alone.
#
# $JARVIS_VOICE_DEST installs somewhere else (a test folder).
set -euo pipefail

SPIKES="${JARVIS_SPIKES:-$HOME/jarvis-spikes}"
DEST="${JARVIS_VOICE_DEST:-$HOME/Library/Application Support/JARVIS/voice}"
NATIVE="$(cd "$(dirname "$0")/.." && pwd)"
umask 077   # the voice clip is the user's: owner-only folders and files

# destination | source | bytes | sha256
FILES=(
    "f5/model.safetensors|models/f5/model.safetensors|397810919|d609e050cc1eeaee9886db05ac5b9727797bad535158c59820126e70648440ab"
    "f5/vocab.txt|models/f5/vocab.txt|11255|4e173934be56219eb38759fa8d4c48132d5a34454f0c44abce409bcf6a07ec46"
    "vocos/model.safetensors|models/vocos/model.safetensors|54339850|948b676e34bb1f8bbc1589dc651fa22a86df3ae18914afc4818ad5df46856784"
    "vocos/config.json|models/vocos/config.json|403|554a74ddbaa6562191f78a576b73a580ef4a0d40071f627cc343e706f7cb3a98"
    "reference/reference.wav|voice-swift/clips/jarvis_shortref_24k.wav|205484|d0d17e83163f6de8076ef40fa3cd96c3ce76376b07e876474e6b815f9a552986"
    "reference/reference.txt|voice-swift/clips/jarvis_shortref_24k.txt|66|bf1f092c7f4ee44df954f1efe4a2a7507bf493cbb8552715756e028a3c263ecf"
    "references/dry/reference.wav|voice-swift/clips/jarvis_dry_24k.wav|223724|80b1e363130de60dfc82fb842b643cf742b5d04700a32948042ce9eacdbf109e"
    "references/dry/reference.txt|voice-swift/clips/jarvis_dry_24k.txt|84|026aaa9c59e6920e25c053d4b867323e72dddd5b8efa66b78527b0c09d1f333d"
    "references/dry-wpe/reference.wav|voice-swift/clips/jarvis_dry_wpe_24k.wav|223724|93abed4065488e9364ec54b9e1dde68f7dfd6d80b3db22b579ffe22695ecc92f"
    "references/dry-wpe/reference.txt|voice-swift/clips/jarvis_dry_wpe_24k.txt|84|026aaa9c59e6920e25c053d4b867323e72dddd5b8efa66b78527b0c09d1f333d"
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
echo "Voice assets ready in $(tilde "$DEST") (${#FILES[@]} files checked)"

# The acknowledgements: name | line. Native JARVIS lists the same (Acknowledgement.lines) and
# renders nothing itself. The speed is the app's default (VoiceHelperSetup). The steps are 8, not
# the replies' 4: rendering happens once, and at 4 the shortest lines often blurred ("On it, sir."
# heard as "On its, uh"), while at 8 every take of the three hardest was exact.
ACK_STEPS=8
ACK_SPEED=1.2
ACKNOWLEDGEMENTS=(
    "right-away|Right away, sir."
    "one-moment|One moment, sir."
    "certainly|Certainly, sir."
    "of-course|Of course, sir."
    "on-it|On it, sir."
    "let-me-see|Let me see, sir."
    "looking-into-it|Looking into it, sir."
    "give-me-a-second|Give me a second, sir."
    "very-good|Very good, sir."
    "working-on-it|Working on it, sir."
)

helper=""
for candidate in "${JARVIS_VOICE_HELPER:-}" "$NATIVE/dist/JARVIS.app/Contents/Helpers/jarvis-voice" \
                 "$NATIVE/VoiceHelper/.build/release/jarvis-voice"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        helper="$candidate"
        break
    fi
done

# render_acknowledgements <name> <reference folder>: every line, spoken with that reference, into
# acknowledgements/<name>/, unless a stamp shows they already were with these settings. The
# helper paces another reference than the default to the default's speed, as it does for replies.
render_acknowledgements() {
    local name="$1" reference="$2"
    local out="$DEST/acknowledgements/$name"
    local stamp
    stamp="steps $ACK_STEPS speed $ACK_SPEED"
    stamp+=" reference $(cat "$reference/reference.wav" "$reference/reference.txt" | shasum -a 256 | cut -d' ' -f1)"
    stamp+=" lines $(printf '%s\n' "${ACKNOWLEDGEMENTS[@]}" | shasum -a 256 | cut -d' ' -f1)"
    local complete=1 entry n
    for entry in "${ACKNOWLEDGEMENTS[@]}"; do
        n="${entry%%|*}"
        [[ -f "$out/$n.wav" ]] || complete=0
    done
    if [[ "$complete" == 1 && -f "$out/stamp" && "$(cat "$out/stamp")" == "$stamp" ]]; then
        echo "ok        acknowledgements/$name (already rendered)"
        return
    fi
    if [[ -z "$helper" ]]; then
        echo "skipped   acknowledgements/$name: no jarvis-voice helper yet (build the app, then run this again)"
        return
    fi
    local tmp="$out.partial"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    local list="$tmp/lines.tsv" t
    for entry in "${ACKNOWLEDGEMENTS[@]}"; do
        IFS='|' read -r n t <<< "$entry"
        printf '%s\t%s\n' "$n" "$t"
    done > "$list"
    if ! "$helper" --assets "$DEST" --out-dir "$tmp" --steps "$ACK_STEPS" --speed "$ACK_SPEED" \
            --reference "$reference" --render "$list" 2>/dev/null; then
        rm -rf "$tmp"
        echo "error: the helper could not render acknowledgements/$name" >&2
        exit 1
    fi
    rm -f "$list"
    printf '%s\n' "$stamp" > "$tmp/stamp"
    rm -rf "$out"
    mv "$tmp" "$out"
    echo "rendered  acknowledgements/$name (${#ACKNOWLEDGEMENTS[@]} lines)"
}

render_acknowledgements default "$DEST/reference"
render_acknowledgements dry "$DEST/references/dry"
render_acknowledgements dry-wpe "$DEST/references/dry-wpe"
