"""PA batch A (quick commands): the fast path's routing, timers, alarm list/cancel and the
system quick commands' replies.

Plugin for tools/golden.py. Nothing is executed: every jarvis function `fast_path` names, other
than the pure ones it is proven with, is swapped for a recorder; subprocess, AppleScript, the
network and AppKit are canned.

quick_router   input {text} -> expected {t, branch, kind, reply?, action?, helper?}.
  `branch` is the plan's name (native/plan/M07 §2.1) of the top-level `if` whose `return` ran, or
  "defer" for the function's end. It is found with sys.settrace on fast_path's frame and the AST
  of the live jarvis.py, so a branch added or moved in Python fails the suite. kind: say (a str
  literal), act (a tuple: `action` is the one recorder its callable hit, or null), helper (a
  recorder's sentinel: `helper` is that call), defer (None). Recorders return a sentinel str;
  `_quit_app` returns it only for the names in QUIT_RUNNING, else None (falls through). The
  pure helpers stay real: `_parse_teach`, `_kind_word`; the tables `_ALL_KINDS` and `_TWEAKS`
  are written under the envelope-free case "tables" so Swift can assert its copies.
quick_timers   input {steps: [{op, ...}]} -> expected {out: [...]}: `_set_timer`, `_timer_status`,
  `_cancel_timers` and the timer's own firing under the frozen clock. threading.Timer is a
  recorder; op "fire" runs, at clock `at`, every recorded timer whose end is due, soonest first
  (what the Timer threads would do), and records what `speak` was given.
quick_alarms   input {file: <json text or null>} -> expected {list, cancel, after}: `_list_alarms`,
  then `_cancel_alarms` and the alarms.json it leaves (null: none written).
quick_system   input {fn, ...} -> expected {text, calls?}: `_ip_report`, `_bt_battery`,
  `_quit_all_apps`, `_empty_trash`, `_lock_screen`, `_sleep_mac`, `_media`, `forget_voice` over
  canned command output; `calls` is what they ran.
"""
import ast
import contextlib
import inspect
import json
import os
import subprocess
import sys
import types

from golden import suite

_EPOCH = 1790582400                    # Mon 2026-09-28 09:00:00 Europe/London (the default)


@contextlib.contextmanager
def _patched(obj, **attrs):
    missing = object()
    d = obj.__dict__ if isinstance(obj, types.ModuleType) else vars(obj)
    saved = {k: d.get(k, missing) for k in attrs}
    for k, v in attrs.items():
        setattr(obj, k, v)
    try:
        yield
    finally:
        for k, v in saved.items():
            if v is missing:
                delattr(obj, k)
            else:
                setattr(obj, k, v)


class Sent(str):
    """What a recorder returns: a str, so `if r:` and `return r` behave as for real replies."""


# ─── quick_router ───────────────────────────────────────────────────────────────

BRANCHES = [
    "corr.forget", "corr.teach", "diagnostics", "shortcut.run", "lights", "settings.root",
    "settings.privacy", "settings.pane", "open.file", "open.app", "media.play", "media.pause",
    "media.next", "media.previous", "media.now_playing", "media.play_query", "media.song_by",
    "location", "weather", "timer.set", "reminder", "alarm.set", "lyrics.find", "messages.read",
    "calendar.today", "briefing", "screen.exact", "screen.fuzzy", "clipboard.help", "note.make",
    "time", "battery", "backend", "presence", "voice.forget", "volume.set", "volume.mute",
    "volume.up", "volume.down", "news", "screenshot", "lock", "trash", "brightness.set",
    "brightness.up", "brightness.down", "message.send", "type", "page.summarize", "shortcut.list",
    "timer.cancel", "timer.status", "alarm.cancel", "alarm.list", "quit.all", "quit.app", "sleep",
    "clipboard.copy_last", "browser.default.get", "browser.default.set", "apps.find", "toggle",
    "files.recent", "files.reveal", "ip", "bt.battery", "web.google", "web.youtube",
]   # then "defer"

