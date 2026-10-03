#!/bin/bash
# Build, assemble and sign native/dist/JARVIS.app (plan: M00 §3.3).
#
# Live updates (U1): the signed build goes to native/dist/staged/JARVIS.app, with version.json
# beside it. If no JARVIS holds .jarvis.lock it is promoted at once (scripts/jarvis-update:
# JARVIS.app moves to previous/, staged/ moves in, renames only). If one is running, the build
# stays staged and the running app swaps itself over when it is idle.
#
# Signed by scripts/sign-app.sh: the Developer ID identity from the login keychain, with the
# "JARVIS Developer ID" provisioning profile embedded (bundle ID com.jarv1s.assistant), so
# ShazamKit works. `--legacy-identity` signs with the old self-signed identity instead, for
# rollback. Never ad-hoc, never --deep, no hardened runtime yet (see sign-app.sh). Never print
# the identity or the DR, and never enable `set -x` in this script.
set -euo pipefail
set +x

NATIVE="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$NATIVE/.." && pwd)"
SIGNING="$REPO/.signing"                            # config and profile, git-ignored; read by sign-app.sh
[[ -f "$SIGNING/config" ]] || { echo "error: $SIGNING/config missing" >&2; exit 1; }
JOBS="${JOBS:-2}"                                   # 8 GB machine: cap compiler parallelism
# Opt-in dev build: `build-app.sh --debug` builds the debug configuration, which adds the
# DEBUG-only modes (M3's --brain-smoke). With no argument the build is release, as before.
# `--legacy-identity` (rollback) signs with the old self-signed identity; either order.
CONFIGURATION=release
SIGN_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIGURATION=debug ;;
        --legacy-identity) SIGN_FLAGS=(--legacy-identity) ;;
        *) echo "usage: build-app.sh [--debug] [--legacy-identity]" >&2; exit 64 ;;
    esac
done
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
         embedding_model.onnx hey_jarvis_v0.1.onnx melspectrogram.onnx resemblyzer.onnx; do
    [[ -f "$VENDOR/$f" ]] || { echo "error: Resources/vendor/$f is missing: run scripts/vendor-voice-assets.sh" >&2; exit 1; }
done
# M8's voice helper (D-54) is a package of its own, so the main build never compiles MLX. It is
# always release, built with -j 3 (VOICE_JOBS), and runs from Contents/Helpers/ beside its two
# resource bundles, where MLX and the helper look for them: mlx-swift_Cmlx.bundle holds
# default.metallib, VoiceHelper_F5TTS.bundle holds mel_filters.npy.
VOICE="$NATIVE/VoiceHelper"
swift build -c release --package-path "$VOICE" --product jarvis-voice -j "${VOICE_JOBS:-3}"
VOICE_BIN="$(swift build -c release --package-path "$VOICE" --show-bin-path)"
# V6's Qwen3-TTS helper, a package of its own again (MLX 0.31.4 against F5's 0.29.1). It runs from
# Contents/Helpers/qwen/, a folder of its own, beside its resource bundles: its
# mlx-swift_Cmlx.bundle is a different MLX's from F5's, under the same name.
VOICE_QWEN="$NATIVE/VoiceHelperQwen"
swift build -c release --package-path "$VOICE_QWEN" --product jarvis-voice-qwen -j "${VOICE_JOBS:-3}"
VOICE_QWEN_BIN="$(swift build -c release --package-path "$VOICE_QWEN" --show-bin-path)"

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
mkdir -p "$STAGE/Contents/Helpers/qwen"
cp "$VOICE_QWEN_BIN/jarvis-voice-qwen" "$STAGE/Contents/Helpers/qwen/jarvis-voice-qwen"
for b in mlx-swift_Cmlx.bundle swift-transformers_Hub.bundle swift-crypto_Crypto.bundle; do
    [[ -d "$VOICE_QWEN_BIN/$b" ]] || { echo "error: $b is missing from the Qwen helper build" >&2; exit 1; }
    cp -R "$VOICE_QWEN_BIN/$b" "$STAGE/Contents/Helpers/qwen/$b"
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

"$NATIVE/scripts/sign-app.sh" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$STAGE" "$SIGNING"

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
# Batch C part 3: the "JARVIS Memory" shortcut on the Desktop (jarvis://memory), only if absent.
"$NATIVE/scripts/install-memory-shortcut.sh" || echo "warning: the Desktop memory shortcut was not placed" >&2
if "$NATIVE/scripts/jarvis-update" lock-free "${JARVIS_HOME:-$REPO}/.jarvis.lock"; then
    "$NATIVE/scripts/jarvis-update" promote "$NATIVE/dist"
    echo "Built: $APP$LABEL"
else
    echo "Built and staged: $STAGED/JARVIS.app$LABEL"
    echo "JARVIS is running, so the build waits there: he swaps over when idle, or use Update Now."
fi
