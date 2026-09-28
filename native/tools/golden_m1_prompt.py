"""M1 T11 golden suite: m1_prompt (plan: native/plan/M01 §2.7, §2.9, §3.8, §4.0, §4.1, §5 A10).

Plugin for tools/golden.py. Drives the REAL process_command in the sandboxed child, with only
the layers that would leave the process replaced:

- online: `claude_generate` captures the system prompt it is handed (sys_prompt + the Claude
  history preamble) and returns the step's canned reply;
- offline: `ollama_stream_chat` captures `payload["messages"][0]["content"]` (sys_prompt) and
  yields one canned chunk, which the real `_consume_chat_stream` consumes (`speak` is a
  recorder, so nothing is voiced); a `fail` step raises there instead, so the real except /
  finally branch pops the user turn and saves;
- the frontmost app: a fake AppKit module drives the real `_front_app` (so the nameless-app
  "None" and the failure "" are Python's own); the value it returned is recorded;
- time: ctx.at() before every step.

A case is one scenario: `input.files_before` (base64 or null for each state file) and
`input.steps`, each {op, now, ...}. `expected.steps` holds per step `bumps` (the
research_bump calls in order, as [key, n]) and `files_after` (the six state files' bytes,
base64 or null). A `turn` step also records `front_app`, `text` (what reached
process_command: `raw` after the real `_apply_corrections`, when the step has `raw`),
`captured_system`, `reply`, and `brain_bumps` (bumps after the head, from `_set_backend`:
M3's, not CoreState's). `bumps` of a turn are the head's only.

Other ops: `tone` (set_tone), `learn` / `forget` (learn_correction / forget_correction),
`kb` (kb_remember), `note` (personality_note_tool), `rewrite` (personality_rewrite_tool) and
`restart` (what a Python restart resets: _history reloaded from disk, _corr_cache,
LAST_TONE, _LAST_CMD). Their `result` is the function's return value. Every step also
records `module_state`: len(_history), len(_corrections_load()) (the snapshot inputs) and
_whisper_prompt() (built from the vocabulary inputs over `expected.whisper_base`).

The `system_prompt` case holds SYSTEM_PROMPT (import-time, CHANGELOG_FILE tokenised by the
harness) and the same f-string re-evaluated from jarvis.py's AST with a sentinel changelog
path and the macOS branch values, also read from the AST (never retyped).

All state is synthetic and neutral. Times travel as {"repr", "bits"}.
"""
import ast
import base64
import json
import os
import struct
import sys
import types

from golden import suite

_T0 = 1790582400.25                     # a time.time()-like epoch with a fraction

_FILES = {"personality.json": "PERSONALITY_FILE", "emotions.json": "EMOTIONS_FILE",
          "profile.json": "PROFILE_FILE", "knowledge.json": "KB_FILE",
          "corrections.json": "CORR_FILE", "history.json": "HIST_FILE"}

_SENTINEL = "<CHANGELOG_FILE>"


def _f(x):
    return {"repr": repr(x), "bits": "%016x" % struct.unpack("<Q", struct.pack("<d", x))[0]}


def _b64(data):
    return None if data is None else base64.b64encode(data).decode("ascii")


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _files(J):
    return {name: _b64(_read(getattr(J, const))) for name, const in _FILES.items()}


# ─── SYSTEM_PROMPT from the AST ─────────────────────────────────────────────────

def _system_prompt_case(ctx):
    J = ctx.J
    path = J.__file__
    tree = ast.parse(open(path, encoding="utf-8").read())
    node = next(n for n in tree.body if isinstance(n, ast.Assign)
                and getattr(n.targets[0], "id", "") == "SYSTEM_PROMPT")
    branch = next(n for n in tree.body if isinstance(n, ast.If)
                  and getattr(n.test, "id", "") == "IS_WIN")
    macos = {a.targets[0].id: ast.literal_eval(a.value) for a in branch.orelse}
    assert sorted(macos) == ["_DEVICE", "_MUSIC_RULE", "_SCRIPT_DESC", "_SCRIPT_TOOL"], macos
    expr = compile(ast.Expression(node.value), path, "eval")
    real = eval(expr, {**macos, "CHANGELOG_FILE": ctx.original["CHANGELOG_FILE"]})
    assert real == J.SYSTEM_PROMPT, "SYSTEM_PROMPT's AST does not reproduce the import-time value"
    assert all(getattr(J, k) == v for k, v in macos.items()), "not the macOS branch"
    return {"name": "system_prompt", "input": {"kind": "system_prompt", "sentinel": _SENTINEL},
            "expected": {"system_prompt": J.SYSTEM_PROMPT,
                         "with_sentinel": eval(expr, {**macos, "CHANGELOG_FILE": _SENTINEL}),
                         "macos": macos}}


