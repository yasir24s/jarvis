"""M1 T3 golden suite: m1_state_styles (plan: native/plan/M01 §2.1, §3.5, §6 T3).

Plugin for tools/golden.py. Each case is one state file as Python's REAL writer puts it on
disk: the suite calls kb_save / _history_save / _corrections_save / profile_save /
personality_save / _emotions_save / _alarms_save on a synthetic value (no real content) and
reads back the bytes it wrote. proactive.json has no writer function (proactive_loop writes
it inline), so its case runs that one statement, `json.dump(st, f)`, verbatim.

The Swift StateStore tests use each case three ways: StateFile.indent must equal the style
Python used; saving `input.value` must produce `expected.text` byte for byte; and loading
`expected.text` then saving it unchanged must reproduce it byte for byte.
"""
import json

from golden import suite

_T = 1790582400.123456          # an epoch with microseconds, like time.time()


def _values():
    """(case name, file, writer name, value) — synthetic values in each file's schema."""
    kb = {"topics": {"synthetic topic alpha": {"summary": "A made-up summary. " * 4,
                                               "updated": _T},
                     "café synthèse": {"summary": "naïve — “q” \U0001F600 \\ \" /",
                                                "updated": 1790582400.0}},
          "queue": ["queued topic one", "queued topic two"]}
    history = [{"role": "user", "content": "what is the synthetic weather"},
               {"role": "assistant", "content": "Synthetic, sir.\nLine two\t\"quoted\" é"},
               {"role": "user", "content": "extra keys survive", "extra": [1, 2.5, None, True]}]
    corrections = [{"heard": "jar this", "meant": "jarvis", "added": _T},
                   {"heard": "no ted", "meant": "noted", "added": 1790582405.0}]
    profile = {"facts": {"favourite synthetic colour": {"value": "teal", "updated": _T},
                         "synthetic city": {"value": "Nowhére", "updated": 1.7905824e9}}}
    personality = {"core": ["Synthetic core trait one.", "Synthetic core trait two."],
                   "learned": [{"note": "Prefers synthetic brevity.", "added": _T},
                               {"note": "Likes made-up jokes.", "added": _T + 0.5}],
                   "consolidated_at": 1790582000.125,
                   "unknown_future_key": {"nested": [1, -0.0, 1e-07, 1e+16, None, False, {}, []]}}
    emotions = {"mood": 0.6000000000000001, "energy": 0.30000000000000004, "warmth": 0.7,
                "patience": 0.8, "at": _T, "unknown_extra": "kept"}
    proactive = {"enroll_reminded": "2026-09-28"}
    alarms = [{"time": "2026-09-28T07:00:00", "label": "synthetic wake"},
              {"time": "2026-09-29T07:30:00.123456", "label": "synthetic stretch",
               "repeat": "daily"},
              {"time": "2026-10-01T18:45:00", "label": "synthetic call", "repeat": "weekdays"}]
    return [("knowledge", "knowledge.json", "kb_save", kb),
            ("knowledge_empty", "knowledge.json", "kb_save", {"topics": {}, "queue": []}),
            ("history", "history.json", "_history_save", history),
            ("corrections", "corrections.json", "_corrections_save", corrections),
            ("profile", "profile.json", "profile_save", profile),
            ("personality", "personality.json", "personality_save", personality),
            ("emotions", "emotions.json", "_emotions_save", emotions),
            ("proactive", "proactive.json", "proactive_loop inline json.dump(st, f)", proactive),
            ("alarms", "alarms.json", "_alarms_save", alarms),
            ("alarms_empty", "alarms.json", "_alarms_save", [])]


def _write(J, writer, value):
    """Runs Python's writer for `value`; returns the path it wrote."""
    if writer == "kb_save":
        J.kb_save(value); return J.KB_FILE
    if writer == "_history_save":
        J._history = list(value); J._history_save(); return J.HIST_FILE
    if writer == "_corrections_save":
        J._corrections_save(list(value)); return J.CORR_FILE
    if writer == "profile_save":
        J.profile_save(value); return J.PROFILE_FILE
    if writer == "personality_save":
        J.personality_save(value); return J.PERSONALITY_FILE
    if writer == "_emotions_save":
        J._emotions_save(value); return J.EMOTIONS_FILE
    if writer.startswith("proactive_loop"):
        with open(J.PROACTIVE_FILE, "w") as f:          # jarvis.py proactive_loop, verbatim
            json.dump(value, f)
        return J.PROACTIVE_FILE
    if writer == "_alarms_save":
        J._alarms_save(value); return J.ALARMS_FILE
    raise ValueError(writer)


def _style(text, value):
    """Which json.dumps style reproduces the writer's bytes: "indent1", "compact", or
    "either" when the value renders the same both ways (an empty list)."""
    matches = [(style, indent) for style, indent in (("indent1", 1), ("compact", None))
               if text == json.dumps(value, indent=indent)]
    if not matches:
        raise AssertionError(f"writer output matches neither json.dumps style: {text[:80]!r}")
    return matches[0] if len(matches) == 1 else ("either", None)


@suite("m1_state_styles")
def state_styles(ctx):
    J = ctx.J
    cases = []
    for name, file, writer, value in _values():
        ctx.reset()
        path = _write(J, writer, value)
        with open(path, "rb") as f:
            text = f.read().decode("ascii")             # ensure_ascii=True: always ASCII
        style, indent = _style(text, value)
        cases.append({"name": name,
                      "input": {"file": file, "writer": writer, "value": value},
                      "expected": {"text": text, "style": style, "indent": indent}})

    # Unknown keys survive a load → modify → save through Python's own personality_load.
    ctx.reset()
    before = _values()[5][3]
    J.personality_save(before)
    with open(J.PERSONALITY_FILE, "rb") as f:
        before_text = f.read().decode("ascii")
    p = J.personality_load()
    note = {"note": "Synthetic appended note — ok.", "added": _T + 60.25}
    p["learned"].append(note)
    J.personality_save(p)
    with open(J.PERSONALITY_FILE, "rb") as f:
        after_text = f.read().decode("ascii")
    cases.append({"name": "personality_append_keeps_unknown_keys",
                  "input": {"file": "personality.json", "before_text": before_text,
                            "append_learned": note},
                  "expected": {"text": after_text}})
    return cases
