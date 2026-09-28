#!/bin/bash
# Build, assemble and sign native/dist/JARVIS.app (plan: M00 §3.3).
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

swift build -c release --package-path "$NATIVE" --product JARVIS -j "$JOBS" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    ${ORT_LIB:+-Xlinker -L"$ORT_LIB"}               # ORT_LIB set only from M10
BIN="$(swift build -c release --package-path "$NATIVE" --show-bin-path)/JARVIS"

STAGE="$NATIVE/dist/.JARVIS.app.staging"; APP="$NATIVE/dist/JARVIS.app"
rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$BIN" "$STAGE/Contents/MacOS/JARVIS"
cp "$NATIVE/Resources/Info.plist" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$REPO" rev-list --count HEAD)" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
if otool -L "$BIN" | grep -q libonnxruntime; then   # only once M10 links ORT
    cp "$ORT_LIB/libonnxruntime.1.26.0.dylib" "$STAGE/Contents/Frameworks/libonnxruntime.1.dylib"
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
for d in "$STAGE"/Contents/Frameworks/*.dylib; do [[ -e "$d" ]] || continue
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$d" 2>/dev/null; done   # inner first, no --deep
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

rm -rf "$APP"; mv "$STAGE" "$APP"                   # swap only after a verified signature
echo "Built: $APP"
