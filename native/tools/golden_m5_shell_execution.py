"""M5 shell replies from real Python functions over a fake subprocess transport.

No commands or scripts execute. Includes the G10 model-script denial cases.
"""
import subprocess
import types

from golden import suite
from golden_m5_system import _assert_guard_live, _patched


@suite("m5_shell_execution")
def shell_execution(ctx):
    _assert_guard_live("m5_shell_execution")
    cases = []
    vectors = [
        ("stdout", b" out \n", b"err", 0),
        ("stderr", b"", b" error \n", 1),
        ("empty", b"", b"", 0),
        ("whitespace", b" \n", b"error", 0),
        ("newlines", b"a\r\nb\rc", b"", 0),
        ("unicode", ("\u001c" + "🙂e\u0301" * 800 + "\u0085").encode(), b"", 0),
        ("invalid_stdout", b"a\xff", b"", 0),
        ("invalid_stderr", b"ok", b"\xff", 0),
        ("nonzero", b"useful", b"failed", 7),
    ]
    for tool in ("run_command", "run_applescript"):
        command = "echo harmless" if tool == "run_command" else 'return "hello 🙂"'
        for name, out, err, status in vectors:
            calls = []
            def run(argv, **kw):
                calls.append({"argv": argv, "stdin_hex": kw.get("input", b"").hex(),
                              "timeout": kw["timeout"]})
                stdout, stderr = out, err
                if kw.get("text"):
                    stdout = subprocess.Popen._translate_newlines(None, out, "utf-8", "strict")
                    stderr = subprocess.Popen._translate_newlines(None, err, "utf-8", "strict")
                return subprocess.CompletedProcess(argv, status, stdout, stderr)
            fake = types.SimpleNamespace(run=run, TimeoutExpired=subprocess.TimeoutExpired)
            with _patched(ctx.J, subprocess=fake, IS_MAC=True):
                text = (ctx.J._exec_shell(command) if tool == "run_command"
                        else ctx.J._run_applescript(command))
            cases.append({"name": f"{tool}/{name}", "input": {
                "tool": tool, "command": command, "stdout_hex": out.hex(),
                "stderr_hex": err.hex(), "status": status}, "expected": {"text": text, "calls": calls}})
        def timeout(argv, **kw):
            raise subprocess.TimeoutExpired(argv, kw["timeout"])
        with _patched(ctx.J, subprocess=types.SimpleNamespace(run=timeout,
                      TimeoutExpired=subprocess.TimeoutExpired), IS_MAC=True):
            text = (ctx.J._exec_shell(command) if tool == "run_command"
                    else ctx.J._run_applescript(command))
        cases.append({"name": f"{tool}/timeout", "input": {"tool": tool,
                      "command": command, "stdout_hex": "", "stderr_hex": "", "status": -9,
                      "timeout": True}, "expected": {"text": text}})
    # A call with no command: execute_tool reads args.get("command", "") and runs "".
    calls = []
    def run_missing(argv, **kw):
        calls.append({"argv": argv, "stdin_hex": "", "timeout": kw["timeout"]})
        return subprocess.CompletedProcess(argv, 0, "", "")
    with _patched(ctx.J, subprocess=types.SimpleNamespace(run=run_missing,
                  TimeoutExpired=subprocess.TimeoutExpired), IS_MAC=True, log=lambda *a, **k: None):
        text = ctx.J.execute_tool("run_command", {})
    cases.append({"name": "run_command/missing", "input": {"tool": "run_command", "missing": True,
                  "stdout_hex": "", "stderr_hex": "", "status": 0},
                  "expected": {"text": text, "calls": calls}})
    for script in ('do shell script "echo hi"', 'tell application "System Events" to get name',
                   'administrator privileges'):
        def never(*args, **kw):
            raise AssertionError("blocked script reached subprocess")
        with _patched(ctx.J, subprocess=types.SimpleNamespace(run=never), log=lambda *a, **k: None):
            text = ctx.J.execute_tool("run_applescript", {"script": script})
        cases.append({"name": f"guard/{len(cases)}", "input": {"tool": "run_applescript",
                      "command": script, "blocked": True}, "expected": {"text": text}})
    _assert_guard_live("m5_shell_execution")
    return cases
