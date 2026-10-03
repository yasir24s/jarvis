#!/bin/bash
# M15 (plan M00 §3.11): which JARVIS the LaunchAgent com.jarvis.assistant runs, and the
# one-command rollback.
#
#   switch-impl.sh native [--dry-run]   run the native app: back up the Python plist, write the
#                                       native one, bootout and bootstrap the agent
#   switch-impl.sh python [--dry-run]   restore the backed-up Python plist byte for byte, bootout
#                                       and bootstrap the agent
#   switch-impl.sh status               which program the plist names, whether launchd has it
#                                       loaded (program, pid, state), the lock holder and the last
#                                       log line
#
# --dry-run prints the plist diff and the commands, and changes nothing: no file is written and
# launchctl and lsregister are not run.
#
# Paths come from $HOME at run time; the script holds no literal home folder.
#   repo     $JARVIS_REPO, else $HOME/jarvis
#   plist    $HOME/Library/LaunchAgents/com.jarvis.assistant.plist
#   backup   <repo>/native/dist/com.jarvis.assistant.python.plist (gitignored)
#   native   <repo>/native/dist/JARVIS.app/Contents/MacOS/JARVIS
#   python   <repo>/dist/JARVIS.app
#   lock     ${JARVIS_HOME:-<repo>}/.jarvis.lock
#
# The native plist keeps every key of the Python one except: ProgramArguments is the native
# executable alone (direct exec), EnvironmentVariables gains JARVIS_HOME=<repo> and loses
# PYTHONUNBUFFERED, PATH is the plan's when the user's lacks /usr/sbin or /sbin, and RunAtLoad,
# KeepAlive and ThrottleInterval 10 are set.
set -euo pipefail

LABEL=com.jarvis.assistant
NATIVE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${JARVIS_REPO:-$HOME/jarvis}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BACKUP="$REPO/native/dist/$LABEL.python.plist"
NATIVE_APP="$REPO/native/dist/JARVIS.app"
NATIVE_EXE="$NATIVE_APP/Contents/MacOS/JARVIS"
PYTHON_APP="$REPO/dist/JARVIS.app"
LOCK="${JARVIS_HOME:-$REPO}/.jarvis.lock"
LOGFILE="$REPO/logs/jarvis.log"
AGENT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Test hooks, never set in normal use: stand-ins for launchctl and lsregister, and a shorter wait.
LAUNCHCTL="${SWITCH_IMPL_LAUNCHCTL:-/bin/launchctl}"
LSREGISTER="${SWITCH_IMPL_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
LOCK_WAIT="${SWITCH_IMPL_LOCK_WAIT:-30}"   # seconds for the old JARVIS to let go of the lock

DOMAIN="gui/$(id -u)"
DRY=0
TMP=""

say() { echo "switch-impl: $*" >&2; }
die() { say "$*"; exit 1; }
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

usage() {
    say "usage: switch-impl.sh native|python [--dry-run] | status"
    exit 64   # EX_USAGE
}

# The plist's first ProgramArguments entry, or "" when there is none.
program_of() {
    /usr/bin/plutil -extract ProgramArguments.0 raw -o - "$1" 2>/dev/null || true
}

