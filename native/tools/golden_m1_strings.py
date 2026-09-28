"""M1 golden suites for Python str / re semantics: m1_strings, m1_regex (M01 §3.2, §3.3, §4.1).

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
import ast
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


# ─── m1_regex ───────────────────────────────────────────────────────────────────
#
# Every regex the M1 subsystems use (M01 §2.10, §4.1). Compiled module-level patterns are
# read from ctx.J by name (their .pattern/.flags, never retyped); the inline ones (re.sub /
# re.findall / re.match with a literal pattern, and the f-string pattern in
# _apply_corrections) are read from jarvis.py's own source with ast. Inputs are typed here;
# every expectation is Python's own result.

_COMPILED = ["_CORR_SAID_RE", "_CORR_TO_RE", "_CORR_WHEN_RE", "_CORR_FORGET_RE",
             "_FORGET_ALL_RE", "_FORGET_ONE_RE", "_PERSONALITY_FORGET_RE",
             "_EMO_PRAISE_RE", "_EMO_THANKS_RE", "_EMO_INSULT_RE", "_FEEDBACK_NEG_RE"]
_COMPILED_LISTS = ["_PROFILE_PATTERNS", "_STYLE_PATTERNS"]      # [(pattern, x), ...]
# Functions whose inline re.* calls are in M1 scope, with the number of calls each must have
# (a changed jarvis.py fails generation instead of silently dropping a pattern).
_INLINE_FUNCS = {"_corr_norm": 2, "_apply_corrections": 2, "set_tone": 1, "kb_lookup": 2,
                 "personality_learn": 3}
_RE_FUNCS = {"sub", "search", "match", "findall", "fullmatch", "compile", "split"}

# Inputs appended to every pattern: the §4.1 case-fold adversaries and line-terminator probes.
_ADVERSARIES = ["", "impreßive", "piß off", "fuck oﬀ", "ſtop swearing", "K", "İ", "ΣΑΣ",
                "Kelvin", "that was IMPRESSIVE\r\nthanks", "a b", "line one\nline two",
                "é", "ͅ", "👍 good job 👍", "Straße"]

_INPUTS = {
    "_CORR_SAID_RE": [
        "I said Kieran not Karen", "i meant tea not tree", "it's jarvis not travis",
        "its jarvis not travis", "The word is ‘Siobhán’ not Shivon", "that's Zoë not Zoey",
        "thats right not left", "I SAID FOO NOT BAR", "Well, I said café not cafe.",
        "I said x\xa0not y", "I said x not y", "I said a\nnot b", "I said a b\nc not d",
        "I said foo\rnot bar", "I said foo not bar", "I said a not b not c",
        "I sad foo not bar", "I said foo nor bar", "isaid foo not bar", "this is not it",
        "I said foo not", "I said foo knot bar", "hi said foo not bar", "It’s foo not bar",
        "İ said foo not bar", "I SAİD foo not bar", "I ſaid foo not bar", "I said ß not ss",
    ],
    "_CORR_TO_RE": [
        "correct Karen to Kieran", "Correct tree to tea please", "CORRECT FOO TO BAR",
        "please correct jarvus to jarvis", "correct a to b to c", "correct\tfoo\tto\tbar",
        "correct naïve to naive", "correct 😀 to smile", "correct foo\nto bar",
        "incorrect foo to bar", "correct foo into bar", "correction foo to bar", "correct foo to",
        "correct to bar", "corect foo to bar", "correct foo bar\nbaz to qux",
        "ÇORRECT foo to bar", "correct foo ţo bar", "correct ß to ss", "CORRECT İ TO I",
    ],
    "_CORR_WHEN_RE": [
        "when I say jarvis I mean Jarvis", "When I say tree I meant tea",
        "WHEN I SAY FOO I MEAN BAR", "so when i say x i mean y", "when i say  x  i mean   y",
        "when i say café i mean coffee", "when I said x I mean y", "when I say x I means y",
        "whenever I say x I mean y", "when I say x", "when I say x I mean", "when i sayx i mean y",
        "when İ say x İ mean y", "when i ſay x i mean y", "WHEN I SAY STRASSE I MEAN Straße",
    ],
    "_CORR_FORGET_RE": [
        "forget the correction for tree", "forget corrections", "Forget the corrections for all",
        "FORGET CORRECTION FOR X", "please forget the correction for café", "forget correction",
        "forget the correction for\nnext line", "forget the correctionsfor x",
        "forget the corection", "forgetting corrections", "forget my corrections",
        "forget the connections", "forgot the correction", "forget the correction for ß",
        "FORGET THE CORRECTİON",
    ],
    "_PROFILE_PATTERNS[0]": [
        "my name is Robin", "My name's Morgan", "MY NAME IS BOB", "hi, my name is Anne-Marie O'Neil",
        "my name is José", "my name is Zoë and I like tea", "my name is " + "abcdefghij" * 6,
        "my name is jo", "my name is ab_cd", "my name is 1234", "my name was Bob", "my names is bob",
        "my name is x", "my name is Émile", "my name is İlker", "my name is ılgaz",
        "my name is Kelvin", "my name’s Bob", "my name is ſam", "my name is Straße",
    ],
    "_PROFILE_PATTERNS[1]": [
        "call me Sam", "Call me Ishmael", "please call me Dr Who", "CALL ME MAYBE", "call me bob-o",
        "call me al", "call me Zoë", "recall me bob", "call me 42", "call me x", "call mom",
        "calls me bob", "call me İpek", "call me Kate", "call me ſid",
    ],
    "_PROFILE_PATTERNS[2]": [
        "I'm working on JARVIS", "i am working on a dissertation.", "I AM WORKING ON STUFF",
        "Currently I'm working on the native port\nand more", "I'm working on\nx",
        "I was working on x", "I'm working in x", "hi'm working on x", "I’m working on x",
        "I'm working on", "İ'm working on x", "I'M WORKİNG ON x", "I'm working on ßtuff",
    ],
    "_PROFILE_PATTERNS[3]": [
        "I'm a student", "I am an engineer", "i'm a PhD candidate at the university", "I am a père",
        "I'm an über-nerd", "I'm a data-scientist's apprentice", "I'm the boss", "I am a",
        "I'm a x", "I'm annoyed", "I'm amazing", "İ'm a student", "I'M A STUDENT", "I'm a ßinger",
    ],
    "_PROFILE_PATTERNS[4]": [
        "I prefer tea", "i really like jazz", "I love you", "I LOVE PYTHON", "I prefer\ttabs",
        "I really like it when it rains", "I preferred tea", "I like tea", "I really love tea",
        "hi love you", "I prefer", "İ love tea", "I LOVE İstanbul", "I love Straße",
    ],
    "_PROFILE_PATTERNS[5]": [
        "remember that I hate mornings", "Remember that my dog is Rex.", "please REMEMBER THAT x",
        "remember that\ttabs win", "remember this x", "remembered that x", "remember that",
        "remember thatx", "REMEMBER THAT İstanbul", "remember ţhat x", "rememßer that x",
    ],
    "_PROFILE_PATTERNS[6]": [
        "my birthday is May 5", "My favourite colour is blue", "my dog's name is Rex",
        "my car is a Tesla", "my café is closed", "my 2nd home is Leeds", "My name is Bob",
        "my x is y", "my favourite thing in the whole wide world is tea", "my job is\nteacher",
        "MY JOB IS TEACHER", "my job İS teacher", "my straße is long", "my ſon is 5",
    ],
    "_FORGET_ALL_RE": [
        "forget everything about me", "Forget everything you know about me please",
        "CLEAR MY PROFILE", "wipe my profile!", "ok, clear my profile.", "forget everything",
        "clear my profiles", "wipe my profile_x", "clear my profileé", "forget everything about meh",
        "clear my profİle", "wipe my profiſe", "FORGET EVERYTHİNG ABOUT ME",
    ],
    "_FORGET_ONE_RE": [
        "forget my birthday", "forget that my dog is called Rex", "Forget what you know about my job",
        "forget about my car", "FORGET MY NAME", "forget my " + "x" * 40, "forget me",
        "forget your birthday", "forgot my birthday", "forget my", "forget my !",
        "forget my café", "forget my İd", "forget my ßtuff",
    ],
    "_PERSONALITY_FORGET_RE": [
        "reset your personality", "forget your style notes", "Forget your personality tweaks",
        "FORGET YOUR STYLE ADJUSTMENTS", "please reset your personality.",
        "reset your personalities", "forget your style", "reset my personality",
        "forget your notes", "reset your personalİty", "forget your ſtyle notes",
    ],
    "_STYLE_PATTERNS[0]": [
        "be more sarcastic", "sound a bit less formal", "act more like a butler",
        "talk a little more slowly", "BE MORE FUN", "please be less wordy, ok?",
        "be more " + "sarcastic " * 6, "be sarcastic", "maybe more sarcastic", "be more ab",
        "being more fun", "sound a lot less formal", "be more ſarcastic", "BE MORE İRONIC",
        "be moré fun", "be more impreßive",
    ],
    "_STYLE_PATTERNS[1]": [
        "tone down the sarcasm", "dial down the jokes", "ease up on the puns", "drop the attitude",
        "cut the crap", "TONE DOWN THE WIT", "tone down sarcasm", "turn down the music",
        "cut th e crap", "shortcut the crap", "drop the ab", "tone down the ßarcasm",
        "DROP THE İRONY",
    ],
    "_STYLE_PATTERNS[2]": [
        "tone up the wit", "dial up the sarcasm", "turn up the charm", "TURN UP THE CHARM",
        "please dial up the jokes a bit", "turn the charm up", "tone up wit", "turn up the ab",
        "turnup the charm", "turn up the ſass", "TURN UP THE İRONY",
    ],
    "_STYLE_PATTERNS[3]": [
        "stop calling me sir", "Stop calling me Mr Stark", "STOP CALLING ME BOSS",
        "please stop calling me mate, ok", "stop calling", "stop calling me x",
        "stop call me sir", "ſtop calling me sir", "stop calling me İbo",
    ],
    "_STYLE_PATTERNS[4]": [
        "call me boss instead", "Call me Sam from now on", "call me Captain instead please",
        "CALL ME BOSS INSTEAD", "call me boss", "call me boss afterwards", "call me b instead",
        "call me İbo instead", "call me boss inſtead",
    ],
    "_STYLE_PATTERNS[5]": [
        "no swearing", "stop swearing!", "watch your language", "Mind your language, Jarvis",
        "no profanity", "clean it up", "no swearing-ish", "no swears", "clean it",
        "stop swearingly", "NO SWEARİNG", "ſtop ſwearing", "clean İt up",
    ],
    "_STYLE_PATTERNS[6]": [
        "you can swear", "you may curse", "You can cuss now", "swearing is fine",
        "swearing is okay", "swearing is allowed", "SWEARING IS OK", "you can't swear",
        "you can swearword", "swearing is bad", "you must swear", "you can ſwear",
        "swearing İs fine",
    ],
    "_STYLE_PATTERNS[7]": [
        "I hate it when you repeat yourself", "i don't like when you interrupt",
        "I dont like it when you do that", "I HATE WHEN YOU SHOUT",
        "I hate it when you " + "ramble " * 12, "I hate it when you\nramble", "I hate you",
        "I hate it when you go", "I don’t like when you do x", "İ hate when you shout",
        "I hate when you ßhout",
    ],
    "_STYLE_PATTERNS[8]": [
        "I love it when you quote the movies", "i like when you sing", "I LIKE IT WHEN YOU DO THAT",
        "I like when you sing", "I love you", "I like when you ab", "I likes when you sing",
        "İ like when you sing", "I lıke when you sing",
    ],
    "_EMO_PRAISE_RE": [
        "good job", "well done, Jarvis", "brilliant!", "that's amazing", "IMPRESSIVE", "perfect",
        "nailed it", "love you", "you're the best", "youre awesome", "you're hilarious", "good one",
        "good work", "love that", "you're good", "not bad", "goodjob", "brilliantly", "love them",
        "you are the best", "impressively", "that was impreßive", "PERFECT!", "you’re great",
        "İMPRESSİVE", "nailed İt", "good ſob",
    ],
    "_EMO_THANKS_RE": [
        "thanks", "thank you", "Cheers mate", "appreciate it", "I appreciate you", "THANK YOU",
        "thank", "thankful", "cheerse", "appreciate that", "no thanksgiving", "thank you",
        "THANKS!", "thank yoü", "ṫhanks",
    ],
    "_EMO_INSULT_RE": [
        "you're useless", "you are stupid", "you an idiot", "you're so fucking useless",
        "you're absolutely hopeless", "shut up", "fuck off", "piss off", "stupid machine",
        "useless robot", "you are such an idiot", "you pathetic", "you're utterly completely rubbish",
        "you're useful", "shut up shop", "shutup", "stupid question", "you're not stupid",
        "you idiot", "YOU'RE USELESS", "fuck oﬀ", "piß off", "ſhut up", "you're uſeless",
        "you are a idiot", "you’re useless", "dumb program!",
    ],
    "_FEEDBACK_NEG_RE": [
        "no, I said lights", "no I meant the other one", "no, that's not it", "not what I asked",
        "that's wrong", "thats not right", "wrong answer", "cancel that", "undo that", "never mind",
        "nevermind", "no I didn't", "that's right", "cancel it", "not what you said",
        "that is wrong", "NEVER MIND", "no, İ said lights", "cancel ţhat", "no, that’s not it",
        "never  mind",
    ],
}

_INLINE_INPUTS = [
    "Hello, World!", "it's", "café—au lait", "😀 smile", "a_b-c", "ΣΑΣ.", "é", "ͅ",
    "\x1c", "tab\there", "", "٣ apples", "½", "Ⅻ", "¹", "a  b", "a\x1cb", "a\x85b",
    "a  b", "​zero width", "﻿", " lead", "trail ", "a᠎b", "a--b",
    "x́y", "tone: dry, witty", "what is the capital of France?", "don't", "Zoë's dog",
    "snake_case", "日本語テキスト", "   ", "Profanity is ON: the user said you may swear",
    "　wide　", "a\xa0b", "tab\x0bvt\x0cff", "ǅungla", "🇬🇧 flag", "👨‍👩‍👧",
]

_TOGGLE_INPUTS = [
    "Profanity is ON: the user said you may swear", "Profanity is OFF: the user asked you not to swear",
    "profanity is on: x", "Pro is ON:", "ab is ON:", "Long toggle name here is OFF: y",
    "The user asked you to be more sarcastic", "Profanity  is ON:", " Profanity is ON:",
    "Profanity is ON", "Profanity is ONE:", "X" * 31 + " is ON:", "X" * 30 + " is ON:",
    "Émile is ON:", "my_flag is OFF:", "Profanity is ON:\nsecond line", "Pro\nfanity is ON:",
    "Profanity is ОN:", "Profanity is on:",
]

_DYNAMIC = [   # (heard, meant, text) — heard/meant as _corr_norm would produce, text as spoken
    ("tree", "tea", "I'd like a cup of tree"), ("jarvus", "jarvis", "Hey Jarvus, what time is it?"),
    ("travis", "jarvis", "TRAVIS turn on the lights"), ("new york", "newark", "flights to New York tomorrow"),
    ("tree", "tea", "street trees"), ("café", "coffee", "a CAFÉ au lait"),
    ("straße", "street", "STRASSE and Straße"), ("ss", "s", "Straße"), ("kelvin", "k", "Kelvin"),
    ("istanbul", "x", "İstanbul"), ("sid", "syd", "ſid"), ("a.b", "ab", "a.b axb"),
    ("c++", "cpp", "I code c++ daily"), ("x", "y", "x marks the spot"), ("i", "eye", "I think I can"),
    ("(hi)", "hello", "say (hi) now"), ("tree", "tea", "tree\ntree"), ("tree", "t\\1ea", "a tree"),
    ("tree", "a\\nb", "a tree"), ("tree", "$1 & \\g<0>", "a tree"), ("oﬀ", "on", "turn OFF the lights"),
    ("zoe", "zoë", "Zoe and zoé"),
]

_ESCAPES = ["a.b", "c++", "(hi)", "[x]", "a|b", "$5", "^_^", "a\\b", "{1,2}", "é", "😀", "new york",
            "#tag", "a-b", "...", "?", "*", "\\w", "a\tb", "x\ny", "'quoted'"]

# Translation rules of §3.3 exercised directly (hand-typed patterns, Python-computed results).
_GENERIC = [
    (r"(?P<w>\w+) (?P=w)", 0, ["the the cat", "the then"]),
    (r"end\Z", 0, ["the end", "the end\n", "end of it"]),
    (r"a.c", 0, ["a\rc", "a\nc", "a c", "a\x85c", "a c"]),
    (r"^a$", 0, ["a", "a\n", "a\n\n", "\na"]),
    (r"\d+", 0, ["٣٤ 12", "½", "Ⅻ", "¹", "१२"]),
    (r"\s", 0, ["\x1c", "\x1f", "​", "᠎", "\x85"]),
    (r"[^a]", re.I, ["A", "a", "b"]),
    (r"[\w.]+", 0, ["a.b é", "..."]),
    (r"[]a]+", 0, ["]a]", "b"]),
    (r"[[a]+", 0, ["[a[", "b"]),
    (r"[a&&b]+", 0, ["&&", "ab"]),
    (r"[$:{}~^]+", 0, ["$:{}~^", "x"]),
    (r"[\w '-]+", re.I, ["ͅ", "Ab-c 'd", "ǅ"]),
    (r"\w+", re.I, ["ͅΙ", "ſKK"]),
    (r"\bk\b", re.I, ["K", "a K b", "ͅk"]),
    (r"[a-z]+", re.I, ["İ", "ı", "K", "ſ", "ABC", "ǅ"]),
    (r"ss", re.I, ["ß", "ẞ", "SS"]),
    (r"ß", re.I, ["ss", "ẞ", "SS"]),
    (r"(a)|(b)", 0, ["b", "a"]),
    (r"x*", 0, ["abxd", ""]),
    (r"\w*", 0, ["ab c"]),
    (r"(?:ab)+?c", 0, ["ababc"]),
    (r"\b", 0, ["ab cd", "", " "]),
    (r"\Bx", 0, ["axb"]),
    (r"\Ax", 0, ["x"]),
    (r"(?x) a", 0, ["a"]),
    (r"(?i)a", 0, ["A"]),
    (r"(?<=a+)b", 0, ["aab"]),
    (r"(?<=ab)c", 0, ["abc"]),
    (r"[\b]", 0, ["\x08", "b"]),
    (r"\v", 0, ["\x0b", "\n"]),
    (r"\e", 0, ["\x1b"]),
    (r"a\x41B\N{LATIN SMALL LETTER C}", 0, ["aABc"]),
]


# Patterns Python accepts but M01 §3.3 has native refuse (PyRegex throws). None is used in M1.
_NATIVE_REFUSES = {
    r"\Bx": "§3.3: \\B throws",
    r"\Ax": "§3.3: \\A throws",
    r"(?x) a": "§3.3: (?x) throws (all inline flags do)",
    r"(?i)a": "§3.3: inline flags throw",
    r"[\b]": "[\\b] is a backspace in Python but not in ICU: throws",
    r"\v": "\\v is U+000B in Python but a class in ICU: throws",
}

# M01 §8 R5 model of ICU's case-insensitive matching, computed by Python: a character whose
# full case fold is several characters (ß ẞ ﬀ ﬁ …) matches that expansion, and İ/ı have no
# case tie to i/I (Python's re.I ties them through simple lowercase / shared uppercase).
# Modelled by rewriting pattern and input — İ→Ĭ, ı→ĭ (letters with no tie to i) and each
# multi-character fold expanded — running Python, and mapping spans back to the input.
_UNTIED = {"İ": "Ĭ", "ı": "ĭ"}


def _r5_rewrite(s):
    out, omap = [], {}
    n = 0
    for j, c in enumerate(s):
        rep = _UNTIED.get(c) or (c.casefold() if len(c.casefold()) > 1 else c)
        omap[n] = j
        out.append(rep)
        n += len(rep)
    omap[n] = len(s)
    return "".join(out), omap


def _r5_model(op, pattern, flags, s, repl=None):
    """What native (ICU) returns under the R5 model; None when the model does not apply."""
    if not flags & re.I:
        return None
    mp, _ = _r5_rewrite(pattern)
    ms, omap = _r5_rewrite(s)
    if (mp, ms) == (pattern, s):
        return None
    rx = re.compile(mp, flags)

    def back(a, b):
        if a not in omap or b not in omap:
            raise ValueError(f"R5 model: span ({a}, {b}) splits a folded character in {s!r}")
        return omap[a], omap[b]

    def mjson(m):
        if m is None:
            return None
        spans = [back(*m.span(k)) if m.span(k) != (-1, -1) else None for k in range(rx.groups + 1)]
        return {"span": list(spans[0]), "groups": [s[a:b] if (a, b) != (None, None) else None
                                                   for a, b in [sp or (None, None) for sp in spans]]}

    if op in ("search", "dyn_search", "escape"):
        return {"match": mjson(rx.search(ms))}
    if op == "match":
        return {"match": mjson(rx.match(ms))}
    if op == "findall":
        k = 1 if rx.groups == 1 else 0
        return {"out": [s[slice(*back(*m.span(k)))] for m in rx.finditer(ms)]}
    if op in ("sub", "dyn_sub"):
        pieces, last = [], 0
        for m in rx.finditer(ms):
            a, b = back(*m.span())
            pieces += [s[last:a], repl]
            last = b
        return {"out": "".join(pieces) + s[last:]}
    raise ValueError(f"R5 model: op {op}")


def _with_r5(op, pattern, flags, s, exp, repl=None):
    """exp plus a `native` block when the R5 model says ICU differs from Python here."""
    model = _r5_model(op, pattern, flags, s, repl)
    if model is None or all(exp.get(k) == v for k, v in model.items()):
        return exp
    return {**exp, "native": {"divergence": "R5-case-folding", **model}}


def _site_calls(tree, funcs):
    """{func: [(re_fn, pattern_node, repl_node, flags_node), ...]} in source order."""
    out = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name in funcs and node.name not in out:
            calls = []
            for sub in ast.walk(node):
                if (isinstance(sub, ast.Call) and isinstance(sub.func, ast.Attribute)
                        and isinstance(sub.func.value, ast.Name) and sub.func.value.id == "re"
                        and sub.func.attr in _RE_FUNCS):
                    kw = {k.arg: k.value for k in sub.keywords}
                    repl = sub.args[1] if sub.func.attr == "sub" else None
                    calls.append((sub.lineno, sub.col_offset, sub.func.attr, sub.args[0], repl,
                                  kw.get("flags")))
            out[node.name] = [c[2:] for c in sorted(calls, key=lambda c: (c[0], c[1]))]
    return out


def _flags_of(node):
    return 0 if node is None else eval(compile(ast.Expression(node), "<flags>", "eval"), {"re": re})


def _match_json(m):
    if m is None:
        return None
    return {"span": list(m.span()), "groups": [m.group(0), *m.groups()]}


def _outcome(fn):
    """Python's result, or the exception it raised (so a raise is golden too)."""
    try:
        return fn()
    except re.error as e:
        return {"error": f"re.error: {e}"}


