"""M1b golden suites: the dissertation dataset (plan: native/plan/M01b §4, §6 T2).

Plugin for tools/golden.py. Every expected value is produced by the REAL, UNPATCHED
jarvis.py (the user declined the §3.7 Python patch), driven through ctx.J inside the
harness sandbox:

    m1b_keys        set_tone / _set_backend / emotion_event with research_bump recorded
                    (the three counter-name sanitisers, jarvis.py 1056 / 2351 / 4855)
    m1b_line_count  code.lines / code.bytes as research_snapshot writes them, for byte blobs
                    put at HERE/jarvis.py, plus the verbatim expressions; one tree for the
                    schema-2 code_native walker (see its note: plan reference, not jarvis.py)
    m1b_tz          ShimTime.strftime("%Y-%m-%d") and ("%z") across DST edges and zones
    m1b_bump        research_bump step sequences over synthetic usage.json files; the bytes
                    after every step, the logged error if any, and the D1 native block
    m1b_last_date   _research_last_date over metrics.jsonl variants built from rows the
                    real research_snapshot appended; D2 / D4 native blocks
    m1b_git         the git half of research_snapshot: argv, timeout and .strip() with
                    jarvis's `subprocess` replaced by a recorder (the harness forbids child
                    processes), plus a deterministic repo whose HEAD is hashed here in pure
                    Python from git's object format; the Swift test builds the same repo
                    with the shell script stored in the case and runs the real git.

All file content is synthetic: shapes follow the real dataset (key names, day layout), no
value is copied from it. Bytes are base64 (`*_b64`) wherever byte-exactness matters.
"""
import base64
import calendar
import hashlib
import json
import os
import subprocess
import time as _time
import types

from golden import suite


def _b64(b):
    return None if b is None else base64.b64encode(b).decode("ascii")


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def _rm(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def _utc(y, mo, d, h=0, mi=0, s=0):
    return float(calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0)))


class _Bumps:
    """Wraps (does not replace) jarvis.research_bump / emotion_event to record call order."""

    def __init__(self, J):
        self.J, self.calls, self.emotions = J, [], []
        self._bump, self._emo = J.research_bump, J.emotion_event

    def __enter__(self):
        def bump(key, n=1):
            self.calls.append(key)
            return self._bump(key, n)

        def emo(name, mag=1.0):
            self.emotions.append(name)
            return self._emo(name, mag)

        self.J.research_bump, self.J.emotion_event = bump, emo
        return self

    def __exit__(self, *exc):
        self.J.research_bump, self.J.emotion_event = self._bump, self._emo
        _rm(self.J.RESEARCH_USAGE)
        _rm(self.J.EMOTIONS_FILE)


class _Logs:
    """Captures jarvis.log(...) lines (research_bump / research_snapshot report failures there)."""

    def __init__(self, J):
        self.J, self.lines, self._log = J, [], J.log

    def __enter__(self):
        self.J.log = self.lines.append
        return self

    def __exit__(self, *exc):
        self.J.log = self._log


# ─── m1b_keys ────────────────────────────────────────────────────────────────────

_BACKEND_LABELS = ["claude", "claude (partial)", "claude (claude-opus-5-5)", "local (qwen2.5:3b)",
                   "local (Apple FM)", "  X--y  ", "Émile (ä)", "á", "x²", "٣", "😀", "İ",
                   "", "ΟΔΟΣ", "Σ", "ΑΣ Β", "aΣ.", "ΣΑ", "Ǆ-ǅ", "ß", "ﬁ", "Ⅻ", "é",
                   "A_B__c", "tab\tnew\nline", " nbsp　", "𐐀𐐨"]
_TONE_DESCS = ["hurried and tense", "clipped, possibly irritated", "animated and upbeat",
               "quiet and subdued", "calm and even", "", " a , b", "ß-x", ",", " ",
               "\x1c\x1dtab\x1e\x1f", "　wide ,x", "\x85nel\xa0", "ÉCOLE, y",
               "été", "a,b,c", "​zero width"]


def _emo_names(J):
    return list(J._EMO_DELTAS) + ["nope", ""]


# Ranges of scalars (inclusive) for the whole-classification corpus; the big uniform Lo
# blocks (CJK, Hangul, Yi) are left out to keep the fixture small, with samples kept.
_CORPUS = [[0x0000, 0x33FF], [0x3400, 0x3410], [0x4DB0, 0x4E10], [0x9FF0, 0xA010],
           [0xA480, 0xABFF], [0xAC00, 0xAC10], [0xD7A0, 0xD7FF], [0xF900, 0xFFFF],
           [0x10400, 0x104FF], [0x16E40, 0x16E9F], [0x1D400, 0x1D7FF], [0x1E900, 0x1E95F],
           [0x1F100, 0x1F1FF], [0x1F600, 0x1F64F], [0xE0000, 0xE007F]]


