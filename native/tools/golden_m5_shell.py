"""M5 gate deviation suite for the run_command pre-guard: m5_shell_chain (X-1 and X-4).

Plugin for tools/golden.py. Python is the oracle for the *parity* half only: each case's
`python` value is `jarvis.py`'s own `_shell_risk` verdict. `_shell_risk` runs its regexes over
the whole line, so it cannot see a disallowed command hidden behind a control operator or a
command substitution, and it does not treat a Keychain secret read as risky at all. The native
gateway uses `ShellPolicy.strictVerdict`, which segments the line (control operators, `$(...)`,
backticks, `<(...)`, `>(...)`, honouring quotes and escapes), classifies every segment, requires
each sudo segment to match the allowlist on its own, and blocks Keychain secret reads. The
`native` half of each case is the hand-specified strict tier; `deviation` is set to the gate
name ("X-1" chained/substituted commands, "X-4" Keychain reads) whenever it differs from Python.

Nothing is executed. Like the M2 suites, this first proves the harness's audit-hook guard is
live by firing the audit events directly (sys.audit runs the hooks and nothing else).

m5_shell_chain  input {cmd} -> expected {python: _shell_risk, native: strict tier, deviation}.
"""
import sys

from golden import suite


def _assert_guard_live(where):
    """The harness's audit hook must refuse a spawn and an outside write. sys.audit only runs
    the hooks, so nothing is spawned or opened even if the guard were missing."""
    probes = (("subprocess.Popen", ("/usr/bin/true", ["/usr/bin/true"], None, None)),
              ("open", ("/" + "golden-guard-probe-never-created", "w", 0)))
    for event, args in probes:
        try:
            sys.audit(event, *args)
        except PermissionError as e:
            if "golden sandbox" in str(e):
                continue
            raise
        raise RuntimeError(f"{where}: write/process guard is not active ({event} allowed)")


# (name, command, native strict tier, gate tag). deviation is the tag only when python != native.
_VECTORS = [
    # X-1 chained sudo (plan §2.3): the second, disallowed sudo would run after confirmation.
    ("chain_sudo_allowed_then_blocked", "sudo pmset -g; sudo killall Finder", "block", "X-1"),
    ("chain_sudo_allowed_and_blocked", "sudo pmset -g && sudo killall Finder", "block", "X-1"),
    ("chain_sudo_allowed_pipe_blocked", "sudo pmset -g | sudo killall Finder", "block", "X-1"),
    # single sudo segments (parity with Python; no deviation expected).
    ("sudo_pmset_allowed", "sudo pmset -g", "confirm", "X-1"),
    ("sudo_killall_blocked", "sudo killall Finder", "block", "X-1"),
    # X-1 command substitution: a dangerous command hidden in $()/backticks/<()/dquoted $().
    ("subst_dollar_rm_root", "foo $(rm -rf /)", "block", "X-1"),
    ("subst_dquoted_rm_root", 'foo "$(rm -rf /)"', "block", "X-1"),
    ("subst_backtick_rm_root", "foo `rm -rf /`", "block", "X-1"),
    ("subst_procsub_rm_root", "diff <(rm -rf /) b", "block", "X-1"),
    # X-1 the strongest case: an allowed sudo up front hides a disallowed sudo in a substitution.
    ("subst_allowed_sudo_hides_bad_sudo", 'sudo pmset -g "$(sudo rm -rf /)"', "block", "X-1"),
    # single-quoted substitution is inert; Python and native agree (confirm from \brm\b).
    ("squoted_subst_inert", "echo '$(rm -rf /)'", "confirm", "X-1"),
    # unparseable input fails closed.
    ("unbalanced_quote", "echo 'unterminated", "block", "X-1"),
    # X-4 Keychain secret reads (Python classifies these ok).
    ("keychain_find_generic", "security find-generic-password -s jarvis", "block", "X-4"),
    ("keychain_find_internet", "security find-internet-password -s example.com", "block", "X-4"),
    ("keychain_dump", "security dump-keychain", "block", "X-4"),
    ("keychain_export", "security export -k login.keychain -p -o out.p12", "block", "X-4"),
    ("keychain_in_chain", "echo hi; security dump-keychain", "block", "X-4"),
    # Benign chains that must stay ok under the stricter policy.
    ("benign_and", "echo hi && ls -la", "ok", None),
    ("benign_semicolon", "cd /tmp; ls", "ok", None),
    ("benign_pipe", "git status | grep modified", "ok", None),
    ("benign_open_chain", "open -a Safari && open -a Music", "ok", None),
    ("benign_subshell", "(cd /tmp && ls)", "ok", None),
]


@suite("m5_shell_chain")
def shell_chain(ctx):
    J = ctx.J
    _assert_guard_live("m5_shell_chain")
    cases = []
    for name, cmd, native, tag in _VECTORS:
        py = J._shell_risk(cmd)
        cases.append({"name": name, "input": {"cmd": cmd},
                      "expected": {"python": py, "native": native,
                                   "deviation": None if py == native else tag}})
    _assert_guard_live("m5_shell_chain")
    return cases
