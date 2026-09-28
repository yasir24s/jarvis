"""M1 T13 cross-implementation suite (plan: native/plan/M01 §5 A9, §6 T13).

    m1_pickup   Python picks up the state files native wrote (A9), and native picks up the
                files Python wrote

Plugin for tools/golden.py. The fixture holds the scenarios the Swift test drives through
CoreState. Each case has:
  input.files_before   starting state bytes (base64; null = absent), written by the REAL
                       jarvis.py functions (personality_learn, emotion_event, profile_remember,
                       kb_remember, kb_note_topic, _history_save)
  input.read_at        when to read files_before
  input.steps          [{op, args, now}]: CoreState calls (turn, assistant, note_tool, …)
  input.now_end        when to read the files the steps left behind
  expected.python_before   Python's own readings of files_before at read_at (the reverse
                           direction: native must read Python's bytes the same way)

READBACK (the A9 proof): `golden.py readback <dir> m1_pickup`. <dir> holds the state files
native wrote, plus m1_pickup_request.json = {"now": {repr, bits}, "personality_file": native's
PERSONALITY_FILE path, "swift": {readings}}. The files are copied into this child's sandbox
(Python reads the sandbox, never the repo, and never writes <dir>). Python's own loaders then
produce the readings, and each one must equal native's byte for byte:
  personality_context  personality_context(), with this sandbox's PERSONALITY_FILE replaced by
                       native's path (the context embeds the absolute path)
  emotion_context      emotion_context() at `now` (it loads, decays and SAVES), and
  emotions_after       the emotions.json bytes that save left (base64)
  profile_context      profile_context()
  kb_context           kb_context()
  history_load         json.dumps(_history_load())

Every string is SYNTHETIC; the names are neutral stand-ins.
"""
import base64
import json
import os
import shutil
import struct
from pathlib import Path

from golden import suite

_T0 = 1790582400.25
_REQUEST = "m1_pickup_request.json"
_FILES = ("personality.json", "emotions.json", "profile.json", "knowledge.json", "history.json")


def _f(x):
    return {"repr": repr(x), "bits": "%016x" % struct.unpack("<Q", struct.pack("<d", x))[0]}


def _unf(v):
    x = struct.unpack("<d", struct.pack("<Q", int(v["bits"], 16)))[0]
    assert repr(x) == v["repr"], v
    return x


def _b64(data):
    return None if data is None else base64.b64encode(data).decode("ascii")


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _paths(J):
    return {"personality.json": J.PERSONALITY_FILE, "emotions.json": J.EMOTIONS_FILE,
            "profile.json": J.PROFILE_FILE, "knowledge.json": J.KB_FILE,
            "history.json": J.HIST_FILE}


def _clear(ctx):
    ctx.reset()
    for p in _paths(ctx.J).values():
        if os.path.exists(p):
            os.remove(p)


def _readings(J):
    """The five A9 readings, in a fixed order (emotion_context saves emotions.json)."""
    return {"personality_context": J.personality_context(),
            "emotion_context": J.emotion_context(),
            "emotions_after": _b64(_read(J.EMOTIONS_FILE)),
            "profile_context": J.profile_context(),
            "kb_context": J.kb_context(),
            "history_load": json.dumps(J._history_load())}


def S(op, at, **args):
    return {"op": op, "args": args, "now": _f(float(at))}


def _steps(t):
    """The CoreState scenario: every file-writing path a session takes."""
    m = 60.0
    return [
        S("turn", t, text="hello there, my name is Morgan", online=True),
        S("assistant", t + 1, text="Good evening, Morgan."),
        S("turn", t + 1 * m, text="be a bit more concise please", online=True),
        S("assistant", t + 1 * m + 1, text="Understood."),
        S("turn", t + 2 * m, text="thanks, that was brilliant", online=True),
        S("assistant", t + 2 * m + 1, text="Glad to help."),
        S("turn", t + 3 * m, text="remember that the spare key is in the blue box", online=True),
        S("assistant", t + 3 * m + 1, text="Noted."),
        S("turn", t + 4 * m, text="what do you know about tide tables", online=False),
        S("assistant", t + 4 * m + 1, text="Tides follow the moon."),
        S("note_tool", t + 5 * m, note="Keep weather reports to one sentence."),
        S("kb_remember", t + 6 * m, topic="lighthouse lenses",
          summary="Synthetic summary: a stepped lens focuses a lamp into a beam."),
        S("emotion_event", t + 7 * m, name="insult"),
        S("set_tone", t + 8 * m, desc="tired"),
        S("consolidate", t + 9 * m,
          reply="Keep answers short and exact.\n- Dry humour, never cruel.\nWeather in one sentence."),
        S("distill", t + 10 * m, reply="The user prefers concise replies."),
        S("save_history", t + 10 * m + 5),
    ]


