"""M1 golden suites for Python str / re semantics: m1_strings (plan: M01 §3.2, §4.1).

Plugin for tools/golden.py (it imports every tools/golden_*.py). Only the *inputs* below are
typed by hand; every expected value is computed here by running Python 3.14 itself.

m1_strings: str.lower/strip/strip(chars)/lstrip/rstrip/split/splitlines, s[:n], len, ==,
`in`, startswith, a[-n:], min/max on floats (bit-exact) and set() of strings, over a corpus
of adversarial strings (Final_Sigma, İ, ß, decomposed é, ZWJ emoji, flags, the \x1c-\x1f and
\x85 separators, NBSP, U+3000, \r\n, empty). Plus whole-Unicode tables: the isspace list,
re `\\w` as ranges, every scalar whose lower() is not itself, and three Final_Sigma probes
that expose Python's cased / case-ignorable data through lower(); plus the scalars that
Python's unicodedata leaves unassigned (Cn), which bounds the Unicode-version divergence.
"""
import re
import struct
import unicodedata

from golden import suite

_MAX = 0x110000


def _scalars():
    """Every Unicode scalar value (surrogates cannot be held by a Swift String)."""
    for cp in range(_MAX):
        if not 0xD800 <= cp <= 0xDFFF:
            yield cp


def _ranges(pred):
    """[[lo, hi], ...] (inclusive) of the scalars where pred(cp) holds."""
    out = []
    for cp in _scalars():
        if pred(cp):
            if out and out[-1][1] == cp - 1:
                out[-1][1] = cp
            else:
                out.append([cp, cp])
    return out


def _bits(x):
    return struct.pack(">d", x).hex()


def _unbits(h):
    return struct.unpack(">d", bytes.fromhex(h))[0]


# ─── m1_strings ─────────────────────────────────────────────────────────────────

# Inputs only. The §4.1 must-includes first, then realistic jarvis.py shapes.
_CORPUS = [
    "",
    " ",
    "  \t\n ",
    "hello",
    "Hello World",
    "  Hello, World.  ",
    "ΟΔΟΣ",
    "Σ",
    "ΑΣ.",
    "ΑΣ",
    "ΣΑΣ",
    "ΣΣΣ",
    "ὈΔΥΣΣΕΎΣ",
    "ΑΣ Α",
    "ΑΣ'Α",
    "Α'Σ",
    "Α'Σ'",
    "ΑΣ́",
    "ʰΣ",
    "AʰΣ",
    "1Σ",
    "İ",
    "İstanbul",
    "ß",
    "ẞ",
    "Straße",
    "café",
    "café",
    "CAFÉ",
    "ǅungla",
    "ﬁ ﬀ ŉ",
    "Kelvin K",
    "ſ",
    "👨‍👩‍👧 family",
    "🇬🇧🇫🇷",
    "\x1c\x1d\x1e\x1f",
    "a\x1cb\x1dc\x1ed\x1fe",
    "\x85x\x85",
    " thin ",
    " narrow ",
    "\xa0nbsp\xa0",
    "　wide　",
    " ogham᠎",
    "a​b﻿",
    "a\r\nb",
    "a\rb\nc",
    "\r\n",
    "\n",
    "a\n\nb\n",
    "\n\r\n\r",
    " x y",
    "\x0bv\x0cf",
    "line1\nline2\r\nline3\rline4",
    "tab\tsep  multi   space",
    "- • bullet point.",
    "•• -text-",
    "--•  - Keep it short.",
    "the user likes it.",
    "value . . .",
    "Remember that I like tea. ",
    "...",
    " . ",
    "Profanity is ON: the user said you may swear",
]

_CHARS = [" .", ".", "-• ", "é", "Σσ"]

_PREFIX_N = [0, 1, 2, 3, 60, -1, -3]

_EQ_PAIRS = [
    ("café", "café"),
    ("café", "café"),
    ("Σ", "σ"),
    ("", ""),
    ("a", "a "),
    ("K", "K"),
    ("Å", "Å"),
    ("hello", "hello"),
]

_CONTAINS_PAIRS = [
    ("café", "cafe"),
    ("café", "e"),
    ("café", "e"),
    ("café", "́"),
    ("👨‍👩‍👧", "👩"),
    ("🇬🇧🇫🇷", "🇧🇫"),
    ("hello world", "o w"),
    ("hello", ""),
    ("", ""),
    ("", "a"),
    ("abc", "abcd"),
    ("the user likes tea", "the user"),
    ("Å", "A"),
]

_STARTS_PAIRS = [
    ("café", "cafe"),
    ("café", "cafe"),
    ("the user likes tea", "the user"),
    ("The user likes tea", "the user"),
    ("", ""),
    ("abc", ""),
    ("", "a"),
    ("👨‍👩‍👧", "👨"),
    ("🇬🇧🇫🇷", "🇬"),
]

_TAIL_K = [0, 1, 3, 10]
_TAIL_N = [-2, -1, 0, 1, 3, 10, 20]

