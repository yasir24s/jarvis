"""M1 golden suite for difflib: m1_difflib (M01 §3.4, §4.1; M01b §4 `sequence_matcher.json`).

Plugin for tools/golden.py (it imports every tools/golden_*.py). Only the *inputs* below are
typed by hand; every expected value is computed here by running Python 3.14's own
`difflib.SequenceMatcher(None, a, b)` (autojunk=True, the module jarvis.py imported).

Each case: input {group, a, b}; expected {ratio: {repr, bits}, blocks: [[a, b, size], ...],
len: [len(a), len(b)] in code points, popular: sorted bpopular (information only), sites:
{function: bool}} where `sites` is the result of each jarvis.py threshold comparison. The
thresholds are read from jarvis.py's source with ast (the `sites` case), never typed.

Groups: basic (edge cases, unicode, whitespace, case), autojunk (len(b) 199/200/201/300, the
count == ntest boundary, pathological repeats), corrections + corrections_near (the
_apply_corrections shape: _corr_norm(text) vs taught `heard`, around 0.82), feedback +
feedback_near (the track_feedback shape: raw text vs the previous command, around 0.65),
seeded (500 small-alphabet pairs) and seeded_long (autojunk-sized small-alphabet pairs).
M01b's FeedbackTracker reuses this fixture: its `sequence_matcher.json` intent is the
`feedback` + `feedback_near` groups (empty sides, unicode, >= 200 chars, the 0.65 boundary).
"""
import ast
import random
import struct

from golden import suite

_OPS = {ast.GtE: ">=", ast.Gt: ">", ast.LtE: "<=", ast.Lt: "<"}
_CMP = {">=": lambda x, y: x >= y, ">": lambda x, y: x > y,
        "<=": lambda x, y: x <= y, "<": lambda x, y: x < y}


def _bits(x):
    return struct.pack(">d", x).hex()


def _is_ratio_call(n):
    """difflib.SequenceMatcher(...).ratio()"""
    return (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "ratio"
            and isinstance(n.func.value, ast.Call) and isinstance(n.func.value.func, ast.Attribute)
            and n.func.value.func.attr == "SequenceMatcher")


def _sites(J):
    """Every `SequenceMatcher(...).ratio() <op> <const>` in jarvis.py, in source order."""
    tree = ast.parse(open(J.__file__, encoding="utf-8").read())
    uses = sum(1 for n in ast.walk(tree) if isinstance(n, ast.Attribute) and n.attr == "SequenceMatcher")
    out = []
    for fn in ast.walk(tree):
        if not isinstance(fn, ast.FunctionDef):
            continue
        for n in ast.walk(fn):
            if isinstance(n, ast.Compare) and len(n.ops) == 1 and _is_ratio_call(n.left):
                const = n.comparators[0]
                assert isinstance(const, ast.Constant) and isinstance(const.value, float), ast.dump(n)
                out.append({"function": fn.name, "line": n.lineno,
                            "op": _OPS[type(n.ops[0])], "value": const.value})
    out.sort(key=lambda s: s["line"])
    assert len(out) == uses, f"{uses} SequenceMatcher uses but {len(out)} threshold comparisons"
    assert [s["function"] for s in out] == ["_apply_corrections", "track_feedback"], out
    return out


# ─── Inputs ─────────────────────────────────────────────────────────────────────