def _corpus(drop=""):
    return "".join(chr(c) for lo, hi in _CORPUS for c in range(lo, hi + 1) if chr(c) not in drop)


@suite("m1b_keys")
def keys(ctx):
    J = ctx.J
    cases = []

    def run(kind, value):
        ctx.reset()
        with _Bumps(J) as b:
            if kind == "backend":
                J._set_backend(value)
            elif kind == "tone":
                J.set_tone(value)
            else:
                J.emotion_event(value)
        return b.calls, b.emotions

    for i, label in enumerate(_BACKEND_LABELS):
        calls, _ = run("backend", label)
        assert len(calls) == 1, calls
        cases.append({"name": f"backend_{i:02d}", "input": {"kind": "backend", "in": label},
                      "expected": {"out": calls[0], "bumps": calls}})
    for i, desc in enumerate(_TONE_DESCS):
        calls, emos = run("tone", desc)
        tone = [c for c in calls if c.startswith("tone_")]
        assert len(tone) <= 1, calls
        cases.append({"name": f"tone_{i:02d}", "input": {"kind": "tone", "in": desc},
                      "expected": {"out": tone[0] if tone else None, "bumps": calls,
                                   "emotion_events": emos}})
    for name in _emo_names(J):
        calls, _ = run("emotion", name)
        assert len(calls) <= 1, calls
        cases.append({"name": f"emotion_{name or 'empty'}",
                      "input": {"kind": "emotion", "in": name,
                                "in_emo_deltas": name in J._EMO_DELTAS},
                      "expected": {"out": calls[0] if calls else None, "bumps": calls}})

    # Whole-classification corpus: one _set_backend / set_tone call over a long string, so
    # every scalar's \w class and str.lower() mapping shows up in the single output key.
    calls, _ = run("backend", _corpus())
    cases.append({"name": "backend_corpus",
                  "input": {"kind": "backend_corpus", "ranges": _CORPUS},
                  "expected": {"out": calls[0], "bumps": len(calls)}})
    calls, _ = run("tone", _corpus(drop=","))
    cases.append({"name": "tone_corpus",
                  "input": {"kind": "tone_corpus", "ranges": _CORPUS, "drop": ","},
                  "expected": {"out": calls[0], "bumps": len(calls)}})
    return cases


# ─── m1b_line_count ──────────────────────────────────────────────────────────────

def _mix70k():
    """Deterministic ~70 KB blob mixing \\n, \\r\\n, lone \\r, multibyte text and a \\r\\n
    that straddles the 8 KB read boundary (LCG, no randomness)."""
    words = ["alpha", "beta", "γάμμα", "дельта", "😀", "x", "", "  ", "\t", "é"]
    ends = ["\n", "\r\n", "\r", "\n", "\n"]
    x, out = 12345, []
    size = 0
    while size < 70_000:
        x = (1103515245 * x + 12345) % 2 ** 31
        piece = " ".join(words[(x >> k) % len(words)] for k in (3, 7, 11)) + ends[(x >> 13) % 5]
        b = piece.encode("utf-8")
        out.append(b)
        size += len(b)
    return b"".join(out)


_BLOBS = [("empty", b""), ("a", b"a"), ("a_lf", b"a\n"), ("a_crlf_b", b"a\r\nb"),
          ("a_cr_b_cr", b"a\rb\r"), ("cr_crlf", b"\r\r\n"), ("lf_lf", b"\n\n"),
          ("cr", b"\r"), ("lf", b"\n"), ("a_cr", b"a\r"), ("crlf_crlf", b"\r\n\r\n"),
          ("lf_cr", b"\n\r"), ("utf8_multibyte", "é\n😀\r\nx y\u0085z".encode()),
          ("vt_ff_fs", b"a\x0bb\x0cc\x1cd\x1de\x1ef"), ("invalid_utf8", b"a\xff\nb\xc3"),
          ("crlf_at_8k_boundary", b"x" * 8191 + b"\r\nyy"),
          ("cr_at_8k_boundary", b"x" * 8191 + b"\ryy\r"),
          ("mix_70k", _mix70k())]

