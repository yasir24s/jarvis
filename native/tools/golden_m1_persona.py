"""M1 T7/T8 golden suites (plan: native/plan/M01 §2.2, §2.3, §2.6, §4.1, §6 T7/T8).

    m1_personality     personality_load / _learn / _forget / _note_tool / _rewrite_tool /
                       _context and maybe_learn_personality, plus the literal tables they use
    m1_emotions_tone   _emotions_load / _decay, emotion_event, emotion_react, _emo_word,
                       emotion_context, set_tone, tone_context, plus the literal tables

Plugin for tools/golden.py. Every case but the literal tables is a SCENARIO run through the
real jarvis.py functions: `input.files_before` holds the state files' starting bytes (base64;
null = absent), `input.steps` a list of {op, args, now}. `expected.steps` holds, per step,
`result` ({"value": …} | {"json": text} | {"raises": ExceptionName}), `bumps` (every
research_bump call, in order, as [key, n]) and `files_after` (the bytes on disk afterwards,
base64 or null). maybe_learn steps also record `action`: the personality_learn /
personality_forget call maybe_learn_personality made (seen by wrapping the module globals);
react steps record the emotion_event name emotion_react chose the same way.

Times and float arguments travel as {"repr", "bits"}, so the fixture parse never decides a
value. State contents are SYNTHETIC (never real notes). Literals are read from ctx.J.

A case whose `expected` has a `native` block is a registered divergence: the block says what
native does instead (the Swift test asserts that positively, Python's result as a known issue).
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


# ─── m1_emotions_tone ────────────────────────────────────────────────────────────

_EMO_AT = _T0 - 3600.0


def _efile(**vals):
    d = {"mood": 0.45, "energy": 0.9, "warmth": 0.72, "patience": 0.33, "at": _EMO_AT}
    d.update(vals)
    return {"emotions.json": _dump({k: v for k, v in d.items() if v is not _DROP})}


_DROP = object()


def _tone_descriptors(J):
    """analyze_tone's five possible outputs, read from its source (not retyped)."""
    import inspect
    import re
    return re.findall(r'return "([^"]+)"', inspect.getsource(J.analyze_tone))


def _emotion_ops(J):
    def react(step, text):
        fired = []
        event = J.emotion_event

        def rec(name, mag=1.0):
            fired.append(name)
            return event(name, mag)
        J.emotion_event = rec
        try:
            step["action"] = None
            J.emotion_react(text)
        finally:
            J.emotion_event = event
            step["action"] = fired[0] if fired else None
        return {"value": None}

    def set_last_tone(step, desc, at):
        J.LAST_TONE["desc"], J.LAST_TONE["at"] = desc, at
        return {"value": None}

    return {
        "load": lambda step: {"json": json.dumps(J._emotions_load(), indent=1)},
        "decay": lambda step: {"json": json.dumps(J._emotions_decay(J._emotions_load()), indent=1)},
        "event": lambda step, name, mag=None: {"value": J.emotion_event(name) if mag is None
                                               else J.emotion_event(name, mag)},
        "react": react,
        "word": lambda step, dim, v: {"value": J._emo_word(dim, v)},
        "context": lambda step: {"value": J.emotion_context()},
        "set_tone": lambda step, desc: {"value": J.set_tone(desc)},
        "tone_context": lambda step: {"value": J.tone_context()},
        "set_last_tone": set_last_tone,
    }


_REACT_TEXTS = [
    # praise
    "good job", "Good work, Jarvis", "good one", "well done", "brilliant", "amazing",
    "impressive", "perfect", "nailed it", "love you", "love it", "love that", "you're the best",
    "youre awesome", "you're great", "you're hilarious", "you're good", "BRILLIANT",
    "not brilliant at all",
    # praise near misses
    "goodjob", "imperfect", "perfectly fine", "you’re the best", "love youtube",
    # thanks
    "thanks", "thank you", "cheers", "appreciate it", "appreciate you", "Thanks a lot",
    "THANK YOU",
    # thanks near misses
    "thank", "thankful", "thanksgiving plans", "appreciate that", "cheersome",
    # insults
    "you are useless", "you're useless", "you useless", "you are fucking useless",
    "you're so stupid", "you are absolutely bloody hopeless", "you're an idiot",
    "you are a idiot", "you're dumb", "you're shit", "you're crap", "you're rubbish",
    "you're pathetic", "shut up", "fuck you", "fuck off", "piss off", "stupid machine",
    "dumb robot", "useless assistant", "useless program", "you're so so stupid",
    "YOU ARE USELESS", "the stupid machine froze",
    # insult near misses
    "you're not stupid", "shut upstairs", "youre useless", "you’re useless",
    "you are uselessly slow",
    # precedence: insult > praise > thanks
    "you're brilliant but you're useless", "brilliant, thanks", "thanks for nothing, you useless machine",
    "good job, thank you", "cheers, well done",
    # nothing
    "", "what time is it", "tell me a joke",
]