KEEP_REAL = {"_parse_teach", "_kind_word"}
QUIT_RUNNING = ["safari", "music", "xcode", "all my browsers"]
# Approved deviations (plan/DEVIATIONS.md) on the carried branches: the case keeps Python's verdict and
# names the row; the Swift test asserts the native verdict for it instead.
DEVIATIONS = {"start a timer for 5 minutes": "DEV-M7-01", "start a timer for 90 seconds": "DEV-M7-01",
              "start timer for 2 hours": "DEV-M7-01", "start music": "DEV-M7-02", "start the music": "DEV-M7-02"}

# native/plan/M07 §4.1's corpus, verbatim, then batch A's own cases.
CORPUS = [
    "forget the correction for passion", "please forget the corrections", "forget corrections",
    "forget all corrections", "i said passion not fashion", "correct fashion to passion",
    "when i say lamps i mean lights", "it's drake not dray", "that's right not wrong",
    "i said hello", "run diagnostics", "Run Diagnostics.", "system status", "how's my system",
    "run a systems check", "diagnostics?", "run diagnostics please",
    "run shortcut morning routine", "run the good night shortcut", "run the shortcuts app",
    "turn on the lights", "switch off my lamp", "lights off", "the lights on",
    "turn on the light switch", "turn off the tv", "open settings", "system settings", "settings",
    "open system preferences", "open settings app", "open microphone privacy settings",
    "open the camera permissions", "open screen recording privacy", "open bluetooth settings",
    "show display settings", "take me to the sound preferences", "go to wifi settings",
    "open screen time settings", "open file budget.xlsx", "open the file notes.txt", "open safari",
    "Open Safari!", "open youtube?", "launch music", "open my browser", "open my music app",
    "open my game app", "open mail", "fire up xcode", "open vs code", "bring up calculator",
    "pull up maps", "open the tv", "open github.com", "open http://example.com", "open flurbo",
    "open finder", "go to google", "open weather", "open notes", "start music", "start the music",
    "start a timer for 5 minutes", "go to sleep", "play", "resume music", "unpause",
    "play some music", "play it", "pause", "stop", "stop music", "next", "skip it", "previous",
    "replay", "what's playing", "name this song", "play bohemian rhapsody", "put on some jazz",
    "listen to the song yellow", "can you play hotel california please", "play songs",
    "i want to hear music", "play cats on youtube", "passion fruit by drake", "hello by adele",
    "what's up by 4 non blondes", "who sang yesterday by the beatles", "stand by me by ben e king",
    "written by shakespeare", "down by the river?", "ac/dc by angus", "where am i", "locate me",
    "what's the weather", "weather in london", "what's the temperature in paris",
    "what's the weather like in new york", "is it raining", "forecast for tomorrow",
    "will it rain today", "whether or not", "set a timer for 5 minutes", "timer for 30 seconds",
    "timer 2 hours", "set a timer for ten minutes", "remind me to call mum in 10 minutes",
    "remind me to buy milk tomorrow", "set a reminder to pay rent at 5 pm", "remind me",
    "set an alarm for 7 am", "wake me up at 6:30", "set alarm in 20 minutes",
    "set an alarm for 7 every weekday", "what's the song that goes never gonna give you up",
    "find the song with the lyrics hello from the other side", "song that goes we will rock you",
    "read my messages", "any new texts", "what's on my calendar", "my schedule today", "brief me",
    "good morning", "good morning jarvis", "what's on my screen", "what's on my screen?",
    "help me with this", "give me ideas", "what's on the screen", "explain my screen",
    "can you see my screen", "see screen time", "lock my screen", "take a screenshot",
    "screen brighter", "what's on my clipboard", "explain this", "what is this",
    "explain this page", "take a note buy eggs", "note: call the bank",
    "note that the meeting moved", "jot down meeting at noon", "notes", "notebook", "note",
    "what time is it", "What Time Is It?", "time", "what's the time", "what time is it in tokyo",
    "what  time is it", "battery level", "battery", "how much battery do i have",
    "what's my airpods battery status", "my battery", "which model are you using",
    "backend status", "hello", "  hello  ", "hello!", "hello jarvis", "are you there", "status",
    "forget my voice", "respond to everyone", "volume 50", "set volume to 30", "volume to 150",
    "set volume to 0", "volume fifty", "mute", "volume up", "louder", "quieter", "news",
    "top headlines", "what's the news", "screenshot", "i'm stepping away", "lock it",
    "empty the trash", "brightness 70", "set brightness to 40 percent", "brightness to 200",
    "brighter", "dim the screen", "text mum saying i'll be late",
    "send a message to dad that says happy birthday", "message sarah telling her i'm outside",
    "text mum", "type hello world", "dictate: dear sir", "take this down the meeting is at noon",
    "summarize this page", "tldr", "list my shortcuts", "what shortcuts do i have",
    "cancel the timer", "stop my timers", "kill all timers", "how long is left on the timer",
    "timer status", "how long left", "cancel my alarm", "turn off the alarm", "delete all alarms",
    "list my alarms", "do i have any alarms", "quit everything", "close all apps", "quit safari",
    "close the deal", "close all my browsers", "exit", "goodnight", "goodnight jarvis",
    "put the mac to sleep", "copy that", "copy it", "what's my default browser",
    "set my default browser to chrome", "make firefox my default browser",
    "what browsers do i have", "which music apps do i have installed", "what games do i have",
    "what friends do i have", "turn on dark mode", "turn off wifi", "enable bluetooth",
    "show hidden files", "hide the dock", "disable do not disturb", "switch on focus",
    "turn on the kettle", "show me the money", "recent files", "what have i been working on",
    "reveal the file budget.pdf", "where is the file thesis.docx",
    "find the file resume in finder", "where is my phone", "what's my ip", "ip address",
    "airpods battery", "how are my headphones", "google swift concurrency",
    "google how tall is everest", "youtube lofi beats", "search youtube for cats",
    "find cooking videos on youtube", "look up youtube for guitar lessons", "tell me a joke",
    "what's the capital of france", "who are you", "how are you doing today", "thank you", "",
    "open my games", "open a game", "stop the timer", "stop the music", "turn the lights off",
    "open the pod bay doors", "hide", "play music by drake", "WHAT'S PLAYING?",
    "what’s playing", "open system settings", "turn off the lights",
    "what's the weather in london?", "launch spotify", "déjà vu by olivia rodrigo",
    "play déjà vu", "turn on the lights ", "open safari\n?", "hello.",
    # batch A: every phrase of the ported branches, and near misses around them
    "Forget The Correction For Passion?", "forget the correction for fashion please",
    "when i say jarvis i meant travis", "correct jervis to jarvis.", "the word is gif not jif",
    "set a timer for 0 seconds", "start a timer for 90 seconds", "timer of 1 hour",
    "a timer for 3 min", "an timer for 2 hrs", "set timer for 10 minutes",
    "timer for 5minutes", "timer for 45 secs and then remind me", "timer for 2 hours 30 minutes",
    "set a timer for ٣ minutes", "set a timer for 00012 seconds", "timer",
    "timer for five minutes", "set a timer", "timers", "cancel timers", "kill the timer",
    "stop all timers", "cancel my timers", "cancel the timers please", "how much time is left on my timer",
    "how long until the timer", "how's the timer", "hows the timer", "check the timer",
    "check my timer", "timer status?", "cancel alarms", "stop the alarm", "kill my alarms",
    "delete the alarm", "turn off all alarms", "cancel all alarms.", "what alarms do i have",
    "my alarms", "list alarms", "what alarms are set", "what alarms do i have?",
    "do i have any alarms set", "lock my mac", "lock the mac", "lock my computer",
    "lock the computer", "lock up", "im stepping away", "going away for a bit", "lock the screen",
    "lock", "empty trash", "empty the bin", "empty my trash", "take out the trash",
    "empty the recycle bin", "empty the trash please", "good night", "good night jarvis",
    "put my mac to sleep", "sleep the mac", "put the computer to sleep", "sleep",
    "close everything", "quit all apps", "close all my apps", "quit all applications",
    "close every app", "quit everything please", "whats my ip", "what's my ip address",
    "whats my ip address", "what is my ip address", "my ip address", "what's my public ip",
    "whats my public ip", "what is my ip", "airpod battery", "how are my airpods",
    "check my airpods", "how's my airpods battery", "hows my airpods battery",
    "whats my airpods battery", "what's my airpods battery", "headphones battery",
    "headphone battery", "resume", "play music", "continue playing", "play a song",
    "play something", "play tunes", "play me music", "play me some music", "pause music",
    "pause it", "next song", "next track", "skip", "skip song", "skip this", "previous song",
    "previous track", "last song", "go back a song", "you there", "you online",
    "are you online", "reset voice recognition", "disable voice recognition", "clear my voice",
    "stop recognizing only me", "forget my voice please", "Forget my voice.",
    "start timer for 2 hours",
]