_BASIC = [
    ("empty-empty", "", ""),
    ("empty-x", "", "x"),
    ("x-empty", "x", ""),
    ("identical", "hello", "hello"),
    ("identical-sentence", "turn on the lights", "turn on the lights"),
    ("disjoint", "abc", "xyz"),
    ("doc-abcd-bcde", "abcd", "bcde"),
    ("doc-abxcd-abcd", "abxcd", "abcd"),
    ("one-sub", "play music", "play musik"),
    ("one-del", "turn on the lights", "turn on the light"),
    ("one-ins", "turn on the light", "turn on the lights"),
    ("one-sub-start", "jarvis", "harvis"),
    ("transpose-end", "abcd", "abdc"),
    ("transpose-word", "the lights", "teh lights"),
    ("transpose-words", "lights on", "on lights"),
    ("reverse", "abcdef", "fedcba"),
    ("repeat-aaaa-aa", "aaaa", "aa"),
    ("repeat-aa-aaaa", "aa", "aaaa"),
    ("repeat-abab", "abababab", "babababa"),
    ("repeat-mississippi", "mississippi", "missisippi"),
    ("repeat-tie", "abcabc", "abc"),
    ("repeat-tie-rev", "abc", "abcabc"),
    ("accent-precomposed", "café", "cafe"),
    ("accent-decomposed", "café", "café"),
    ("combining-tilde", "ñ", "ñ"),
    ("combining-stack", "á̂b", "ấb"),
    ("emoji-astral", "😀 hi", "😃 hi"),
    ("emoji-same", "hi 😀", "hi 😀"),
    ("emoji-zwj", "👨‍👩‍👧", "👨‍👩"),
    ("flags", "🇬🇧 time", "🇺🇸 time"),
    ("cjk", "你好世界", "你好，世界"),
    ("cjk-kana", "天気はどうですか", "天気はどう"),
    ("dotted-i", "İstanbul", "istanbul"),
    ("sigma", "ΟΔΟΣ", "οδος"),
    ("ws-double", "hello world", "hello  world"),
    ("ws-tab", "hello world", "hello\tworld"),
    ("ws-edges", " hello world ", "hello world"),
    ("ws-newline", "hello\nworld", "hello world"),
    ("ws-nbsp", "hello world", "hello world"),
    ("ws-only", "   ", " "),
    ("case-title", "Hello World", "hello world"),
    ("case-upper", "JARVIS", "jarvis"),
    ("case-mixed", "What's The Time", "what's the time"),
    ("punct", "what's the time?", "whats the time"),
]

_PARA = ("Good morning. Today you have a dentist appointment at nine, a call with the "
         "research group at eleven, and the quarterly review in the afternoon. The weather "
         "is cloudy with light rain expected around four, so take an umbrella when you go.")
_FOX = "the quick brown fox jumps over the lazy dog while jarvis reads the news aloud "


