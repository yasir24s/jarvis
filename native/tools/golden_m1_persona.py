"""M1 T7/T8 golden suites (plan: native/plan/M01 §2.2, §2.3, §2.6, §4.1, §6 T7/T8).

    m1_personality     personality_load / _learn / _forget / _note_tool / _rewrite_tool /
                       _context and maybe_learn_personality, plus the literal tables they use

Plugin for tools/golden.py. Every case but the literal tables is a SCENARIO run through the
real jarvis.py functions: `input.files_before` holds the state files' starting bytes (base64;
null = absent), `input.steps` a list of {op, args, now}. `expected.steps` holds, per step,
`result` ({"value": …} | {"json": text} | {"raises": ExceptionName}), `bumps` (every
research_bump call, in order, as [key, n]) and `files_after` (the bytes on disk afterwards,
base64 or null). maybe_learn steps also record `action`: the personality_learn /
personality_forget call maybe_learn_personality made (seen by wrapping the module globals).

Times and float arguments travel as {"repr", "bits"}, so the fixture parse never decides a
value. State contents are SYNTHETIC (never real notes). Literals are read from ctx.J.
"""
import base64
import json
import os
import struct

from golden import suite

_T0 = 1790582400.123456          # a time.time()-like epoch with microseconds


def _f(x):
    return {"repr": repr(x), "bits": "%016x" % struct.unpack("<Q", struct.pack("<d", x))[0]}


def _b64(data):
    return None if data is None else base64.b64encode(data).decode("ascii")


def _dump(obj):
    """Bytes as Python's own indent=1 writers put them on disk."""
    return json.dumps(obj, indent=1).encode("ascii")


# ─── Scenario runner ─────────────────────────────────────────────────────────────

class _Recorder:
    def __init__(self, J):
        self.calls = []
        self.orig = J.research_bump

        def bump(key, n=1):
            self.calls.append([key, n])
            return self.orig(key, n)
        J.research_bump = bump


def _paths(J):
    return {"personality.json": J.PERSONALITY_FILE, "emotions.json": J.EMOTIONS_FILE}


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _scenario(ctx, rec, ops, name, before, steps, files):
    """before: {file: bytes|None}; steps: [(op, args, now)]."""
    J = ctx.J
    ctx.reset()
    J.LAST_TONE["desc"], J.LAST_TONE["at"] = "", 0.0
    paths = _paths(J)
    for f in files:
        if os.path.exists(paths[f]):
            os.remove(paths[f])
        if before.get(f) is not None:
            with open(paths[f], "wb") as fh:
                fh.write(before[f])
    out = []
    for op, args, now in steps:
        ctx.at(now)
        rec.calls.clear()
        step = {}
        try:
            step["result"] = ops[op](step, **args)
        except Exception as e:                       # Python raises mid-turn (M01 §8 R8)
            step["result"] = {"raises": type(e).__name__}
        step["bumps"] = list(rec.calls)
        step["files_after"] = {f: _b64(_read(paths[f])) for f in files}
        out.append(step)
    return {"name": name,
            "input": {"files_before": {f: _b64(before.get(f)) for f in files},
                      "steps": [{"op": op, "args": _wire_args(args), "now": _f(float(now))}
                                for op, args, now in steps]},
            "expected": {"steps": out}}


def _wire_args(args):
    return {k: (_f(v) if isinstance(v, float) else v) for k, v in args.items()}


# ─── m1_personality ──────────────────────────────────────────────────────────────

_CORE = ["Synthetic trait alpha: calm and exact.",
         "Synthetic trait beta — dry, never cruel.",
         "Synthetic trait gamma: brief by default."]


def _notes(n, t0=_T0 - 86400.0, stem="Synthetic style note number"):
    return [{"note": f"{stem} {i:02d} about delivery", "added": t0 + i * 0.25} for i in range(n)]