def _fast_path_ifs(J):
    """The top-level `if` statements of fast_path, as (first line, last line), in order."""
    with open(J.__file__, encoding="utf-8") as f:
        tree = ast.parse(f.read())
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "fast_path")
    ifs = [(n.lineno, n.end_lineno) for n in fn.body if isinstance(n, ast.If)]
    names = {n.id for n in ast.walk(fn) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load)}
    return fn, ifs, names


def _router_cases(ctx):
    J = ctx.J
    fn, ifs, names = _fast_path_ifs(J)
    if len(ifs) != len(BRANCHES):
        raise RuntimeError(f"fast_path has {len(ifs)} top-level ifs, the branch list {len(BRANCHES)}: "
                           f"a branch was added or removed")
    calls = []

    def recorder(name):
        def rec(*args, **kwargs):
            entry = {"fn": name, "args": list(args)}
            if kwargs:
                entry["kwargs"] = kwargs
            calls.append(entry)
            if name == "_quit_app":
                if args and args[0] in QUIT_RUNNING:
                    return Sent("quit")
                calls.pop()                   # a probe that fell through is not the helper
                return None
            return Sent(name)
        return rec

    stubs = {}
    for n in sorted(names):
        obj = J.__dict__.get(n)
        if inspect.isfunction(obj) and obj.__module__ == J.__name__ and n not in KEEP_REAL \
                and n != "fast_path":
            stubs[n] = recorder(n)
    stubs["_default_browser_name"] = lambda: "Safari"
    code = J.fast_path.__code__

    def branch_of(line):
        for k, (a, b) in enumerate(ifs):
            if a <= line <= b:
                return BRANCHES[k]
        return "defer"

    cases = []
    with _patched(J, **stubs):
        seen = set()
        for i, text in enumerate(CORPUS):
            if text in seen:
                continue
            seen.add(text)
            calls.clear()
            ret_line = []

            def tracer(frame, event, arg):
                if frame.f_code is code:
                    def local(fr, ev, a):
                        if ev == "return":
                            ret_line.append(fr.f_lineno)
                        return local
                    return local
                return None

            sys.settrace(tracer)
            try:
                out = J.fast_path(text)
            finally:
                sys.settrace(None)
            exp = {"t": text.lower().strip().rstrip("?."), "branch": branch_of(ret_line[-1])}
            hits = list(calls)
            if out is None:
                exp["kind"] = "defer"
            elif isinstance(out, tuple):
                reply, act = out
                exp["kind"] = "act"
                exp["reply"] = reply
                before = len(calls)
                if act is not None:
                    act()
                done = calls[before:]
                if act is not None and len(done) != 1:
                    raise RuntimeError(f"{text!r}: the action hit {len(done)} recorders")
                exp["action"] = done[0] if done else None
            elif isinstance(out, Sent):
                if not hits:
                    raise RuntimeError(f"{text!r}: a sentinel with no recorder call")
                exp["kind"] = "helper"
                exp["helper"] = hits[-1]
            else:
                exp["kind"] = "say"
                exp["reply"] = out
            if text in DEVIATIONS:
                exp["deviation"] = DEVIATIONS[text]
            cases.append({"name": f"{i:03d} {text!r}", "input": {"text": text}, "expected": exp})
    if set(DEVIATIONS) - seen:
        raise RuntimeError(f"deviation phrases missing from the corpus: {sorted(set(DEVIATIONS) - seen)}")
    cases.append({"name": "tables", "input": {},
                  "expected": {"ALL_KINDS": sorted(J._ALL_KINDS), "TWEAKS": list(J._TWEAKS),
                               "QUIT_RUNNING": QUIT_RUNNING, "BRANCHES": BRANCHES + ["defer"]}})
    return cases


