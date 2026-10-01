"""G10 settings and system-control replies, recorded without opening System Settings or
changing any setting: subprocess, shutil.which and the AppleScript runner are fakes."""
import os
import subprocess
import types

from golden import suite
from golden_m5_system import _assert_guard_live, _patched


@suite("m5_open_settings")
def settings(ctx):
    _assert_guard_live("m5_open_settings")
    panes = list(ctx.J._SETTINGS_PANES) + list(ctx.J._PRIVACY_ANCHORS)
    panes += ["the sound settings", "my displays pane", "Bluetooth preferences", "blue",
              "privacy & security", "xyz", "", "accessibility"]
    cases = []
    for index, pane in enumerate(panes):
        calls = []
        with _patched(ctx.J, subprocess=types.SimpleNamespace(Popen=lambda argv: calls.append(argv))):
            text = ctx.J._open_settings(pane)
        cases.append({"name": f"pane/{index}", "input": {"pane": pane},
                      "expected": {"text": text, "url": calls[0][1]}})
    return cases


@suite("m5_system_control")
def controls(ctx):
    _assert_guard_live("m5_system_control")
    vectors = [(key, on, "", False, "", "Done, sir.")
               for key in ctx.J._TWEAKS for on in (True, False)]
    vectors += [(key, on, ports, bt, output, shortcut)
                for key, ports, bt, output, shortcut in [
                    ("wifi", "Hardware Port: Wi-Fi\nDevice: en7\n", False, "", ""),
                    ("wifi", "no wifi", False, "", ""),
                    ("bt", "", False, "", ""), ("bt", "", True, "", ""),
                    ("dnd", "", False, "", "Done, sir."),
                    ("dnd", "", False, "", "I couldn't find a shortcut matching toggle do not disturb, sir."),
                    ("dark", "", False, "execution error", ""),
                    ("light mode", "", False, "", ""),
                    ("the dock autohide", "", False, "", ""),
                    ("hidden", "", False, "", ""), ("nonsense", "", False, "", "")]
                for on in (True, False)]
    cases = []
    for index, (feature, on, ports, bt, script_output, shortcut) in enumerate(vectors):
        calls, scripts = [], []
        def run(argv, **kw):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, ports if "-listallhardwareports" in argv else "", "")
        def applescript(script):
            scripts.append(script)
            return script_output
        with _patched(ctx.J, subprocess=types.SimpleNamespace(run=run),
                      shutil=types.SimpleNamespace(which=lambda name: "/fake/blueutil" if bt else None),
                      _run_applescript=applescript, _run_shortcut=lambda name: shortcut,
                      log=lambda *a, **k: None):
            text = ctx.J._toggle_system(feature, on)
        cases.append({"name": f"control/{index}", "input": {"feature": feature, "enable": on,
                      "ports": ports, "bt": bt, "script_output": script_output, "shortcut": shortcut},
                      "expected": {"text": text, "argv": calls, "scripts": scripts}})
    cases += _dnd_cases(ctx)
    _assert_guard_live("m5_system_control")
    return cases


def _process(spec):
    """A recorded `shortcuts` result: stdout/stderr bytes, exit status, timeout or errno."""
    out = spec.get("stdout", "").encode() if "stdout_hex" not in spec else bytes.fromhex(spec["stdout_hex"])
    err = spec.get("stderr", "").encode() if "stderr_hex" not in spec else bytes.fromhex(spec["stderr_hex"])
    return {"stdout_hex": out.hex(), "stderr_hex": err.hex(), "status": spec.get("status", 0),
            "timeout": bool(spec.get("timeout")), "errno": spec.get("errno")}


def _dnd_cases(ctx):
    """system_control's DND branch through the real _run_shortcut, _match_shortcut and
    _shortcuts_all: only subprocess.run (for `shortcuts list` and `shortcuts run`) and
    shutil.which are fakes, so no shortcut runs and no Focus state changes."""
    vectors = [
        ("no_cli", False, None, None),
        ("empty_list", True, {}, None),
        ("exact", True, {"stdout": "Toggle Do Not Disturb\n"}, {}),
        ("exact_fails", True, {"stdout": "Other\ntoggle do not disturb\n"}, {"status": 1, "stderr": "boom"}),
        ("shortest_substring", True, {"stdout": "Do Not Disturb Plus\nDo Not Disturb\n"}, {}),
        ("token_overlap", True, {"stdout": "Disturb Toggle\nUnrelated\n"}, {}),
        ("no_match", True, {"stdout": "Unrelated\nToggle Wi-Fi\n"}, None),
        ("run_timeout", True, {"stdout": "Toggle Do Not Disturb\n"}, {"timeout": True}),
        ("run_missing", True, {"stdout": "Toggle Do Not Disturb\n"}, {"errno": 2}),
        ("run_invalid_utf8", True, {"stdout": "Toggle Do Not Disturb\n"}, {"stdout_hex": "ff"}),
        ("list_timeout", True, {"timeout": True}, None),
        ("list_invalid_stderr", True, {"stdout": "Toggle Do Not Disturb\n", "stderr_hex": "ff"}, None),
        ("list_crlf", True, {"stdout": "  Toggle Do Not Disturb  \r\n\r\n"}, {}),
        ("reply_says_couldnt_find", True, {"stdout": "couldn't find toggle do not disturb\n"}, {"status": 1}),
    ]
    cases = []
    for name, cli, listed, ran in vectors:
        calls = []
        def run(argv, **kw):
            calls.append(list(argv))
            spec = listed if argv[1:2] == ["list"] else ran
            if spec is None:
                raise AssertionError(f"dnd/{name}: unexpected {argv}")
            if spec.get("timeout"):
                raise subprocess.TimeoutExpired(argv, kw["timeout"])
            if spec.get("errno"):
                raise FileNotFoundError(spec["errno"], os.strerror(spec["errno"]), argv[0])
            p = _process(spec)
            out, err = bytes.fromhex(p["stdout_hex"]), bytes.fromhex(p["stderr_hex"])
            if kw.get("text"):
                out = subprocess.Popen._translate_newlines(None, out, "utf-8", "strict")
                err = subprocess.Popen._translate_newlines(None, err, "utf-8", "strict")
            return subprocess.CompletedProcess(argv, p["status"], out, err)
        fake = types.SimpleNamespace(run=run, TimeoutExpired=subprocess.TimeoutExpired)
        with _patched(ctx.J, subprocess=fake, IS_WIN=False, log=lambda *a, **k: None,
                      shutil=types.SimpleNamespace(which=lambda tool: "/fake/shortcuts" if cli else None)):
            text = ctx.J._toggle_system("dnd", True)
        cases.append({"name": f"dnd/{name}", "input": {"feature": "dnd", "enable": True, "cli": cli,
                      "list": _process(listed) if listed is not None else None,
                      "run": _process(ran) if ran is not None else None},
                      "expected": {"text": text, "argv": calls, "scripts": []}})
    return cases
