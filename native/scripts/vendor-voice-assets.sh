#!/bin/bash
# Fill native/Resources/vendor/ (git-ignored) with the binaries the voice stages load at run
# time (plan: M08-M13 §3.1, T0.1). Nothing is downloaded: every file is copied from this Mac.
#
#   libonnxruntime.1.26.0.dylib + the libonnxruntime.1.dylib symlink   from ~/jarvis-swift/Resources/
#   _webrtcvad.cpython-314-darwin.so (py-webrtcvad 2.0.10)            from Python 3.14's site-packages
#   embedding_model.onnx, hey_jarvis_v0.1.onnx, melspectrogram.onnx    from ~/jarvis-swift/Resources/models/
#                                                                       (openWakeWord 0.6.0's, for M11)
#   resemblyzer.onnx (M10's speaker encoder)                           exported by tools/export_resemblyzer.py
#
# Every file is checked against the size and md5 below before the copy and after it, so a pip
# upgrade of webrtcvad fails here instead of at dlopen (plan §8 R2). A file already in place
# with the right size and md5 is left alone, so running this again is safe. Piper's
# espeakbridge.so and espeak-ng-data/ are not vendored: F5 replaced Piper (D-54).
#
# build-app.sh copies the folder into the app bundle and signs each library before the app.
# $JARVIS_SWIFT_DIR, $JARVIS_PY_SITE and $JARVIS_PYTHON point at other sources.
set -euo pipefail

NATIVE="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$NATIVE/Resources/vendor"
SWIFT_DIR="${JARVIS_SWIFT_DIR:-$HOME/jarvis-swift}"
PY_SITE="${JARVIS_PY_SITE:-/Library/Frameworks/Python.framework/Versions/3.14/lib/python3.14/site-packages}"
PYTHON="${JARVIS_PYTHON:-/Library/Frameworks/Python.framework/Versions/3.14/bin/python3}"

# destination | source | bytes | md5
FILES=(
    "libonnxruntime.1.26.0.dylib|$SWIFT_DIR/Resources/libonnxruntime.1.26.0.dylib|28800472|8d1cf5349bd20160d59fc7422654ed1f"
    "_webrtcvad.cpython-314-darwin.so|$PY_SITE/_webrtcvad.cpython-314-darwin.so|171200|fe15c00f708036e542a03d32541721b9"
    "embedding_model.onnx|$SWIFT_DIR/Resources/models/embedding_model.onnx|1326578|7602421d736d1a67e616bd85a01686fc"
    "hey_jarvis_v0.1.onnx|$SWIFT_DIR/Resources/models/hey_jarvis_v0.1.onnx|1271370|de6abe00036ec10b675a679f45c5c643"
    "melspectrogram.onnx|$SWIFT_DIR/Resources/models/melspectrogram.onnx|1087958|763f67cda79753bd15a7dc9e2c391100"
)

# A path under $HOME, as ~/... for messages.
tilde() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# matches <file> <bytes> <md5>: exit 0 when the file has that size and md5.
matches() {
    [[ -f "$1" ]] || return 1
    [[ "$(stat -f %z "$1")" == "$2" ]] || return 1
    [[ "$(md5 -q "$1")" == "$3" ]]
}

# The ignore rule must hold before anything lands in the folder.
if ! git -C "$NATIVE" check-ignore -q "$VENDOR/libonnxruntime.1.26.0.dylib"; then
    echo "error: $(tilde "$VENDOR") is not git-ignored; refusing to fill it" >&2
    exit 1
fi
mkdir -p "$VENDOR"

copied=0; kept=0
for row in "${FILES[@]}"; do
    IFS='|' read -r name src bytes sum <<< "$row"
    dst="$VENDOR/$name"
    if matches "$dst" "$bytes" "$sum"; then kept=$((kept + 1)); continue; fi
    if ! matches "$src" "$bytes" "$sum"; then
        if [[ -f "$src" ]]; then
            echo "error: $(tilde "$src") is not the pinned file (want $bytes bytes, md5 $sum)" >&2
        else
            echo "error: $(tilde "$src") is missing" >&2
        fi
        exit 1
    fi
    cp "$src" "$dst.tmp"
    mv -f "$dst.tmp" "$dst"
    matches "$dst" "$bytes" "$sum" || { echo "error: the copy of $name does not match" >&2; exit 1; }
    copied=$((copied + 1))
done

# The runtime's install name is @rpath/libonnxruntime.1.dylib; the symlink keeps that name valid.
ln -sfn libonnxruntime.1.26.0.dylib "$VENDOR/libonnxruntime.1.dylib"
[[ "$(lipo -archs "$VENDOR/libonnxruntime.1.26.0.dylib")" == arm64 ]] \
    || { echo "error: the ONNX Runtime dylib is not arm64-only" >&2; exit 1; }

# The speaker encoder is not copied: it is exported from resemblyzer 0.1.4's own weights (T10.0),
# and the export script keeps it only after checking it against torch. The export is
# deterministic (torch 2.12.0), so its size and md5 are pinned like the copies. It takes about a
# minute and 1 GB of memory, once.
MODEL="$VENDOR/resemblyzer.onnx"
if matches "$MODEL" 5701350 5571f01852375eee552d067f74137738; then
    kept=$((kept + 1))
else
    "$PYTHON" "$NATIVE/tools/export_resemblyzer.py" --out "$MODEL" \
        || { echo "error: tools/export_resemblyzer.py failed" >&2; exit 1; }
    if ! matches "$MODEL" 5701350 5571f01852375eee552d067f74137738; then
        rm -f "$MODEL"
        echo "error: the exported resemblyzer.onnx is not the pinned file (did torch or resemblyzer change?)" >&2
        exit 1
    fi
    copied=$((copied + 1))
fi

echo "vendor-voice-assets: $copied copied or exported, $kept already in place, in $(tilde "$VENDOR")"
