#!/bin/bash
# Sign a staged JARVIS.app, inner code first (plan: M00 §3.3). build-app.sh calls it once the
# bundle is assembled, and stages the bundle only if this exits 0.
#
#   sign-app.sh [--legacy-identity] <staged JARVIS.app> <signing folder>
#
# Default: the Developer ID identity in the login keychain (no custom keychain, no unlock),
# with the "JARVIS Developer ID" provisioning profile embedded as Contents/embedded.provisionprofile,
# so the App ID's services (ShazamKit, later MusicKit) reach the app. The signing folder
# (<repo>/.signing, git-ignored) holds:
#   config                                  DEVELOPER_ID_TEAM (the team ID), and optionally
#                                           DEVELOPER_ID_IDENTITY (else found with find-identity)
#   JARVIS_Developer_ID.provisionprofile    the profile for <team>.com.jarv1s.assistant
# The app's entitlements are Resources/JARVIS.entitlements plus the application and team
# identifiers and time-sensitive notifications, built from the team ID; the profile must grant
# all three. Info.plist gains JARVISShazamKit = true, so identify_song turns on.
#
# --legacy-identity: the old self-signed path, for rollback: the identity and keychain from
# config (KEYCHAIN, KEYCHAIN_PASSWORD, IDENTITY), no profile, no JARVISShazamKit, the
# entitlements file as it is. The bundle ID stays com.jarv1s.assistant.
#
# No hardened runtime yet (local use, not notarised): notarisation needs --options runtime and
# a secure timestamp, and library validation would then reject the vendored ORT dylib unless it
# is signed by the same team (it is, here) or the app has the disable-library-validation
# entitlement. Never --deep, never ad-hoc. Never print the identity, KEYCHAIN_PASSWORD or the
# DR, and never enable `set -x` in this script.
set -euo pipefail
set +x