# Which JARVIS a plist runs: native, python or other.
kind_of() {
    local program
    program="$(program_of "$1")"
    if [[ "$program" == "$NATIVE_EXE" ]]; then echo native
    elif [[ "$program" == "$PYTHON_APP"/* ]]; then echo python
    else echo "other ($program)"
    fi
}

# A command that changes something: printed under --dry-run, run otherwise.
act() {
    if (( DRY )); then
        printf '  %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

# 0 once no JARVIS holds the lock (flock, as jarvis-update's lock-free), 1 after LOCK_WAIT seconds.
wait_for_lock() {
    local waited=0
    while ! "$NATIVE_DIR/scripts/jarvis-update" lock-free "$LOCK"; do
        (( waited >= LOCK_WAIT )) && return 1
        sleep 1
        waited=$((waited + 1))
    done
}

# The native plist, built from the Python plist $1 into $2.
build_native() {
    local source="$1" out="$2" path
    cp "$source" "$out"
    /usr/bin/plutil -replace ProgramArguments -json "[$(json_string "$NATIVE_EXE")]" "$out"
    /usr/bin/plutil -extract EnvironmentVariables xml1 -o - "$out" >/dev/null 2>&1 \
        || /usr/bin/plutil -insert EnvironmentVariables -dictionary "$out"
    /usr/bin/plutil -replace EnvironmentVariables.JARVIS_HOME -string "$REPO" "$out"
    /usr/bin/plutil -remove EnvironmentVariables.PYTHONUNBUFFERED "$out" 2>/dev/null || true
    path="$(/usr/bin/plutil -extract EnvironmentVariables.PATH raw -o - "$out" 2>/dev/null || true)"
    if [[ ":$path:" != *":/usr/sbin:"* || ":$path:" != *":/sbin:"* ]]; then
        /usr/bin/plutil -replace EnvironmentVariables.PATH -string "$AGENT_PATH" "$out"
    fi
    /usr/bin/plutil -replace RunAtLoad -bool YES "$out"
    /usr/bin/plutil -replace KeepAlive -bool YES "$out"
    /usr/bin/plutil -replace ThrottleInterval -integer 10 "$out"
}

# $1 as a JSON string (for plutil -json): backslashes and quotes escaped.
json_string() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

switch_to() {
    local target="$1" new bundle current
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/switch-impl.XXXXXX")"
    new="$TMP/$LABEL.plist"
    current="$( [[ -f "$PLIST" ]] && kind_of "$PLIST" || echo missing)"
    say "the LaunchAgent now runs: $current"

    if [[ "$target" == native ]]; then
        [[ -x "$NATIVE_EXE" ]] || die "no native build at $NATIVE_EXE"
        if [[ "$current" != native && "$current" != missing ]]; then
            # The live plist carries the user's own edits: it is the backup, never install.sh's template.
            say "backing up the current plist to $BACKUP"
            if (( ! DRY )); then
                mkdir -p "$(dirname "$BACKUP")"
                cp -p "$PLIST" "$BACKUP"
                /usr/bin/plutil -lint -s "$BACKUP" || die "the backup does not lint"
            fi
        fi
        # Built from the Python plist: the one just backed up (the live one, under --dry-run).
        local source="$BACKUP"
        if (( DRY )) && [[ "$current" != native && "$current" != missing ]]; then source="$PLIST"; fi
        [[ -f "$source" ]] || die "no Python plist to start from: $BACKUP"
        build_native "$source" "$new"
        bundle="$NATIVE_APP"
    else
        [[ -f "$BACKUP" ]] || die "no backed-up Python plist at $BACKUP: nothing to restore"
        cp -p "$BACKUP" "$new"
        bundle="$PYTHON_APP"
    fi
    /usr/bin/plutil -lint -s "$new" || die "the new plist does not lint"

    if (( DRY )); then
        echo "--- plist diff ($PLIST -> $target)"
        diff -u "$PLIST" "$new" 2>/dev/null || true
        [[ -f "$PLIST" ]] || cat "$new"
        echo "--- commands"
    fi
    act "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" || say "bootout: $LABEL was not loaded"
    if (( DRY )); then
        echo "  # wait up to ${LOCK_WAIT}s for $LOCK to be free"
    elif ! wait_for_lock; then
        say "JARVIS still holds $LOCK after ${LOCK_WAIT}s; the plist is unchanged"
        [[ -f "$PLIST" ]] && "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" || true
        exit 1
    fi
    if (( DRY )); then
        echo "  install $new -> $PLIST"
    else
        mkdir -p "$(dirname "$PLIST")"
        cp -p "$new" "$PLIST.switch-impl.tmp"
        mv -f "$PLIST.switch-impl.tmp" "$PLIST"
    fi
    act /usr/bin/plutil -lint -s "$PLIST"
    act "$LSREGISTER" -f "$bundle"
    act "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"
    if (( DRY )); then
        say "dry run: nothing was changed"
        return 0
    fi
    say "the LaunchAgent now runs: $(kind_of "$PLIST")"
    status
}

status() {
    local printed
    if [[ -f "$PLIST" ]]; then
        echo "plist: $(kind_of "$PLIST")"
        echo "program = $(program_of "$PLIST")"
    else
        echo "plist: missing ($PLIST)"
    fi
    if printed="$("$LAUNCHCTL" print "$DOMAIN/$LABEL" 2>/dev/null)"; then
        echo "loaded: yes"
        echo "$printed" | grep -E '^[[:space:]]*(program|pid|state) = ' | sed -e 's/^[[:space:]]*/launchd /' || true
    else
        echo "loaded: no"
    fi
    if [[ -s "$LOCK" ]]; then
        echo "lock: $(head -n 1 "$LOCK")"
    elif "$NATIVE_DIR/scripts/jarvis-update" lock-free "$LOCK"; then
        echo "lock: free"
    else
        echo "lock: held"
    fi
    if [[ -f "$LOGFILE" ]]; then
        echo "last log line: $(tail -n 1 "$LOGFILE")"
    fi
}

[[ $# -ge 1 ]] || usage
COMMAND="$1"; shift
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        *) usage ;;
    esac
done
case "$COMMAND" in
    native|python) switch_to "$COMMAND" ;;
    status) (( DRY )) && usage; status ;;
    *) usage ;;
esac