_TREE = {"A/x.swift": b"import Foundation\nlet x = 1\n",
         "A/B/y.swift": b"// crlf\r\nlet y = 2\r\n",
         "A/B/C/deep.swift": b"no final newline",
         "z.swiftx": b"not counted\n",
         ".hidden.swift": b"// hidden, counted\n",
         "E/Upper.SWIFT": b"case-sensitive suffix, not counted\n",
         "F/bad.swift": b"bad \xff utf8\rline\n",
         "F/empty.swift": b"",
         "dir.swift/inner.swift": b"inside a dir named .swift\n",
         "G/cr.swift": b"a\rb\rc"}
_TREE_LINKS = {"C/link.swift": "../A/x.swift", "D": "A", "H/dangling.swift": "../nowhere.swift"}


def _code_native_reference(root):
    """plan M01b §3.7 H2 `_research_code_native`, verbatim but for the root argument. It
    is NOT in jarvis.py (the Python patch was declined): this case is native-specified."""
    b = l = n = 0
    try:
        for dp, dn, fn in os.walk(root):
            dn.sort()
            for name in sorted(fn):
                p = os.path.join(dp, name)
                if name.endswith(".swift") and os.path.isfile(p) and not os.path.islink(p):
                    with open(p, encoding="utf-8", errors="replace") as f:
                        l += sum(1 for _ in f)
                    b += os.path.getsize(p); n += 1
    except Exception:
        pass
    return {"bytes": b, "lines": l, "files": n}


@suite("m1b_line_count")
def line_count(ctx):
    J = ctx.J
    me = os.path.join(J.HERE, "jarvis.py")
    original = _read(me)
    cases = []
    try:
        for name, blob in _BLOBS:
            ctx.reset()
            _rm(J.RESEARCH_METRICS)
            _write(me, blob)
            with _Logs(J) as logs:
                J.research_snapshot()
            rows = (_read(J.RESEARCH_METRICS) or b"").splitlines()
            code = json.loads(rows[-1])["code"] if rows else None
            try:
                with open(me) as f:                         # research_snapshot, verbatim
                    expr = sum(1 for _ in f)
            except UnicodeDecodeError:
                expr = None
            with open(me, encoding="utf-8", errors="replace") as f:
                replace = sum(1 for _ in f)
            cases.append({"name": name, "input": {"b64": _b64(blob)},
                          "expected": {"lines": code["lines"] if code else None,
                                       "bytes": code["bytes"] if code else None,
                                       "snapshot_row": code is not None,
                                       "snapshot_log": [x for x in logs.lines
                                                        if x.startswith("Research snapshot:")],
                                       "lines_expr": expr, "lines_replace": replace}})
    finally:
        _write(me, original)
        _rm(J.RESEARCH_METRICS)

    root = os.path.join(str(ctx.sandbox), "tree", "Sources")
    for rel, data in _TREE.items():
        os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
        _write(os.path.join(root, rel), data)
    for rel, target in _TREE_LINKS.items():
        os.makedirs(os.path.dirname(os.path.join(root, rel)) or root, exist_ok=True)
        os.symlink(target, os.path.join(root, rel))
    cases.append({"name": "code_native_tree",
                  "input": {"files": {k: _b64(v) for k, v in _TREE.items()},
                            "symlinks": _TREE_LINKS,
                            "oracle": "plan M01b §3.7 H2 _research_code_native reference "
                                      "(not in jarvis.py: Python patch declined)"},
                  "expected": _code_native_reference(root)})
    return cases


# ─── m1b_tz ──────────────────────────────────────────────────────────────────────

_TZ_POINTS = [
    ("Europe/London", [_utc(2026, 10, 24, 22, 59, 59), _utc(2026, 10, 24, 23, 0, 0),
                       _utc(2026, 10, 25, 0, 59, 59), _utc(2026, 10, 25, 1, 0, 0),
                       _utc(2026, 10, 25, 23, 59, 59), _utc(2026, 10, 26, 0, 0, 0),
                       _utc(2027, 3, 27, 23, 59, 59), _utc(2027, 3, 28, 0, 59, 59),
                       _utc(2027, 3, 28, 1, 0, 0), _utc(2027, 3, 28, 22, 59, 59),
                       _utc(2027, 3, 28, 23, 0, 0), _utc(2026, 8, 20, 22, 59, 59) + 0.999999,
                       1790582400.0, 1790582400.123456]),
    ("Asia/Kolkata", [_utc(2026, 9, 28, 18, 29, 59), _utc(2026, 9, 28, 18, 30, 0),
                      _utc(2026, 12, 31, 18, 29, 59) + 0.5]),
    ("America/St_Johns", [_utc(2026, 7, 1, 2, 29, 59), _utc(2026, 7, 1, 2, 30, 0),
                          _utc(2026, 11, 1, 4, 29, 59), _utc(2026, 11, 1, 4, 30, 0),
                          _utc(2027, 1, 15, 3, 29, 59), _utc(2027, 1, 15, 3, 30, 0)]),
    ("UTC", [_utc(2026, 12, 31, 23, 59, 59) + 0.999, _utc(2027, 1, 1)]),
    ("Pacific/Chatham", [_utc(2026, 9, 28, 11, 14, 59), _utc(2026, 9, 28, 11, 15, 0)]),
]