@suite("quick_router")
def quick_router(ctx):
    ctx.reset()
    return _router_cases(ctx)


# ─── quick_timers ───────────────────────────────────────────────────────────────

class _FakeTimer:
    made = []

    def __init__(self, interval, function, args=None, kwargs=None):
        self.interval, self.function = interval, function
        self.cancelled = False
        self.daemon = False
        _FakeTimer.made.append(self)

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True


TIMER_SCRIPTS = [
    ("set_one_minute", [{"op": "set", "secs": 60}]),
    ("set_zero_is_one_second", [{"op": "set", "secs": 0}]),
    ("set_seconds", [{"op": "set", "secs": 45}]),
    ("set_one_second", [{"op": "set", "secs": 1}]),
    ("set_ninety", [{"op": "set", "secs": 90}]),
    ("set_two_minutes", [{"op": "set", "secs": 120}]),
    ("set_minute_and_one", [{"op": "set", "secs": 61}]),
    ("set_hour", [{"op": "set", "secs": 3600}]),
    ("set_two_hours", [{"op": "set", "secs": 7200}]),
    ("set_odd", [{"op": "set", "secs": 3725}]),
    ("status_none", [{"op": "status"}]),
    ("cancel_none", [{"op": "cancel"}]),
    ("status_one", [{"op": "set", "secs": 300}, {"op": "status", "at": _EPOCH + 100}]),
    ("status_fraction", [{"op": "set", "secs": 300}, {"op": "status", "at": _EPOCH + 100.75}]),
    ("status_last_second", [{"op": "set", "secs": 300}, {"op": "status", "at": _EPOCH + 299.5}]),
    ("status_overdue", [{"op": "set", "secs": 10}, {"op": "status", "at": _EPOCH + 20}]),
    ("status_two_sorted", [{"op": "set", "secs": 600}, {"op": "set", "secs": 60, "at": _EPOCH + 5},
                           {"op": "status", "at": _EPOCH + 10}]),
    ("status_tie_keeps_order", [{"op": "set", "secs": 60}, {"op": "set", "secs": 60},
                                {"op": "status", "at": _EPOCH + 1}]),
    ("cancel_one", [{"op": "set", "secs": 60}, {"op": "cancel"}, {"op": "status"}]),
    ("cancel_three", [{"op": "set", "secs": 60}, {"op": "set", "secs": 120}, {"op": "set", "secs": 5},
                      {"op": "cancel"}, {"op": "cancel"}]),
    ("fire_one", [{"op": "set", "secs": 60}, {"op": "fire", "at": _EPOCH + 60}, {"op": "status"},
                  {"op": "cancel"}]),
    ("fire_early_nothing", [{"op": "set", "secs": 60}, {"op": "fire", "at": _EPOCH + 59.9},
                            {"op": "status"}]),
    ("fire_soonest_first", [{"op": "set", "secs": 120}, {"op": "set", "secs": 30},
                            {"op": "fire", "at": _EPOCH + 30}, {"op": "status", "at": _EPOCH + 30},
                            {"op": "fire", "at": _EPOCH + 500}, {"op": "status"}]),
    ("fire_after_cancel_silent", [{"op": "set", "secs": 30}, {"op": "cancel"},
                                  {"op": "fire", "at": _EPOCH + 100}]),
    ("fire_late_wakes", [{"op": "set", "secs": 30}, {"op": "fire", "at": _EPOCH + 4000}]),
]


