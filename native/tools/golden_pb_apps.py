"""PB: make_note, run_shortcut, list_shortcuts, summarize_page and find_song_by_lyrics over fakes.

pb_notes      input {args, outputs} -> expected {text, scripts}
pb_shortcuts  input {tool, args, cli, list, run} -> expected {text, argv}
              `shutil.which` answers `cli`; `subprocess.run` replays the recorded `shortcuts list`
              and `shortcuts run` results (golden_m5_settings._process), so nothing runs.
pb_browser    input {tool, args, front, outputs, online, pages, model} -> expected {text, scripts,
              requests, prompts}
              `_front_app` answers `front`, `_run_applescript` the next of `outputs`, the network is
              golden_w1_web's fake, and `_ask_model` records each prompt and answers `model`.
"""
import os
import subprocess
import types
import urllib.request

from golden import suite
from golden_m5_settings import _process
from golden_m5_system import _assert_guard_live, _patched
from golden_w1_web import _offline_world


def _queue(outputs, scripts):
    queue = list(outputs)

    def applescript(script):
        scripts.append(script)
        return (queue.pop(0) if queue else "").strip()[:1000]   # as _run_applescript trims osascript
    return applescript


@suite("pb_notes")
def notes(ctx):
    _assert_guard_live("pb_notes")
    vectors = [({"text": t}, [""]) for t in ("", "  ", "Buy milk", ' say "hi" \\ there \n', "🙂 café", None, 0)]
    vectors += [({"text": 5}, [""]), ({}, [""]), ({"text": "x"}, ["execution error: Notes got an error (-1743)"]),
                ({"text": "x"}, ["Error"]), ({"text": "x"}, ["note id x-coredata://1"])]
    cases = []
    for index, (args, outputs) in enumerate(vectors):
        scripts = []
        with _patched(ctx.J, IS_MAC=True, IS_WIN=False, _run_applescript=_queue(outputs, scripts),
                      emotion_event=lambda *a, **k: None):
            text = ctx.J.execute_tool("make_note", args)
        cases.append({"name": f"make_note/{index}", "input": {"args": args, "outputs": outputs},
                      "expected": {"text": text, "scripts": scripts}})
    _assert_guard_live("pb_notes")
    return cases


@suite("pb_shortcuts")
def shortcuts(ctx):
    _assert_guard_live("pb_shortcuts")
    many = "".join(f"Shortcut {i}\n" for i in range(1, 19))
    lights = {"stdout": "Lights On\nLights Off\nMorning Routine\nLiving Room Lights\n"}
    vectors = [
        ("run_shortcut", {"name": "lights on"}, False, None, None),
        ("run_shortcut", {"name": "lights on"}, True, {}, None),
        ("run_shortcut", {"name": "Lights ON"}, True, lights, {}),
        ("run_shortcut", {"name": "  lights off  "}, True, lights, {}),
        ("run_shortcut", {"name": "lights"}, True, lights, {}),
        ("run_shortcut", {"name": "morning"}, True, lights, {}),
        ("run_shortcut", {"name": "run my morning routine now"}, True, lights, {}),
        ("run_shortcut", {"name": "routine for the morning"}, True, lights, {}),
        ("run_shortcut", {"name": "living room"}, True, lights, {"status": 1, "stderr": "boom"}),
        ("run_shortcut", {"name": "lights on"}, True, lights, {"timeout": True}),
        ("run_shortcut", {"name": "lights on"}, True, lights, {"errno": 2}),
        ("run_shortcut", {"name": "lights on"}, True, lights, {"stdout_hex": "ff"}),
        ("run_shortcut", {"name": "garage"}, True, lights, None),
        ("run_shortcut", {"name": ""}, True, lights, None),
        ("run_shortcut", {}, True, lights, None),
        ("run_shortcut", {"name": None}, True, lights, None),
        ("run_shortcut", {"name": 5}, True, lights, None),
        ("run_shortcut", {"name": "lights on"}, True, {"timeout": True}, None),
        ("run_shortcut", {"name": "lights on"}, True, {"stdout": "Lights On\n", "stderr_hex": "ff"}, None),
        ("run_shortcut", {"name": "lights on"}, True, {"stdout": "  Lights On  \r\n\r\n"}, {}),
        ("list_shortcuts", {}, False, None, None),
        ("list_shortcuts", {}, True, {}, None),
        ("list_shortcuts", {}, True, lights, None),
        ("list_shortcuts", {}, True, {"stdout": many}, None),
        ("list_shortcuts", {}, True, {"stdout": "".join(f"S{i}\n" for i in range(15))}, None),
        ("list_shortcuts", {}, True, {"timeout": True}, None),
        ("list_shortcuts", {}, True, {"stdout": "A\n", "status": 1}, None),
    ]
    cases = []
    for index, (tool, args, cli, listed, ran) in enumerate(vectors):
        calls = []

        def run(argv, **kw):
            calls.append(list(argv))
            spec = listed if argv[1:2] == ["list"] else ran
            if spec is None:
                raise AssertionError(f"{tool}/{index}: unexpected {argv}")
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
        with _patched(ctx.J, subprocess=fake, IS_MAC=True, IS_WIN=False, log=lambda *a, **k: None,
                      emotion_event=lambda *a, **k: None,
                      shutil=types.SimpleNamespace(which=lambda tool: "/fake/shortcuts" if cli else None)):
            text = ctx.J.execute_tool(tool, args)
        cases.append({"name": f"{tool}/{index}",
                      "input": {"tool": tool, "args": args, "cli": cli,
                                "list": _process(listed) if listed is not None else None,
                                "run": _process(ran) if ran is not None else None},
                      "expected": {"text": text, "argv": calls}})
    _assert_guard_live("pb_shortcuts")
    return cases


