"""M1 T9 golden suite (plan: native/plan/M01 §2.4, §3.7, §4.1, §6 T9).

    m1_profile_kb      profile_load / _remember / _forget / _context, maybe_learn_profile with
                       _PROFILE_PATTERNS / _FORGET_ALL_RE / _FORGET_ONE_RE, and kb_load /
                       kb_remember / kb_lookup / kb_note_topic / kb_context, plus the literal
                       tables they use

Plugin for tools/golden.py. Every case but the literal tables is a SCENARIO run through the
real jarvis.py functions: `input.files_before` holds the state files' starting bytes (base64;
null = absent), `input.steps` a list of {op, args, now}. `expected.steps` holds, per step,
`result` ({"value": …} | {"json": text} | {"raises": ExceptionName}), `bumps` (every
research_bump call, in order, as [key, n]; these functions make none) and `files_after` (the
bytes on disk afterwards, base64 or null). maybe_learn steps also record `action`: the
profile_remember / profile_forget call maybe_learn_profile made (seen by wrapping the module
globals). The format is the persona suites' (tools/golden_m1_persona.py), so the Swift side
reuses its runner.

Times travel as {"repr", "bits"}. State contents are SYNTHETIC (neutral stand-in names and
projects, never real data). Literals are read from ctx.J.

A case whose `expected` has a `native` block is a registered divergence: the block says what
native does instead (the Swift test asserts that positively, Python's result as a known issue).
"""
import base64
import json
import math
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


class _Recorder:
    def __init__(self, J):
        self.calls = []
        self.orig = J.research_bump

        def bump(key, n=1):
            self.calls.append([key, n])
            return self.orig(key, n)
        J.research_bump = bump


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
    paths = {"profile.json": J.PROFILE_FILE, "knowledge.json": J.KB_FILE}
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
                      "steps": [{"op": op, "args": args, "now": _f(float(now))}
                                for op, args, now in steps]},
            "expected": {"steps": out}}


def _ops(J):
    def maybe_learn(step, text):
        calls = []
        remember, forget = J.profile_remember, J.profile_forget

        def rec_remember(key, value):
            calls.append({"action": "remember", "key": key, "value": value})
            return remember(key, value)

        def rec_forget(match=None):
            calls.append({"action": "forget_all"} if match is None
                         else {"action": "forget", "match": match})
            return forget(match)
        J.profile_remember, J.profile_forget = rec_remember, rec_forget
        try:
            J.maybe_learn_profile(text)
        finally:
            J.profile_remember, J.profile_forget = remember, forget
            step["action"] = calls[0] if calls else None
        return {"value": None}

    return {
        "load": lambda step: {"json": json.dumps(J.profile_load(), indent=1)},
        "remember": lambda step, key, value: {"value": J.profile_remember(key, value)},
        "forget": lambda step, match=None: {"value": J.profile_forget(match)},
        "context": lambda step: {"value": J.profile_context()},
        "maybe_learn": maybe_learn,
        "kb_load": lambda step: {"json": json.dumps(J.kb_load(), indent=1)},
        "kb_remember": lambda step, topic, summary: {"value": J.kb_remember(topic, summary)},
        "kb_lookup": lambda step, query: {"value": J.kb_lookup(query)},
        "kb_note_topic": lambda step, text: {"value": J.kb_note_topic(text)},
        "kb_context": lambda step, n=3: {"value": J.kb_context(n)},
    }