# ─── Injected layers ────────────────────────────────────────────────────────────

def _fake_appkit(mode, name):
    class App:
        def localizedName(self):
            return None if mode == "nil_name" else name

    class Workspace:
        def frontmostApplication(self):
            return None if mode == "no_app" else App()

    class NSWorkspace:
        @staticmethod
        def sharedWorkspace():
            if mode == "raises":
                raise RuntimeError("synthetic: no workspace")
            return Workspace()

    m = types.ModuleType("AppKit")
    m.NSWorkspace = NSWorkspace
    return m


class _Brain:
    """Replaces the backends and records bumps; `head` marks where process_command's head ends."""

    def __init__(self, J):
        self.J = J
        self.bumps, self.head, self.captured, self.spoken = [], None, [], []
        self.reply, self.fail, self.text = None, False, None
        orig_bump, orig_backend = J.research_bump, J._set_backend

        def bump(key, n=1):
            self.bumps.append([key, n])
            return orig_bump(key, n)

        def set_backend(name):
            self._mark()
            return orig_backend(name)

        def claude(sys_prompt, user_text, hud=None):
            assert user_text == self.text, (user_text, self.text)
            self._mark()
            self.captured.append(sys_prompt)
            return self.reply

        def ollama(payload, timeout=120):
            self._mark()
            self.captured.append(payload["messages"][0]["content"])
            if self.fail:
                raise RuntimeError("synthetic brain failure")
            return iter([{"message": {"role": "assistant", "content": self.reply}, "done": True}])

        J.research_bump = bump
        J._set_backend = set_backend
        J.claude_generate = claude
        J.ollama_stream_chat = ollama
        J.speak = lambda text, *a, **k: self.spoken.append(text)
        J.CLAUDE_ENABLED = True

    def _mark(self):
        if self.head is None:
            self.head = len(self.bumps)

    def start(self, text=None, reply=None, fail=False):
        self.bumps, self.head, self.captured = [], None, []
        self.text, self.reply, self.fail = text, reply, fail


# ─── Scenario steps (inputs only; every expected value comes from jarvis.py) ────

def T(text, at, online=True, front=("app", "Xcode"), reply=None, fail=False, raw=False):
    """A turn. raw=True: `text` is what STT heard; _apply_corrections runs first."""
    s = {"op": "turn", "at": at, "online": online, "front": {"mode": front[0], "name": front[1]},
         "fail": fail}
    s["raw" if raw else "text"] = text
    if reply is not None:
        s["reply"] = reply
    return s


def TONE(desc, at): return {"op": "tone", "at": at, "desc": desc}
def LEARN(text, at): return {"op": "learn", "at": at, "text": text}
def FORGET(text, at): return {"op": "forget", "at": at, "text": text}
def KB(topic, summary, at): return {"op": "kb", "at": at, "topic": topic, "summary": summary}
def NOTE(note, at): return {"op": "note", "at": at, "note": note}
def REWRITE(core, at): return {"op": "rewrite", "at": at, "core": core}
def RESTART(at): return {"op": "restart", "at": at}


_LONG_SUMMARY = ("Tidal locking happens when a moon's rotation period matches its orbital "
                 "period, so the same face always points at its planet. Tidal forces raise a "
                 "bulge that lags or leads the line between the bodies; the resulting torque "
                 "slows the spin until the bulge stays aligned. Most large moons in the solar "
                 "system are locked, and many close-in exoplanets are thought to be too, which "
                 "gives them a permanent day side and night side.")


