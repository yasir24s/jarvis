"""M0 golden suites: pyjson, pytime, pyround (plan: native/plan/M00 §4, M01 §3.1).

Plugin for tools/golden.py (it imports every tools/golden_*.py). Every expected value below
is computed by running Python here, in the harness child; nothing is hand-typed except the
*inputs*. The one label that is not a Python outcome is `expected.native`: where the
normative spec (M01 §3.1 R6 lone surrogates, the 512 depth cap, the fromisoformat subset)
deliberately differs from Python, the case carries Python's real outcome AND a `native`
block naming the divergence. The Swift test checks the spec behaviour and records the
Python mismatch as a known issue, so the divergence stays visible instead of being deleted.

Case data must survive the harness's own `json.dump(..., ensure_ascii=False,
allow_nan=False)`: no NaN floats and no lone surrogates in any case value. Inputs that need
them travel as JSON text; outputs that would contain them travel as code-point lists.
"""
import calendar
import json
import random
import struct
import time
from datetime import datetime

from golden import suite

_OMIT_OVER = 64 * 1024          # an expected text longer than this is omitted (and listed)


# ─── pyjson ─────────────────────────────────────────────────────────────────────

def _has_lone_surrogate(s):
    return any(0xD800 <= ord(c) <= 0xDFFF for c in s)


def _fffd(v):
    """The value as native holds it (M01 §3.1 rule 5, §8 R6): every lone surrogate that
    json.loads produced becomes U+FFFD. Valid pairs were already joined by the scanner."""
    if isinstance(v, str):
        return "".join("\ufffd" if 0xD800 <= ord(c) <= 0xDFFF else c for c in v)
    if isinstance(v, list):
        return [_fffd(x) for x in v]
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            out[_fffd(k)] = _fffd(x)       # dict semantics: a merged key keeps its first slot
        return out
    return v


def _walk(v):
    """Every scalar, key and container depth in v, iteratively (inputs nest 100000 deep)."""
    stack = [(v, 1)]
    while stack:
        x, d = stack.pop()
        if isinstance(x, list):
            yield "depth", d
            stack.extend((y, d + 1) for y in x)
        elif isinstance(x, dict):
            yield "depth", d
            for k, y in x.items():
                yield "str", k
                stack.append((y, d + 1))
        elif isinstance(x, str):
            yield "str", x


def _contains_lone_surrogate(v):
    return any(kind == "str" and _has_lone_surrogate(x) for kind, x in _walk(v))


def _depth(v):
    return max((d for kind, d in _walk(v) if kind == "depth"), default=0)


def _styles(v):
    """The four dumps styles (M00 §4): compact, indent=1, indent=0, ensure_ascii=False."""
    out, omitted = {}, []
    for key, text in (("dumps_text", json.dumps(v)),
                      ("indent1_text", json.dumps(v, indent=1)),
                      ("indent0_text", json.dumps(v, indent=0)),
                      ("noascii_text", json.dumps(v, ensure_ascii=False))):
        if len(text) > _OMIT_OVER:
            omitted.append(key)
        elif _has_lone_surrogate(text):
            out[key.replace("_text", "_codepoints")] = [ord(c) for c in text]
        else:
            out[key] = text
    if omitted:
        out["omitted"] = omitted
    return out


