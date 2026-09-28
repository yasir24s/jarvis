"""M1 T6 + T10 golden suites: m1_corrections, m1_history_app (plan: native/plan/M01 §2.5-2.7,
§3.7, §6 T6/T10).

Plugin for tools/golden.py. Every expected value comes from running jarvis.py's REAL
functions in the sandboxed child; nothing expected is typed here. Inputs are typed here.

m1_corrections — _corr_norm, _parse_teach / _is_teach_correction, and multi-step scenarios
over learn_correction / forget_correction / _apply_corrections with _corr_cache live: each
step records the reply, the corrections.json bytes, the in-memory cache and every
research_bump the step made. Literals the Swift port must hold (regex sources and flags, the
numeric thresholds, the cap) are read from jarvis.py with ast / the compiled patterns.

m1_history_app — app_context() over injected frontmost apps (a fake AppKit module drives the
real _front_app, so the "no app" and "nil name" branches are Python's own), track_feedback
scenarios under the frozen clock (research_bump and emotion_event recorded, not run), and
history scenarios: _history_load over malformed files, process_command's inline history
statements (read from its source with ast), _history_save bytes, _claude_history_preamble.

Divergences are `native` blocks inside `expected`, computed here from the stated native
rule, so the Swift test can assert native behaviour positively:
- `corr-malformed-pair-raises`: a hand-edited corrections.json pair whose heard/meant is not
  a string makes _apply_corrections raise (TypeError / AttributeError) in Python; native
  returns the transcript unchanged.
- `sub-literal-repl`: a hand-edited `meant` holding a backslash is a re.sub template in
  Python; native substitutes it literally (PyRegex.sub(_:literal:), M01 §3.3).
- `history-nonstring-content`: a loaded turn whose content is a truthy non-string makes
  _claude_history_preamble raise AttributeError; native skips that turn.
"""
import ast
import copy
import difflib
import json
import os
import re
import shutil
import sys
import types
from pathlib import Path

from golden import suite

_T0 = 1790582400.25                     # an epoch with a fraction, like time.time()


# ─── Source introspection (literals are never retyped) ──────────────────────────

def _tree(J):
    return ast.parse(open(J.__file__, encoding="utf-8").read())


def _function(tree, name):
    for n in ast.walk(tree):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError(f"jarvis.py has no function {name}")


def _compares(fn):
    """{source text of `x OP constant`: constant} for every numeric comparison in fn."""
    out = {}
    for n in ast.walk(fn):
        if (isinstance(n, ast.Compare) and len(n.ops) == 1
                and isinstance(n.comparators[0], ast.Constant)
                and isinstance(n.comparators[0].value, (int, float))
                and not isinstance(n.comparators[0].value, bool)):
            out[ast.unparse(n)] = n.comparators[0].value
    return out


def _slices(fn):
    """{source text of `x[lo:hi]`: [lo, hi]} for every slice with constant bounds."""
    def const(e):
        if e is None:
            return None
        v = ast.literal_eval(e)
        assert isinstance(v, int), ast.dump(e)
        return v
    out = {}
    for n in ast.walk(fn):
        if isinstance(n, ast.Subscript) and isinstance(n.slice, ast.Slice):
            out[ast.unparse(n)] = [const(n.slice.lower), const(n.slice.upper)]
    return out


def _re_sub_literals(fn):
    """[(pattern, repl)] of every re.sub(<str>, <str>, ...) call in fn, in source order."""
    calls = [n for n in ast.walk(fn)
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
             and n.func.attr == "sub" and isinstance(n.func.value, ast.Name)
             and n.func.value.id == "re" and isinstance(n.args[0], ast.Constant)]
    calls.sort(key=lambda n: (n.lineno, n.col_offset))
    return [[c.args[0].value, c.args[1].value] for c in calls]


def _str_tuples(fn):
    """Every tuple of string constants in fn (e.g. the `in (...)` exclusion lists)."""
    return [[e.value for e in n.elts] for n in ast.walk(fn)
            if isinstance(n, ast.Tuple) and n.elts
            and all(isinstance(e, ast.Constant) and isinstance(e.value, str) for e in n.elts)]


def _pattern(rx):
    return {"pattern": rx.pattern, "ignorecase": bool(rx.flags & re.I),
            "other_flags": rx.flags & ~(re.I | re.U)}


# ─── Files ──────────────────────────────────────────────────────────────────────