_PAGE = ("<html><head><title>T</title><style>p{}</style><script>var x=1;</script></head><body>"
         "<nav>Home | About</nav><header>Site</header><h1>Big &amp; news</h1>\n<p>First   para.</p>"
         "<aside>ads</aside><p>Caf&eacute; &#8212; second.</p><footer>(c)</footer></body></html>")


def _browser_vectors():
    safari = ["yes", "https://example.com/article"]
    url = "https://example.com/article"
    page = {url: {"body": _PAGE}}
    v = []
    for args in ({}, {"question": "what is the main claim"}, {"question": ""}, {"question": None}):
        v.append(("summarize_page", args, "Safari", safari, True, page, "  It says big news.  "))
    v.append(("summarize_page", {"question": 5}, "Safari", safari, True, page, "x"))
    v.append(("summarize_page", {}, "Safari", safari, True, page, ""))
    v.append(("summarize_page", {}, "Finder", ["no", "no"], True, page, "x"))
    v.append(("summarize_page", {}, "Finder", ["no", "yes", url], True, page, "x"))
    v.append(("summarize_page", {}, "Google Chrome", ["yes", url], True, page, "x"))
    v.append(("summarize_page", {}, "Google Chrome", ["no", "yes", "favorites://"], True, page, "x"))
    v.append(("summarize_page", {}, "Safari", ["yes", "file:///tmp/x.html", "yes", url], True, page, "x"))
    v.append(("summarize_page", {}, "Safari", safari, False, page, "x"))
    v.append(("summarize_page", {}, "Safari", safari, True, {}, "x"))
    v.append(("summarize_page", {}, "Safari", safari, True, {url: {"status": 404}}, "x"))
    v.append(("summarize_page", {}, "Safari", safari, True, {url: {"body": "<script>x</script>  "}}, "x"))
    v.append(("summarize_page", {}, "Safari", safari, True, {url: {"body": "word " * 2000}}, "x"))
    v.append(("summarize_page", {}, "Safari", safari, True, {url: {"hex": "3c703e636166c3a920ff3c2f703e"}}, "x"))
    for lyrics, answer in (("", "x"), (" ,:'\". ", "x"), ("is this the real life", "Bohemian Rhapsody by Queen"),
                           ("'is this the real life,'", '"Bohemian Rhapsody by Queen"\nMore text'),
                           ("hello from the other side", "unknown"), ("x", "I don't know"), ("x", "  "),
                           ("x", "Unknown."), ("x", "I DO NOT KNOW"), ("x", "A" * 200), ("x", "'  Song by Band '"),
                           (None, "x"), (5, "x")):
        v.append(("find_song_by_lyrics", {"lyrics": lyrics}, "", [], False, {}, answer))
    v.append(("find_song_by_lyrics", {}, "", [], False, {}, "x"))
    return v


class _Sized:
    def __init__(self, response):
        self.data = response.read()

    def read(self, n=-1):
        return self.data if n is None or n < 0 else self.data[:n]


@suite("pb_browser")
def browser(ctx):
    _assert_guard_live("pb_browser")
    J = ctx.J
    cases = []
    for index, (tool, args, front, outputs, online, pages, model) in enumerate(_browser_vectors()):
        scripts, prompts = [], []

        def ask(prompt):
            prompts.append(prompt)
            return model.strip()

        with _patched(J, IS_MAC=True, IS_WIN=False, _run_applescript=_queue(outputs, scripts),
                      _front_app=lambda: front, _ask_model=ask, emotion_event=lambda *a, **k: None,
                      log=lambda *a, **k: None):
            with _offline_world(J, online, pages) as net:
                served = urllib.request.urlopen
                # _fetch_page_text reads at most 400 000 bytes: read(n), which W1's response lacks.
                urllib.request.urlopen = lambda req, timeout=None, **kw: _Sized(served(req, timeout=timeout, **kw))
                try:
                    text = J.execute_tool(tool, args)
                finally:
                    urllib.request.urlopen = served
        cases.append({"name": f"{tool}/{index}",
                      "input": {"tool": tool, "args": args, "front": front, "outputs": outputs, "online": online,
                                "pages": pages, "model": model},
                      "expected": {"text": text, "scripts": scripts, "requests": net.requests, "prompts": prompts}})
    _assert_guard_live("pb_browser")
    return cases
