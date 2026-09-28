"""M1b T5 golden suite: the daily snapshot row (plan: native/plan/M01b §2.1, §2.2, §3.3, §3.4,
§4 `snapshot.json`, §6 T5).

    m1b_snapshot    the REAL, UNPATCHED research_snapshot run in synthetic sandboxes: every
                    state file it reads, HERE/jarvis.py stand-ins, usage.json variants, git
                    through a recording stand-in for jarvis's `subprocess` (the harness
                    forbids child processes), and the in-memory history length

Plugin for tools/golden.py. jarvis.py was not patched (user decision), so Python writes
schema-1 rows only. "Strip-schema-2 mode": the Swift test builds the native row, removes
the four schema-2 keys (emotions_at, schema, runtime, code_native) and compares the rest
BYTE FOR BYTE with the line Python appended. The schema-2 blocks are native-specified and
unit-tested against §3.3.

Case shape: `input` = {ts {repr, bits}, files {relpath: b64 | null (absent)}, git [plan],
history_turns}; `expected` = {line_b64 (the appended line without "\n") | null (no row),
log [research_snapshot's log lines], git_calls [argv + kwargs]}. A `native` block marks
the registered deviation D5 (§3.4): Python writes no row when jarvis.py cannot be read,
native writes one with code.bytes / code.lines null. The "literals" case carries
_PERSONALITY_SEED and the _EMO_DIMS baselines, which the Swift test injects into
FileSnapshotSources.

All content is synthetic: shapes follow the real files (key names, layout); no value is
copied from them.
"""
import base64
import json
import math
import os
import shutil
import struct
import subprocess
import types

from golden import suite

_T0 = 1790582400.123456          # 2026-09-28 09:00 BST, with microseconds
_FILES = ["jarvis.py", "personality.json", "emotions.json", "profile.json", "corrections.json",
          "knowledge.json", "history.json", "voiceprint.npy", "research/usage.json",
          "research/metrics.jsonl"]


def _f(x):
    return {"repr": repr(x), "bits": "%016x" % struct.unpack("<Q", struct.pack("<d", x))[0]}


def _b64(data):
    return None if data is None else base64.b64encode(data).decode("ascii")


def _dump(obj, indent=1):
    return json.dumps(obj, indent=indent).encode("ascii")


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except (FileNotFoundError, IsADirectoryError):
        return None