def _read(path):
    """The file as Python left it: None (absent), {"dir": true}, {"text"} or {"hex"}."""
    if os.path.isdir(path):
        return {"dir": True}
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        b = f.read()
    try:
        return {"text": b.decode("utf-8")}
    except UnicodeDecodeError:
        return {"hex": b.hex()}


def _put(path, spec):
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.remove(path)
    if spec is None:
        return
    if spec.get("dir"):
        os.mkdir(path)
    elif "text" in spec:
        with open(path, "wb") as f:
            f.write(spec["text"].encode("utf-8"))
    else:
        with open(path, "wb") as f:
            f.write(bytes.fromhex(spec["hex"]))


def _indent1(value):
    """A synthetic initial file in the corrections writer's own style (indent=1)."""
    return {"text": json.dumps(value, indent=1)}


class _Effects:
    """Records research_bump / emotion_event calls in order (they are not run)."""

    def __init__(self, J, emotions=False):
        self.log = []
        J.research_bump = lambda key, n=1: self.log.append(["bump", key, n])
        if emotions:
            J.emotion_event = lambda name, mag=1.0: self.log.append(["emotion", name, mag])

    def take(self):
        out, self.log = self.log, []
        return out


# ─── m1_corrections ─────────────────────────────────────────────────────────────

_NORM_INPUTS = [
    "", "   ", "Hello", "  Hello,   World!  ", "It's JARVIS.", "jar-vis", "jar_vis", "a\tb\nc",
    "a\xa0b", "x\u2028y", "tab\x1fsep", "Café Olé", "naïve", "e\u0301", "İstanbul", "ΣΑΣ",
    "Straße", "日本語のテキスト", "play 🎵 music", "100% sure", "C:\\Users\\x", "“quoted” — dash",
    "Rock'n'roll's", "  --  ", "Ⅻ roman", "½ half", "a_b-c.d", "UPPER lower MiXeD", "\u0345", "x\u200by",
]

_TEACH_INPUTS = [
    "I said Morgan not Organ", "i meant tea not tree", "It's JARVIS, not Service!",
    "its jarvis not service", "The word is 'Crème' not Crem.", "that's right not left",
    "thats right not left", "correct Organ to Morgan", "please correct jarvus to jarvis",
    "correct a to b to c", "When I say Jar Vis I mean Jarvis.", "when i say foo i meant bar",
    "I said a not b not c", "I said foo not", "correct to bar", "hello there", "",
    "   ", "I said x\u00a0not y", "I said a\nnot b", "forget the correction for organ",
    "forget corrections", "Forget the corrections for all", "forget all corrections",
    "please forget the correction", "I said !!! not ???", "I said Morgan not Organ, thanks",
    "well it's a not b", "I SAID FOO NOT BAR", "correct foo into bar",
    "i said one two three not four five six",
]

# Hand-edited corrections.json content for load / cap / malformed scenarios.
_MIXED = [
    {"heard": "organ", "meant": "morgan", "added": 1790580000.5},
    {"heard": "", "meant": "empty heard"},
    {"heard": "no meant"},
    {"meant": "no heard"},
    "a string entry",
    ["a", "list"],
    None,
    {"heard": None, "meant": "x"},
    {"heard": "zero meant", "meant": 0},
    {"heard": "service", "meant": "jarvis", "added": 1790580001, "note": "extra key kept"},
]


def _cap_file():
    return [{"heard": f"word{k:03d}", "meant": f"fixed{k:03d}", "added": 1790500000.0 + k}
            for k in range(205)]


def _named(i):
    """The public-repo rule: skip borrowed m1_difflib pairs built on its "send a message to
    <first name>" base, so no person's name is copied into these fixtures."""
    return "message to" in (i["a"] + " " + i["b"]).lower()


def _fuzzy_steps():
    """Fuzzy whole-utterance cases around 0.82, from the m1_difflib fixture's
    corrections / corrections_near pairs (a = normalised utterance, b = heard)."""
    fx = Path(__file__).resolve().parents[1] / "Tests/Fixtures/golden/m1_difflib.golden.json"
    cases = json.loads(fx.read_text(encoding="utf-8"))["cases"]
    out = []
    for c in cases:
        i = c["input"]
        if i["group"] not in ("corrections", "corrections_near") or _named(i):
            continue
        out.append((c["name"], i["a"], i["b"]))
    return out