def _outcome(raw):
    """What `json.load(open(path))` does with these bytes: strict UTF-8 decode, then
    json.loads on the str (so a BOM survives the decode and json.loads rejects it)."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None, {"raises": "UnicodeDecodeError"}
    try:
        return json.loads(text), None
    except json.JSONDecodeError as e:
        return None, {"raises": "JSONDecodeError", "message": e.msg}
    except RecursionError:
        return None, {"raises": "RecursionError"}
    except ValueError as e:                              # int > 4300 digits
        return None, {"raises": "ValueError", "message": str(e).split(":")[0]}


def _json_case(name, *, text=None, raw=None, repeat=None):
    if repeat is not None:                               # [[piece, count], ...] — keeps huge
        text = "".join(p * n for p, n in repeat)         # inputs out of the fixture
        inp = {"json_text_repeat": [[p, n] for p, n in repeat]}
    elif raw is not None:
        inp = {"json_hex": raw.hex()}
    else:
        inp = {"json_text": text}
    if raw is None:
        raw = text.encode("utf-8")
    v, err = _outcome(raw)
    if err is not None:
        return {"name": name, "input": inp, "expected": err}
    exp = _styles(v)
    if _contains_lone_surrogate(v):
        exp["native"] = {"divergence": "R6", **_styles(_fffd(v))}
    elif _depth(v) > 512:
        exp["native"] = {"divergence": "depth", "raises": "depth"}
    return {"name": name, "input": inp, "expected": exp}


def _synthetic_state_files():
    """Synthetic values in the SHAPES of the real state files (M01 §2.1); no real content."""
    t = 1784772604.524249
    kb = {"topics": {"synthetic topic alpha": {"summary": "A made-up summary. " * 6,
                                               "updated": t},
                     "synthetic topic beta": {"summary": "Short.", "updated": t + 3600.25}},
          "queue": ["queued topic one", "queued topic two"]}
    kb_unicode = {"topics": {"caf\u00e9 synth\u00e8se": {"summary": "na\u00efve \u2014 \u201cquoted\u201d \U0001F600",
                                                        "updated": 1784772604.0}},
                  "queue": []}
    history = [{"role": "user", "content": "what is the synthetic weather"},
               {"role": "assistant", "content": "It is synthetic, sir. \"Quoted\" and \\ slashed / ok."},
               {"role": "user", "content": "line one\nline two\ttabbed", "extra": 1}]
    corrections = [{"heard": "jar this", "meant": "jarvis", "added": t},
                   {"heard": "no ted", "meant": "noted", "added": 1784772605.0}]
    profile = {"facts": {"favourite synthetic colour": {"value": "teal", "updated": t},
                         "synthetic city": {"value": "Nowhere", "updated": 1.7847726e9}}}
    personality = {"core": ["Synthetic core trait one.", "Synthetic core trait two."],
                   "learned": [{"note": "Prefers synthetic brevity.", "added": t},
                               {"note": "Likes made-up jokes.", "added": t + 0.5}],
                   "consolidated_at": 1784772000.123,
                   "unknown_future_key": {"nested": [1, 2.5, None, True]}}
    emotions = {"mood": 0.6000000000000001, "energy": 0.7999999999999999, "warmth": 0.7,
                "patience": 0.8, "at": t}
    proactive = {"enroll_reminded": "2026-09-28"}
    alarms = [{"time": "2026-09-28T07:00:00", "label": "synthetic wake"},
              {"time": "2026-09-29T07:30:00.123456", "label": "synthetic stretch",
               "repeat": "daily"},
              {"time": "2026-10-01T18:45:00", "label": "synthetic call", "repeat": "weekdays"}]
    usage = {"2026-09-27": {"turns": 12, "tool_calls": 3, "wake_words": 40},
             "2026-09-28": {"turns": 1}}
    snap = {"ts": t, "date": "2026-09-28",
            "code": {"bytes": 101234, "lines": 5900, "git_head": "abc1234", "git_commits": "321"},
            "personality": personality,
            "emotions": {k: round(v, 3) for k, v in emotions.items() if k != "at"},
            "counts": {"profile_facts": 2, "corrections": 2, "kb_topics": 2, "history_turns": 3},
            "voiceprint_enrolled": False, "usage_today": usage["2026-09-28"]}
    # (name, value, indent) — indent as the Python writer uses it (M00 §2.2)
    return [("knowledge", kb, 1), ("knowledge_unicode", kb_unicode, 1),
            ("history", history, None), ("corrections", corrections, 1),
            ("profile", profile, 1), ("personality", personality, 1),
            ("emotions", emotions, 1), ("proactive", proactive, None),
            ("alarms", alarms, None), ("usage", usage, 1), ("metrics_line", snap, None)]


def _random_float_batches():
    rnd = random.Random(20260928)
    batches = []
    for b in range(12):                                   # uniformly random bit patterns
        xs = []
        while len(xs) < 25:
            (x,) = struct.unpack("<d", rnd.getrandbits(64).to_bytes(8, "little"))
            if x == x and abs(x) != float("inf"):
                xs.append(x)
        batches.append((f"float_random_bits_{b:02d}", xs))
    for b in range(2):                                    # subnormals
        xs = [struct.unpack("<d", (rnd.getrandbits(52) | (rnd.getrandbits(1) << 63))
                            .to_bytes(8, "little"))[0] for _ in range(25)]
        batches.append((f"float_random_subnormal_{b:02d}", xs))
    for b in range(4):                                    # short decimals across exponents
        xs = [float(f"{rnd.randint(0, 10 ** rnd.randint(1, 17))}e{rnd.randint(-30, 30)}")
              * rnd.choice((1, -1)) for _ in range(25)]
        batches.append((f"float_random_decimal_{b:02d}", xs))
    for b in range(2):                                    # epoch-like with microseconds
        xs = [round(1.7e9 + rnd.random() * 1e8, 6) for _ in range(25)]
        batches.append((f"float_random_epoch_{b:02d}", xs))
    for b in range(2):                                    # emotion-like, as round(v, 3) writes
        xs = [round(rnd.uniform(-1, 1), 3) for _ in range(25)]
        batches.append((f"float_random_emotion_{b:02d}", xs))
    for b in range(2):                                    # integral floats around 2**53
        xs = [float(rnd.randint(2 ** 50, 2 ** 62)) for _ in range(25)]
        batches.append((f"float_random_integral_{b:02d}", xs))
    return batches


@suite("pyjson")
def pyjson(ctx):
    cases = []

    def add(name, **kw):
        cases.append(_json_case(name, **kw))

    # containers, whitespace, literals
    for name, text in [
        ("empty_object", "{}"), ("empty_array", "[]"), ("empty_in_array", "[{}, [], [[]]]"),
        ("empty_in_object", '{"a": {}, "b": []}'),
        ("nested_4_deep", '{"a": [{"b": {"c": [1, {"d": null}]}}], "e": [[[[2]]]]}'),
        ("whitespace_heavy", ' \t\n\r{ \n "a" \t:\r [ 1 ,\n2 ] , "b"\n:\n{ } }\r\n\t '),
        ("literal_true", "true"), ("literal_false", "false"), ("literal_null", "null"),
        ("literals_in_array", "[true, false, null]"),
        ("top_level_string", '"top"'), ("top_level_int", " 42 "),
        ("key_order", '{"b": 1, "a": 2}'),
        ("key_order_many", '{"z": 1, "y": 2, "x": 3, "a": 4, "m": 5, "b": 6}'),
        ("duplicate_key", '{"a": 1, "b": 2, "a": 3}'),
        ("duplicate_key_type_change", '{"a": {"x": 1}, "b": 0, "a": [2]}'),
        ("duplicate_key_escaped_vs_raw", '{"\\u00e9": 1, "\u00e9": 2}'),
        ("duplicate_key_nested", '{"o": {"k": 1, "k": 2}, "o": {"k": 3, "j": 4, "k": 5}}'),
        ("keys_precomposed_vs_decomposed", '{"\u00e9": 1, "e\u0301": 2}'),
        ("key_empty", '{"": 1, " ": 2}'),
        ("key_needs_escape", '{"a\\"b\\\\c\\n": "v"}'),
        # ints
        ("int_zero", "0"), ("int_minus_zero", "-0"), ("int_minus_one", "-1"),
        ("int_2p53_plus_1", "9007199254740993"), ("int64_max", "9223372036854775807"),
        ("int64_min", "-9223372036854775808"), ("int64_max_plus_1", "9223372036854775808"),
        ("int64_min_minus_1", "-9223372036854775809"), ("int_2p64", str(2 ** 64)),
        ("int_10p30", str(10 ** 30)), ("int_minus_10p30", str(-10 ** 30)),
        ("ints_in_array", "[0, -0, 1, -1, 9223372036854775807, 18446744073709551616]"),
        # floats: literal texts that are not repr form
        ("float_upper_e", "1E2"), ("float_plus_exp", "1e+2"), ("float_frac_exp", "1.0e-2"),
        ("float_trailing_zeros", "1.10"), ("float_text_minus_zero", "-0.0"), ("float_text_zero", "0.0"),
        ("float_overflow", "1e400"), ("float_neg_overflow", "-1e400"),
        ("float_underflow", "1e-400"), ("float_huge_exponent", "1e999999999999"),
        ("float_tiny_exponent", "1e-999999999999"),
        ("float_half_min_subnormal_up", "2.5e-324"),
        ("float_half_min_subnormal_down", "2.4703282292062327e-324"),
        ("float_long_mantissa", "0." + "1" * 400),
        ("nan_literal", "NaN"), ("infinity_literal", "Infinity"),
        ("neg_infinity_literal", "-Infinity"),
        ("nonfinite_in_array", "[NaN, Infinity, -Infinity, 1.5]"),
        # strings
        ("str_e_acute_raw", '"\u00e9"'), ("str_e_acute_escaped", '"\\u00e9"'),
        ("str_e_acute_upper_hex", '"\\u00E9"'), ("str_emoji_raw", '"\U0001F600"'),
        ("str_emoji_escaped", '"\\ud83d\\ude00"'), ("str_emoji_upper_hex", '"\\uD83D\\uDE00"'),
        ("str_del_raw", '"\x7f"'), ("str_del_escaped", '"\\u007f"'), ("str_slash", '"/"'),
        ("str_slash_escaped", '"\\/"'), ("str_simple_escapes", '"\\"\\\\\\b\\f\\n\\r\\t"'),
        ("str_nul_and_us", '"\\u0000\\u001f"'), ("str_all_c0",
         '"' + "".join(f"\\u{i:04x}" for i in range(32)) + '"'),
        ("str_space", '" "'), ("str_empty", '""'),
        ("str_u2028_raw", '"a\u2028b\u2029c"'), ("str_u2028_escaped", '"a\\u2028b\\u2029c"'),
        ("str_feff_inside", '"\ufeff"'), ("str_bmp_edges", '"\u0080\u00ff\u0100\u07ff\u0800\uffff"'),
        ("str_max_scalar", '"\U0010FFFF"'), ("str_combining", '"e\u0301\u0327 a\u030a"'),
        ("str_mixed_scripts", '"\u65e5\u672c \u0645\u0631\u062d\u0628\u0627 \u0928\u092e\u0938\u094d\u0924\u0947"'),
        ("str_printable_ascii", json.dumps("".join(chr(i) for i in range(32, 127)))),
        ("str_c1_controls", '"\u0080\u0085\u009f"'),
        # lone surrogate escapes (M01 R6: native holds U+FFFD)
        ("lone_high_surrogate", '"\\ud800"'), ("lone_low_surrogate", '"\\udc00"'),
        ("lone_high_then_pair", '"\\ud83d\\ud83d\\ude00"'),
        ("reversed_pair", '"\\ude00\\ud83d"'), ("lone_in_middle", '"a\\ud800b"'),
        ("high_then_non_surrogate_escape", '"\\ud800\\u0041"'),
        ("lone_surrogate_key", '{"\\ud800": 1, "\\ufffd": 2}'),
        # rejections — Python's actual outcome is recorded, whatever it is
        ("reject_empty", ""), ("reject_whitespace_only", " \n\t"),
        ("reject_bom_text", "\ufeff{}"), ("reject_trailing_comma_array", "[1,]"),
        ("reject_trailing_comma_object", '{"a": 1,}'), ("reject_leading_comma", "[,1]"),
        ("reject_two_values", "1 2"), ("reject_unclosed_array", "[1"),
        ("reject_unclosed_object", '{"a": 1'), ("reject_missing_colon", '{"a" 1}'),
        ("reject_key_without_value", '{"a"}'), ("reject_single_quotes", "{'a': 1}"),
        ("reject_non_string_key", "{1: 2}"), ("reject_tru", "tru"), ("reject_nul", "nul"),
        ("reject_truex", "truex"), ("reject_minus_nan", "-NaN"), ("reject_nan_lower", "nan"),
        ("reject_inf", "inf"), ("reject_infinity_lower", "infinity"), ("reject_plus_one", "+1"),
        ("reject_leading_zero", "01"), ("reject_minus_leading_zero", "-01"),
        ("reject_trailing_dot", "1."), ("reject_leading_dot", ".5"), ("reject_bare_e", "1e"),
        ("reject_e_plus", "1e+"), ("reject_frac_e", "1.5e"), ("reject_minus_only", "-"),
        ("reject_double_minus", "--1"), ("reject_hex", "0x10"),
        ("reject_raw_control_us", '"\x1f"'), ("reject_raw_tab", '"\t"'),
        ("reject_raw_newline", '"\n"'), ("reject_raw_nul", '"\x00"'),
        ("reject_bad_escape", '"\\x"'), ("reject_short_unicode_escape", '"\\u12"'),
        ("reject_bad_unicode_hex", '"\\u12g4"'), ("reject_upper_u_escape", '"\\U0001F600"'),
        ("reject_unterminated_string", '"abc'), ("reject_high_then_bad_escape", '"\\ud800\\uzzzz"'),
        ("reject_formfeed_whitespace", "\x0c1"), ("reject_vtab_whitespace", "\x0b1"),
        ("reject_nbsp_trailing", "1\u00a0"), ("reject_extra_bracket", "[1]]"),
        ("reject_comment", "// c\n1"), ("reject_trailing_garbage", "[1]x"),
        ("reject_nan_in_object_key", "{NaN: 1}"),
    ]:
        add(name, text=text)

    add("float_long_integral_mantissa", repeat=[("1", 5000), (".0", 1)])
    add("str_10k", text=json.dumps(("synthetic text \u00e9\U0001F600 " * 500)[:10240],
                                   ensure_ascii=False))
    add("int_4300_digits", repeat=[("7", 4300)])
    add("int_4301_digits", repeat=[("7", 4301)])
    add("int_4301_digits_negative", repeat=[("-", 1), ("7", 4301)])
    add("depth_512_arrays", repeat=[("[", 512), ("]", 512)])
    add("depth_513_arrays", repeat=[("[", 513), ("]", 513)])
    add("depth_512_objects", repeat=[('{"a": ', 511), ("{}", 1), ("}", 511)])
    add("depth_513_objects", repeat=[('{"a": ', 512), ("{}", 1), ("}", 512)])
    add("depth_100000_arrays", repeat=[("[", 100000), ("]", 100000)])

    # bytes that are not valid UTF-8, and a BOM as raw bytes
    for name, raw in [("bytes_invalid_ff", b'"\xff"'), ("bytes_truncated_2byte", b'"\xc3"'),
                      ("bytes_overlong_slash", b'"\xc0\xaf"'),
                      ("bytes_encoded_surrogate", b'"\xed\xa0\x80"'),
                      ("bytes_above_max_scalar", b'"\xf4\x90\x80\x80"'),
                      ("bytes_invalid_outside_string", b"[1]\xff"),
                      ("bytes_bom", b"\xef\xbb\xbf{}"),
                      ("bytes_valid_4byte", '"\U0001F600"'.encode("utf-8"))]:
        add(name, raw=raw)

    # floats from Python values: the input text is Python's own json.dumps (repr digits)
    named = [("0.1", 0.1), ("0.1_plus_0.2", 0.1 + 0.2), ("1e16", 1e16), ("1e-5", 1e-5),
             ("1.5e-05", 1.5e-05), ("0.0001", 0.0001), ("1.5e300", 1.5e300),
             ("minus_zero", -0.0), ("5e-324", 5e-324), ("1.0", 1.0),
             ("epoch_1784772604.524249", 1784772604.524249),
             ("1234567890123456.0", 1234567890123456.0),
             ("9007199254740993.0", 9007199254740993.0),
             ("123456789012345678.0", 123456789012345678.0), ("1e22", 1e22), ("100.0", 100.0),
             ("max", 1.7976931348623157e308), ("min_normal", 2.2250738585072014e-308),
             ("max_subnormal", 2.225073858507201e-308), ("0.6000000000000001", 0.6 + 1e-16),
             ("0.7999999999999999", 0.7999999999999999), ("9500000000000000.0", 9.5e15),
             ("1.23e-18", 1.23e-18), ("1e15", 1e15), ("1e17", 1e17),
             ("9999999999999998.0", 9999999999999998.0), ("0.001", 0.001),
             ("0.00012345", 0.00012345), ("1.2345e-05", 1.2345e-05), ("neg_2.5", -2.5),
             ("1_over_3", 1 / 3), ("2_over_3", 2 / 3), ("pi_ish", 3.141592653589793),
             ("2p63", 9.223372036854776e18), ("2p64", 1.8446744073709552e19)]
    for label, x in named:
        add(f"float_{label}", text=json.dumps(x))
    add("floats_all_named", text=json.dumps([x for _, x in named]))
    for name, xs in _random_float_batches():
        add(name, text=json.dumps(xs))

    # round trips in the shapes of the real state files, written the way Python writes them
    for name, v, indent in _synthetic_state_files():
        add(f"state_{name}", text=json.dumps(v, indent=indent))
    return cases


# ─── pytime ─────────────────────────────────────────────────────────────────────

_FORMATS = ["%Y-%m-%d", "%H", "It is %I:%M %p on %A, %B %d.", "%I:%M %p", "%A at %I:%M %p",
            "%Y-%m-%d at %H.%M.%S", "%Y-%m-%d %H:%M", "%%|%S|%m|%d|%B|%A|%p|%I|%M|%Y|%H"]
_POSTS = {"lstrip0": ("%I:%M %p", lambda s: s.lstrip("0")),
          "replace_space0": ("%A at %I:%M %p", lambda s: s.replace(" 0", " "))}


def _local(y, mo, d, h=0, mi=0, s=0):
    return float(time.mktime((y, mo, d, h, mi, s, 0, 0, -1)))


def _utc(y, mo, d, h=0, mi=0, s=0):
    return float(calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)))


def _time_epochs(ctx):
    e = [("default", ctx.clock.now),
         ("midnight", _local(2026, 9, 28)), ("last_second", _local(2026, 9, 28, 23, 59, 59)),
         ("noon", _local(2026, 9, 28, 12)), ("half_past_midnight", _local(2026, 9, 28, 0, 30)),
         ("half_past_noon", _local(2026, 9, 28, 12, 30)), ("one_pm", _local(2026, 9, 28, 13, 5)),
         ("eleven_pm", _local(2026, 9, 28, 23, 1, 7)),
         ("bst_start_before", _utc(2026, 3, 29, 0, 59, 59)),
         ("bst_start_after", _utc(2026, 3, 29, 1, 0, 0)),
         ("bst_end_before", _utc(2026, 10, 25, 0, 59, 59)),
         ("bst_end_after", _utc(2026, 10, 25, 1, 0, 0)),
         ("leap_day_2028", _local(2028, 2, 29, 9, 8, 7)),
         ("new_year_2027", _local(2027, 1, 1, 0, 0, 0)),
         ("fractional", 1784772604.524249), ("fractional_half", 1784772604.5),
         ("y2001_start", _utc(2001, 1, 1))]
    e += [(f"month_{m:02d}", _local(2026, m, 15, 10, 5, 9)) for m in range(1, 13)]
    e += [(f"weekday_{d}", _local(2026, 9, 28 + d, 7, 45, 0)) for d in range(7)]
    return e


def _iso_or_raise(s):
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return {"raises": "ValueError"}
    if dt.tzinfo is not None:
        return {"aware": True, "iso": dt.isoformat(), "epoch": dt.timestamp()}
    # epoch_iso: what the instant reads as locally. It differs from iso for a wall time in
    # the spring-forward gap, which a naive datetime can hold and an instant cannot.
    return {"iso": dt.isoformat(), "epoch": dt.timestamp(),
            "epoch_iso": datetime.fromtimestamp(dt.timestamp()).isoformat()}


@suite("pytime")
def pytime(ctx):
    cases = []
    for label, t in _time_epochs(ctx):
        for i, fmt in enumerate(_FORMATS):
            text = time.strftime(fmt, time.localtime(t))
            dtext = datetime.fromtimestamp(t).strftime(fmt)
            assert text == dtext, (label, fmt, text, dtext)    # both jarvis paths agree here
            cases.append({"name": f"strftime_{label}_f{i}",
                          "input": {"op": "strftime", "epoch": t, "format": fmt},
                          "expected": {"text": text}})
        for post, (fmt, fn) in _POSTS.items():
            cases.append({"name": f"strftime_{label}_{post}",
                          "input": {"op": "strftime", "epoch": t, "format": fmt, "post": post},
                          "expected": {"text": fn(time.strftime(fmt, time.localtime(t)))}})
    iso_epochs = [(label, t) for label, t in _time_epochs(ctx)
                  if not label.startswith(("month_", "weekday_"))]
    iso_epochs += [("us_one", 1784772604.000001), ("us_half_down", 1784772604.0000005),
                   ("us_carry", 1784772604.9999996), ("us_no_carry", 1784772604.9999994),
                   ("us_999999", 1784772604.999999), ("us_round_even", 1784772604.0000025),
                   ("ms_only", 1784772604.25)]
    for label, t in iso_epochs:
        iso = datetime.fromtimestamp(t).isoformat()
        cases.append({"name": f"isoformat_{label}", "input": {"op": "isoformat", "epoch": t},
                      "expected": {"iso": iso,
                                   "roundtrip_epoch": datetime.fromisoformat(iso).timestamp()}})
    natives_unsupported = {"20260928T090000", "2026-W40-1", "2026-09-28T09:00:00Z",
                           "2026-09-28T09:00:00+01:00"}
    for i, s in enumerate(["2026-09-28T09:00:00", "2026-09-28T09:00:00.524249",
                           "2026-09-28T09:00", "2026-09-28T09", "2026-09-28",
                           "2026-09-28 09:00:00", "2026-09-28x09:00:00",
                           "2026-09-28T09:00:00.5", "2026-09-28T09:00:00.52",
                           "2026-09-28T09:00:00.123", "2026-09-28T09:00:00.1234567",
                           "2026-09-28T09:00:00,5", "2026-09-28T24:00:00",
                           "2026-12-31T24:00:00", "2026-03-29T01:30:00", "2026-10-25T01:30:00",
                           "2026-10-25T00:59:59", "2026-10-25T02:00:00",
                           "2028-02-29T12:00:00", "2026-02-29T00:00:00", "2026-02-30T00:00:00",
                           "2026-13-01T00:00:00", "2026-09-28T25:00:00",
                           "2026-09-28T24:00:01", "2026-09-28T09:60:00",
                           "2026-09-28T09:00:61", "2026-9-28", "2026-09-28T9:00",
                           "garbage", "", "2026-09-28T", "2026-09-28T09:00:00.",
                           "20260928T090000", "2026-W40-1", "2026-09-28T09:00:00Z",
                           "2026-09-28T09:00:00+01:00"]):
        exp = _iso_or_raise(s)
        if s in natives_unsupported:
            exp["native"] = {"divergence": "fromisoformat-subset", "result": None}
        cases.append({"name": f"fromisoformat_{i:02d}", "input": {"op": "fromisoformat", "iso": s},
                      "expected": exp})
    return cases


# ─── pyround ────────────────────────────────────────────────────────────────────

@suite("pyround")
def pyround(ctx):
    cases = []

    def add(name, x, n):
        r = round(x) if n is None else round(x, n)
        cases.append({"name": name, "input": {"x_text": repr(x), "n": n},
                      "expected": {"text": repr(r)}})

    fixed = [(2.675, 2), (0.0125, 3), (-0.0005, 3), (-0.0001, 3), (0.5, 0), (1.5, 0),
             (2.5, 0), (-0.5, 0), (-2.5, 0), (1e-10, 3), (0.125, 2), (0.375, 2), (0.625, 2),
             (-0.125, 2), (1.0005, 3), (0.6000000000000001, 3), (0.7999999999999999, 3),
             (1784772604.524249, 3), (1784772604.524249, 0), (1784772604.5, 0),
             (123456.0, -2), (123450.0, -2), (123350.0, -2), (-1234.5, -1), (1e300, -300),
             (1.5e300, -300), (5e-324, 323), (5e-324, 324), (5e-324, 400), (0.1, 20),
             (0.1, 17), (0.1, 16), (1.5, 400), (123.456, -400), (-123.456, -400),
             (0.0, 3), (-0.0, 3), (-0.0, 0), (9.995, 2), (0.045, 2), (1.005, 2),
             (float("nan"), 3), (float("inf"), 3), (float("-inf"), 2), (2.5, -1), (25.0, -1),
             (35.0, -1), (0.285, 2), (0.335, 2), (1e16, 2), (1e22, -21), (4.35, 1)]
    for i, (x, n) in enumerate(fixed):
        add(f"fixed_{i:02d}", x, n)
    for i, x in enumerate([0.5, 1.5, 2.5, -0.5, -1.5, 3.7, -3.7, 0.49999999999999994,
                           100 / 6.25, 99 / 6.25, 37.5 / 6.25, 150 / 60, 90 / 60, 89.9 / 60,
                           4503599627370495.5, 1784772604.524249]):
        add(f"int_{i:02d}", x, None)
    rnd = random.Random(1)
    for i in range(200):                              # M00 §4: emotion-like values, n=3
        add(f"emotion_rnd1_{i:03d}", rnd.uniform(-1, 1), 3)
    rnd = random.Random(2)
    for i in range(100):                              # near-ties: (2k+1)/2000 is never exact
        add(f"near_tie_{i:03d}", (2 * rnd.randint(-1000, 999) + 1) / 2000, 3)
    rnd = random.Random(3)
    for i in range(60):                               # arbitrary magnitudes and ndigits
        x = rnd.uniform(-1, 1) * 10 ** rnd.randint(-12, 12)
        add(f"random_{i:02d}", x, rnd.randint(-6, 14))
    return cases