def _pfile(core=_CORE, learned=None, **extra):
    d = {"core": core, "learned": _notes(2) if learned is None else learned}
    d.update(extra)
    return {"personality.json": _dump(d)}


def _personality_ops(J):
    def maybe_learn(step, text):
        calls = []
        learn, forget = J.personality_learn, J.personality_forget

        def rec_learn(note):
            calls.append({"action": "learn", "note": note})
            return learn(note)

        def rec_forget():
            calls.append({"action": "factory_reset"})
            return forget()
        J.personality_learn, J.personality_forget = rec_learn, rec_forget
        try:
            step["action"] = None
            J.maybe_learn_personality(text)
        finally:
            J.personality_learn, J.personality_forget = learn, forget
            step["action"] = calls[0] if calls else None
        return {"value": None}

    return {
        "load": lambda step: {"json": json.dumps(J.personality_load(), indent=1)},
        "learn": lambda step, note: {"value": J.personality_learn(note)},
        "forget": lambda step: {"value": J.personality_forget()},
        "note_tool": lambda step, note: {"value": J.personality_note_tool(note)},
        "rewrite_tool": lambda step, core: {"value": J.personality_rewrite_tool(core)},
        "context": lambda step: {"value": J.personality_context()},
        "maybe_learn": maybe_learn,
    }


# Every _STYLE_PATTERNS alternative, the forget RE, near misses, case, whitespace, curly quotes.
_STYLE_TEXTS = [
    # row 1: be/act/sound/talk (a bit|a little)? more|less (like)? …
    "be more sarcastic", "Please act a bit more like a butler, please.",
    "could you sound a little less formal.", "talk more like Tony Stark would",
    "BE LESS WORDY", "be\tmore\nconcise", "act less like", "be more direct . .",
    "maybe more tea", "being more careful", "be more ok", "talk a bit more",
    "be more ‘fun’", "sound more like a very very very very long winded narrator of epic sagas",
    # row 2: tone down / dial down / ease up on / drop / cut the …
    "tone down the sarcasm", "Dial down the wit please", "ease up on the jokes",
    "drop the attitude", "cut the crap, mate", "drop them", "cut thesarcasm",
    "shortcut the chatter", "tone down the ab",
    # row 3: tone up / dial up / turn up the …
    "turn up the charm", "dial up the wit", "Tone up the humour!", "turn up",
    # row 4: stop calling me …
    "stop calling me sir", "Stop calling me Mr Stark!", "stop calling me x",
    # row 5: call me … instead|from now on
    "call me boss instead", "Call me Captain from now on", "Call me Ishmael",
    "stop calling me sir, call me boss instead",
    # row 6: profanity OFF
    "no swearing please", "Stop swearing!", "watch your language", "MIND YOUR LANGUAGE",
    "no profanity", "clean it up", "no swearingly", "clean it upstairs",
    # row 7: profanity ON
    "you can swear", "You may curse now", "you can cuss", "swearing is fine", "swearing is ok",
    "swearing is okay", "swearing is allowed", "you can't swear", "swearing is okayish",
    "watch your language, actually you can swear",
    # row 8: i hate / don't like (it )?when you …
    "I hate it when you repeat yourself", "i dont like when you mumble.",
    "I don't like it when you interrupt me", "I don’t like it when you interrupt me",
    "i hate when you\nrepeat the same line", "I hate it when you pause\rand restart",
    "i hate it when you ramble on and on about nothing in particular for ages and ages and ages",
    "i hate it when you no",
    # row 9: i love / like (it )?when you …
    "I love it when you quote the movies", "i like when you keep it short",
    "I'd like when you are brief", "I LIKE IT WHEN YOU SWEAR",
    # the forget RE (a factory reset)
    "reset your personality", "Forget your style notes", "forget your personality tweaks",
    "please forget your style adjustments now", "reset your personality's quirks",
    "reset your personalityx", "forget your notes",
    # nothing
    "", "   \t  ", "what's the weather like", "be", "call me",
]