def _scenarios():
    """(name, initial corrections.json spec, [step]). A step is {"op", ...}:
    learn / forget / apply {"text"[, "at"]}; external_write {"file"}; restart {}."""
    L = lambda text, at=_T0: {"op": "learn", "text": text, "at": at}
    F = lambda text: {"op": "forget", "text": text}
    A = lambda text: {"op": "apply", "text": text}
    S = [
        ("teach_then_apply", None, [
            A("call Organ now"), L("I said Morgan not Organ"), A("call Organ now"), A("Organ"),
            A("ORGAN, are you there?"), A("organ organ Organ"), A("organic is here"),
            A("ask organ's mum"), A(""), A("   "),
        ]),
        ("reteach_same_heard", None, [
            L("I said Morgan not Organ", _T0), L("correct tree to tea", _T0 + 1.5),
            L("correct Organ to Sam", _T0 + 2.75), A("tell organ and the tree"),
            L("when I say organ I mean organ", _T0 + 3),
        ]),
        ("teach_punctuation_case", None, [
            L("It's JARVIS, not Service!", _T0), L("The word is 'Crème' not Crem.", _T0 + 1),
            L("When I say Jar Vis I mean Jarvis.", _T0 + 2), L("that's right not left", _T0 + 3),
            L("I said Morgan not Organ, thanks", _T0 + 4), A("hey service"), A("Crem called"),
            A("jar vis open safari"), A("Jar-Vis open safari"), A("turn left here"),
        ]),
        ("teach_rejected", None, [
            L("hello there"), L("I said x not x"), L("I said foo not a"), L("I said !!! not ???"),
            L("correct !!! to foo"), L("I said Organ not organ"), L(""), A("foo a organ"),
        ]),
        ("forget_one_all_unknown", None, [
            L("I said Morgan not Organ", _T0), L("correct tree to tea", _T0 + 1),
            L("correct jarvus to jarvis", _T0 + 2), F("forget the correction for Organ."),
            F("forget the correction for tea"), F("forget the correction for nobody"),
            A("jarvus and organ and tree"), F("forget corrections for all"),
            L("correct jarvus to jarvis", _T0 + 3), F("forget the corrections everything"),
            L("correct jarvus to jarvis", _T0 + 4), F("forget corrections them all"),
            L("correct jarvus to jarvis", _T0 + 5), F("forget all corrections"),
            L("correct jarvus to jarvis", _T0 + 6), F("please forget the correction"),
            F("forget the correction for jarvus"),
        ]),
        ("forget_all_of_them_and_nomatch_text", None, [
            L("correct jarvus to jarvis", _T0), F("forget the corrections for all of them"),
            L("correct jarvus to jarvis", _T0 + 1), F("nothing to forget here"),
        ]),
        ("word_boundary", None, [
            L("correct join to joyn", _T0), A("rejoin the call"), A("joined the call"),
            A("join the call"), A("join."), A("please join"), A("join_now"), A("join-now"),
            A("JOIN the Join"),
        ]),
        ("multiword_and_punctuation_split", None, [
            L("correct no ted to noted", _T0), A("no ted please"), A("No Ted, please"),
            A("no-ted please"), A("no  ted please"), A("no\tted please"),
        ]),
        ("longest_first_and_chaining", _indent1([
            {"heard": "ted", "meant": "fred", "added": 1.0},
            {"heard": "no ted", "meant": "noted", "added": 2.0},
            {"heard": "fred", "meant": "freddie", "added": 3.0},
            {"heard": "abc", "meant": "first", "added": 4.0},
            {"heard": "xyz", "meant": "second", "added": 5.0},
        ]), [
            A("no ted please"), A("ted is here"), A("abc xyz"), A("tell ted"),
        ]),
        ("short_heard_skipped", _indent1([
            {"heard": "ab", "meant": "cd", "added": 1.0},
            {"heard": "abc", "meant": "xyz", "added": 2.0},
        ]), [
            A("ab ab"), A("ab"), A("abc ab"), L("correct ab to cd", _T0), A("ab"),
        ]),
        ("fuzzy_word_count", _indent1([
            {"heard": "turn on the living room lights", "meant": "LIGHTS ON", "added": 1.0},
        ]), [
            A("turn on the living room light"), A("turn on the living room lamps"),
            A("please turn on the living room light"),
            A("please now turn on the living room light"), A("Turn on the living-room lights!"),
            A("turn on the livingroom lights"),
        ]),
        ("fuzzy_then_next_pair", _indent1([
            {"heard": "play despacito now", "meant": "play despacito", "added": 1.0},
            {"heard": "despacito", "meant": "DESPACITO", "added": 2.0},
        ]), [
            A("play despasito now"), A("play despacito"),
        ]),
        ("teach_commands_never_altered", None, [
            L("I said Morgan not Organ", _T0), A("I said Organ not Robin"),
            L("I said Organ not Robin", _T0 + 1), A("forget the correction for organ"),
            A("correct organ to sam"), A("when I say organ I mean sam"), A("organ called"),
            A("robin called"),
        ]),
        ("cap_200", _indent1(_cap_file()), [
            A("word000 and word204"), L("correct word999 to fixed999", _T0), A("word000 word005"),
            {"op": "restart"}, A("word004 word005"),
        ]),
        ("cap_reteach_existing", _indent1(_cap_file()[:200]), [
            L("correct word000 to again000", _T0), A("word000"),
        ]),
        ("load_filters_malformed_entries", _indent1(_MIXED), [
            A("organ and service"), L("correct tree to tea", _T0), A("zero meant"),
        ]),
        ("load_not_a_list", {"text": '{"heard": "organ", "meant": "morgan"}'}, [
            A("organ"), L("I said Morgan not Organ", _T0), A("organ"),
        ]),
        ("load_string", {"text": '"organ"'}, [A("organ"), L("correct organ to morgan", _T0)]),
        ("load_invalid_json", {"text": '[{"heard": "organ", "meant": "morgan"'}, [
            A("organ"), L("correct organ to morgan", _T0),
        ]),
        ("load_empty_file", {"text": ""}, [A("organ"), L("correct organ to morgan", _T0)]),
        ("load_not_utf8", {"hex": "5b7b226865617264223a20226b61ff72656e227d5d"}, [
            A("organ"), L("correct organ to morgan", _T0),
        ]),
        ("load_null", {"text": "null"}, [A("organ"), F("forget the correction for organ")]),
        ("cache_ignores_external_write", None, [
            A("organ"),
            {"op": "external_write",
             "file": _indent1([{"heard": "organ", "meant": "morgan", "added": 1.0}])},
            A("organ"), {"op": "restart"}, A("organ"), L("correct tree to tea", _T0),
            {"op": "external_write", "file": _indent1([])}, A("tree"), {"op": "restart"},
            A("tree"),
        ]),
        ("save_fails_cache_still_updates", {"dir": True}, [
            A("organ"), L("I said Morgan not Organ", _T0), A("organ called"),
            F("forget the correction for organ"), A("organ called"),
        ]),
        ("unicode_pairs", None, [
            L("I said Crème not Crem", _T0), L("correct café to coffee", _T0 + 1),
            L("correct 日本 to japan", _T0 + 2), A("Crem and CAFÉ"), A("ask Crem"),
            A("日本 weather"), A("go to the cafe"),
        ]),
        ("nonstring_heard_int", _indent1([
            {"heard": "organ", "meant": "morgan", "added": 1.0},
            {"heard": 5, "meant": "five", "added": 2.0},
        ]), [
            A("organ"), L("correct tree to tea", _T0), F("forget the correction for tree"),
        ]),
        ("nonstring_heard_list", _indent1([
            {"heard": ["a", "b", "c"], "meant": "abc", "added": 1.0},
            {"heard": ["a"], "meant": "short list", "added": 2.0},
        ]), [
            A("organ"),
        ]),
        ("nonstring_heard_short_list_only", _indent1([
            {"heard": ["a"], "meant": "short list", "added": 2.0},
            {"heard": "organ", "meant": "morgan", "added": 3.0},
        ]), [
            A("organ"),
        ]),
        ("nonstring_meant", _indent1([
            {"heard": "organ", "meant": 7, "added": 1.0},
        ]), [
            A("hello there"), A("organ"), A("orgun"), A("orgn"),
        ]),
        ("backslash_meant", _indent1([
            {"heard": "organ", "meant": "m\\-organ", "added": 1.0},
            {"heard": "service", "meant": "jar\\\\vis", "added": 2.0},
        ]), [
            A("organ"), A("service"),
        ]),
    ]
    for name, a, b in _fuzzy_steps():
        S.append((f"fuzzy_{name.replace('/', '_')}",
                  _indent1([{"heard": b, "meant": "MEANT", "added": 1.0}]), [A(a)]))
    return S