def _seed_files(ctx):
    """Starting state written by jarvis.py itself, three days before the scenario."""
    J = ctx.J
    _clear(ctx)
    t = _T0 - 3 * 86400
    ctx.at(t)
    for i in range(11):
        J.personality_learn(f"Synthetic seeded style note {i:02d} about pacing")
    J.emotion_event("praise")
    ctx.at(t + 3600)
    J.emotion_event("gratitude")
    J.profile_remember("name", "Robin")
    J.profile_remember("current project", "a synthetic garden planner")
    J.kb_remember("tide tables", "Synthetic summary: tides rise and fall roughly twice a day.")
    J.kb_note_topic("tell me about the history of lighthouses")
    J._history = [{"role": "user", "content": "Synthetic opening line."},
                  {"role": "assistant", "content": "Synthetic reply line."}]
    J._history_save()
    files = {f: _read(p) for f, p in _paths(J).items()}
    return files


def _first_diff(a, b):
    i = 0
    while i < min(len(a), len(b)) and a[i] == b[i]:
        i += 1
    return i


def _readback(ctx, directory):
    J = ctx.J
    directory = Path(directory)
    req = json.loads((directory / _REQUEST).read_text(encoding="utf-8"))
    _clear(ctx)
    for f, p in _paths(J).items():
        src = directory / f
        if src.is_file():
            shutil.copyfile(src, p)
    ctx.at(_unf(req["now"]))
    got = _readings(J)
    got["personality_context"] = got["personality_context"].replace(
        J.PERSONALITY_FILE, req["personality_file"])
    swift = req["swift"]
    out = []
    for key in ("personality_context", "emotion_context", "emotions_after", "profile_context",
                "kb_context", "history_load"):
        py, sw = got[key], swift.get(key)
        if py == sw:
            continue
        if not isinstance(sw, str) or not isinstance(py, str):
            out.append(f"{key}: python {type(py).__name__} vs swift {type(sw).__name__}")
            continue
        i = _first_diff(py, sw)
        out.append(f"{key}: differs at char {i} (python {len(py)}, swift {len(sw)}): "
                   f"python {py[max(0, i - 20):i + 40]!r} swift {sw[max(0, i - 20):i + 40]!r}")
    return out



@suite("m1_pickup", readback=_readback)
def pickup_suite(ctx):
    J = ctx.J
    cases = []

    _clear(ctx)
    ctx.at(_T0)
    cases.append({"name": "fresh_start",
                  "input": {"files_before": {f: None for f in _FILES}, "read_at": _f(_T0),
                            "steps": _steps(_T0), "now_end": _f(_T0 + 3600.0)},
                  "expected": {"python_before": _readings(J)}})

    files = _seed_files(ctx)
    for f, p in _paths(J).items():                  # restore the exact seeded bytes, then read
        if os.path.exists(p):
            os.remove(p)
        if files[f] is not None:
            with open(p, "wb") as fh:
                fh.write(files[f])
    ctx.reset()
    ctx.at(_T0 - 86400)
    cases.append({"name": "python_seeded",
                  "input": {"files_before": {f: _b64(files[f]) for f in _FILES},
                            "read_at": _f(_T0 - 86400), "steps": _steps(_T0),
                            "now_end": _f(_T0 + 3600.0)},
                  "expected": {"python_before": _readings(J)}})
    _clear(ctx)
    return cases
