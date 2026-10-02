#!/bin/bash
# Build, assemble and sign native/dist/JARVIS.app (plan: M00 §3.3).
#
# Live updates (U1): the signed build goes to native/dist/staged/JARVIS.app, with version.json
# beside it. If no JARVIS holds .jarvis.lock it is promoted at once (scripts/jarvis-update:
# JARVIS.app moves to previous/, staged/ moves in, renames only). If one is running, the build
# stays staged and the running app swaps itself over when it is idle.
#
# Signed with the PYTHON app's stable identity (~/jarvis/.signing/config) so both bundles share
# one designated requirement, i.e. one TCC client. Never ad-hoc (`codesign -s -`: new DR every
# build, TCC grants reset), never --deep, never --options runtime (library validation would
# reject the self-signed ORT dylib from M10). Never print KEYCHAIN_PASSWORD, IDENTITY or the
# DR (its certificate hash IS $IDENTITY), and never enable `set -x` in this script.
set -euo pipefail
set +x

NATIVE="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$NATIVE/.." && pwd)"
CONFIG="$REPO/.signing/config"                      # the PYTHON app's identity, never ~/jarvis-swift/.signing
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG missing — run $REPO/setup-signing.sh once" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"                                    # defines KEYCHAIN, KEYCHAIN_PASSWORD, IDENTITY — never echo them
JOBS="${JOBS:-2}"                                   # 8 GB machine: cap compiler parallelism
# Opt-in dev build: `build-app.sh --debug` builds the debug configuration, which adds the
# DEBUG-only modes (M3's --brain-smoke). With no argument the build is release, as before.
CONFIGURATION=release
if [[ "${1:-}" == "--debug" ]]; then CONFIGURATION=debug; fi
# The dataset's build channel (M01b §3.6, T10), written to Info.plist as JARVISBuildChannel: dev
# unless JARVIS_BUILD_CHANNEL=release, so a mislabel can only hide release data. Separate from
# the Swift configuration above, but a --debug build is never labelled release.
CHANNEL="${JARVIS_BUILD_CHANNEL:-dev}"
if [[ "$CHANNEL" != dev && "$CHANNEL" != release ]]; then
    echo "error: JARVIS_BUILD_CHANNEL must be dev or release" >&2; exit 1
fi
if [[ "$CONFIGURATION" == debug && "$CHANNEL" == release ]]; then
    echo "error: a --debug build is always the dev channel" >&2; exit 1
fi

swift build -c "$CONFIGURATION" --package-path "$NATIVE" --product JARVIS -j "$JOBS" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    ${ORT_LIB:+-Xlinker -L"$ORT_LIB"}               # ORT_LIB set only from M10
BIN="$(swift build -c "$CONFIGURATION" --package-path "$NATIVE" --show-bin-path)/JARVIS"
# M10 (plan: M08-M13 §3.1): libpystubs.dylib, which the app dlopens before webrtcvad's module,
# and the vendored binaries from scripts/vendor-voice-assets.sh. Neither is linked: the app
# dlopens ORT and the module from Contents/Frameworks and reads the models from
# Contents/Resources/vendor.
swift build -c "$CONFIGURATION" --package-path "$NATIVE" --product pystubs -j "$JOBS"
PYSTUBS="$(swift build -c "$CONFIGURATION" --package-path "$NATIVE" --show-bin-path)/libpystubs.dylib"
VENDOR="$NATIVE/Resources/vendor"
for f in libonnxruntime.1.26.0.dylib _webrtcvad.cpython-314-darwin.so \
         embedding_model.onnx hey_jarvis_v0.1.onnx melspectrogram.onnx; do
    [[ -f "$VENDOR/$f" ]] || { echo "error: Resources/vendor/$f is missing: run scripts/vendor-voice-assets.sh" >&2; exit 1; }
done
# M8's voice helper (D-54) is a package of its own, so the main build never compiles MLX. It is
# always release, built with -j 3 (VOICE_JOBS), and runs from Contents/Helpers/ beside its two
# resource bundles, where MLX and the helper look for them: mlx-swift_Cmlx.bundle holds
# default.metallib, VoiceHelper_F5TTS.bundle holds mel_filters.npy.
VOICE="$NATIVE/VoiceHelper"
swift build -c release --package-path "$VOICE" --product jarvis-voice -j "${VOICE_JOBS:-3}"
VOICE_BIN="$(swift build -c release --package-path "$VOICE" --show-bin-path)"

STAGE="$NATIVE/dist/.JARVIS.app.staging"; APP="$NATIVE/dist/JARVIS.app"
rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks" \
    "$STAGE/Contents/Helpers"
cp "$BIN" "$STAGE/Contents/MacOS/JARVIS"
cp "$VOICE_BIN/jarvis-voice" "$STAGE/Contents/Helpers/jarvis-voice"
# U1's update helper (scripts/jarvis-update), which the app starts to swap itself over.
cp "$NATIVE/scripts/jarvis-update" "$STAGE/Contents/Helpers/jarvis-update"
chmod 755 "$STAGE/Contents/Helpers/jarvis-update"
for b in mlx-swift_Cmlx.bundle VoiceHelper_F5TTS.bundle; do
    [[ -d "$VOICE_BIN/$b" ]] || { echo "error: $b is missing from the voice helper build" >&2; exit 1; }
    cp -R "$VOICE_BIN/$b" "$STAGE/Contents/Helpers/$b"