def _corr_step(ctx, fx, st):
    J = ctx.J
    op = st["op"]
    if "at" in st:
        ctx.at(st["at"])
    out = {}
    try:
        if op == "learn":
            out["result"] = J.learn_correction(st["text"])
        elif op == "forget":
            out["result"] = J.forget_correction(st["text"])
        elif op == "apply":
            out["result"] = J._apply_corrections(st["text"])
        elif op == "external_write":
            _put(J.CORR_FILE, st["file"])
        elif op == "restart":
            J._corr_cache = None
        else:
            raise ValueError(op)
    except (TypeError, AttributeError) as e:
        out["raises"] = type(e).__name__
    out["file"] = _read(J.CORR_FILE)
    out["cache"] = copy.deepcopy(J._corr_cache)
    out["effects"] = fx.take()
    return out


def _native_apply(text, cache):
    """The native rule (see the module docstring): Python's pass with every `meant` taken
    literally, and the transcript unchanged wherever Python would raise."""
    if not text or _is_teach_py(text) or not cache:
        return text
    if any(not isinstance(p.get("heard", ""), (str, list, dict)) for p in cache):
        return text                                     # len() in the sort key raises
    result, norm = text, _norm_py(text)
    for p in sorted(cache, key=lambda x: -len(x.get("heard", ""))):
        heard, meant = p["heard"], p["meant"]
        if len(heard) < 3:
            continue
        if not isinstance(heard, str):
            return text                                 # re.escape(list/dict) raises
        if re.search(rf"\b{re.escape(heard)}\b", norm):
            if not isinstance(meant, str):
                return text                             # re.sub(repl=non-str) raises
            result = re.sub(rf"\b{re.escape(heard)}\b", lambda _m: meant, result, flags=re.I)
            norm = _norm_py(result)
        elif len(norm.split()) <= 6 and difflib.SequenceMatcher(None, norm, heard).ratio() >= 0.82:
            if not isinstance(meant, str):
                return text                             # _corr_norm(non-str) raises
            result, norm = meant, _norm_py(meant)
    return result