@suite("quick_timers")
def quick_timers(ctx):
    J = ctx.J
    spoken = []
    cases = []
    threading_ns = types.SimpleNamespace(Timer=_FakeTimer)
    with _patched(J, threading=threading_ns, chime=lambda *a, **k: None,
                  _notify=lambda *a, **k: "", speak=lambda text, *a, **k: spoken.append(text)):
        for name, steps in TIMER_SCRIPTS:
            ctx.reset()
            ctx.at(_EPOCH)
            J._timers.clear()
            J._timer_seq[0] = 0
            _FakeTimer.made.clear()
            out = []
            for st in steps:
                if "at" in st:
                    ctx.at(st["at"])
                if st["op"] == "set":
                    out.append(J._set_timer(st["secs"]))
                elif st["op"] == "status":
                    out.append(J._timer_status())
                elif st["op"] == "cancel":
                    out.append(J._cancel_timers())
                elif st["op"] == "fire":
                    now = J.time.time()
                    due = [(info["end"], tid) for tid, info in J._timers.items() if info["end"] <= now]
                    lines = []
                    for _, tid in sorted(due):
                        timer = J._timers[tid]["timer"]
                        if timer.cancelled:
                            continue
                        spoken.clear()
                        timer.function()
                        lines.extend(spoken)
                    out.append(lines)
            cases.append({"name": name, "input": {"epoch": _EPOCH, "steps": steps},
                          "expected": {"out": out}})
    return cases