# Every _PROFILE_PATTERNS row, both forget REs, near misses, case, whitespace, curly quotes,
# non-ASCII letters under re.I. Names and projects are neutral stand-ins.
_PROFILE_TEXTS = [
    # row 1: my name('s| is) [a-z][\w '-]{1,40}
    "my name is Robin", "My name's Morgan", "hey, my name is Robin O'Tester-Two and I like tea",
    "my name is robin.", "MY NAME IS ALEX", "my name is 42", "my name is K", "my name is Élodie",
    "my name is Zoë the Second", "my name’s Robin", "my name is ſam", "my names is Robin",
    "my name is Robin, and yours is?", "my name is  a very long name with far too many words in it ok",
    # row 2: call me [a-z][\w '-]{1,40}
    "call me Robin", "Please call me captain", "call me 007", "Call me Krin", "call me",
    "you can call me Sam!",
    # row 3: i('m| am) working on (.+)
    "I'm working on a bird feeder", "i am working on the garden shed.", "I’m working on a kite",
    "I am working on   it . .", "im working on a boat", "I'm a builder working on a shed",
    # row 4: i('m| am) an? [\w '-]{2,40}
    "I'm a bit tired", "I am an engineer", "I'm ambitious", "I'm an artist, and I like it",
    "i am a software developer at the university", "I'm a", "I'm a x", "I’m a teacher",
    # row 5: i (prefer|really like|love) (.+)
    "I prefer tea", "i really like jazz.", "I love 🍕 and ☕ in the morning", "I like tea",
    "I PREFER\tthe window seat", "I love", "I love .",
    # row 6: remember that (.+)
    "remember that the bins go out on Tuesday", "Remember that.", "please remember that   ",
    "Remember that I park on level 3",
    # row 7 (dynamic key): my (\w[\w ]{1,20}?) is (.+)
    "my birthday is in June", "My Favourite Film is Alien.", "my dog's name is Rex",
    "my car is red and my bike is blue", "my cat isn't here", "my café is open late",
    "my very very long winded hobby name is x", "my x is y", "my pin is 1234 ...",
    # forget all
    "forget everything about me", "Forget everything you know about me", "clear my profile",
    "wipe my profile please", "forget everything", "clear my profiles",
    # forget one
    "forget my birthday", "forget that my name", "forget what you know about my job",
    "forget about my car please", "Forget my NAME.", "forget my name is Robin", "forget my",
    # nothing
    "", "   \t  ", "what's the weather like", "tell me a joke", "my", "I'm",
]