def _text(n):
    return (_FOX * (n // len(_FOX) + 1))[:n]


def _edit(s, every, repl="#"):
    """Replace every `every`-th character: a deterministic, spread-out edit."""
    return "".join(repl if k % every == every - 1 else c for k, c in enumerate(s))


def _autojunk_inputs():
    out = []
    for n in (199, 200, 201, 300):
        b = _text(n)
        out.append((f"len{n}-edited", _edit(b, 13), b, n >= 200))
        out.append((f"len{n}-reversed-roles", b, _edit(b, 13), n >= 200))
        out.append((f"len{n}-prefix", b[:120], b, n >= 200))
    # len(a) >= 200 does not trigger it: only b is chained.
    out.append(("a-long-b-short", _text(260), _text(150), False))
    # The count == ntest boundary at len(b) = 200 (ntest = 3): 'q' x3 stays, 'z' x4 is popular.
    filler = [chr(0x4E00 + k) for k in range(193)]
    b = "".join(filler[:40]) + "qqq" + "".join(filler[40:120]) + "zzzz" + "".join(filler[120:])
    assert len(b) == 200
    out.append(("ntest-boundary", "qqq" + "".join(filler[:40]) + "zzzz", b, True))
    out.append(("ntest-boundary-mid", "".join(filler[30:50]) + "qqqzzzz" + "".join(filler[110:130]), b, True))
    # Pathological repeats.
    out.append(("a300-a299b", "a" * 300, "a" * 299 + "b", True))
    out.append(("a299b-a300", "a" * 299 + "b", "a" * 300, True))
    out.append(("a300-a300", "a" * 300, "a" * 300, True))
    out.append(("a200-a199", "a" * 200, "a" * 199, False))
    out.append(("a199-a200", "a" * 199, "a" * 200, True))
    out.append(("ab150-ba150", "ab" * 150, "ba" * 150, True))
    out.append(("b-a300-middle", "xyz" + "a" * 100 + "xyz", "a" * 300, True))
    out.append(("empty-a300", "", "a" * 300, True))
    out.append(("a300-empty", "a" * 300, "", False))
    # A realistic long paragraph (dictation) vs an edit, both orders.
    para2 = _PARA.replace("nine", "ten").replace("umbrella", "coat").replace("cloudy", "overcast")
    out.append(("paragraph", _PARA, para2, True))
    out.append(("paragraph-rev", para2, _PARA, True))
    return out


# _apply_corrections: whole short utterance (<= 6 words) vs a taught `heard` (both _corr_norm'd).
_CORRECTIONS = [
    ("turn of the light", "turn of the lights"),
    ("Play Hello by Adele.", "play hello by adell"),
    ("what's the whether", "what s the weather"),
    ("jervis", "jarvis"),
    ("Open Spotty Fly", "open spotify"),
    ("call my mom", "call my mum"),
    ("set an alarm for seven", "set alarm for seven"),
    ("Remind me to buy milk", "remind me to by milk"),
    ("play despacito", "play the spacito"),
    ("what is the time", "what's the time"),
    ("Hey Jarvis!", "hay jarvis"),
    ("Café Olé", "cafe ole"),
]

_FEEDBACK = [
    ("empty-empty", "", ""),
    ("empty-last", "", "what time is it"),
    ("text-empty", "hello", ""),
    ("rephrase-like", "what's the weather", "what's the weather like"),
    ("on-off", "turn on the lights", "turn off the lights"),
    ("punct-case", "Play some music.", "play some music"),
    ("number-word", "set a timer for 5 minutes", "set a timer for five minutes"),
    ("reword", "what time is it", "what's the time"),
    ("different-app", "open safari", "open spotify"),
    ("unrelated", "tell me a joke", "what's on my calendar"),
    ("mum-mom", "remind me to call mum", "remind me to call mom"),
    ("german", "Wie spät ist es?", "wie spat ist es"),
    ("accent", "café near me", "cafe near me"),
    ("emoji", "play 🎵 music", "play music"),
    ("cjk", "日本の天気は", "日本の天気"),
    ("combining", "naïve question", "naïve question"),
    ("identical", "stop", "stop"),
    ("long-edit", _PARA, _PARA.replace("dentist", "doctor")),
    ("long-vs-short", _PARA, "what's on my calendar today"),
    ("short-vs-long", "what's on my calendar today", _PARA),
]

# Bases for the near-threshold searches (realistic spoken commands).
_BASES = [
    "turn on the living room lights", "what's the weather like tomorrow", "play some jazz music",
    "set a timer for ten minutes", "remind me to call the dentist", "open spotify",
    "what time is it in tokyo", "add milk to my shopping list", "read me the latest news",
    "how far is the moon", "turn the volume down", "tell me a joke", "send a message to sarah",
    "what's on my calendar today", "pause the music", "who won the football last night",
    "start a stopwatch", "switch off the bedroom lamp", "search the web for pasta recipes",
    "what's the capital of australia",
    # Longer <= 6-word commands: T = len(a) + len(b) near 100 makes an exact 0.82 reachable.
    "schedule the quarterly performance review meeting", "download the documentary about photosynthesis",
    "recommend something entertaining for tonight", "translate unbelievable into portuguese",
]
_LETTERS = "abcdefghijklmnopqrstuvwxyz"


def _mutate(s, rng, raw):
    for _ in range(rng.randint(1, 4)):
        op = rng.randrange(7 if raw else 6)
        if not s:
            break
        k = rng.randrange(len(s))
        if op == 0:
            s = s[:k] + rng.choice(_LETTERS) + s[k + 1:]
        elif op == 1:
            s = s[:k] + s[k + 1:]
        elif op == 2:
            s = s[:k] + rng.choice(_LETTERS) + s[k:]
        elif op == 3 and k + 1 < len(s):
            s = s[:k] + s[k + 1] + s[k] + s[k + 2:]
        elif op == 4:
            w = s.split()
            if len(w) > 1:
                del w[rng.randrange(len(w))]
                s = " ".join(w)
        elif op == 5 and s.split():
            w = s.split()
            j = rng.randrange(len(w))
            w.insert(j, rng.choice(_BASES).split()[0])
            s = " ".join(w)
        elif op == 6:
            s = s.capitalize() + rng.choice(["?", ".", "!", ""])
    return s


def _near(D, rng, thr, cmp, shape, keep, want_each):
    """Seeded mutations of _BASES whose ratio lands within 0.01 of `thr`, `want_each` passing
    and `want_each` failing the comparison; plus up to 3 pairs landing exactly on `thr`."""
    passing, failing, exact, seen = [], [], [], set()
    for _ in range(400000):
        base = rng.choice(_BASES)
        a, b = shape(_mutate(base, rng, raw=shape is _raw), base)
        if (a, b) in seen or not keep(a):
            continue
        r = D.SequenceMatcher(None, a, b).ratio()
        if abs(r - thr) > 0.01:
            continue
        seen.add((a, b))
        if r == thr and len(exact) < 3:
            exact.append((a, b))
        elif cmp(r, thr) and len(passing) < want_each:
            passing.append((a, b))
        elif not cmp(r, thr) and len(failing) < want_each:
            failing.append((a, b))
        if len(passing) == want_each and len(failing) == want_each and len(exact) == 3:
            break
    assert len(passing) == want_each and len(failing) == want_each, (thr, len(passing), len(failing))
    assert exact, f"no pair lands exactly on {thr}"
    return ([("exact", p) for p in exact] + [("pass", p) for p in passing] + [("fail", p) for p in failing])


def _raw(text, base):
    return text, base


# ─── Suite ──────────────────────────────────────────────────────────────────────

def _difflib_cases(J):
    D = J.difflib                      # the very module jarvis.py calls
    sites = _sites(J)
    norm = J._corr_norm
    cases = [{"name": "sites", "input": {"group": "sites"},
              "expected": {"sites": [{k: s[k] for k in ("function", "op", "value")} for s in sites]}}]

    changed = set()

    def add(group, name, a, b, autojunk=None):
        sm = D.SequenceMatcher(None, a, b)
        r = sm.ratio()
        extra = {}
        if autojunk is not None:
            assert bool(sm.bpopular) == autojunk, (name, sorted(sm.bpopular))
            off = D.SequenceMatcher(None, a, b, autojunk=False)
            extra["autojunk_changes"] = off.get_matching_blocks() != sm.get_matching_blocks()
            if extra["autojunk_changes"]:
                changed.add(name)
        cases.append({
            "name": f"{group}/{name}",
            "input": {"group": group, "a": a, "b": b},
            "expected": {
                "ratio": {"repr": repr(r), "bits": _bits(r)},
                "blocks": [list(m) for m in sm.get_matching_blocks()],
                "len": [len(a), len(b)],
                "popular": sorted(sm.bpopular),
                "sites": {s["function"]: _CMP[s["op"]](r, s["value"]) for s in sites},
                **extra,
            },
        })

    for name, a, b in _BASIC:
        add("basic", name, a, b)
    for name, a, b, aj in _autojunk_inputs():
        add("autojunk", name, a, b, autojunk=aj)
    # The corpus must exercise the rule: with autojunk=False these answers differ.
    must = {"len200-edited", "len201-edited", "len300-edited", "len200-reversed-roles",
            "ntest-boundary", "ab150-ba150", "b-a300-middle", "paragraph"}
    assert must <= changed, sorted(must - changed)
    for k, (text, heard) in enumerate(_CORRECTIONS):
        a, b = norm(text), norm(heard)
        assert len(a.split()) <= 6, a
        add("corrections", f"{k:02d}", a, b)
    for name, a, b in _FEEDBACK:
        add("feedback", name, a, b)

    corr, fb = sites
    rng = random.Random(1790582400)
    for k, (tag, (a, b)) in enumerate(_near(D, rng, corr["value"], _CMP[corr["op"]],
                                            lambda t, base: (norm(t), norm(base)),
                                            lambda a: len(a.split()) <= 6, 25)):
        assert len(a.split()) <= 6, a
        add("corrections_near", f"{k:02d}-{tag}", a, b)
    for k, (tag, (a, b)) in enumerate(_near(D, rng, fb["value"], _CMP[fb["op"]], _raw,
                                            lambda a: True, 25)):
        add("feedback_near", f"{k:02d}-{tag}", a, b)

    rng = random.Random(20260928)
    alphabets = ["ab", "abc", "ab ", "abcd", "aé😀", "áb"]
    for k in range(500):
        al = rng.choice(alphabets)
        a = "".join(rng.choice(al) for _ in range(rng.randint(0, 30)))
        b = "".join(rng.choice(al) for _ in range(rng.randint(0, 30)))
        add("seeded", f"{k:03d}", a, b)
    for k in range(40):
        al = rng.choice(alphabets + ["abcdefghij", _LETTERS + " "])
        a = "".join(rng.choice(al) for _ in range(rng.randint(150, 320)))
        b = "".join(rng.choice(al) for _ in range(rng.randint(190, 320)))
        add("seeded_long", f"{k:02d}", a, b)

    names = [c["name"] for c in cases]
    assert len(names) == len(set(names)), "duplicate case names"
    return cases


@suite("m1_difflib")
def difflib_suite(ctx):
    return _difflib_cases(ctx.J)