def _apply_native_block(text, cache, py):
    """A `native` block when the native rule differs from Python — allowed only for the
    hand-edited shapes the docstring lists (anything else is a model error: fail)."""
    nat = _native_apply(text, cache)
    if "raises" not in py and nat == py["result"]:
        return None
    odd = [p for p in cache or [] if not isinstance(p.get("heard"), str)
           or not isinstance(p.get("meant"), str)]
    slash = [p for p in cache or [] if isinstance(p.get("meant"), str) and "\\" in p["meant"]]
    if "raises" in py:
        assert odd, f"Python raised with only string pairs: {text!r}"
        return {"divergence": "corr-malformed-pair-raises", "result": nat}
    assert slash and not odd, f"native model differs from Python on {text!r}: {nat!r} vs {py!r}"
    return {"divergence": "sub-literal-repl", "result": nat}


def _is_teach_py(text):
    return bool(_TEACH_RES and (any(r.search((text or "").strip()) for r in _TEACH_RES[:3])
                                or _TEACH_RES[3].search(text or "")))


_TEACH_RES = []


def _norm_py(s):
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", (s or "").lower())).strip()


def _corr_constants(J):
    t = _tree(J)
    return {
        "patterns": {n: _pattern(getattr(J, n)) for n in
                     ("_CORR_SAID_RE", "_CORR_TO_RE", "_CORR_WHEN_RE", "_CORR_FORGET_RE")},
        "norm_subs": _re_sub_literals(_function(t, "_corr_norm")),
        "save_slices": _slices(_function(t, "_corrections_save")),
        "learn_compares": _compares(_function(t, "learn_correction")),
        "forget_all_words": _str_tuples(_function(t, "forget_correction")),
        "apply_compares": _compares(_function(t, "_apply_corrections")),
    }


@suite("m1_corrections")
def corrections_suite(ctx):
    J = ctx.J
    assert _norm_py("A-b  C!") == J._corr_norm("A-b  C!")
    _TEACH_RES[:] = [J._CORR_SAID_RE, J._CORR_TO_RE, J._CORR_WHEN_RE, J._CORR_FORGET_RE]
    fx = _Effects(J)
    cases = [{"name": "constants", "input": {"kind": "constants"},
              "expected": _corr_constants(J)}]
    for k, s in enumerate(_NORM_INPUTS):
        cases.append({"name": f"norm/{k:02d} {s!r}", "input": {"kind": "norm", "text": s},
                      "expected": {"result": J._corr_norm(s)}})
    for k, s in enumerate(_TEACH_INPUTS):
        hm = J._parse_teach(s)
        cases.append({"name": f"teach/{k:02d} {s!r}", "input": {"kind": "teach", "text": s},
                      "expected": {"parse": list(hm) if hm else None,
                                   "is_teach": bool(J._is_teach_correction(s))}})
    for name, initial, steps in _scenarios():
        ctx.reset()
        ctx.at(_T0)
        _put(J.CORR_FILE, initial)
        fx.take()
        results = []
        for st in steps:
            before = copy.deepcopy(J._corr_cache)
            r = _corr_step(ctx, fx, st)
            if st["op"] == "apply":
                cache = before if before is not None else J._corr_cache
                nat = _apply_native_block(st["text"], cache, r)
                if nat:
                    r["native"] = nat
            results.append(r)
        cases.append({"name": f"scenario/{name}",
                      "input": {"kind": "scenario", "initial": initial, "steps": steps},
                      "expected": {"steps": results}})
    return cases