@suite("m1b_tz")
def tz(ctx):
    J = ctx.J
    home = os.environ["TZ"]
    cases = []
    try:
        for zone, points in _TZ_POINTS:
            os.environ["TZ"] = zone
            _time.tzset()
            for ts in points:
                ctx.at(ts)
                cases.append({"name": f"{zone}@{ts!r}", "input": {"tz": zone, "ts": ts},
                              "expected": {"date": J.time.strftime("%Y-%m-%d"),
                                           "z": J.time.strftime("%z")}})
    finally:
        os.environ["TZ"] = home
        _time.tzset()
    return cases


# ─── m1b_bump ────────────────────────────────────────────────────────────────────

_T0 = _utc(2026, 8, 12, 9, 30, 0) + 0.25          # 2026-08-12 10:30:00.25 BST
_D0 = "2026-08-12"


def _real_shaped():
    """Synthetic usage.json in the real file's shape: days out of order, today in the middle."""
    return {
        "2026-08-10": {"interactions": 14, "backend_claude": 11, "backend_local_qwen2_5_3b_": 3,
                       "tone_calm_and_even": 5, "speaker_pass": 9},
        "2026-08-09": {"interactions": 2, "stt_segments_dropped": 7},
        _D0: {"interactions": 4, "tone_quiet_and_subdued": 1, "speaker_reject": 2,
              "wake_rejected_foreign_voice": 1},
        "2026-08-11": {"personality_consolidations": 1, "emotion_user_urgent": 3},
    }


def _ind(v):
    return json.dumps(v, indent=1).encode("ascii")


