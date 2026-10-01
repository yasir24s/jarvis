"""G10 system-action replies and scripts, recorded without any real side effects."""
import subprocess
import types

from golden import suite
from golden_m5_system import _assert_guard_live, _patched


@suite("m5_actions")
def actions(ctx):
    _assert_guard_live("m5_actions")
    vectors = []
    for tool in ("set_volume", "set_brightness"):
        for level in (-20, 0, 1, 30, 50, 55.9, 100, 130, True, "55", "1_0", "55.5", "", None, "abc"):
            vectors.append((tool, {"level": level}, False, ""))
    for level in (0, 30, 100):
        vectors.append(("set_brightness", {"level": level}, True, ""))
    vectors.append(("set_brightness", {"level": 30}, False, "execution error"))
    for text in ("", " \n", "hello", 'say "hi" \\', "🙂" * 21, "a\n\nb\n", "  hello\u0085", "a\r\nb"):
        vectors.append(("type_text", {"text": text}, False, ""))
    vectors.append(("type_text", {"text": "hello"}, False, "execution error (-1719)"))
    for args in ({}, {"message": "hello"}, {"title": 'a"b', "message": 'x\\y\n🙂'},
                 {"title": None, "message": False}):
        vectors.append(("notify", args, False, ""))
    cases = []
    for index, (tool, args, cli, script_output) in enumerate(vectors):
        calls, scripts = [], []
        def run(argv, **kw):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")
        def applescript(script):
            scripts.append(script)
            return script_output
        with _patched(ctx.J, subprocess=types.SimpleNamespace(run=run), IS_MAC=True, IS_WIN=False,
                      _run_applescript=applescript,
                      _brightness_cli=lambda: "/fake/brightness" if cli else None,
                      emotion_event=lambda *a, **k: None):
            text = ctx.J.execute_tool(tool, args)
        expected = {"text": text, "argv": calls, "scripts": scripts}
        if tool == "notify":
            # Native's osascript fallback escapes as _as_escape does; Python embeds the raw str().
            title, message = str(args.get("title", "JARVIS")), str(args.get("message", ""))
            native = (f'display notification "{ctx.J._as_escape(message)}" '
                      f'with title "{ctx.J._as_escape(title)}"')
            if native != calls[0][2]:
                expected["deviation"] = "R11"
                expected["native_script"] = native
        cases.append({"name": f"{tool}/{index}", "input": {"tool": tool, "args": args,
                      "cli": cli, "script_output": script_output},
                      "expected": expected})
    _assert_guard_live("m5_actions")
    return cases