# ─── quick_alarms ───────────────────────────────────────────────────────────────

ALARM_FILES = [
    ("no_file", None),
    ("empty_list", "[]"),
    ("one_morning", '[{"time": "2026-09-29T07:30:00", "label": ""}]'),
    ("one_labelled", '[{"time": "2026-09-29T18:05:00", "label": "call mum"}]'),
    ("noon_and_midnight", '[{"time": "2026-09-29T12:00:00", "label": ""}, '
                          '{"time": "2026-09-30T00:15:00", "label": ""}]'),
    ("repeats", '[{"time": "2026-09-29T07:00:00", "label": "", "repeat": "daily"}, '
                '{"time": "2026-09-29T06:45:00", "label": "gym", "repeat": "weekdays"}]'),
    ("unknown_repeat", '[{"time": "2026-09-29T07:00:00", "label": "", "repeat": "monthly"}]'),
    ("no_label_key", '[{"time": "2026-09-29T09:10:00"}]'),
    ("malformed_time", '[{"time": "soon", "label": "x"}, {"time": "2026-09-29T07:30:00", "label": ""}]'),
    ("only_malformed", '[{"time": "soon", "label": "x"}]'),
    ("fractional_seconds", '[{"time": "2026-09-29T07:30:15.250000", "label": ""}]'),
    ("three", '[{"time": "2026-09-29T07:30:00", "label": ""}, {"time": "2026-09-29T08:00:00", '
              '"label": "train"}, {"time": "2026-09-29T21:59:00", "label": "", "repeat": "daily"}]'),
    ("not_json", "{not json"),
]


@suite("quick_alarms")
def quick_alarms(ctx):
    J = ctx.J
    cases = []
    for name, text in ALARM_FILES:
        ctx.reset()
        J._alarm_timers.clear()
        if os.path.exists(J.ALARMS_FILE):
            os.remove(J.ALARMS_FILE)
        if text is not None:
            with open(J.ALARMS_FILE, "w", encoding="utf-8") as f:
                f.write(text)
        listed = J._list_alarms()
        cancelled = J._cancel_alarms()
        after = None
        if os.path.exists(J.ALARMS_FILE):
            with open(J.ALARMS_FILE, encoding="utf-8") as f:
                after = f.read()
        cases.append({"name": name, "input": {"file": text},
                      "expected": {"list": listed, "cancel": cancelled, "after": after}})
    return cases


# ─── quick_system ───────────────────────────────────────────────────────────────

class _Runner:
    """Stands in for jarvis.subprocess. `outputs` maps an argv tuple to stdout text; a missing
    argv raises FileNotFoundError, as a command that cannot run would."""

    def __init__(self, outputs):
        self.outputs = outputs
        self.calls = []
        self.TimeoutExpired = subprocess.TimeoutExpired
        self.CalledProcessError = subprocess.CalledProcessError

    def run(self, argv, capture_output=False, text=False, timeout=None, input=None, **kw):
        self.calls.append(list(argv))
        key = tuple(argv)
        if key not in self.outputs:
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        out = self.outputs[key]
        return subprocess.CompletedProcess(argv, 0, stdout=out if text else out.encode(),
                                           stderr="" if text else b"")


class _App:
    def __init__(self, a, terminated):
        self.a, self.terminated = a, terminated

    def activationPolicy(self): return self.a["policy"]
    def localizedName(self): return self.a["name"]

    def terminate(self):
        self.terminated.append(self.a["name"])
        return self.a.get("terminates", True)