def _personality_cases(ctx, rec):
    J = ctx.J
    ops = _personality_ops(J)
    P = ("personality.json",)
    T = _T0
    cases = []

    def sc(name, before, steps):
        cases.append(_scenario(ctx, rec, ops, name, before, steps, P))

    # The literal tables, compared field by field by the Swift test.
    cases.append({"name": "literals", "input": {},
                  "expected": {"seed_json": json.dumps(J._PERSONALITY_SEED, indent=1),
                               "forget_re": {"pattern": J._PERSONALITY_FORGET_RE.pattern,
                                             "ignorecase": bool(J._PERSONALITY_FORGET_RE.flags & 2)},
                               "style_patterns": [{"pattern": p.pattern,
                                                   "ignorecase": bool(p.flags & 2),
                                                   "template": t}
                                                  for p, t in J._STYLE_PATTERNS]}})

    # ── Loads (each followed by a context build) ──
    loads = [
        ("load_missing", {}),
        ("load_corrupt", {"personality.json": b'{"core": ["half'}),
        ("load_empty_file", {"personality.json": b""}),
        ("load_bom", {"personality.json": b"\xef\xbb\xbf" + _dump({"core": _CORE, "learned": []})}),
        ("load_not_dict", {"personality.json": b"[1, 2, 3]"}),
        ("load_core_empty", _pfile(core=[])),
        ("load_core_null", _pfile(core=None)),
        ("load_core_zero", _pfile(core=0)),
        ("load_core_string", _pfile(core="abc", learned=[])),
        ("load_core_dict", {"personality.json": _dump({"core": {"k one": 1, "k two": 2}})}),
        ("load_core_nonstr", _pfile(core=["fine", 5])),
        ("load_missing_learned", {"personality.json": _dump({"core": _CORE})}),
        ("load_extra_keys", _pfile(learned=_notes(3), consolidated_at=1790000000.5,
                                   unknown_future_key={"nested": [1, -0.0, 1e-07, 1e16, None, True]})),
        ("load_learned_null", {"personality.json": _dump({"core": _CORE, "learned": None})}),
        ("load_learned_empty_string", {"personality.json": _dump({"core": _CORE, "learned": ""})}),
        ("load_learned_string", {"personality.json": _dump({"core": _CORE, "learned": "abc"})}),
        ("load_learned_empty_dict", {"personality.json": _dump({"core": _CORE, "learned": {}})}),
        ("load_note_missing", _pfile(learned=_notes(2) + [{"added": 1.5}])),
        ("load_note_missing_outside_last8", _pfile(learned=[{"added": 1.5}] + _notes(8))),
        ("load_note_not_str", _pfile(learned=[{"note": 5, "added": 1.0}])),
        ("load_entry_not_dict", _pfile(learned=["a bare string entry"])),
        ("load_float_edges", _pfile(learned=[
            {"note": "Float edge note one", "added": 0.6000000000000001},
            {"note": "Float edge note two", "added": 1e16},
            {"note": "Float edge note three", "added": 1e-07},
            {"note": "Float edge note four", "added": -0.0},
            {"note": "Float edge note five", "added": 1790582400.1234567},
            {"note": "Float edge note six", "added": 1790582400},
            {"note": "Café “quoted” \U0001F600 note", "added": 5e-324}])),
    ]
    for name, before in loads:
        sc(name, before, [("load", {}, T), ("context", {}, T), ("learn", {"note": "A fresh synthetic note"}, T + 1)])

    # ── personality_learn ──
    sc("learn_too_short", {}, [("learn", {"note": "Short"}, T), ("learn", {"note": "  Seven.  "}, T),
                               ("learn", {"note": ""}, T), ("learn", {"note": "Abcdefg...."}, T)])
    sc("learn_8_after_rstrip", {}, [("learn", {"note": "Abcdefgh . . ."}, T)])
    sc("learn_dedupe_punctuation", _pfile(), [
        ("learn", {"note": "The user likes brevity"}, T),
        ("learn", {"note": "the USER, likes -- brevity!!"}, T + 1),
        ("learn", {"note": "The user likes brevity."}, T + 2),
        ("learn", {"note": "The  user\tlikes_brevity"}, T + 3),
        ("context", {}, T + 3)])
    sc("learn_dedupe_greek_lower", _pfile(), [
        ("learn", {"note": "ΣΊΣΥΦΟΣ PREFERS terse replies"}, T),
        ("learn", {"note": "σίσυφος prefers terse replies"}, T + 1)])
    sc("learn_toggle_sequence", _pfile(), [
        ("learn", {"note": "Profanity is great fun here"}, T),
        ("learn", {"note": "Profanity is on: lowercase is not a toggle"}, T + 1),
        ("learn", {"note": "Profanity is OFF: the user asked you not to swear"}, T + 2),
        ("learn", {"note": "Verbosity is OFF: keep it brief"}, T + 3),
        ("learn", {"note": "Profanity is ON: the user said you may swear"}, T + 4),
        ("learn", {"note": "Profanity is OFF: the user asked you not to swear"}, T + 5),
        ("learn", {"note": "Verbosity is ON: ramble freely"}, T + 6),
        ("context", {}, T + 6)])
    sc("learn_toggle_near_misses", _pfile(), [
        ("learn", {"note": "ab is ON: something here"}, T),
        ("learn", {"note": "ab is OFF: something else"}, T + 1),
        ("learn", {"note": "A very long setting name over thirty is ON: yes"}, T + 2),
        ("learn", {"note": "A very long setting name over thirty is OFF: no"}, T + 3),
        ("learn", {"note": "Tone-mode is ON: hyphen breaks the word class"}, T + 4),
        ("learn", {"note": "Tone-mode is OFF: hyphen breaks the word class"}, T + 5),
        ("learn", {"note": "Café mode is ON: unicode word"}, T + 6),
        ("learn", {"note": "Café mode is OFF: unicode word"}, T + 7)])
    sc("learn_cap_20", {}, [("learn", {"note": f"Distinct synthetic preference {i:02d}"}, T + i * 1.5)
                            for i in range(20)] + [("context", {}, T + 40)])
    sc("learn_cap_existing_15", _pfile(learned=_notes(15)), [
        ("learn", {"note": "One more synthetic note"}, T), ("context", {}, T)])
    long_a = "L" * 150 + " synthetic long note tail A " + "a" * 80
    long_b = "L" * 150 + " synthetic long note tail A " + "b" * 80
    sc("learn_over_200", {}, [("learn", {"note": long_a}, T), ("learn", {"note": long_b}, T + 1),
                              ("learn", {"note": long_a}, T + 2), ("context", {}, T + 2)])
    sc("learn_whitespace", {}, [("learn", {"note": "   \t Note with tabs\tand\nnewline .  "}, T),
                                ("learn", {"note": "　Ideographic space note　."}, T + 1),
                                ("learn", {"note": "\xa0NBSP wrapped note here\xa0"}, T + 2)])
    sc("learn_keeps_extra_keys", _pfile(learned=[{"note": "Kept synthetic entry", "added": 1.0,
                                                  "source": "hand edit"}],
                                        consolidated_at=1790000000.25, unknown={"x": [1, 2]}),
       [("learn", {"note": "Another synthetic entry"}, T)])
    sc("learn_corrupt_file", {"personality.json": b"not json"},
       [("learn", {"note": "A note over a corrupt file"}, T)])
    sc("learn_time_fraction", {}, [("learn", {"note": "Fractional time synthetic note"}, 1790582400.1),
                                   ("learn", {"note": "Second fractional synthetic note"}, 1790582400.3)])

    # ── personality_forget ──
    sc("forget_with_state", _pfile(learned=_notes(5), consolidated_at=1790000000.5, unknown=True),
       [("forget", {}, T), ("context", {}, T)])
    sc("forget_missing", {}, [("forget", {}, T)])
    sc("forget_corrupt", {"personality.json": b"{"}, [("forget", {}, T)])

    # ── personality_note_tool ──
    sc("note_tool", _pfile(), [
        ("note_tool", {"note": "short"}, T),
        ("note_tool", {"note": "   Abcdefg   "}, T),
        ("note_tool", {"note": "Abcdefg."}, T),
        ("note_tool", {"note": "The user wants shorter answers."}, T + 1),
        ("note_tool", {"note": ""}, T + 2)])
    sc("note_tool_bad_entry", _pfile(learned=[{"added": 2.0}]),
       [("note_tool", {"note": "A perfectly fine note"}, T)])

    # ── personality_rewrite_tool ──
    lines = [f"Synthetic rewritten trait {i}" for i in range(13)]
    rewrites = [
        ("rewrite_2_lines", "\n".join(lines[:2])),
        ("rewrite_3_lines", "\n".join(lines[:3])),
        ("rewrite_12_lines", "\n".join(lines[:12])),
        ("rewrite_13_lines", "\n".join(lines[:13])),
        ("rewrite_empty", ""),
        ("rewrite_bullets", "- trait one\n• trait two\n-•- trait three.\n  *star kept*\n-"),
        ("rewrite_blank_lines", "\n\n  \n trait a \n\t\n trait b.\n trait c...\n..."),
        ("rewrite_crlf", "a trait\r\nb trait\r\nc trait\r\n"),
        ("rewrite_line_breaks", "one two\x0bthree\x0cfour\x1cfive\x85six\rseven"),
        ("rewrite_301_char_line", "x" * 301 + "\n" + "y" * 299 + "\n" + "z" * 300 + ".."),
        ("rewrite_unicode", "Café — trait\n•• bullet twice\n  　ideographic　"),
    ]
    for name, core in rewrites:
        sc(name, _pfile(learned=_notes(2), consolidated_at=1790000000.5),
           [("rewrite_tool", {"core": core}, T), ("context", {}, T)])
    sc("rewrite_missing_file", {}, [("rewrite_tool", {"core": "\n".join(lines[:4])}, T)])
    sc("rewrite_corrupt_file", {"personality.json": b"[}"}, [("rewrite_tool", {"core": "\n".join(lines[:4])}, T)])

    # ── personality_context ──
    for n in (0, 1, 8, 9):
        sc(f"context_{n}_notes", _pfile(learned=_notes(n)), [("context", {}, T)])
    sc("context_seed", {}, [("context", {}, T)])
    sc("context_unicode", _pfile(learned=[{"note": "Café “note” \U0001F600 Σ", "added": 1.0}]),
       [("context", {}, T)])

    # ── maybe_learn_personality ──
    base = _pfile(learned=_notes(2))
    for k, text in enumerate(_STYLE_TEXTS):
        sc(f"style_{k:02d}", base, [("maybe_learn", {"text": text}, T)])
    sc("style_profanity_on_off_on", base, [
        ("maybe_learn", {"text": "you can swear"}, T),
        ("maybe_learn", {"text": "no swearing"}, T + 1),
        ("maybe_learn", {"text": "swearing is fine"}, T + 2),
        ("context", {}, T + 2)])
    sc("style_forget_populated", _pfile(learned=_notes(9), consolidated_at=1790000000.5), [
        ("maybe_learn", {"text": "Reset your personality, please"}, T), ("context", {}, T)])
    sc("style_bad_entry", _pfile(learned=[{"added": 2.0}]), [
        ("maybe_learn", {"text": "be more sarcastic"}, T)])
    return cases


@suite("m1_personality")
def personality(ctx):
    rec = _Recorder(ctx.J)
    return _personality_cases(ctx, rec)