# ─── m1_history_app ─────────────────────────────────────────────────────────────

_APPS = [
    ("xcode", "name", "Xcode"), ("music", "name", "Music"), ("empty", "name", ""),
    ("jarvis", "name", "jarvis"), ("JARVIS", "name", "JARVIS"), ("Jarvis", "name", "Jarvis"),
    ("finder", "name", "Finder"), ("FINDER", "name", "FINDER"),
    ("loginwindow", "name", "loginwindow"), ("LoginWindow", "name", "LoginWindow"),
    ("finder_trailing_space", "name", "Finder "), ("jarvis_hud", "name", "JARVIS HUD"),
    ("cafe", "name", "Café Olé"), ("cjk", "name", "日本語アプリ"), ("emoji", "name", "📝 Notes"),
    ("dotted_I", "name", "İnstagram"), ("sigma", "name", "ΣΑΣ"), ("kelvin_finder", "name", "\u212aFinder"),
    ("braces", "name", "{app} 100%"), ("newline", "name", "Line\nBreak"),
    ("literal_None", "name", "None"), ("long", "name", "Visual Studio Code — Insiders " * 4),
    ("no_frontmost_app", "no_app", None), ("nil_localized_name", "nil_name", None),
    ("workspace_raises", "raises", None),
]


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


def _feedback_scenarios():
    """(name, initial _LAST_CMD, [(text, at)])."""
    T = _T0
    fresh = {"text": "", "at": 0.0}
    S = [
        ("first_command_never_rephrase", fresh, [("turn on the lights", T)]),
        ("rephrase_within_window", fresh, [("turn on the lights", T), ("turn on the light", T + 5)]),
        ("window_29_9", fresh, [("turn on the lights", T), ("turn on the light", T + 29.9)]),
        ("window_29_999999", fresh, [("turn on the lights", T), ("turn on the light", T + 29.999999)]),
        ("window_30_0", fresh, [("turn on the lights", T), ("turn on the light", T + 30.0)]),
        ("window_30_1", fresh, [("turn on the lights", T), ("turn on the light", T + 30.1)]),
        ("clock_backwards", fresh, [("turn on the lights", T), ("turn on the light", T - 100)]),
        ("clock_backwards_far", fresh, [("turn on the lights", T), ("turn on the light", 0.0)]),
        ("identical_text_not_rephrase", fresh, [("stop", T), ("stop", T + 1)]),
        ("dissimilar", fresh, [("tell me a joke", T), ("what's on my calendar", T + 2)]),
        ("negative_first", fresh, [("no, I said lights", T)]),
        ("negative_beats_rephrase", fresh, [("turn on the lights", T), ("no, I meant the lights", T + 1)]),
        ("negative_updates_last", fresh, [("cancel that", T), ("cancel that now", T + 1)]),
        ("negatives", fresh, [(s, T + k) for k, s in enumerate([
            "No, I said lights", "no i meant kitchen", "that's not it", "not what I asked",
            "that's wrong", "thats not right", "wrong answer", "Cancel that", "undo that",
            "never mind", "nevermind", "NEVER MIND", "no that is fine", "I said no", "wrongly",
            "cancel", "mind your step", "not what I expected"])]),
        ("chain_updates_last", fresh, [
            ("play some jazz music", T), ("play some jazz musik", T + 10),
            ("play some jazz musics", T + 20), ("play some jazz", T + 45),
            ("play some jaz", T + 74.9)]),
        ("empty_text", fresh, [("", T), ("", T + 1), ("turn on", T + 2), ("", T + 3)]),
        ("initial_state_at_zero", {"text": "turn on the light", "at": 0.0}, [("turn on the lights", 10.0)]),
        ("unicode", fresh, [("café near me", T), ("cafe near me", T + 3),
                            ("日本の天気は", T + 4), ("日本の天気", T + 5)]),
    ]
    fx = Path(__file__).resolve().parents[1] / "Tests/Fixtures/golden/m1_difflib.golden.json"
    for c in json.loads(fx.read_text(encoding="utf-8"))["cases"]:
        i = c["input"]
        if i["group"] in ("feedback", "feedback_near") and not _named(i):
            # a = the new text, b = the previous command (track_feedback's argument order)
            S.append((f"pair_{c['name'].replace('/', '_')}", {"text": i["b"], "at": T},
                      [(i["a"], T + 1.0)]))
    return S