_WORD_VALUES = [0.0, -0.0, 0.19999999999999998, 0.2, 0.39999999999999997, 0.4,
                0.5999999999999999, 0.6, 0.6000000000000001, 0.7999999999999999, 0.8, 0.9999,
                0.9999999999999999, 1.0, 1.2, -0.1, -0.2, -1.0, 1e300, -1e300, 5e-324,
                float("nan"), float("inf"), float("-inf")]


def _emotion_cases(ctx, rec):
    J = ctx.J
    ops = _emotion_ops(J)
    E = ("emotions.json",)
    T = _T0
    cases = []

    def sc(name, before, steps, native=None):
        c = _scenario(ctx, rec, ops, name, before, steps, E)
        if native:
            c["expected"]["native"] = native
        cases.append(c)

    descs = _tone_descriptors(J)
    cases.append({"name": "literals", "input": {},
                  "expected": {
                      "dims": [{"name": k, "baseline": _f(b), "half": _f(h)}
                               for k, (b, h) in J._EMO_DIMS.items()],
                      "deltas": [{"event": ev, "changes": [{"dim": k, "delta": _f(d)} for k, d in ch.items()]}
                                 for ev, ch in J._EMO_DELTAS.items()],
                      "bands": [{"dim": k, "words": w} for k, w in J._EMO_BANDS.items()],
                      "patterns": {n: {"pattern": getattr(J, n).pattern,
                                       "ignorecase": bool(getattr(J, n).flags & 2)}
                                   for n in ("_EMO_PRAISE_RE", "_EMO_THANKS_RE", "_EMO_INSULT_RE")},
                      "tone_descriptors": descs}})

    # ── Loads: each followed by decay, a context build (which saves) and an event ──
    full = [("load", {}, T), ("decay", {}, T), ("context", {}, T), ("event", {"name": "praise"}, T)]
    crash = full[1:]
    loads = [
        ("load_missing", {}, full),
        ("load_corrupt", {"emotions.json": b'{"mood": 0.5,'}, full),
        ("load_empty_file", {"emotions.json": b""}, full),
        ("load_bom", {"emotions.json": b"\xef\xbb\xbf" + _efile()["emotions.json"]}, full),
        ("load_not_dict", {"emotions.json": b"[1, 2]"}, full),
        ("load_number", {"emotions.json": b"42"}, full),
        ("load_null", {"emotions.json": b"null"}, full),
        ("load_list_of_dims", {"emotions.json": _dump(["mood", "energy", "warmth", "patience"])}, crash),
        ("load_str_of_dims", {"emotions.json": _dump("mood energy warmth patience")}, crash),
        ("load_str_missing_dim", {"emotions.json": _dump("mood energy warmth")}, full),
        ("load_missing_dimension", _efile(patience=_DROP), full),
        ("load_extra_key", _efile(extra_synthetic={"kept": [1, 2.5]}), full),
        ("load_key_order", {"emotions.json": _dump({"at": _EMO_AT, "patience": 0.1, "warmth": 0.2,
                                                    "energy": 0.3, "mood": 0.4})}, full),
        ("load_int_values", _efile(mood=1, energy=0, warmth=1, patience=0, at=1790580000), full),
        ("load_bool_values", _efile(mood=True, energy=False), full),
        ("load_float_edges", _efile(mood=0.6000000000000001, energy=0.30000000000000004,
                                    warmth=1e-07, patience=5e-324), full),
        ("load_at_missing", _efile(at=_DROP), full),
        ("load_at_int", _efile(at=1790582000), full),
        ("load_at_bool", _efile(at=True), full),
        ("load_at_string", _efile(at="yesterday"), full),
        ("load_at_null", _efile(at=None), full),
        ("load_at_nan", _efile(at=float("nan")), full),
        ("load_at_inf", _efile(at=float("inf")), full),
        ("load_at_minus_inf", _efile(at=float("-inf")), full),
        ("load_dim_nan", _efile(mood=float("nan")), full + [("event", {"name": "gratitude"}, T)]),
        ("load_dim_inf", _efile(energy=float("inf")), full),
        ("load_dim_null", _efile(warmth=None), full),
        ("load_dim_list", _efile(warmth=[0.5]), full),
        ("load_dim_bigint", {"emotions.json": _efile()["emotions.json"].replace(b'"mood": 0.45',
                                                                              b'"mood": ' + b"9" * 400)}, full),
    ]
    for name, before, steps in loads:
        sc(name, before, steps)
    # float("0.5") parses in Python; native's pyFloat reads JSON numbers only (M01 §3.7, §8 R8).
    sc("load_dim_numeric_string", _efile(patience="0.5"), full,
       native={"divergence": "R8-str-float", "throws_from_step": 1, "files_unchanged": True,
               "bumps": []})

    # ── Decay across dt (minutes unless noted), including backwards and huge ──
    base = _efile(mood=0.1, energy=1.0, warmth=0.0, patience=0.3, at=T)
    for label, dt in [("0", 0.0), ("minus_60s", -60.0), ("1e-6s", 1e-6), ("30s", 30.0),
                      ("1", 60.0), ("7_5", 450.0), ("30", 1800.0), ("45", 2700.0), ("90", 5400.0),
                      ("240", 14400.0), ("1e6", 6e7), ("1e12s", 1e12)]:
        sc(f"decay_dt_{label}", base, [("decay", {}, T + dt), ("context", {}, T + dt),
                                       ("context", {}, T + dt), ("context", {}, T + dt + 30.0)])
    sc("decay_clock_backwards", _efile(at=T + 3600.0), [
        ("context", {}, T), ("context", {}, T + 1800.0), ("context", {}, T - 86400.0)])
    sc("decay_fractional_times", base, [("context", {}, T + 0.1), ("context", {}, T + 0.30000000000000004),
                                        ("context", {}, T + 1234.5678)])

    # ── Events ──
    for name in list(J._EMO_DELTAS) + ["surprise", "", "Praise", "emotion_praise"]:
        sc(f"event_{name or 'empty'}", {}, [("event", {"name": name}, T)])
    for name in J._EMO_DELTAS:
        sc(f"event_{name}_decayed", _efile(), [("event", {"name": name}, T)])
    sc("event_magnitudes", _efile(), [("event", {"name": "praise", "mag": 2.5}, T),
                                      ("event", {"name": "insult", "mag": -1.0}, T + 1),
                                      ("event", {"name": "gratitude", "mag": 0.0}, T + 2)])
    sc("event_clamp", _efile(mood=0.95, energy=0.02, warmth=0.99, patience=0.05, at=T),
       [("event", {"name": "insult"}, T)] * 6 + [("event", {"name": "praise"}, T)] * 4
       + [("event", {"name": "barge_in"}, T), ("context", {}, T)])
    sc("event_bad_at", _efile(at="later"), [("event", {"name": "praise"}, T),
                                            ("event", {"name": "surprise"}, T)])

    # ── emotion_react corpus (one evolving state; insult > praise > thanks) ──
    sc("react_corpus", {}, [("react", {"text": t}, T) for t in _REACT_TEXTS] + [("context", {}, T)])
    sc("react_decaying", _efile(), [("react", {"text": t}, T + 600.0 * k)
                                    for k, t in enumerate(["you're useless", "thanks", "well done",
                                                           "shut up", "cheers"])])

    # ── _emo_word ──
    sc("word_table", {}, [("word", {"dim": d, "v": v}, T) for d in J._EMO_DIMS for v in _WORD_VALUES]
       + [("word", {"dim": "Mood", "v": 0.5}, T), ("word", {"dim": "", "v": 0.5}, T)])

    # ── emotion_context at exact band boundaries (dt = 0) ──
    for b in (0.0, 0.2, 0.4, 0.6, 0.8, 1.0):
        sc(f"context_all_{b}", _efile(mood=b, energy=b, warmth=b, patience=b, at=T), [("context", {}, T)])
    sc("context_seed", {}, [("context", {}, T)])

    # ── set_tone / tone_context ──
    synthetic = ["", "unhurried, calm", ",,,", "  weird—desc ,x", "Café über-calm, x"]
    for k, desc in enumerate(descs + synthetic):
        sc(f"tone_{k:02d}", {}, [("set_tone", {"desc": desc}, T), ("tone_context", {}, T),
                                 ("tone_context", {}, T + 89.99), ("tone_context", {}, T + 90.0),
                                 ("tone_context", {}, T + 90.000001), ("tone_context", {}, T - 10.0)])
    sc("tone_initial", {}, [("tone_context", {}, T)])
    sc("tone_empty_keeps_previous", {}, [
        ("set_tone", {"desc": descs[-1]}, T), ("set_tone", {"desc": ""}, T + 50.0),
        ("tone_context", {}, T + 90.0), ("tone_context", {}, T + 95.0)])
    sc("tone_set_directly", {}, [
        ("set_last_tone", {"desc": descs[0], "at": 1000.0}, T), ("tone_context", {}, 1090.0),
        ("tone_context", {}, 1090.0000001), ("set_last_tone", {"desc": "", "at": T}, T),
        ("tone_context", {}, T)])
    sc("tone_hurried_twice", _efile(), [("set_tone", {"desc": descs[0]}, T),
                                        ("set_tone", {"desc": descs[0]}, T + 120.0),
                                        ("tone_context", {}, T + 120.0)])
    sc("tone_hurried_bad_emotions", _efile(at="later"), [
        ("set_tone", {"desc": descs[0]}, T), ("tone_context", {}, T)])
    return cases


@suite("m1_emotions_tone")
def emotions_tone(ctx):
    rec = _Recorder(ctx.J)
    return _emotion_cases(ctx, rec)