def _appkit(apps, terminated):
    class Workspace:
        def runningApplications(self):
            if apps == "raise":
                raise RuntimeError("no workspace")
            return [_App(a, terminated) for a in apps]
    ns = types.SimpleNamespace(sharedWorkspace=lambda: Workspace())
    return types.SimpleNamespace(NSWorkspace=ns)


_IOREG_AIRPODS = ('+-o AppleDeviceManagementHIDEventService  <class AppleDeviceManagementHIDEventService>\n'
                  '    {\n      "BatteryPercentLeft" = 80\n      "Product" = "The Den\'s AirPods Pro"\n'
                  '      "BatteryPercentRight" = 75\n      "BatteryPercentCase" = 40\n    }\n')
_IOREG_ONE_BUD = ('+-o Service\n    {\n      "Product" = "Beats Fit Pro"\n'
                  '      "BatteryPercentRight" = 5\n    }\n')
_IOREG_NO_NAME = '+-o Service\n    {\n      "BatteryPercentLeft" = 100\n    }\n'
_IOREG_NO_LEVELS = '+-o Service\n    {\n      "Product" = "Headset"\n      "BatteryPercentLeft" = full\n    }\n'
_IOREG_TWO = (_IOREG_ONE_BUD + _IOREG_AIRPODS)

SYSTEM_CASES = [
    ("ip/both", {"fn": "ip", "en0": "192.168.1.20\n", "en1": None, "online": True,
                 "public": {"ip": "203.0.113.7", "success": True}}),
    ("ip/en1_only", {"fn": "ip", "en0": "", "en1": "10.0.0.5\n", "online": True, "public": {"ip": "203.0.113.7"}}),
    ("ip/local_offline", {"fn": "ip", "en0": "192.168.1.20\n", "en1": None, "online": False, "public": None}),
    ("ip/public_only", {"fn": "ip", "en0": "", "en1": "", "online": True, "public": {"ip": "198.51.100.2"}}),
    ("ip/public_fails", {"fn": "ip", "en0": "192.168.1.20\n", "en1": None, "online": True, "public": "raise"}),
    ("ip/public_missing_key", {"fn": "ip", "en0": "192.168.1.20\n", "en1": None, "online": True,
                               "public": {"success": False}}),
    ("ip/nothing", {"fn": "ip", "en0": "", "en1": "", "online": False, "public": None}),
    ("ip/commands_fail", {"fn": "ip", "en0": None, "en1": None, "online": False, "public": None}),
    ("ip/whitespace_en0", {"fn": "ip", "en0": "  \n", "en1": "172.16.0.9", "online": False, "public": None}),
    ("bt/airpods", {"fn": "bt", "ioreg": _IOREG_AIRPODS}),
    ("bt/one_bud", {"fn": "bt", "ioreg": _IOREG_ONE_BUD}),
    ("bt/no_name", {"fn": "bt", "ioreg": _IOREG_NO_NAME}),
    ("bt/no_levels", {"fn": "bt", "ioreg": _IOREG_NO_LEVELS}),
    ("bt/two_devices", {"fn": "bt", "ioreg": _IOREG_TWO}),
    ("bt/empty", {"fn": "bt", "ioreg": ""}),
    ("bt/blank", {"fn": "bt", "ioreg": " \n"}),
    ("bt/fails", {"fn": "bt", "ioreg": None}),
    ("quit_all/several", {"fn": "quit_all", "apps": [
        {"name": "Finder", "policy": 0}, {"name": "Safari", "policy": 0}, {"name": "Notes", "policy": 0},
        {"name": "JARVIS", "policy": 0}, {"name": "Spotlight", "policy": 2}, {"name": "Dock", "policy": 1},
        {"name": "Jarvis Helper", "policy": 0}]}),
    ("quit_all/one", {"fn": "quit_all", "apps": [{"name": "Finder", "policy": 0}, {"name": "Mail", "policy": 0}]}),
    ("quit_all/refused", {"fn": "quit_all", "apps": [{"name": "Pages", "policy": 0, "terminates": False},
                                                     {"name": "Xcode", "policy": 0}]}),
    ("quit_all/none", {"fn": "quit_all", "apps": [{"name": "Finder", "policy": 0}, {"name": "Dock", "policy": 1}]}),
    ("quit_all/all_refuse", {"fn": "quit_all", "apps": [{"name": "Pages", "policy": 0, "terminates": False}]}),
    ("quit_all/finder_substring", {"fn": "quit_all", "apps": [{"name": "Path Finder", "policy": 0},
                                                              {"name": "TextEdit", "policy": 0}]}),
    ("quit_all/workspace_fails", {"fn": "quit_all", "apps": "raise"}),
    ("trash/ok", {"fn": "trash", "osascript": ""}),
    ("trash/error", {"fn": "trash", "osascript": "37:52: execution error: Finder got an error: (-128)"}),
    ("trash/Error_caps", {"fn": "trash", "osascript": "ERROR"}),
    ("lock", {"fn": "lock"}),
    ("sleep", {"fn": "sleep"}),
    ("media/play", {"fn": "media", "cmd": "play"}),
    ("media/pause", {"fn": "media", "cmd": "pause"}),
    ("media/next", {"fn": "media", "cmd": "next track"}),
    ("media/previous", {"fn": "media", "cmd": "previous track"}),
    ("forget_voice/enrolled", {"fn": "forget_voice", "enrolled": True}),
    ("forget_voice/not_enrolled", {"fn": "forget_voice", "enrolled": False}),
]