def _bump_cases():
    L = _utc
    real = _ind(_real_shaped())
    return [
        ("missing_file", None, [(_T0, "interactions", 1), (_T0 + 1, "backend_claude", 1),
                                (_T0 + 2, "interactions", 1)], {}),
        ("missing_research_dir", None, [(_T0, "interactions", 1)], {"research_dir_missing": True}),
        ("empty_object", b"{}", [(_T0, "interactions", 1), (_T0, "speaker_pass", 1)], {}),
        ("real_shaped_days_out_of_order", real,
         [(_T0, "interactions", 1), (_T0, "tone_hurried_and_tense", 1),
          (_T0, "speaker_reject", 1), (_T0 + 86400, "interactions", 1),
          (_T0 + 86400, "backend_claude", 1), (_T0, "wake_rejected_foreign_voice", 1)], {}),
        ("real_shaped_compact_with_newline", json.dumps(_real_shaped()).encode() + b"\n",
         [(_T0, "interactions", 1)], {}),
        ("non_ascii_keys", _ind({_D0: {"tone_café_ü": 2, "emotion_😀": 1, "a\"b\\c/ ": 1}}),
         [(_T0, "tone_café_ü", 1), (_T0, "backend_émile_ä_", 1), (_T0, "emotion_😀", 3)], {}),
        ("float_counter", _ind({_D0: {"interactions": 2.0, "x": 0.1, "big": 1e16}}),
         [(_T0, "interactions", 1), (_T0, "x", 2), (_T0, "big", 1)], {}),
        ("bool_counter", _ind({_D0: {"speaker_pass": True, "speaker_reject": False}}),
         [(_T0, "speaker_pass", 1), (_T0, "speaker_reject", 1)], {}),
        ("n_values", None, [(_T0, "a", 5), (_T0, "b", 0), (_T0, "a", -2), (_T0, "c", -1)], {}),
        ("bigint_counter", _ind({_D0: {"interactions": 9223372036854775807,
                                       "huge": 123456789012345678901234567890,
                                       "neg": -9223372036854775808}}),
         [(_T0, "interactions", 1), (_T0, "huge", 1), (_T0, "neg", -1), (_T0, "interactions", -2)],
         {}),
        ("nan_inf_counter", b'{"2026-08-12": {"a": NaN, "b": Infinity, "c": -Infinity}}',
         [(_T0, "a", 1), (_T0, "b", 1), (_T0, "c", 1)], {}),
        ("other_values_preserved",
         _ind({"meta": {"note": "synthetic", "list": [1, 2.5, None, True, {}, []]},
               "2026-08-01": {"x": 1e-07, "y": -0.0}, _D0: {}}),
         [(_T0, "interactions", 1)], {}),
        ("duplicate_keys", b'{"2026-08-12": {"a": 1, "b": 2, "a": 5}, "2026-08-11": {"z": 1},'
                           b' "2026-08-12": {"a": 7, "c": 1}}',
         [(_T0, "a", 1), (_T0, "d", 1)], {}),
        ("rollover_bst_midnight", _ind({"2026-08-20": {"interactions": 1}}),
         [(L(2026, 8, 20, 22, 59, 59) + 0.5, "interactions", 1),
          (L(2026, 8, 20, 23, 0, 0), "interactions", 1),
          (L(2026, 8, 20, 23, 0, 1), "speaker_pass", 1)], {}),
        ("rollover_gmt_midnight", None,
         [(L(2026, 11, 10, 23, 59, 59), "interactions", 1),
          (L(2026, 11, 11, 0, 0, 0), "interactions", 1)], {}),
        ("dst_end_day", None,
         [(L(2026, 10, 24, 22, 59, 59), "interactions", 1),
          (L(2026, 10, 24, 23, 0, 0), "interactions", 1),
          (L(2026, 10, 25, 1, 30, 0), "interactions", 1),
          (L(2026, 10, 25, 23, 59, 59), "interactions", 1),
          (L(2026, 10, 26, 0, 0, 0), "interactions", 1)], {}),
        ("non_dict_root", b"[]", [(_T0, "interactions", 1)], {}),
        ("non_dict_root_number", b"7", [(_T0, "interactions", 1)], {}),
        ("non_dict_day_value", _ind({"2026-08-11": {"a": 1}, _D0: [1, 2]}),
         [(_T0, "interactions", 1), (_T0 - 86400, "a", 1)], {}),
        ("non_dict_day_string", _ind({_D0: "x"}), [(_T0, "interactions", 1)], {}),
        ("non_numeric_counter", _ind({_D0: {"interactions": "7", "n": None, "l": [1]}}),
         [(_T0, "interactions", 1), (_T0, "n", 1), (_T0, "l", 1), (_T0, "fresh", 1)], {}),
        ("truncated_json", real[:len(real) // 2], [(_T0, "interactions", 1),
                                                   (_T0, "interactions", 1)], {}),
        ("garbage_text", b"not json at all\n", [(_T0, "interactions", 1)], {}),
        ("invalid_utf8", b'{"2026-08-11": {"x\xff": 1}}', [(_T0, "interactions", 1)], {}),
        ("utf8_bom", b'\xef\xbb\xbf{"2026-08-11": {"x": 1}}', [(_T0, "interactions", 1)], {}),
        ("empty_file", b"", [(_T0, "interactions", 1)], {}),
        ("whitespace_only_file", b" \n", [(_T0, "interactions", 1)], {}),
        ("usage_is_directory", None, [(_T0, "interactions", 1)], {"usage_is_directory": True}),
    ]


def _usage_today(J):
    """research_snapshot's usage_today expression, verbatim."""
    day = J.time.strftime("%Y-%m-%d")
    try:
        with open(J.RESEARCH_USAGE) as f:
            usage_today = json.load(f).get(day, {})
    except Exception:
        usage_today = {}
    return usage_today


def _parse_failure(data):
    """Why Python's `json.load(open(usage))` raises for these bytes (None if it parses)."""
    if data is None:
        return None
    try:
        json.loads(data.decode("utf-8"))
        return None
    except Exception as e:
        return type(e).__name__