done
cp "$NATIVE/Resources/Info.plist" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$REPO" rev-list --count HEAD)" "$STAGE/Contents/Info.plist"
# The code that runs, for the dataset's runtime block (RuntimeInfo): the commit, and whether the
# tree differed from it (any tracked change or untracked file; .build/ and dist/ are ignored).
COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"
if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then DIRTY=true; else DIRTY=false; fi
/usr/libexec/PlistBuddy -c "Add :JARVISBuildChannel string $CHANNEL" -c "Add :JARVISGitCommit string $COMMIT" \
    -c "Add :JARVISGitDirty bool $DIRTY" "$STAGE/Contents/Info.plist"
# The build's identity for live updates (U1): sealed inside the bundle, and copied beside the
# staged bundle once it is signed. Two builds of one dirty commit differ by their build time.
printf '{"commit": "%s", "dirty": %s, "built": "%s"}\n' "$COMMIT" "$DIRTY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STAGE/Contents/Resources/version.json"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
# The Dock icon (D-43; M00 deferred jarvis_icon.png → .icns to M4): every size iconutil wants,
# scaled from the 1024 px source. Info.plist names it (CFBundleIconFile AppIcon).
ICONTMP="$(mktemp -d)"; ICONSET="$ICONTMP/AppIcon.iconset"; mkdir "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$REPO/jarvis_icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$REPO/jarvis_icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONTMP"
cp "$VENDOR/libonnxruntime.1.26.0.dylib" "$STAGE/Contents/Frameworks/libonnxruntime.1.dylib"
cp "$PYSTUBS" "$STAGE/Contents/Frameworks/libpystubs.dylib"
cp "$VENDOR/_webrtcvad.cpython-314-darwin.so" "$STAGE/Contents/Frameworks/"
mkdir -p "$STAGE/Contents/Resources/vendor"
cp "$VENDOR"/*.onnx "$STAGE/Contents/Resources/vendor/"

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
for d in "$STAGE"/Contents/Frameworks/*.dylib "$STAGE"/Contents/Frameworks/*.so; do [[ -e "$d" ]] || continue
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$d" 2>/dev/null; done   # inner first, no --deep
# The voice helper's nested code, also inner first: its resource bundles, then the helper.
for h in "$STAGE"/Contents/Helpers/*.bundle "$STAGE/Contents/Helpers/jarvis-voice"; do
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$h" 2>/dev/null; done
codesign --verify --strict "$STAGE/Contents/Helpers/jarvis-voice" 2>/dev/null \
    || { echo "error: codesign --verify --strict failed on the voice helper" >&2; exit 1; }
# The update helper is a script: signed on its own before the app, its signature kept in its
# extended attributes. Unsigned, it would fail the app's signature as unsigned nested code.
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$STAGE/Contents/Helpers/jarvis-update" 2>/dev/null
codesign --verify --strict "$STAGE/Contents/Helpers/jarvis-update" 2>/dev/null \
    || { echo "error: codesign --verify --strict failed on the update helper" >&2; exit 1; }
# codesign's stderr names the signing identity; keep it off the terminal unless signing fails.
if ! out="$(codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" \
        --entitlements "$NATIVE/Resources/JARVIS.entitlements" "$STAGE" 2>&1)"; then
    echo "error: codesign failed (output withheld: it may name the identity)" >&2; exit 1
fi
codesign --verify --strict "$STAGE" 2>/dev/null \
    || { echo "error: codesign --verify --strict failed on the staged bundle" >&2; exit 1; }

# TCC continuity check WITHOUT printing the DR: compare hashes of the two `designated` lines.
dr() {
    local line
    line="$(codesign -d -r- "$1" 2>&1 | grep '^designated')" || return 1
    printf '%s' "$line" | shasum -a 256 | cut -c1-64
}
PY_APP="$REPO/dist/JARVIS.app"
if [[ -d "$PY_APP" ]]; then
    new_dr="$(dr "$STAGE")" || { echo "error: no designated requirement on the staged bundle" >&2; exit 1; }
    py_dr="$(dr "$PY_APP")" || { echo "error: no designated requirement on $PY_APP" >&2; exit 1; }
    if [[ "$new_dr" == "$py_dr" ]]; then
        echo "DR matches Python bundle: yes"
    else
        echo "DR matches Python bundle: no"
        echo "error: DR differs from the Python bundle — TCC grants would split" >&2; exit 1
    fi
fi

# Stage only after a verified signature, and never overwrite the app that may be running. The
# staged version.json goes last: the app and the update helper treat a stage without it as
# unfinished.
STAGED="$NATIVE/dist/staged"
rm -f "$STAGED/version.json"; rm -rf "$STAGED/JARVIS.app"; mkdir -p "$STAGED"
mv "$STAGE" "$STAGED/JARVIS.app"
cp "$STAGED/JARVIS.app/Contents/Resources/version.json" "$STAGED/.version.json.tmp"
mv "$STAGED/.version.json.tmp" "$STAGED/version.json"
LABEL=""
if [[ "$CONFIGURATION" == debug ]]; then LABEL=" (debug configuration)"; fi
if "$NATIVE/scripts/jarvis-update" lock-free "${JARVIS_HOME:-$REPO}/.jarvis.lock"; then
    "$NATIVE/scripts/jarvis-update" promote "$NATIVE/dist"
    echo "Built: $APP$LABEL"
else
    echo "Built and staged: $STAGED/JARVIS.app$LABEL"
    echo "JARVIS is running, so the build waits there: he swaps over when idle, or use Update Now."
fi