_FLOATS = [0.0, -0.0, 1.0, -1.0, 0.5, 1e-300, float("inf"), float("-inf"), float("nan")]

_SETS = [
    ["café", "café", "café"],
    ["a", "b", "a", "A"],
    ["Σ", "σ", "ς", "σ"],
    [],
    ["", "", " "],
    ["K", "K", "k", "K"],
    ["👨‍👩‍👧", "👨", "👨‍👩‍👧"],
]


def _strings_cases():
    cases = []

    def add(op, name, inp, exp):
        cases.append({"name": f"{op}#{len(cases):04d} {name}", "input": {"op": op, **inp},
                      "expected": exp})

    for s in _CORPUS:
        tag = ascii(s)[:40]
        add("lower", tag, {"s": s}, {"out": s.lower()})
        add("strip", tag, {"s": s}, {"out": s.strip()})
        add("split", tag, {"s": s}, {"out": s.split()})
        add("splitlines", tag, {"s": s}, {"out": s.splitlines()})
        add("len", tag, {"s": s}, {"out": len(s)})
        for chars in _CHARS:
            ctag = f"{tag} chars={ascii(chars)}"
            add("strip_chars", ctag, {"s": s, "chars": chars}, {"out": s.strip(chars)})
            add("lstrip_chars", ctag, {"s": s, "chars": chars}, {"out": s.lstrip(chars)})
            add("rstrip_chars", ctag, {"s": s, "chars": chars}, {"out": s.rstrip(chars)})
        for n in _PREFIX_N:
            add("prefix", f"{tag} n={n}", {"s": s, "n": n}, {"out": s[:n]})

    for a, b in _EQ_PAIRS:
        add("eq", f"{ascii(a)} {ascii(b)}", {"a": a, "b": b}, {"out": a == b})
    for hay, needle in _CONTAINS_PAIRS:
        add("contains", f"{ascii(needle)} in {ascii(hay)}", {"hay": hay, "needle": needle},
            {"out": needle in hay})
    for s, p in _STARTS_PAIRS:
        add("startswith", f"{ascii(s)} {ascii(p)}", {"s": s, "p": p}, {"out": s.startswith(p)})
    for k in _TAIL_K:
        for n in _TAIL_N:
            a = list(range(k))
            add("tail", f"k={k} n={n}", {"a": a, "n": n}, {"out": a[-n:]})
    for x in _FLOATS:
        for y in _FLOATS:
            pair = f"{x!r} {y!r}"
            add("pymin", pair, {"a": _bits(x), "b": _bits(y)}, {"out": _bits(min(x, y))})
            add("pymax", pair, {"a": _bits(x), "b": _bits(y)}, {"out": _bits(max(x, y))})
        # the jarvis.py clamp idiom min(1.0, max(0.0, x))
        add("clamp01", repr(x), {"x": _bits(x)}, {"out": _bits(min(1.0, max(0.0, x)))})
    for xs in _SETS:
        add("pykey_set", ascii(xs)[:60], {"xs": xs},
            {"distinct": list(dict.fromkeys(xs)), "count": len(set(xs))})

    # Whole-Unicode tables. Swift's Unicode.Scalar.Properties may carry a newer Unicode than
    # Python's unicodedata; the tables that depend on it carry a `native` block naming that
    # divergence, and table_unassigned gives native the Python-side data to bound it with.
    word = re.compile(r"\w")
    version = {"divergence": "unicode-version", "python_unidata": unicodedata.unidata_version}
    add("table_isspace", "str.isspace over all scalars", {},
        {"isspace": [cp for cp in _scalars() if chr(cp).isspace()]})
    add("table_unassigned", f"unicodedata {unicodedata.unidata_version} category Cn", {},
        {"unidata_version": unicodedata.unidata_version,
         "unassigned": _ranges(lambda cp: unicodedata.category(chr(cp)) == "Cn")})
    add("table_word", "re \\w over all scalars", {},
        {"word_ranges": _ranges(lambda cp: word.match(chr(cp)) is not None), "native": version})
    add("table_lower", "every scalar whose lower() differs", {},
        {"lower": [[cp, chr(cp).lower()] for cp in _scalars() if chr(cp).lower() != chr(cp)],
         "native": version})
    # Final_Sigma probes (U+03A3 ends/starts the probe, U+0391 and "A" are cased letters):
    #   "A" + c + "Σ" → ς  iff c is case-ignorable or cased
    #   c + "Σ"       → ς  iff c is cased and not case-ignorable
    #   "ΑΣ" + c      → ς  iff c is case-ignorable or not cased
    add("table_sigma", "lower() Final_Sigma probes over all scalars", {},
        {"after_cased_c": _ranges(lambda cp: ("A" + chr(cp) + "Σ").lower()[-1] == "ς"),
         "after_c": _ranges(lambda cp: (chr(cp) + "Σ").lower()[-1] == "ς"),
         "before_c": _ranges(lambda cp: ("ΑΣ" + chr(cp)).lower()[1] == "ς"),
         "native": version})
    return cases


@suite("m1_strings")
def strings_suite(ctx):
    return _strings_cases()