def _history_source(J):
    """process_command's inline history statements, checked against their source text, plus
    the constants of _history_load / _history_save / _claude_history_preamble."""
    t = _tree(J)
    pc = {ast.unparse(n) for n in ast.walk(_function(t, "process_command")) if isinstance(n, ast.stmt)}
    stmts = {
        "append_user": "_history.append({'role': 'user', 'content': text})",
        "trim": "_history = _history[-12:]",
        "append_assistant_reply": "_history.append({'role': 'assistant', 'content': reply})",
        "append_assistant_content": "_history.append({'role': 'assistant', 'content': content})",
        "append_assistant_empty": "_history.append({'role': 'assistant', 'content': ''})",
        "pop_trailing_user": "if _history and _history[-1].get('role') == 'user':\n    _history.pop()",
    }
    missing = [k for k, v in stmts.items() if v not in pc]
    assert not missing, f"process_command history statements changed: {missing}"
    return {
        "process_command_slices": {k: v for k, v in _slices(_function(t, "process_command")).items()
                                   if k.startswith("_history")},
        "load_slices": _slices(_function(t, "_history_load")),
        "load_roles": _str_tuples(_function(t, "_history_load")),
        "save_slices": _slices(_function(t, "_history_save")),
        "preamble_slices": _slices(_function(t, "_claude_history_preamble")),
    }


def _history_op(J, op, arg):
    """process_command's statements (their source is asserted by _history_source)."""
    if op == "load":
        J._history = J._history_load()
    elif op == "user":
        J._history.append({"role": "user", "content": arg})
        J._history = J._history[-12:]
    elif op == "assistant":
        J._history.append({"role": "assistant", "content": arg})
    elif op == "pop":
        if J._history and J._history[-1].get("role") == "user":
            J._history.pop()
    elif op == "save":
        J._history_save()
    elif op == "preamble":
        return J._claude_history_preamble()
    else:
        raise ValueError(op)
    return None


def _turns(n, start=0):
    out = []
    for k in range(start, start + n):
        out.append({"role": "user" if k % 2 == 0 else "assistant", "content": f"turn {k:02d}"})
    return out


def _history_scenarios():
    """(name, initial history.json spec, [[op, arg]]). Every scenario starts with a load."""
    u = lambda s: ["user", s]
    a = lambda s: ["assistant", s]
    P, SV, POP, LD = ["preamble", None], ["save", None], ["pop", None], ["load", None]
    txt = lambda v: {"text": json.dumps(v)}
    mixed = [
        {"role": "user", "content": "kept user"},
        {"role": "system", "content": "dropped system"},
        {"role": "tool", "content": "dropped tool"},
        "a string",
        None,
        ["role", "user"],
        {"content": "no role"},
        {"role": "assistant", "content": "kept assistant", "extra": [1, 2.5, None]},
        {"role": "USER", "content": "wrong case"},
        {"role": 1, "content": "numeric role"},
        {"role": "assistant"},
        {"role": "user", "content": None},
        {"role": "user", "content": "  padded  \n"},
        {"role": "assistant", "content": 0},
        {"role": "user", "content": ""},
    ]
    return [
        ("missing_file", None, [LD, P, u("hello"), P, a("Hello, sir."), SV, u("again"), P, SV]),
        ("empty_file", {"text": ""}, [LD, u("x"), SV]),
        ("invalid_json", {"text": '[{"role": "user", "content": "x"}'}, [LD, u("y"), SV]),
        ("json_object", txt({"role": "user", "content": "x"}), [LD, u("y"), SV]),
        ("json_string", txt("user"), [LD, SV]),
        ("json_number", {"text": "12"}, [LD, SV]),
        ("json_null", {"text": "null"}, [LD, SV]),
        ("not_utf8", {"hex": "5b7b22726f6c65223a202275736572222c2022636f6e74656e74223a2022ff227d5d"},
         [LD, SV]),
        ("bom", {"text": "\ufeff" + json.dumps(_turns(2))}, [LD, SV]),
        ("mixed_entries", txt(mixed), [LD, P, u("next"), P, SV]),
        ("load_keeps_last_12", txt(_turns(20)), [LD, P, SV]),
        ("load_filters_then_last_12", txt(_turns(10) + [{"role": "system", "content": "s"}] * 5
                                          + _turns(6, 10)), [LD, SV]),
        ("cap_12_rolling", None, [LD] + [x for k in range(8) for x in (u(f"q{k}"), a(f"a{k}"))]
         + [P, SV, u("q8"), P, SV]),
        ("thirteen_in_memory", txt(_turns(12)), [LD, a("extra assistant"), SV, u("then user"), SV]),
        ("pop_trailing_user", txt(_turns(3)), [LD, u("failed turn"), POP, SV, POP, SV]),
        ("pop_empty", None, [LD, POP, SV]),
        ("preamble_window", txt(_turns(12)), [LD, P, u("current"), P]),
        ("preamble_skips_blank", None, [LD, u("first"), a("   "), u("second"), a(""),
                                        u("  third  "), a("reply\nwith newline"), u("now"), P]),
        ("preamble_single_turn", None, [LD, u("only"), P]),
        ("unicode_content", None, [LD, u("Café — “quoted” 🎵 日本"), a("Sí, señor.\tTab"), SV, P]),
        ("nonstring_content", txt([{"role": "user", "content": 5},
                                   {"role": "assistant", "content": "ok"},
                                   {"role": "user", "content": "now"}]), [LD, P, SV]),
        ("save_empty_after_pop", None, [LD, u("x"), POP, SV]),
        ("extra_keys_round_trip", txt([{"role": "assistant", "content": "c", "images": [],
                                        "tool_calls": None, "z": {"a": 1e-07}}]),
         [LD, SV, u("q"), SV]),
    ]