def _facts(n, t0=_T0 - 86400.0):
    return {f"fact {i:02d}": {"value": f"synthetic value {i}", "updated": t0 + (i % 5) * 0.5 + i // 5}
            for i in range(n)}


def _pfile(facts=None, **extra):
    d = dict(extra)
    d["facts"] = _facts(3) if facts is None else facts
    return {"profile.json": _dump(d)}


def _topics(n, t0=_T0 - 86400.0, stem="topic"):
    return {f"{stem} {i:03d}": {"summary": f"synthetic summary {i}", "updated": t0 + (i * 7919 % n)}
            for i in range(n)}


def _kfile(topics=None, queue=None, **extra):
    d = {"topics": _topics(4) if topics is None else topics, "queue": [] if queue is None else queue}
    d.update(extra)
    return {"knowledge.json": _dump(d)}


def _cases(ctx, rec):
    J = ctx.J
    ops = _ops(J)
    P, K = ("profile.json",), ("knowledge.json",)
    T = _T0
    cases = []

    def sc(name, before, steps, files, native=None):
        c = _scenario(ctx, rec, ops, name, before, steps, files)
        if native:
            c["expected"]["native"] = native
        cases.append(c)

    # The literal tables, compared field by field by the Swift test.
    cases.append({"name": "literals", "input": {},
                  "expected": {"profile_patterns": [{"pattern": p.pattern, "ignorecase": bool(p.flags & 2),
                                                     "key": k} for p, k in J._PROFILE_PATTERNS],
                               "forget_all_re": {"pattern": J._FORGET_ALL_RE.pattern,
                                                 "ignorecase": bool(J._FORGET_ALL_RE.flags & 2)},
                               "forget_one_re": {"pattern": J._FORGET_ONE_RE.pattern,
                                                 "ignorecase": bool(J._FORGET_ONE_RE.flags & 2)},
                               "kb_stop": sorted(J._KB_STOP)}})

    # ── maybe_learn_profile: every text on an empty profile, then the context it leaves ──
    for i, text in enumerate(_PROFILE_TEXTS):
        sc(f"maybe_learn_{i:02d}", {}, [("maybe_learn", {"text": text}, T), ("context", {}, T)], P)
    # …and on a populated one (forget one / all act on real keys)
    populated = _pfile({"name": {"value": "Robin", "updated": T - 50},
                        "pet name": {"value": "Rex", "updated": T - 40},
                        "birthday": {"value": "in June", "updated": T - 30},
                        "current project": {"value": "a bird feeder", "updated": T - 20}})
    for i, text in enumerate(["forget my name", "forget my birthday", "forget my pet", "forget my car",
                              "clear my profile", "forget about my car please", "my name is Morgan",
                              "I'm working on a canoe", "my Pet Name is Bo", "forget my current project"]):
        sc(f"maybe_learn_populated_{i:02d}", populated,
           [("maybe_learn", {"text": text}, T), ("context", {}, T)], P)

    # ── A conversation from a missing file: accumulate, replace, forget ──
    sc("conversation", {}, [
        ("maybe_learn", {"text": "my name is Robin"}, T),
        ("maybe_learn", {"text": "I'm working on a bird feeder"}, T + 1.5),
        ("maybe_learn", {"text": "I prefer tea over coffee."}, T + 2.25),
        ("context", {}, T + 3),
        ("maybe_learn", {"text": "call me Sam"}, T + 4),         # replaces "name", keeps its position
        ("context", {}, T + 4),
        ("maybe_learn", {"text": "forget my name"}, T + 5),
        ("context", {}, T + 5),
        ("maybe_learn", {"text": "wipe my profile"}, T + 6),
        ("context", {}, T + 6),
        ("load", {}, T + 6)], P)

    # ── profile_remember: cleaning, caps, skips ──
    sc("remember_caps", {}, [
        ("remember", {"key": "  K" * 30 + "  ", "value": "v" * 400}, T),
        ("remember", {"key": "Key", "value": "  trailing dots . . .  "}, T + 1),
        ("remember", {"key": "Key", "value": "replaced"}, T + 2),
        ("remember", {"key": "İstanbul trip", "value": "in spring"}, T + 3),     # lower() grows it
        ("remember", {"key": "ΟΔΟΣ", "value": "Σ final sigma"}, T + 4),
        ("load", {}, T + 4), ("context", {}, T + 4)], P)
    sc("remember_skips", {}, [
        ("remember", {"key": "   ", "value": "x"}, T),
        ("remember", {"key": "k", "value": " . . "}, T),
        ("remember", {"key": "k", "value": ""}, T),
        ("remember", {"key": "", "value": ""}, T),
        ("context", {}, T)], P)
    sc("remember_unicode_values", {}, [
        ("remember", {"key": "preference", "value": "🍕 and ☕, “always”"}, T),
        ("remember", {"key": "note", "value": "café crème — naïve ﬁ ligature ​ zero width"}, T + 1),
        ("remember", {"key": "emoji key 🎈", "value": "balloon"}, T + 2),
        ("context", {}, T + 2)], P)
    sc("remember_into_other_keys", {"profile.json": _dump({"other": [1, 2], "version": 3})}, [
        ("remember", {"key": "name", "value": "Robin"}, T), ("load", {}, T)], P)

    # ── profile_forget ──
    sc("forget_substring_many", populated, [("forget", {"match": "name"}, T), ("context", {}, T)], P)
    sc("forget_nothing_still_saves", populated, [("forget", {"match": "zzz"}, T)], P)
    sc("forget_empty_string_matches_all", populated, [("forget", {"match": ""}, T)], P)
    sc("forget_case_sensitive", populated, [("forget", {"match": "NAME"}, T)], P)
    sc("forget_all", populated, [("forget", {}, T), ("context", {}, T)], P)
    sc("forget_missing_file", {}, [("forget", {"match": "name"}, T), ("load", {}, T)], P)
    sc("forget_all_missing_file", {}, [("forget", {}, T)], P)

    # ── profile_context ordering: 12 newest, ties in file order, default 0, int vs float ──
    sc("context_14_facts", _pfile(_facts(14)), [("context", {}, T), ("load", {}, T)], P)
    sc("context_ties_and_defaults", _pfile({
        "a": {"value": "no updated"}, "b": {"value": "tie one", "updated": 5.0},
        "c": {"value": "int tie", "updated": 5}, "d": {"value": "bool one", "updated": True},
        "e": {"value": "int one", "updated": 1}, "f": {"value": "tie two", "updated": 5.0},
        "g": {"value": "zero", "updated": 0}, "h": {"value": "negative", "updated": -2.5},
        "i": {"value": "big int", "updated": 1790582401}, "j": {"value": "float just below",
                                                                "updated": 1790582400.9999998},
        "k": {"value": "huge", "updated": 1e300}, "l": {"value": "neg zero", "updated": -0.0},
        "m": {"value": "tiny", "updated": 5e-324}, "n": {"value": "last", "updated": 5.0}}),
        [("context", {}, T)], P)
    sc("context_one_fact_any_updated", _pfile({"only": {"value": "v", "updated": "not a number"}}),
       [("context", {}, T)], P)
    sc("context_string_updated_sorted", _pfile({"x": {"value": "1", "updated": "2026-01-02"},
                                                 "y": {"value": "2", "updated": "2026-01-10"},
                                                 "z": {"value": "3", "updated": "2026-01-02"}}),
       [("context", {}, T)], P)
    sc("context_value_types", _pfile({
        "int": {"value": 5, "updated": 9}, "float": {"value": 1.5, "updated": 8},
        "null": {"value": None, "updated": 7}, "bool": {"value": True, "updated": 6},
        "list": {"value": ["a", "b's", 'say "hi"', 1, -0.0, None, False, {"k": []}], "updated": 5},
        "dict": {"value": {"x": 1e16, "y\n": "tab\there"}, "updated": 4},
        "ctl": {"value": ["\x00\x7f\x85 é​\U0001F600\U000E0001\\"], "updated": 3},
        "str": {"value": "plain", "updated": 2}}), [("context", {}, T)], P)
    sc("context_empty_facts", _pfile({}), [("context", {}, T)], P)

    # ── Load failures and wrong shapes (Python raises → native throws, R8) ──
    shapes = [
        ("shape_missing", {}),
        ("shape_corrupt", {"profile.json": b'{"facts": {"na'}),
        ("shape_empty_file", {"profile.json": b""}),
        ("shape_bom", {"profile.json": b"\xef\xbb\xbf" + _dump({"facts": _facts(2)})}),
        ("shape_not_dict", {"profile.json": b"[1, 2, 3]"}),
        ("shape_null_file", {"profile.json": b"null"}),
        ("shape_no_facts", {"profile.json": _dump({"other": 1})}),
        ("shape_facts_null", {"profile.json": _dump({"facts": None})}),
        ("shape_facts_list_empty", {"profile.json": _dump({"facts": []})}),
        ("shape_facts_list", {"profile.json": _dump({"facts": ["name", "other"]})}),
        ("shape_facts_list_mixed", {"profile.json": _dump({"facts": ["zz", 5]})}),
        ("shape_facts_list_nested", {"profile.json": _dump({"facts": [["name"], {"name": 1}]})}),
        ("shape_facts_str", {"profile.json": _dump({"facts": "abc"})}),
        ("shape_facts_zero", {"profile.json": _dump({"facts": 0})}),
        ("shape_facts_int", {"profile.json": _dump({"facts": 7})}),
        ("shape_fact_not_dict", {"profile.json": _dump({"facts": {"name": "Robin"}})}),
        ("shape_fact_no_value", {"profile.json": _dump({"facts": {"name": {"updated": 1.0}}})}),
        ("shape_mixed_updated", {"profile.json": _dump({"facts": {"a": {"value": "1", "updated": "x"},
                                                                  "b": {"value": "2", "updated": 3}}})}),
        ("shape_null_updated", {"profile.json": _dump({"facts": {"a": {"value": "1", "updated": None},
                                                                 "b": {"value": "2", "updated": None}}})}),
    ]
    # profile_load / kb_load hand a parseable non-dict back to their callers, which all raise
    # on it (the steps after the load show that). Native's load has the planned `JSONObject`
    # result (M01 §3.7), so it throws at the load itself.
    not_dict = {"divergence": "R8-load-not-dict", "throws_from_step": 0, "files_unchanged": True, "bumps": []}
    for name, before in shapes:
        sc(name, before, [("load", {}, T), ("context", {}, T), ("forget", {"match": "na"}, T),
                          ("forget", {"match": "zz"}, T + 1), ("remember", {"key": "role", "value": "tester"}, T + 2),
                          ("context", {}, T + 2), ("forget", {}, T + 3)], P,
           native=not_dict if name in ("shape_not_dict", "shape_null_file") else None)
    # NaN in "updated": Python orders it by where its timsort run happens to put it; native
    # refuses (StateShapeError) rather than reproduce the accident.
    nan_file = {"profile.json": json.dumps({"facts": {"a": {"value": "1", "updated": 2.0},
                                                      "b": {"value": "2", "updated": math.nan},
                                                      "c": {"value": "3", "updated": 1.0}}},
                                           indent=1).encode("ascii")}
    sc("shape_nan_updated", nan_file, [("context", {}, T)], P,
       native={"divergence": "R8-nan-sort", "throws_from_step": 0, "files_unchanged": True, "bumps": []})

    # ── kb_note_topic: the queue ──
    sc("kb_note_queue", {}, [
        ("kb_note_topic", {"text": "What is a bird feeder?"}, T),
        ("kb_note_topic", {"text": "  WHAT IS A BIRD FEEDER?  "}, T + 1),        # same after cleaning: no save
        ("kb_note_topic", {"text": "   "}, T + 2),
        ("kb_note_topic", {"text": "Q" * 130}, T + 3),
        ("kb_note_topic", {"text": "Café crème — ΣΊΣΥΦΟΣ 🎈"}, T + 4),
        ("kb_load", {}, T + 4)], K)
    sc("kb_note_queue_rolls_at_30", _kfile(queue=[f"queued question {i}" for i in range(30)]), [
        ("kb_note_topic", {"text": "queued question 5"}, T),
        ("kb_note_topic", {"text": "a new question"}, T + 1),
        ("kb_note_topic", {"text": "queued question 0"}, T + 2),                  # rolled out: new again
        ("kb_load", {}, T + 2)], K)
    sc("kb_note_queue_over_30_in_file", _kfile(queue=[f"q{i}" for i in range(35)]), [
        ("kb_note_topic", {"text": "q1"}, T), ("kb_note_topic", {"text": "fresh"}, T)], K)
    sc("kb_note_no_topics_key", {"knowledge.json": _dump({"queue": ["x"]})}, [
        ("kb_note_topic", {"text": "y"}, T), ("kb_lookup", {"query": "y"}, T), ("kb_context", {}, T),
        ("kb_remember", {"topic": "y", "summary": "s"}, T)], K)
    sc("kb_note_no_queue_key", {"knowledge.json": _dump({"topics": {}, "extra": True})}, [
        ("kb_note_topic", {"text": "y"}, T)], K)
    for name, q in [("str", "abc def"), ("dict", {"abc": 1}), ("null", None), ("int", 3)]:
        sc(f"kb_note_queue_{name}", {"knowledge.json": _dump({"topics": {}, "queue": q})}, [
            ("kb_note_topic", {"text": "abc"}, T), ("kb_note_topic", {"text": "zzz"}, T)], K)

    # ── kb_lookup: exact, overlap, ties, substring bonus, stop words, empty ──
    lk = _kfile({
        "bird feeder": {"summary": "A tray or tube that holds seed for garden birds.", "updated": T - 9},
        "the moon": {"summary": "Earth's only natural satellite.", "updated": T - 8},
        "moon landing": {"summary": "Apollo 11 landed in July 1969.", "updated": T - 7},
        "what is": {"summary": "stop words only topic", "updated": T - 6},
        "café crème": {"summary": "Coffee with cream.", "updated": T - 5},
        "garden birds": {"summary": "Robins, tits and finches.", "updated": T - 4},
        "empty summary": {"summary": "", "updated": T - 3},
        "ΣΊΣΥΦΟΣ myth": {"summary": "A king condemned to roll a boulder.", "updated": T - 2},
    })
    queries = ["bird feeder", "Bird Feeder  ", "tell me about the moon", "moon", "what is",
               "what is the moon landing", "garden", "birds in the garden", "feeder birds",
               "CAFÉ", "cafe creme", "how do you know", "", "   ", "nothing matches here",
               "empty summary please", "σίσυφος", "ΣΊΣΥΦΟΣ MYTH", "e", "a", "the"]
    sc("kb_lookup_many", lk, [("kb_lookup", {"query": q}, T) for q in queries], K)
    sc("kb_lookup_first_strictly_better", _kfile({
        "alpha beta": {"summary": "first", "updated": 1.0}, "beta gamma": {"summary": "second", "updated": 2.0},
        "alpha gamma": {"summary": "third", "updated": 3.0}}),
        [("kb_lookup", {"query": "alpha beta gamma delta"}, T), ("kb_lookup", {"query": "gamma"}, T),
         ("kb_lookup", {"query": "beta"}, T)], K)
    sc("kb_lookup_empty_kb", {}, [("kb_lookup", {"query": "anything"}, T), ("kb_context", {}, T)], K)
    sc("kb_lookup_bad_shapes", _kfile({"good topic": {"summary": "fine", "updated": 1.0},
                                       "bad topic": "not a dict", "no summary": {"updated": 2.0}}),
       [("kb_lookup", {"query": "good topic"}, T), ("kb_lookup", {"query": "unrelated words"}, T),
        ("kb_lookup", {"query": "bad topic"}, T), ("kb_lookup", {"query": "no summary"}, T),
        ("kb_lookup", {"query": "topic"}, T), ("kb_lookup", {"query": "summary no"}, T)], K)
    # A summary that is not a str: Python returns it; native's lookup yields String?, so it throws.
    sc("kb_lookup_nonstr_summary", _kfile({"number topic": {"summary": 5, "updated": 1.0}}),
       [("kb_lookup", {"query": "number topic"}, T)], K,
       native={"divergence": "R8-kb-summary-not-str", "throws_from_step": 0, "files_unchanged": True,
               "bumps": []})

    # ── kb_remember: normalisation, caps, replace, prune past 200 ──
    sc("kb_remember_basic", {}, [
        ("kb_remember", {"topic": "  Bird FEEDER ", "summary": "A tray for seed."}, T),
        ("kb_remember", {"topic": "t" * 130, "summary": "s" * 900}, T + 1),
        ("kb_remember", {"topic": "", "summary": "x"}, T + 2),
        ("kb_remember", {"topic": "x", "summary": ""}, T + 2),
        ("kb_remember", {"topic": "bird feeder", "summary": "Replaced, keeps position."}, T + 3),
        ("kb_remember", {"topic": "Café 🎈", "summary": "  spaces kept  "}, T + 4),
        ("kb_load", {}, T + 4), ("kb_context", {}, T + 4), ("kb_lookup", {"query": "bird feeder"}, T + 4)], K)
    prune = _topics(200)
    prune["topic 007"]["updated"] = prune["topic 003"]["updated"]          # a tie at the cut
    del prune["topic 011"]["updated"]                                      # default 0: oldest
    sc("kb_remember_prunes_50", {"knowledge.json": _dump({"topics": prune, "queue": ["q"]})}, [
        ("kb_remember", {"topic": "topic 050", "summary": "replace: still 200, no prune"}, T),
        ("kb_remember", {"topic": "brand new", "summary": "201 → prune 50"}, T + 1),
        ("kb_context", {"n": 5}, T + 1)], K)
    sc("kb_remember_prune_ties", {"knowledge.json": _dump({"topics": {f"t{i:03d}": {"summary": "s", "updated": 1.0}
                                                                      for i in range(200)}, "queue": []})}, [
        ("kb_remember", {"topic": "zz new", "summary": "x"}, T)], K)
    sc("kb_remember_bad_shapes", {"knowledge.json": _dump({"topics": ["a"], "queue": []})}, [
        ("kb_remember", {"topic": "a", "summary": "b"}, T), ("kb_context", {}, T),
        ("kb_lookup", {"query": "a"}, T), ("kb_note_topic", {"text": "a"}, T)], K)

    # ── kb_context ──
    sc("kb_context_newest_3", _kfile(_topics(9)), [("kb_context", {}, T), ("kb_context", {"n": 0}, T),
                                                   ("kb_context", {"n": 20}, T)], K)
    sc("kb_context_ties_and_long", _kfile({
        "a": {"summary": "x" * 200, "updated": 5.0}, "b": {"summary": "tie two", "updated": 5},
        "c": {"summary": "no updated"}, "d": {"summary": "tie three", "updated": 5.0},
        "e": {"summary": ["list", "summary", "it's"], "updated": 5.0}}), [("kb_context", {}, T),
                                                                          ("kb_context", {"n": 5}, T)], K)
    kshapes = [
        ("kb_shape_missing", {}),
        ("kb_shape_corrupt", {"knowledge.json": b'{"topics": '}),
        ("kb_shape_not_dict", {"knowledge.json": b'"just a string"'}),
        ("kb_shape_topics_null", {"knowledge.json": _dump({"topics": None, "queue": []})}),
        ("kb_shape_topic_not_dict", {"knowledge.json": _dump({"topics": {"a": 1}, "queue": []})}),
        ("kb_shape_summary_int", {"knowledge.json": _dump({"topics": {"a": {"summary": 1}}, "queue": []})}),
        ("kb_shape_summary_null", {"knowledge.json": _dump({"topics": {"a": {"summary": None}}, "queue": []})}),
        ("kb_shape_no_summary", {"knowledge.json": _dump({"topics": {"a": {"updated": 1}}, "queue": []})}),
    ]
    for name, before in kshapes:
        sc(name, before, [("kb_load", {}, T), ("kb_context", {}, T), ("kb_lookup", {"query": "zz qq"}, T),
                          ("kb_note_topic", {"text": "new q"}, T),
                          ("kb_remember", {"topic": "fresh", "summary": "s"}, T + 1)], K,
           native=not_dict if name == "kb_shape_not_dict" else None)
    return cases


@suite("m1_profile_kb")
def profile_kb(ctx):
    rec = _Recorder(ctx.J)
    return _cases(ctx, rec)
