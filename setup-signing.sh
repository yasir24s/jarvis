#!/bin/bash
# setup-signing.sh — ONE-TIME creation of a stable local code-signing identity.
#
# Why: TCC (mic/screen/automation permission) grants are tied to the app's
# code-signing designated requirement. Plain `codesign -s -` (ad-hoc) produces a
# new cdhash-based requirement on EVERY build, so macOS treats each rebuild of
# dist/JARVIS.app as a brand-new app and re-prompts for permissions. This script
# creates ONE self-signed certificate in a dedicated keychain; install.sh (and
# the pkg postinstall) sign every build with that SAME cert, so the designated
# requirement (identifier "com.jarvis.assistant" and certificate leaf =
# H"<cert hash>") is identical across rebuilds and TCC grants stick.
#
# The cert is intentionally NOT in the login keychain (avoids GUI password
# prompts: we control this keychain's password, stored in .signing/config,
# chmod 600). Safe to re-run: it is a no-op if the identity already exists.
#
# Note: the keychain file may already exist if the sibling ~/jarvis-swift
# experiment created it first (both editions share one dedicated keychain file,
# each with its own certificate). In that case we reuse the keychain — never
# delete or overwrite it, that would break the Swift app's signing — importing
# our own cert into it. The keychain password is bootstrapped once from the
# sibling's config if available; after that this project is fully self-contained
# (everything needed lives in .signing/config and ~/Library/Keychains).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CERT_NAME="JARVIS Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/jarvis-signing.keychain-db"
CONFIG_DIR="$DIR/.signing"
CONFIG="$CONFIG_DIR/config"

if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
    if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
        echo "Signing identity already set up: $IDENTITY ($CERT_NAME)"
        exit 0
    fi
    echo "Config exists but identity missing from keychain; recreating..."
fi

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

# ── Obtain the keychain (create it, or unlock the existing shared one) ────────
KEYCHAIN_PASSWORD=""
if [[ -f "$KEYCHAIN" ]]; then
    # Keychain already exists (typically created by ~/jarvis-swift/setup-signing.sh).
    # We need its password to import our cert. Try, in order: our own config
    # (sourced above, may hold a stale-but-correct password) and a one-time
    # bootstrap from the sibling project's config if that project is present.
    for candidate_cfg in "$CONFIG" "$HOME/jarvis-swift/.signing/config"; do
        [[ -f "$candidate_cfg" ]] || continue
        candidate_pw="$(bash -c "source '$candidate_cfg' 2>/dev/null && printf %s \"\${KEYCHAIN_PASSWORD:-}\"")"
        [[ -n "$candidate_pw" ]] || continue
        if security unlock-keychain -p "$candidate_pw" "$KEYCHAIN" 2>/dev/null; then
            KEYCHAIN_PASSWORD="$candidate_pw"
            break
        fi
    done
    if [[ -z "$KEYCHAIN_PASSWORD" ]]; then
        cat >&2 <<EOF
error: $KEYCHAIN
already exists but its password is unknown, so a new identity cannot be
imported into it. This keychain was likely created by another JARVIS project
(e.g. ~/jarvis-swift). Options:
  * restore that project's .signing/config so the password can be bootstrapped, or
  * if no other project still uses it, delete the keychain and re-run:
        security delete-keychain "$KEYCHAIN"
    (WARNING: deleting it resets the OTHER project's signing identity and its
    TCC grants — only do this if that project is gone.)
EOF
        exit 1
    fi
    echo "Reusing existing keychain: $KEYCHAIN"
else
    KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # no timeout, no lock-on-sleep
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi

# ── Create + import our identity (skip if a previous run already imported it) ─
EXISTING="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v name="\"$CERT_NAME\"" '$0 ~ name {print $2; exit}')"
if [[ -n "$EXISTING" ]]; then
    echo "Identity \"$CERT_NAME\" already present in keychain; reusing it."
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    # 1. Self-signed cert with the Code Signing extended key usage (10-year validity).
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes -subj "/CN=$CERT_NAME" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

    # 2. Bundle into PKCS#12 using legacy PBE algorithms (required for
    #    `security import` to parse it on macOS).
    openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -passout "pass:$KEYCHAIN_PASSWORD" -name "$CERT_NAME" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

    # 3. Import identity and let codesign use it without prompting.
    security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# ── Record the identity's SHA-1 (codesign accepts the hash even though the ────
#    self-signed cert is not in the system trust store).
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" \
    | awk -v name="\"$CERT_NAME\"" '$0 ~ name {print $2; exit}')"
if [[ -z "$IDENTITY" ]]; then
    echo "error: identity not found after import" >&2
    exit 1
fi

cat > "$CONFIG" <<EOF
# Generated by setup-signing.sh — do not commit (.gitignore'd).
KEYCHAIN="$KEYCHAIN"
KEYCHAIN_PASSWORD="$KEYCHAIN_PASSWORD"
IDENTITY="$IDENTITY"
EOF
chmod 600 "$CONFIG"

echo "Created signing identity: $IDENTITY ($CERT_NAME)"
echo "Keychain: $KEYCHAIN"
echo "Config:   $CONFIG"