@suite("m1b_bump")
def bump(ctx):
    J = ctx.J
    usage = J.RESEARCH_USAGE
    cases = []
    for name, initial, steps, opts in _bump_cases():
        ctx.reset()
        if os.path.isdir(usage):
            os.rmdir(usage)
        _rm(usage)
        if opts.get("research_dir_missing"):
            os.rmdir(J.RESEARCH_DIR)
        if opts.get("usage_is_directory"):
            os.mkdir(usage)
        if initial is not None:
            _write(usage, initial)
        failure = _parse_failure(initial)
        out_steps = []
        for k, (ts, key, n) in enumerate(steps):
            ctx.at(ts)
            before = _read(usage) if os.path.isfile(usage) else None
            with _Logs(J) as logs:
                J.research_bump(key, n)
            after = _read(usage) if os.path.isfile(usage) else None
            errs = [x for x in logs.lines if x.startswith("Research bump:")]
            step = {"ts": ts, "key": key, "n": n, "day": J.time.strftime("%Y-%m-%d"),
                    "error": errs[0] if errs else None, "python_wrote": not errs,
                    "after_b64": _b64(after), "native": None}
            # D1 (plan §3.4): native first copies unparseable NON-EMPTY bytes aside, once,
            # named from the bump's own clock, then writes the Python-identical result.
            if k == 0 and failure and initial:
                step["native"] = {"deviation": "D1", "quarantine_b64": _b64(before),
                                  "quarantine_name": f"usage.json.corrupt-{int(ts)}"}
            out_steps.append(step)
        cases.append({"name": name,
                      "input": {"initial_b64": _b64(initial), "steps": [
                                    {"ts": s["ts"], "key": s["key"], "n": s["n"]} for s in out_steps],
                                **opts},
                      "expected": {"steps": out_steps, "final_b64": out_steps[-1]["after_b64"],
                                   "parse_failure": failure,
                                   "deviation": "D1" if failure and initial else None,
                                   "usage_today_json": json.dumps(_usage_today(J))}})
        if os.path.isdir(usage):
            os.rmdir(usage)
        _rm(usage)
        os.makedirs(J.RESEARCH_DIR, exist_ok=True)
    return cases


# ─── m1b_last_date ───────────────────────────────────────────────────────────────

def _rows(ctx, J, dates, big_at=None, big_size=9000):
    """Rows the REAL research_snapshot appends, one per (y, m, d) at 12:00 UTC. The row at
    index `big_at` carries a personality whose note is sized so the row is `big_size`
    bytes (without its newline)."""
    _rm(J.RESEARCH_METRICS)
    base = {"core": ["Synthetic core trait."], "learned": []}
    rows = []
    for i, (y, m, d) in enumerate(dates):
        ctx.reset()
        ctx.at(_utc(y, m, d, 12) + 0.125 * i)
        if i == big_at:
            note = {"note": "", "added": 1790582400.5}
            p = {**base, "learned": [note]}
            J.personality_save(p)
            J.research_snapshot()
            small = len(_read(J.RESEARCH_METRICS).splitlines()[-1])
            with open(J.RESEARCH_METRICS, "rb+") as f:          # drop the sizing row
                data = f.read()
                f.seek(0); f.truncate(); f.write(data[:data.rstrip(b"\n").rfind(b"\n") + 1])
            note["note"] = "p" * (big_size - small)
            J.personality_save(p)
        else:
            J.personality_save(base)
        J.research_snapshot()
        rows.append(_read(J.RESEARCH_METRICS).splitlines()[-1])
    _rm(J.RESEARCH_METRICS)
    _rm(J.PERSONALITY_FILE)
    return rows