LEGACY=false
if [[ "${1:-}" == "--legacy-identity" ]]; then LEGACY=true; shift; fi
if [[ $# -ne 2 ]]; then
    echo "usage: sign-app.sh [--legacy-identity] <staged JARVIS.app> <signing folder>" >&2; exit 64
fi
STAGE="$1"; SIGNING="$2"
NATIVE="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID=com.jarv1s.assistant                          # AppIdentity.bundleID
CONFIG="$SIGNING/config"
PROFILE="$SIGNING/JARVIS_Developer_ID.provisionprofile"
BASE_ENTITLEMENTS="$NATIVE/Resources/JARVIS.entitlements"
PLISTBUDDY=/usr/libexec/PlistBuddy

# Test hooks, never set in normal use: stand-ins for codesign and security.
CODESIGN="${SIGN_APP_CODESIGN:-/usr/bin/codesign}"
SECURITY="${SIGN_APP_SECURITY:-/usr/bin/security}"

[[ -d "$STAGE/Contents" ]] || { echo "error: $STAGE is not an app bundle" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG missing" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"                                        # never echo what it defines

plist_get() { "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null; }
staged_id="$(plist_get "$STAGE/Contents/Info.plist" CFBundleIdentifier)" || staged_id=""
if [[ "$staged_id" != "$BUNDLE_ID" ]]; then
    echo "error: the staged Info.plist's CFBundleIdentifier is not $BUNDLE_ID" >&2; exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ "$LEGACY" == true ]]; then
    : "${KEYCHAIN:?KEYCHAIN missing from $CONFIG}" "${KEYCHAIN_PASSWORD:?}" "${IDENTITY:?IDENTITY missing from $CONFIG}"
    "$SECURITY" unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    SIGN=(--force --sign "$IDENTITY" --keychain "$KEYCHAIN")
    ENTITLEMENTS="$BASE_ENTITLEMENTS"
else
    TEAM="${DEVELOPER_ID_TEAM:-}"
    [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "error: DEVELOPER_ID_TEAM in $CONFIG is missing or not a team ID" >&2; exit 1; }
    # The identity: from config, else the one Developer ID Application identity of this team
    # in the keychain search list, by its hash (the name is never printed).
    SIGN_ID="${DEVELOPER_ID_IDENTITY:-}"
    if [[ -n "$SIGN_ID" ]]; then
        if [[ ! "$SIGN_ID" =~ ^[0-9A-F]{40}$ && ! "$SIGN_ID" =~ ^Developer\ ID\ Application:\ .*\($TEAM\)$ ]]; then
            echo "error: DEVELOPER_ID_IDENTITY in $CONFIG is not this team's Developer ID Application identity" >&2; exit 1
        fi
    else
        found="$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
            | sed -nE "s/^ *[0-9]+\) ([0-9A-F]{40}) \"Developer ID Application: .*\($TEAM\)\"$/\1/p" | sort -u)" || found=""
        count="$(printf '%s' "$found" | grep -c . || true)"
        if [[ "$count" -ne 1 ]]; then
            echo "error: expected one Developer ID Application identity for the team, found $count" >&2; exit 1
        fi
        SIGN_ID="$found"
    fi
    SIGN=(--force --sign "$SIGN_ID")

    # The profile must be this app's, this team's, and grant what the entitlements claim.
    [[ -f "$PROFILE" ]] || { echo "error: $PROFILE missing" >&2; exit 1; }
    "$SECURITY" cms -D -i "$PROFILE" > "$WORK/profile.plist" 2>/dev/null \
        || { echo "error: the provisioning profile does not decode" >&2; exit 1; }
    [[ "$(plist_get "$WORK/profile.plist" Entitlements:com.apple.application-identifier || true)" == "$TEAM.$BUNDLE_ID" ]] \
        || { echo "error: the provisioning profile is not for $BUNDLE_ID on this team" >&2; exit 1; }
    [[ "$(plist_get "$WORK/profile.plist" Entitlements:com.apple.developer.team-identifier || true)" == "$TEAM" ]] \
        || { echo "error: the provisioning profile's team is not DEVELOPER_ID_TEAM" >&2; exit 1; }
    [[ "$(plist_get "$WORK/profile.plist" Entitlements:com.apple.developer.usernotifications.time-sensitive || true)" == true ]] \
        || { echo "error: the provisioning profile does not grant time-sensitive notifications" >&2; exit 1; }

    cp "$PROFILE" "$STAGE/Contents/embedded.provisionprofile"
    "$PLISTBUDDY" -c "Add :JARVISShazamKit bool true" "$STAGE/Contents/Info.plist"
    ENTITLEMENTS="$WORK/JARVIS.entitlements"
    cp "$BASE_ENTITLEMENTS" "$ENTITLEMENTS"
    "$PLISTBUDDY" -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
        -c "Add :com.apple.developer.team-identifier string $TEAM" \
        -c "Add :com.apple.developer.usernotifications.time-sensitive bool true" "$ENTITLEMENTS"
fi

# codesign's stderr names the signing identity; keep it off the terminal.
sign() { "$CODESIGN" "${SIGN[@]}" "$@" 2>/dev/null; }
verify() {
    "$CODESIGN" --verify --strict "$1" 2>/dev/null || { echo "error: codesign --verify --strict failed on $2" >&2; exit 1; }
}
for d in "$STAGE"/Contents/Frameworks/*.dylib "$STAGE"/Contents/Frameworks/*.so; do [[ -e "$d" ]] || continue
    sign "$d" || { echo "error: codesign failed on $(basename "$d")" >&2; exit 1; }; done   # inner first, no --deep
# The voice helper's nested code, also inner first: its resource bundles, then the helper.
for h in "$STAGE"/Contents/Helpers/*.bundle "$STAGE/Contents/Helpers/jarvis-voice"; do [[ -e "$h" ]] || continue
    sign "$h" || { echo "error: codesign failed on $(basename "$h")" >&2; exit 1; }; done
verify "$STAGE/Contents/Helpers/jarvis-voice" "the voice helper"
# V6: the Qwen helper the same way, inner first.
for h in "$STAGE"/Contents/Helpers/qwen/*.bundle "$STAGE/Contents/Helpers/qwen/jarvis-voice-qwen"; do [[ -e "$h" ]] || continue
    sign "$h" || { echo "error: codesign failed on qwen/$(basename "$h")" >&2; exit 1; }; done
verify "$STAGE/Contents/Helpers/qwen/jarvis-voice-qwen" "the Qwen voice helper"
# The update helper is a script: signed on its own before the app, its signature kept in its
# extended attributes. Unsigned, it would fail the app's signature as unsigned nested code.
sign "$STAGE/Contents/Helpers/jarvis-update" || { echo "error: codesign failed on the update helper" >&2; exit 1; }
verify "$STAGE/Contents/Helpers/jarvis-update" "the update helper"
if ! sign --entitlements "$ENTITLEMENTS" "$STAGE"; then
    echo "error: codesign failed (output withheld: it may name the identity)" >&2; exit 1
fi
verify "$STAGE" "the staged bundle"

# The designated requirement, checked WITHOUT printing it: it names the app's bundle ID, and on
# the default path the team's Developer ID (Apple's anchor, the Developer ID markers, and the
# leaf certificate's OU = the team).
drline="$("$CODESIGN" -d -r- "$STAGE" 2>&1 | grep '^designated')" || drline=""
[[ -n "$drline" ]] || { echo "error: no designated requirement on the staged bundle" >&2; exit 1; }
dr_has() { [[ "$drline" == *"$1"* ]]; }
if ! dr_has "identifier \"$BUNDLE_ID\""; then
    echo "DR names $BUNDLE_ID: no"
    echo "error: the staged bundle's designated requirement does not name $BUNDLE_ID" >&2; exit 1
fi
if [[ "$LEGACY" == true ]]; then
    echo "DR names $BUNDLE_ID: yes (legacy self-signed identity; no profile, ShazamKit off)"
elif dr_has "anchor apple generic" && dr_has "certificate leaf[field.1.2.840.113635.100.6.1.13]" \
        && { dr_has "certificate leaf[subject.OU] = $TEAM" || dr_has "certificate leaf[subject.OU] = \"$TEAM\""; }; then
    echo "DR names $BUNDLE_ID and the team's Developer ID: yes"
else
    echo "DR names $BUNDLE_ID and the team's Developer ID: no"
    echo "error: the staged bundle's designated requirement is not the team's Developer ID" >&2; exit 1
fi