def _seeded_files():
    t = _T0
    personality = {
        "core": ["You are JARVIS, a dry and loyal assistant.",
                 "Keep replies short and spoken.",
                 "Language: mild, never crude."],
        "learned": [{"note": f"Synthetic style note number {k:02d}", "at": t - 86400 + k}
                    for k in range(10)],
        "consolidated_at": t - 3 * 86400,
        "extra_key": "kept as is",
    }
    emotions = {"mood": 0.31, "energy": 0.95, "warmth": 0.52, "patience": 0.2, "at": t - 5400.5}
    facts = {f"fact {k:02d}": {"value": f"value {k:02d}", "updated": t - 1000 + (k // 2)}
             for k in range(13)}
    facts["name"] = {"value": "Morgan", "updated": t - 5000}
    knowledge = {
        "topics": {f"topic {k}": {"summary": f"Synthetic summary {k} " + "x" * (30 * k),
                                  "updated": t - 600 + (k % 3)} for k in range(6)},
        "queue": [f"queued question {k}" for k in range(30)],
    }
    corrections = [{"heard": "organ", "meant": "Morgan", "added": t - 100.5},
                   {"heard": "jar vis", "meant": "jarvis", "added": t - 90.25},
                   {"heard": "no", "meant": "too short to apply", "added": t - 80}]
    history = [{"role": "user", "content": "earlier question one"},
               {"role": "assistant", "content": "Earlier answer one, sir."},
               {"role": "tool", "content": "a tool result", "tool_name": "get_time"},
               {"role": "user", "content": "  earlier question two  ", "extra": 1},
               {"role": "assistant", "content": None},
               {"role": "system", "content": "dropped on load"},
               "not a dict"]
    history += [{"role": "user" if k % 2 == 0 else "assistant", "content": f"older turn {k}"}
                for k in range(8)]
    return {
        "personality.json": json.dumps(personality, indent=1).encode(),
        "emotions.json": json.dumps(emotions, indent=1).encode(),
        "profile.json": json.dumps({"facts": facts}, indent=1).encode(),
        "knowledge.json": json.dumps(knowledge, indent=1).encode(),
        "corrections.json": json.dumps(corrections, indent=1).encode(),
        "history.json": json.dumps(history).encode(),
    }


def _long_history_steps():
    steps = []
    at = 0.0
    for k in range(15):
        online = k % 3 != 1
        steps.append(T(f"question number {k} about the garden planner", at, online=online,
                       reply=f"Answer {k}, sir." if k % 4 else f"Answer {k}, sir.  Anything else?",
                       fail=(k == 7)))
        at += 45.5
        if k == 10:
            steps.append(RESTART(at))
            at += 1
    return steps


def _scenarios():
    apps = [("app", "Xcode"), ("app", "Finder"), ("app", "JARVIS"), ("app", "loginwindow"),
            ("no_app", ""), ("nil_name", ""), ("app", "Música"), ("app", "Visual Studio Code"),
            ("raises", ""), ("app", "FINDER"), ("app", "Terminal")]
    return [
        ("fresh", {}, [
            T("what's the weather like today", 0),
            T("what's the weather like today", 5, online=False),
            T("thanks", 60, online=False, front=("app", "Finder")),
        ]),
        ("style_notes", {}, [
            T("be a bit more sarcastic", 0),
            T("tone down the puns", 20, online=False),
            T("no swearing please", 40),
            T("you can swear now", 60),
            T("i hate it when you repeat yourself", 80, online=False),
            T("i love it when you quote old films", 100),
            T("stop calling me sir", 120),
            T("dial up the wit", 140),
            T("sound less formal", 160, online=False),
            T("talk more like a butler", 180),
            NOTE("Keep weather answers to one line", 200),
            NOTE("short", 205),
            T("mind your language", 220),
            REWRITE("You are JARVIS.\n- Calm and precise.\n• Warm but brief.", 225),
            T("how do I sound now", 230, online=False),
            T("forget your style notes", 240),
            T("how do I sound now", 260),
        ]),
        ("emotions", {}, [
            T("you are completely useless", 0),
            T("you're so stupid", 30, online=False),
            T("brilliant, well done", 600),
            T("cheers for that", 1200, online=False),
            T("status report", 1200 + 3 * 3600),
            T("shut up", 1200 + 3 * 3600 + 10),
            T("good job, you stupid machine", 1200 + 3 * 3600 + 20, online=False),
            T("how are you feeling", 2 * 86400),
        ]),
        ("tone_window", {}, [
            TONE("hurried and tense", 0),
            T("quick, open my calendar", 30),
            T("and the notes app", 90, online=False),
            T("thanks", 90.5),
            TONE("clipped, possibly irritated", 100),
            T("again", 150),
            TONE("", 160),
            T("hello", 170, online=False),
            TONE("animated and upbeat", 200),
            TONE("quiet and subdued", 210),
            TONE("calm and even", 220),
            T("goodnight", 230),
        ]),
        ("profile_facts", {}, [
            T("my name is Robin", 0),
            T("I'm working on a garden planner app", 20),
            T("I prefer tea over coffee", 40, online=False),
            T("my favourite colour is teal", 60),
            T("remember that the team meeting moved to Friday", 80),
            T("I am a night owl", 100, online=False),
            T("what do you know about me", 120, online=False),
            T("forget my favourite colour", 140),
            T("forget about my name", 160),
            T("what do you know about me", 180),
            T("forget everything about me", 200, online=False),
            T("what do you know about me", 220),
        ]),
        ("kb_lookup", {}, [
            KB("sourdough starter", "A sourdough starter is a fermented mix of flour and water "
               "that leavens bread.", 0),
            KB("rust borrow checker", "The borrow checker enforces that references never "
               "outlive the data they point to.", 10),
            KB("tidal locking", _LONG_SUMMARY, 20),
            T("tell me about the sourdough starter", 30, online=False),
            T("tell me about the sourdough starter", 35),
            T("explain tidal locking again", 60, online=False),
            T("what is quantum tunnelling", 90, online=False),
            T("the and of", 120, online=False),
            KB("sourdough starter", "Updated: feed the starter daily.", 130),
            T("sourdough", 140, online=False),
            KB("", "an empty topic is skipped", 150),
            T("Rust Borrow Checker", 160, online=False),
        ]),
        ("corrections", {}, [
            LEARN("I said Morgan not organ", 0),
            T("tell organ the plan is ready", 10, raw=True),
            T("organ", 20, raw=True, online=False),
            LEARN("correct jarvus to jarvis", 30),
            T("hey jarvus what time is it", 40, raw=True),
            T("I said Morgan not organ", 50, raw=True, online=False),
            RESTART(60),
            T("ask organ about the jarvus build", 70, raw=True),
            FORGET("forget the correction for organ", 80),
            T("tell organ hello", 90, raw=True, online=False),
            LEARN("when i say robbin i mean Robin", 95),
            T("robbin", 100, raw=True),
            FORGET("forget all corrections", 110),
            T("ask jarvus again", 120, raw=True),
        ]),
        ("rephrase_feedback", {}, [
            T("play some jazz", 0),
            T("play some jazz music", 10, online=False),
            T("play some jazz music", 20),
            T("play some jazz musik", 55),
            T("no, I said the other playlist", 60, online=False),
            T("never mind", 65),
            T("play some calm piano", 66),
            T("play some calm piano now", 95.75, online=False),
            T("play some calm piano now please", 125.75),
            T("that's wrong", 200),
        ]),
        ("long_history", {}, _long_history_steps()),
        ("unicode", {}, [
            T("I don\u2019t like it when you ramble", 0, front=("app", "M\u00fasica")),
            T("I don't like it when you ramble", 10),
            T("my name\u2019s R\u00f6bin", 20, online=False),
            T("my name is R\u00f6bin", 30),
            T("it\u2019s brilliant, thank you", 40),
            T("play \U0001F3B5 something mellow", 50, online=False),
            T("\u039f\u0394\u039f\u03a3 means road", 60),
            T("Cafe\u0301 au lait please", 70, online=False),
            T("remember that the caf\u00e9 opens at 8\u00a0am", 80),
            T("I\u2019m a keen cyclist", 90),
            T("I'm a keen cyclist", 100, online=False),
            T("call me Sam from now on", 110),
            T("\u65e5\u672c\u8a9e\u3067\u8a71\u3057\u3066", 120),
            T("\u201cquoted\u201d words \u2014 and a dash", 130, online=False),
            T("  padded\tline\r\nwith breaks  ", 140),
        ]),
        ("front_apps", {}, [T(f"front app check {k}", 100 * k, online=k % 2 == 0, front=a)
                            for k, a in enumerate(apps)]),
        ("seeded_state", _seeded_files(), [
            T("good morning", 0),
            T("what's on today", 20, online=False),
            T("remind organ about topic 3", 40, raw=True, online=False),
            T("tell me about topic 5", 60, online=False),
            T("thank you", 80),
        ]),
    ]


# ─── Runner ─────────────────────────────────────────────────────────────────────

def _reset(J):
    J._history = []
    J._corr_cache = None
    J.LAST_TONE["desc"], J.LAST_TONE["at"] = "", 0.0
    J._LAST_CMD["text"], J._LAST_CMD["at"] = "", 0.0


def _run_step(ctx, brain, s):
    J = ctx.J
    now = _T0 + s["at"]
    ctx.at(now)
    op = s["op"]
    out = {}
    if op == "turn":
        sys.modules["AppKit"] = _fake_appkit(s["front"]["mode"], s["front"]["name"])
        out["front_app"] = J._front_app()
        text = J._apply_corrections(s["raw"]) if "raw" in s else s["text"]
        reply = s.get("reply", f"Certainly, sir ({s['at']:g}).")
        brain.start(text=text, reply=reply, fail=s["fail"])
        result = J.process_command(text, s["online"])
        assert len(brain.captured) == 1, brain.captured
        head = brain.head if brain.head is not None else len(brain.bumps)
        assert all(k.startswith("backend_") for k, _ in brain.bumps[head:]), brain.bumps
        if s["fail"]:
            assert not J._history or J._history[-1].get("role") != "user" or \
                J._history[-1].get("content") != text
        else:
            assert J._history[-1] == {"role": "assistant", "content": result}, J._history[-1:]
        if "raw" in s:
            out["text"] = text
        out.update({"captured_system": brain.captured[0], "reply": result,
                    "bumps": brain.bumps[:head], "brain_bumps": brain.bumps[head:]})
    else:
        brain.start()
        if op == "tone":
            r = J.set_tone(s["desc"])
        elif op == "learn":
            r = J.learn_correction(s["text"])
        elif op == "forget":
            r = J.forget_correction(s["text"])
        elif op == "kb":
            r = J.kb_remember(s["topic"], s["summary"])
        elif op == "note":
            r = J.personality_note_tool(s["note"])
        elif op == "rewrite":
            r = J.personality_rewrite_tool(s["core"])
        elif op == "restart":
            _reset(J)
            J._history = J._history_load()
            r = None
        else:
            raise AssertionError(op)
        out.update({"result": r, "bumps": brain.bumps})
    out["files_after"] = _files(J)
    # Module state CoreState answers for (read after the files: none of these writes).
    out["module_state"] = {"history_len": len(J._history),
                           "corrections_len": len(J._corrections_load()),
                           "whisper_prompt": J._whisper_prompt()}
    return out


@suite("m1_prompt", fixture="m1_prompt.golden.json", epoch=_T0)
def prompt_suite(ctx):
    J = ctx.J
    cases = [_system_prompt_case(ctx)]
    real_appkit = sys.modules.get("AppKit")
    brain = _Brain(J)
    try:
        for name, before, steps in _scenarios():
            _reset(J)
            for fname, const in _FILES.items():
                path = getattr(J, const)
                if fname in before:
                    with open(path, "wb") as f:
                        f.write(before[fname])
                else:
                    try:
                        os.remove(path)
                    except FileNotFoundError:
                        pass
            J._history = J._history_load()      # what import does with the starting file
            results = [_run_step(ctx, brain, s) for s in steps]
            cases.append({
                "name": f"scenario/{name}",
                "input": {"kind": "scenario",
                          "files_before": {f: _b64(before.get(f)) for f in _FILES},
                          "steps": [{**s, "now": _f(_T0 + s["at"])} for s in steps]},
                "expected": {"whisper_base": J.WHISPER_PROMPT, "steps": results},
            })
    finally:
        if real_appkit is None:
            sys.modules.pop("AppKit", None)
        else:
            sys.modules["AppKit"] = real_appkit
    return cases