@suite("m1b_last_date")
def last_date(ctx):
    J = ctx.J
    m = J.RESEARCH_METRICS
    days = [(2026, 8, d) for d in range(1, 8)]
    small = _rows(ctx, J, days)                          # ~7 short rows
    big = _rows(ctx, J, [(2026, 8, 8), (2026, 8, 9)], big_at=1)
    assert len(big[1]) == 9000, len(big[1])
    date = lambda row: json.loads(row)["date"]
    nl = lambda rows: b"".join(r + b"\n" for r in rows)
    many = [r for _ in range(3) for r in small]          # > 8 KB of short rows
    cases_in = [
        ("missing", None, None),
        ("empty", b"", ""),
        ("one_row", nl(small[:1]), date(small[0])),
        ("rows", nl(small), date(small[-1])),
        ("no_final_newline", nl(small)[:-1], date(small[-1])),
        ("malformed_last_row", nl(small) + small[-1][:40] + b"\n", ""),
        ("trailing_blank_lines", nl(small) + b"\n\n  \n\t\n", date(small[-1])),
        ("crlf", b"".join(r + b"\r\n" for r in small), date(small[-1])),
        ("lone_cr", b"".join(r + b"\r" for r in small), date(small[-1])),
        ("last_row_9000_bytes", nl(small[:2] + big), date(big[1])),
        ("last_row_9000_bytes_only", nl(big[1:]), date(big[1])),
        ("over_8kb_short_last_row", nl(many), date(many[-1])),
        ("big_row_then_short_row", nl(big[1:] + small[:1]), date(small[0])),
        ("whitespace_only", b"\n \n\r\n", ""),
        ("last_row_array", nl(small) + b"[1, 2]\n", ""),
        ("last_row_without_date", nl(small) + b'{"ts": 1.5}\n', ""),
        ("invalid_utf8_before_last_row", nl(small[:2]) + b"\xff\xfe\n" + nl(small[2:3]),
         date(small[2])),
        ("invalid_utf8_inside_last_row", nl(small[:1]) + small[1][:-1] + b"\xff}\n",
         date(small[1])),
    ]
    cases = []
    for name, data, native in cases_in:
        _rm(m)
        if data is not None:
            _write(m, data)
        py = J._research_last_date()
        exp_native = "" if native is None else native
        cases.append({"name": name, "input": {"b64": _b64(data)},
                      "expected": {"python": py, "native": exp_native,
                                   "deviation": None if py == exp_native else "D2",
                                   "size": 0 if data is None else len(data),
                                   "last_line_bytes": len(data.rstrip().splitlines()[-1])
                                   if data and data.strip() else 0}})
    # D4: Python appends a new row straight after a dangling fragment (no final \n), which
    # merges the two into one malformed line, so the last date reads "" (a duplicate row
    # every hour). Native writes "\n" first; the fragment stays a skippable malformed line.
    for name, initial in [("append_after_fragment", nl(small[:3]) + small[3][:50]),
                          ("append_after_complete_row_without_newline", nl(small[:3])[:-1]),
                          ("append_to_missing", None), ("append_to_empty", b"")]:
        _rm(m)
        if initial is not None:
            _write(m, initial)
        ctx.reset()
        ctx.at(_utc(2026, 8, 20, 12) + 0.5)
        J.research_snapshot()
        after = _read(m)
        pre = initial or b""
        row = after[len(pre):]
        assert after.startswith(pre) and row.endswith(b"\n")
        row = row[:-1]
        py = J._research_last_date()
        needs_nl = bool(pre) and not pre.endswith(b"\n")
        native_after = pre + (b"\n" if needs_nl else b"") + row + b"\n"
        cases.append({"name": name,
                      "input": {"initial_b64": _b64(initial), "append_line_b64": _b64(row)},
                      "expected": {"python_after_b64": _b64(after), "python": py,
                                   "native": {"after_b64": _b64(native_after),
                                              "last_date": date(row),
                                              "deviation": "D4" if needs_nl else None}}})
    _rm(m)
    return cases


# ─── m1b_git ─────────────────────────────────────────────────────────────────────

class _FakeSubprocess:
    """Stands in for jarvis's `subprocess` module inside research_snapshot only."""
    TimeoutExpired = subprocess.TimeoutExpired

    def __init__(self, plan):
        self.plan, self.calls = plan, []

    def run(self, args, **kw):
        self.calls.append({"args": list(args), "kwargs": {k: kw[k] for k in sorted(kw)}})
        step = self.plan[len(self.calls) - 1]
        if step == "timeout":
            raise subprocess.TimeoutExpired(args, kw.get("timeout"))
        if step == "missing":
            raise FileNotFoundError(2, "No such file or directory", "git")
        stdout, rc = step
        return types.SimpleNamespace(args=args, returncode=rc, stdout=stdout, stderr="")


_GIT_PLANS = [
    ("ok", [("abc1234\n", 0), ("212\n", 0)]),
    ("ascii_whitespace", [(" \tdeadbee \r\n", 0), ("\n 3 \x0c\n", 0)]),
    ("unicode_whitespace", [("abc1234　 ", 0), ("\x1c5\x85", 0)]),
    ("nonzero_exit_empty_stdout", [("", 128), ("", 128)]),
    ("nonzero_exit_with_stdout", [("HEAD\n", 128), ("", 128)]),
    ("timeout_first", ["timeout"]),
    ("timeout_second", [("abc1234\n", 0), "timeout"]),
    ("git_missing", ["missing"]),
]

_GIT_AUTHOR = ("Fixture Author", "author@example.invalid")
_GIT_COMMITTER = ("Fixture Committer", "committer@example.invalid")
_GIT_COMMITS = [({"README.md": b"synthetic fixture repo\n"}, "first", 1790000000),
                ({"a.txt": b"alpha\n", "dir/b.txt": b"beta\r\n"}, "second", 1790000100),
                ({"README.md": b"synthetic fixture repo, edited\n"}, "third", 1790000200)]