def _native_preamble(turns, py):
    """history-nonstring-content: native skips a turn whose content is a truthy non-string."""
    if "raises" not in py:
        return None
    lines = []
    for m in turns[-7:-1]:
        c = m.get("content") or ""
        if not isinstance(c, str):
            continue
        c = c.strip()
        if c:
            lines.append(("User: " if m.get("role") == "user" else "You: ") + c)
    return {"divergence": "history-nonstring-content",
            "result": ("\n\nRecent conversation:\n" + "\n".join(lines)) if lines else ""}


@suite("m1_history_app")
def history_app_suite(ctx):
    J = ctx.J
    fx = _Effects(J, emotions=True)
    t = _tree(J)
    cases = [{"name": "constants", "input": {"kind": "constants"}, "expected": {
        "feedback_pattern": _pattern(J._FEEDBACK_NEG_RE),
        "feedback_compares": _compares(_function(t, "track_feedback")),
        "last_cmd_initial": dict(J._LAST_CMD),
        "app_exclusions": _str_tuples(_function(t, "app_context")),
        "history": _history_source(J),
    }}]

    real_appkit = sys.modules.get("AppKit")
    try:
        for name, mode, value in _APPS:
            sys.modules["AppKit"] = _fake_appkit(mode, value)
            cases.append({"name": f"app/{name}",
                          "input": {"kind": "app", "mode": mode, "name": value},
                          "expected": {"front_app": J._front_app(), "context": J.app_context()}})
    finally:
        if real_appkit is None:
            sys.modules.pop("AppKit", None)
        else:
            sys.modules["AppKit"] = real_appkit

    for name, initial, steps in _feedback_scenarios():
        J._LAST_CMD.clear()
        J._LAST_CMD.update(initial)
        fx.take()
        results = []
        for text, at in steps:
            ctx.at(at)
            J.track_feedback(text)
            results.append({"effects": fx.take(), "last": dict(J._LAST_CMD)})
        cases.append({"name": f"feedback/{name}",
                      "input": {"kind": "feedback", "initial": initial,
                                "steps": [{"text": s, "at": at} for s, at in steps]},
                      "expected": {"steps": results}})

    for name, initial, ops in _history_scenarios():
        ctx.reset()
        _put(J.HIST_FILE, initial)
        results = []
        for op, arg in ops:
            r = {}
            try:
                res = _history_op(J, op, arg)
                if op == "preamble":
                    r["result"] = res
            except AttributeError as e:
                r["raises"] = type(e).__name__
            if op == "preamble":
                nat = _native_preamble(J._history, r)
                if nat:
                    r["native"] = nat
            r["turns"] = copy.deepcopy(J._history)
            if op == "save":
                r["file"] = _read(J.HIST_FILE)
            results.append(r)
        cases.append({"name": f"history/{name}",
                      "input": {"kind": "history", "initial": initial,
                                "ops": [[op, arg] for op, arg in ops]},
                      "expected": {"steps": results}})
    return cases