@suite("quick_system")
def quick_system(ctx):
    J = ctx.J
    cases = []
    for name, inp in SYSTEM_CASES:
        ctx.reset()
        fn = inp["fn"]
        exp = {}
        if fn == "ip":
            outs = {}
            for iface in ("en0", "en1"):
                if inp[iface] is not None:
                    outs[("ipconfig", "getifaddr", iface)] = inp[iface]
            runner = _Runner(outs)
            fetched = []

            def http_json(url, timeout=8, _p=inp["public"]):
                fetched.append(url)
                if _p == "raise" or _p is None:
                    raise OSError("unreachable")
                return _p
            with _patched(J, subprocess=runner, is_online=lambda timeout=1.2, _o=inp["online"]: _o,
                          _http_json=http_json):
                exp["text"] = J._ip_report()
            exp["calls"] = runner.calls + [["GET", u] for u in fetched]
        elif fn == "bt":
            outs = {}
            if inp["ioreg"] is not None:
                outs[("ioreg", "-r", "-l", "-k", "BatteryPercentLeft")] = inp["ioreg"]
            runner = _Runner(outs)
            with _patched(J, subprocess=runner):
                exp["text"] = J._bt_battery()
            exp["calls"] = runner.calls
        elif fn == "quit_all":
            terminated = []
            saved = sys.modules.get("AppKit")
            sys.modules["AppKit"] = _appkit(inp["apps"], terminated)
            try:
                exp["text"] = J._quit_all_apps()
            finally:
                if saved is None:
                    del sys.modules["AppKit"]
                else:
                    sys.modules["AppKit"] = saved
            exp["calls"] = [["terminate", n] for n in terminated]
        elif fn == "trash":
            scripts = []
            with _patched(J, _run_applescript=lambda s, _o=inp["osascript"]: (scripts.append(s), _o)[1]):
                exp["text"] = J._empty_trash()
            exp["calls"] = [["osascript", s] for s in scripts]
        elif fn in ("lock", "sleep"):
            runner = _Runner({("pmset", "displaysleepnow"): "", ("pmset", "sleepnow"): ""})
            with _patched(J, subprocess=runner):
                exp["text"] = J._lock_screen() if fn == "lock" else J._sleep_mac()
            exp["calls"] = runner.calls
        elif fn == "media":
            scripts = []
            with _patched(J, _run_applescript=lambda s: (scripts.append(s), "ok")[1]):
                exp["text"] = J._media(inp["cmd"])
            exp["calls"] = [["osascript", s] for s in scripts]
        elif fn == "forget_voice":
            if inp["enrolled"]:
                with open(J.VOICEPRINT_FILE, "wb") as f:
                    f.write(b"\x93NUMPY")
            exp["text"] = J.forget_voice()
            exp["calls"] = [["voiceprint_exists_after", os.path.exists(J.VOICEPRINT_FILE)]]
        cases.append({"name": name, "input": inp, "expected": exp})
    return cases