def _sha1(kind, body):
    return hashlib.sha1(kind + b" " + str(len(body)).encode() + b"\0" + body).hexdigest()


def _git_objects():
    """HEAD of the fixture repo computed from git's object format (blob / tree / commit,
    SHA-1), plus every object id (to size the unique --short prefix)."""
    ids, files, parent = [], {}, None
    for changes, message, when in _GIT_COMMITS:
        files.update(changes)

        def tree(prefix):
            entries = {}
            for path, data in files.items():
                if not path.startswith(prefix):
                    continue
                rest = path[len(prefix):]
                if "/" in rest:
                    d = rest.split("/")[0]
                    entries[d] = (b"40000", tree(prefix + d + "/"), d + "/")
                else:
                    blob = _sha1(b"blob", data)
                    ids.append(blob)
                    entries[rest] = (b"100644", blob, rest)
            body = b"".join(mode + b" " + name.encode() + b"\0" + bytes.fromhex(oid)
                            for name, (mode, oid, _) in sorted(entries.items(),
                                                               key=lambda kv: kv[1][2]))
            oid = _sha1(b"tree", body)
            ids.append(oid)
            return oid

        root = tree("")
        who = lambda n, e: f"{n} <{e}> {when} +0000".encode()
        body = (b"tree " + root.encode() + b"\n"
                + (b"parent " + parent.encode() + b"\n" if parent else b"")
                + b"author " + who(*_GIT_AUTHOR) + b"\n"
                + b"committer " + who(*_GIT_COMMITTER) + b"\n\n" + message.encode() + b"\n")
        parent = _sha1(b"commit", body)
        ids.append(parent)
    return parent, sorted(set(ids))


def _octal(data):
    return "".join(f"\\{b:03o}" for b in data)


def _git_script():
    """/bin/sh script that builds the fixture repo in "$1" with hermetic git config."""
    a, c = _GIT_AUTHOR, _GIT_COMMITTER
    out = ["#!/bin/sh",
           "# Generated by native/tools/golden_research.py (m1b_git). Builds a throwaway repo",
           "# in \"$1\"; never point it at a real checkout.",
           "set -eu", 'cd "$1"',
           'export HOME="$1" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C',
           f"export GIT_AUTHOR_NAME='{a[0]}' GIT_AUTHOR_EMAIL='{a[1]}'",
           f"export GIT_COMMITTER_NAME='{c[0]}' GIT_COMMITTER_EMAIL='{c[1]}'",
           "git -c init.defaultBranch=main init -q ."]
    for changes, message, when in _GIT_COMMITS:
        for path, data in changes.items():
            if "/" in path:
                out.append(f"mkdir -p '{os.path.dirname(path)}'")
            out.append(f"printf '{_octal(data)}' > '{path}'")
        out.append("git add -A")
        out.append(f"GIT_AUTHOR_DATE='@{when} +0000' GIT_COMMITTER_DATE='@{when} +0000' "
                   f"git commit -q -m '{message}'")
    return "\n".join(out) + "\n"


@suite("m1b_git")
def git(ctx):
    J = ctx.J
    cases = []
    real = J.subprocess
    try:
        for name, plan in _GIT_PLANS:
            ctx.reset()
            _rm(J.RESEARCH_METRICS)
            fake = _FakeSubprocess(plan)
            J.subprocess = fake
            try:
                J.research_snapshot()
            finally:
                J.subprocess = real
            code = json.loads(_read(J.RESEARCH_METRICS).splitlines()[-1])["code"]
            cases.append({"name": f"strip_{name}",
                          "input": {"kind": "runner", "plan": [
                              {"raise": p} if isinstance(p, str) else {"stdout": p[0], "rc": p[1]}
                              for p in plan]},
                          "expected": {"calls": fake.calls, "git_head": code["git_head"],
                                       "git_commits": code["git_commits"]}})
    finally:
        J.subprocess = real
        _rm(J.RESEARCH_METRICS)

    head, ids = _git_objects()
    n = 7
    while sum(1 for i in ids if i.startswith(head[:n])) > 1:
        n += 1
    cases.append({"name": "fixture_repo",
                  "input": {"kind": "repo", "script": _git_script()},
                  "expected": {"git_head": head[:n], "git_commits": str(len(_GIT_COMMITS)),
                               "head_full": head,
                               "oracle": "git object format (SHA-1) computed in Python; the "
                                         "harness forbids spawning git in the child"}})
    return cases