def _regex_cases(J):
    cases = []

    def add(op, pid, name, inp, exp):
        cases.append({"name": f"{op} {pid} #{len(cases):04d} {name}",
                      "input": {"op": op, "pattern_id": pid, **inp}, "expected": exp})

    def pattern_inputs(pid):
        base = list(_INPUTS[pid])
        variants = []
        for p in base[:3]:
            variants += [p.upper(), p.lower(), p.title(), p.swapcase(), p + "\r\nmore",
                         p.replace(" ", " ", 1), p + "\x85tail"]
        return list(dict.fromkeys(base + variants + _ADVERSARIES))

    # 1. Module-level compiled patterns, straight from the jarvis module.
    compiled = [(n, getattr(J, n)) for n in _COMPILED]
    for n in _COMPILED_LISTS:
        compiled += [(f"{n}[{k}]", entry[0]) for k, entry in enumerate(getattr(J, n))]
    for pid, pat in compiled:
        if not isinstance(pat, re.Pattern) or pat.flags & ~(re.I | re.U):
            raise ValueError(f"{pid}: not a str pattern with only re.I ({pat!r})")
        ic = bool(pat.flags & re.I)
        for s in pattern_inputs(pid):
            add("search", pid, ascii(s)[:48], {"pattern": pat.pattern, "ignorecase": ic, "s": s},
                _with_r5("search", pat.pattern, pat.flags, s, {"match": _match_json(pat.search(s))}))
    if set(_INPUTS) != {pid for pid, _ in compiled}:
        raise ValueError(f"input table and compiled patterns disagree: "
                         f"{set(_INPUTS) ^ {pid for pid, _ in compiled}}")

    # 2. Inline patterns, from jarvis.py's source.
    tree = ast.parse(open(J.__file__, encoding="utf-8").read())
    sites = _site_calls(tree, _INLINE_FUNCS)
    for func, want in _INLINE_FUNCS.items():
        if len(sites.get(func, [])) != want:
            raise ValueError(f"{func}: expected {want} re.* calls, found {len(sites.get(func, []))}")
    dynamic = []
    seen = set()
    for func, calls in sites.items():
        for k, (fn, pnode, rnode, fnode) in enumerate(calls):
            flags = _flags_of(fnode)
            ic = bool(flags & re.I)
            pid = f"{func}:re.{fn}#{k}"
            if isinstance(pnode, ast.JoinedStr):
                dynamic.append((pid, fn, pnode, rnode, flags))
                continue
            pattern = pnode.value
            repl = rnode.value if isinstance(rnode, ast.Constant) else None
            key = (fn, pattern, flags, repl)
            if key in seen:
                continue
            seen.add(key)
            rx = re.compile(pattern, flags)
            inputs = _TOGGLE_INPUTS if fn == "match" else _INLINE_INPUTS
            for s in inputs:
                base = {"pattern": pattern, "ignorecase": ic, "s": s}
                tag = ascii(s)[:48]
                if fn == "sub":
                    add("sub", pid, tag, {**base, "repl": repl},
                        _with_r5("sub", pattern, flags, s, {"out": rx.sub(repl, s)}, repl))
                elif fn == "findall":
                    add("findall", pid, tag, base,
                        _with_r5("findall", pattern, flags, s, {"out": rx.findall(s)}))
                elif fn == "match":
                    add("match", pid, tag, base,
                        _with_r5("match", pattern, flags, s, {"match": _match_json(rx.match(s))}))
                else:
                    raise ValueError(f"{pid}: unhandled inline re.{fn}")
                add("search", pid, tag, base,
                    _with_r5("search", pattern, flags, s, {"match": _match_json(rx.search(s))}))

    # 3. The f-string pattern in _apply_corrections: rf"\b{re.escape(heard)}\b".
    if [d[1] for d in dynamic] != ["search", "sub"]:
        raise ValueError(f"_apply_corrections dynamic calls changed: {[d[:2] for d in dynamic]}")
    for pid, fn, pnode, rnode, flags in dynamic:
        template = compile(ast.Expression(pnode), "<dynamic>", "eval")
        for heard, meant, text in _DYNAMIC:
            pattern = eval(template, {"re": re, "heard": heard})
            base = {"heard": heard, "python_pattern": pattern, "ignorecase": bool(flags & re.I),
                    "s": text}
            tag = f"{ascii(heard)} in {ascii(text)[:36]}"
            if fn == "search":
                add("dyn_search", pid, tag, base,
                    _with_r5("dyn_search", pattern, flags, text,
                             {"match": _match_json(re.search(pattern, text, flags))}))
            else:
                exp = _outcome(lambda: {"out": re.sub(pattern, meant, text, flags=flags)})
                literal = re.sub(pattern, lambda m: meant, text, flags=flags)
                if exp != {"out": literal}:
                    # Python processes backslashes in a str repl; native takes meant literally.
                    exp = {**exp, "native": {"divergence": "sub-literal-repl", "out": literal}}
                else:
                    exp = _with_r5("dyn_sub", pattern, flags, text, exp, meant)
                add("dyn_sub", pid, f"{tag} -> {ascii(meant)}", {**base, "repl": meant}, exp)

    # 4. re.escape round trip: the escaped text must find the literal.
    for x in _ESCAPES:
        hay = f"say {x} now {x.upper()} then {x}"
        add("escape", "re.escape", ascii(x), {"x": x, "s": hay},
            {"match": _match_json(re.search(re.escape(x), hay))})

    # 5. Translation rules, hand-typed patterns.
    for k, (pattern, flags, inputs) in enumerate(_GENERIC):
        try:
            rx = re.compile(pattern, flags)
        except re.error as e:
            add("compile", f"generic#{k}", ascii(pattern), {"pattern": pattern, "ignorecase": bool(flags & re.I)},
                {"error": f"re.error: {e}"})
            continue
        refuse = _NATIVE_REFUSES.get(pattern)

        def exp_of(op, e):
            if refuse:
                return {**e, "native": {"divergence": "unsupported-construct", "reason": refuse}}
            return _with_r5(op, pattern, flags, s, e, "<>")

        for s in inputs:
            base = {"pattern": pattern, "ignorecase": bool(flags & re.I), "s": s}
            tag = f"{ascii(pattern)} on {ascii(s)}"
            add("search", f"generic#{k}", tag, base, exp_of("search", {"match": _match_json(rx.search(s))}))
            if rx.groups <= 1:
                add("findall", f"generic#{k}", tag, base, exp_of("findall", {"out": rx.findall(s)}))
                add("sub", f"generic#{k}", tag, {**base, "repl": "<>"},
                    exp_of("sub", {"out": rx.sub("<>", s)}))
    if set(_NATIVE_REFUSES) - {g[0] for g in _GENERIC}:
        raise ValueError("a _NATIVE_REFUSES pattern is not in _GENERIC")

    # 6. Whole-Unicode tables of the single-character classes jarvis.py uses.
    version = {"divergence": "unicode-version", "python_unidata": unicodedata.unidata_version}
    add("table_unassigned", "unicodedata", f"{unicodedata.unidata_version} category Cn", {},
        {"unidata_version": unicodedata.unidata_version,
         "unassigned": _ranges(lambda cp: unicodedata.category(chr(cp)) == "Cn")})
    for pattern, flags in [(r"\w", 0), (r"\w", re.I), (r"\W", 0), (r"\s", 0), (r"\S", 0),
                           (r"\d", 0), (r"[^\w\s]", 0), (r"[\w '-]", re.I), (r"[\w ]", re.I),
                           (r"[\w ]", 0)]:
        rx = re.compile(pattern, flags)
        add("table", "class", f"{ascii(pattern)} flags={flags}",
            {"pattern": pattern, "ignorecase": bool(flags & re.I)},
            {"ranges": _ranges(lambda cp: rx.match(chr(cp)) is not None),
             # only the category escapes depend on the Unicode version; \s is a fixed set
             **({"native": version} if re.search(r"\\[wWd]", pattern) else {})})
    return cases


@suite("m1_regex")
def regex_suite(ctx):
    return _regex_cases(ctx.J)