def _rm(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.remove(path)


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


_GIT_OK = [("abc1234\n", 0), ("212\n", 0)]


def _run(ctx, name, ts, files, git=_GIT_OK, history_turns=0, native=None):
    J = ctx.J
    ctx.reset()
    here = J.HERE
    paths = {rel: os.path.join(here, rel) for rel in _FILES}
    for rel, p in paths.items():
        _rm(p)
        data = files.get(rel)
        if data == "DIR":
            os.makedirs(p)
        elif data is not None:
            with open(p, "wb") as fh:
                fh.write(data)
    J._history = [{"role": "user" if i % 2 == 0 else "assistant", "content": f"synthetic turn {i}"}
                  for i in range(history_turns)]
    before = _read(paths["research/metrics.jsonl"]) or b""
    ctx.at(ts)
    fake = _FakeSubprocess(git)
    real_sub, real_log = J.subprocess, J.log
    logs = []
    J.subprocess, J.log = fake, logs.append
    try:
        J.research_snapshot()
    finally:
        J.subprocess, J.log = real_sub, real_log
    after = _read(paths["research/metrics.jsonl"]) or b""
    if after == before:
        line = None
    else:
        assert after.startswith(before) and after.endswith(b"\n"), name
        line = after[len(before):-1]
        assert b"\n" not in line, name
    case = {"name": name,
            "input": {"ts": _f(float(ts)),
                      "files": {rel: (None if files.get(rel) is None else
                                      "DIR" if files[rel] == "DIR" else _b64(files[rel]))
                                for rel in _FILES},
                      "git": [{"raise": p} if isinstance(p, str) else {"stdout": p[0], "rc": p[1]}
                              for p in git],
                      "history_turns": history_turns},
            "expected": {"line_b64": _b64(line), "log": logs, "git_calls": fake.calls}}
    if native:
        case["expected"]["native"] = native
    J._history = []
    return case


def _personality(learned=2, **extra):
    d = {"core": ["Synthetic trait alpha: calm and exact.", "Synthetic trait beta — dry, never cruel."],
         "learned": [{"note": f"Synthetic learned note {i} — café ☕ “quoted” 🎈", "added": _T0 - 900 + i * 0.25}
                     for i in range(learned)]}
    d.update(extra)
    return _dump(d)


def _emotions(**kw):
    d = {"mood": 0.6123456, "energy": 0.55, "warmth": 0.7, "patience": 0.8, "at": _T0 - 3600.5}
    d.update(kw)
    return _dump({k: v for k, v in d.items() if v is not _DROP})


_DROP = object()


def _usage(today="2026-09-28"):
    return _dump({"2026-09-26": {"interactions": 4, "tone_calm_and_even": 2},
                  "2026-09-27": {"emotion_praise": 1, "interactions": 9},
                  today: {"interactions": 3, "backend_claude": 2, "user_correction": 1}})


_JARVIS = b"# synthetic jarvis.py stand-in\nimport os\n\ndef main():\n    return 'caf\xc3\xa9'\n"


def _real_shaped():
    return {
        "jarvis.py": _JARVIS,
        "personality.json": _personality(learned=3, consolidated_at=_T0 - 86400.25),
        "emotions.json": _emotions(),
        "profile.json": _dump({"facts": {"name": {"value": "Robin", "updated": _T0 - 50},
                                         "current project": {"value": "a bird feeder — v2 🐦",
                                                             "updated": _T0 - 40}}}),
        "corrections.json": _dump([{"heard": "jarvus", "meant": "jarvis", "added": _T0 - 10},
                                   {"heard": "sea cow", "meant": "café", "added": _T0 - 5}]),
        "knowledge.json": _dump({"topics": {f"topic {i}": {"summary": f"synthetic summary {i}", "updated": _T0 - i}
                                            for i in range(4)}, "queue": ["what is a bird feeder?"]}),
        "history.json": json.dumps([{"role": "user", "content": "hi"}]).encode("ascii"),
        "research/usage.json": _usage(),
    }


def _cases(ctx):
    J = ctx.J
    T = _T0
    cases = [{"name": "literals", "input": {},
              "expected": {"personality_seed_json": json.dumps(J._PERSONALITY_SEED),
                           "emotion_baselines": [[k, _f(float(b))] for k, (b, _) in J._EMO_DIMS.items()]}}]

    def sc(name, files, **kw):
        cases.append(_run(ctx, name, kw.pop("ts", T), files, **kw))

    rs = _real_shaped()
    # ── The 12 sandboxes of M01b §4 (and their neighbours) ──
    sc("all_missing", {"jarvis.py": _JARVIS})
    sc("real_shaped", rs, history_turns=5)
    sc("emotions_int_extra_no_at", {**rs, "emotions.json": _dump(
        {"mood": 1, "energy": 0, "warmth": 0.7, "patience": 0.8, "focus": 0.12345})})
    sc("emotions_odd_floats", {**rs, "emotions.json": json.dumps(
        {"mood": 0.1 + 0.2, "energy": 2.675, "warmth": 1e-07, "patience": -0.0, "bias": 0.0625,
         "x": 1e16, "big": 10 ** 30, "flag": True, "off": False, "tiny": 5e-324, "half": 0.0005,
         "nan": math.nan, "inf": math.inf, "ninf": -math.inf, "at": 1790000000.1234567}, indent=1).encode("ascii")})
    sc("emotions_missing_dim", {**rs, "emotions.json": _dump({"mood": 0.5, "energy": 0.5, "warmth": 0.5, "at": 1.0})})
    sc("emotions_at_string", {**rs, "emotions.json": _emotions(at="yesterday")})
    sc("emotions_not_dict_scalar", {**rs, "emotions.json": b"5"})
    sc("emotions_list_partial", {**rs, "emotions.json": b'["mood", "energy"]'})
    sc("emotions_corrupt", {**rs, "emotions.json": b'{"mood": 0.'})
    sc("profile_without_facts_kb_without_topics", {**rs, "profile.json": _dump({"other": 1}),
                                                   "knowledge.json": _dump({"queue": ["x"]})})
    sc("counts_list_and_str_shapes", {**rs, "profile.json": _dump({"facts": [1, 2, 3]}),
                                      "knowledge.json": _dump({"topics": "é🎈x"})})
    sc("counts_corrupt_files", {**rs, "profile.json": b"{", "knowledge.json": b"\xef\xbb\xbf{}",
                                "corrections.json": b"[{"})
    sc("corrections_invalid", {**rs, "corrections.json": _dump([
        {"heard": "a", "meant": "b"}, {"heard": "", "meant": "b"}, {"heard": "a"}, "str", 5, None,
        {"heard": "x", "meant": "y", "added": 1}, {"heard": 0, "meant": "z"},
        {"heard": [1], "meant": {"k": 1}}, [{"heard": "n", "meant": "m"}]])})
    sc("corrections_dict", {**rs, "corrections.json": _dump({"heard": "a", "meant": "b"})})
    sc("history_13_mid_turn", {**rs, "history.json": _dump(
        [{"role": ["user", "assistant", "tool"][i % 3], "content": f"t{i}"} for i in range(14)], indent=None)},
       history_turns=13)
    sc("voiceprint_present", {**rs, "voiceprint.npy": b"\x93NUMPY synthetic"})
    sc("jarvis_crlf", {**rs, "jarvis.py": b"a = 1\r\nb = 2\r\n"})
    sc("jarvis_lone_cr", {**rs, "jarvis.py": b"a = 1\rb = 2\r\rc"})
    sc("jarvis_no_final_newline", {**rs, "jarvis.py": b"line one\nline two"})
    sc("jarvis_empty", {**rs, "jarvis.py": b""})
    sc("jarvis_bom_and_multibyte", {**rs, "jarvis.py": b"\xef\xbb\xbfx = '\xe2\x80\xa8'\n\xf0\x9f\x8e\x88\n"})
    sc("git_non_repo", rs, git=[("", 128), ("", 128)])
    sc("git_timeout", rs, git=["timeout"])
    sc("git_missing", rs, git=["missing"])
    sc("git_whitespace", rs, git=[(" \tdeadbee \r\n", 0), ("\n 3 \x0c\n", 0)])
    # ── usage_today variants ──
    sc("usage_missing", {k: v for k, v in rs.items() if k != "research/usage.json"})
    sc("usage_corrupt", {**rs, "research/usage.json": b'{"2026-09-28": {"inter'})
    sc("usage_list_root", {**rs, "research/usage.json": b"[]"})
    sc("usage_bom", {**rs, "research/usage.json": b"\xef\xbb\xbf" + _usage()})
    sc("usage_today_absent", {**rs, "research/usage.json": _dump({"2026-09-27": {"interactions": 1}})})
    sc("usage_today_not_dict", {**rs, "research/usage.json": _dump({"2026-09-28": [1, "two", None]})})
    sc("usage_float_and_bool_counters", {**rs, "research/usage.json": _dump(
        {"2026-09-28": {"interactions": 2.0, "speaker_pass": True, "tone_é": 1, "big": 10 ** 20}})})
    # ── personality shapes ──
    sc("personality_core_falsy", {**rs, "personality.json": _dump({"core": [], "learned": [{"note": "x"}]})})
    sc("personality_not_dict", {**rs, "personality.json": b'["core"]'})
    sc("personality_extra_keys_no_learned", {**rs, "personality.json": _dump(
        {"core": ["only"], "unknown_future": {"nested": [1, -0.0, 1e-07, None, True]}, "consolidated_at": 1.5})})
    # ── time: local midnight (BST), GMT, metrics already holding a row ──
    sc("tz_after_local_midnight_bst", {**rs, "research/usage.json": _usage("2026-09-29")},
       ts=1790638200.5)                                                  # 2026-09-28 23:30 UTC
    sc("tz_gmt_winter", {**rs, "research/usage.json": _usage("2026-12-01")}, ts=1796083200.0)
    sc("metrics_existing_row", {**rs, "research/metrics.jsonl": b'{"ts": 1.0, "date": "2026-09-27"}\n'})
    # ── Python raises → no row (native: .failed, nothing appended) ──
    sc("fail_emotions_extra_str", {**rs, "emotions.json": _emotions(note="x")})
    sc("fail_emotions_extra_null", {**rs, "emotions.json": _emotions(extra=None)})
    sc("fail_emotions_list_all_dims", {**rs, "emotions.json": b'["mood", "energy", "warmth", "patience"]'})
    sc("fail_emotions_str_all_dims", {**rs, "emotions.json": b'"mood energy warmth patience"'})
    sc("fail_profile_list", {**rs, "profile.json": b"[1, 2]"})
    sc("fail_profile_facts_int", {**rs, "profile.json": _dump({"facts": 7})})
    sc("fail_kb_list", {**rs, "knowledge.json": b"[]"})
    sc("fail_kb_topics_null", {**rs, "knowledge.json": _dump({"topics": None})})
    # ── D5: jarvis.py cannot be read. Python raises (no row); native writes the row with
    #    code.bytes / code.lines null and the git fields as usual. ──
    #    Every other input equals real_shaped's, so native's row must be Python's real_shaped
    #    line with those two values null (`reference`).
    d5 = {"divergence": "D5", "native_row": True, "code_null": ["bytes", "lines"], "reference": "real_shaped"}
    sc("d5_jarvis_missing", {k: v for k, v in rs.items() if k != "jarvis.py"}, history_turns=5, native=d5)
    sc("d5_jarvis_invalid_utf8", {**rs, "jarvis.py": b"ok\n\xff\xfe bad\n"}, history_turns=5, native=d5)
    sc("d5_jarvis_directory", {**rs, "jarvis.py": "DIR"}, history_turns=5, native=d5)
    return cases


@suite("m1b_snapshot")
def snapshot(ctx):
    J = ctx.J
    me = os.path.join(J.HERE, "jarvis.py")
    original = _read(me)
    try:
        return _cases(ctx)
    finally:
        for rel in _FILES:
            _rm(os.path.join(J.HERE, rel))
        with open(me, "wb") as fh:
            fh.write(original)
