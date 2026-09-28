"""M1 T12 golden suite (plan: native/plan/M01 §2.2, §3.7, §3.8, §4.1 m1_persona_llm, §6 T12).

    m1_persona_llm   personality_consolidate and personality_distill_async, run for real with
                     `ollama_post` faked: the fake records the request and returns a canned
                     reply (or raises, standing in for a network failure or timeout)

Plugin for tools/golden.py. Every case is a SCENARIO: `input.files_before` holds the starting
bytes of personality.json and history.json (base64; null = absent). `_history` is then
loaded from that history.json, as at import. `input.steps` is a list of {op, args, now},
where op is "consolidate" or "distill" and args is {reply, fail, during}. `reply` is what the
model says, `fail` makes the fake raise, and `during` is a tool call made WHILE the model is
"thinking" (so the reload-before-commit is observable). `expected.steps` holds, per step:
  llm_request  {system, user, timeout} as handed to ollama_post, or null when there was no call
  result       {"value": None} | {"raises": ExceptionName} (proactive_loop catches a raise)
  bumps        every research_bump call, in order, as [key, n]
  files_after  the bytes of both files afterwards (base64 or null)

personality_distill_async starts a daemon thread. Each distill step snapshots
threading.enumerate() before the call and JOINS every thread that appeared, so the worker
(and its personality_learn) has finished before the step's files are read. Nothing else
changes: the real function, its real thread, its real worker.

State contents are SYNTHETIC. A case whose `expected` has a `native` block is a registered
divergence: the block says what native does instead.
"""
import base64
import json
import os
import struct
import threading

from golden import suite

_T0 = 1790582400.123456
_WEEK = 7 * 86400


def _f(x):
    return {"repr": repr(x), "bits": "%016x" % struct.unpack("<Q", struct.pack("<d", x))[0]}


def _b64(data):
    return None if data is None else base64.b64encode(data).decode("ascii")


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


_CORE = ["Synthetic trait alpha: calm and exact.",
         "Synthetic trait beta — dry, never cruel.",
         "Synthetic trait gamma: brief by default."]


def _notes(n, t0=_T0 - 30 * 86400.0):
    return [{"note": f"Synthetic style note {i:02d} about delivery", "added": t0 + i * 0.5}
            for i in range(n)]


def _pers(learned=None, core=_CORE, **extra):
    d = {"core": core, "learned": _notes(10) if learned is None else learned}
    d.update(extra)
    return json.dumps(d, indent=1).encode("ascii")


def _hist(turns):
    return json.dumps(turns).encode("ascii")


def _turns(n, stem="Synthetic line"):
    return [{"role": "user" if i % 2 == 0 else "assistant", "content": f"{stem} {i:02d}."}
            for i in range(n)]


def _run(ctx, rec, name, before, steps, native=None):
    """before: {"personality.json": bytes|None, "history.json": bytes|None};
    steps: [(op, args, now)]."""
    J = ctx.J
    files = {"personality.json": J.PERSONALITY_FILE, "history.json": J.HIST_FILE}
    ctx.reset()
    J._last_distill = 0.0
    for f, path in files.items():
        if os.path.exists(path):
            os.remove(path)
        if before.get(f) is not None:
            with open(path, "wb") as fh:
                fh.write(before[f])
    J._history = J._history_load()           # what import does
    out = []
    for op, args, now in steps:
        ctx.at(now)
        rec.calls.clear()
        step = {"llm_request": None}

        def fake(path, payload, timeout=120, _args=args, _step=step):
            msgs = payload["messages"]
            _step["llm_request"] = {"system": msgs[0]["content"], "user": msgs[1]["content"],
                                    "timeout": timeout}
            # Checked after the step: an assert here would vanish into the worker's except.
            _step["_shape_ok"] = (path == "/api/chat" and payload["stream"] is False
                                  and payload["options"] == {"temperature": 0}
                                  and [m["role"] for m in msgs] == ["system", "user"])
            during = _args.get("during")
            if during:
                if during["op"] == "rewrite_tool":
                    J.personality_rewrite_tool(during["core"])
                elif during["op"] == "note_tool":
                    J.personality_note_tool(during["note"])
                elif during["op"] == "forget":
                    J.personality_forget()
                else:
                    raise AssertionError(during)
            if _args.get("fail"):
                raise TimeoutError("synthetic model timeout")
            return {"message": {"content": _args.get("reply")}}
        J.ollama_post = fake
        try:
            if op == "consolidate":
                J.personality_consolidate()
            elif op == "distill":
                alive = set(threading.enumerate())
                J.personality_distill_async()
                for t in set(threading.enumerate()) - alive:
                    t.join()
            else:
                raise AssertionError(op)
            step["result"] = {"value": None}
        except AssertionError:
            raise
        except Exception as e:                     # proactive_loop's except catches it
            step["result"] = {"raises": type(e).__name__}
        if not step.pop("_shape_ok", True):
            raise AssertionError(f"{name}: unexpected ollama_post payload shape")
        step["bumps"] = list(rec.calls)
        step["files_after"] = {f: _b64(_read(p)) for f, p in files.items()}
        out.append(step)
    case = {"name": name,
            "input": {"files_before": {f: _b64(before.get(f)) for f in files},
                      "steps": [{"op": op, "args": args, "now": _f(float(now))}
                                for op, args, now in steps]},
            "expected": {"steps": out}}
    if native:
        case["expected"]["native"] = native
    return case


def C(reply=None, fail=False, during=None, at=_T0):
    return ("consolidate", {"reply": reply, "fail": fail, "during": during}, at)


def D(reply=None, fail=False, during=None, at=_T0):
    return ("distill", {"reply": reply, "fail": fail, "during": during}, at)


_GOOD3 = "Keep answers short and exact.\nDry humour, never cruel.\nAddress the user as Sam."
_EIGHT = "\n".join(f"Merged synthetic note number {i} here." for i in range(8))
_NINE = "\n".join(f"Merged synthetic note number {i} here." for i in range(9))


def _consolidation_cases(ctx, rec):
    P = lambda **k: {"personality.json": _pers(**k), "history.json": None}
    return [
        _run(ctx, rec, "consolidate_not_due_9_notes", P(learned=_notes(9)), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_not_due_under_a_week",
             P(learned=_notes(12), consolidated_at=_T0 - _WEEK + 0.5), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_due_exactly_a_week",
             P(learned=_notes(12), consolidated_at=_T0 - _WEEK), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_due_no_key_10_notes", P(), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_missing_file", {"personality.json": None, "history.json": None},
             [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_reply_0_lines_empty", P(), [C("")]),
        _run(ctx, rec, "consolidate_reply_none_content", P(), [C(None)]),
        _run(ctx, rec, "consolidate_reply_only_short_lines", P(),
             [C("ok\n  fine   \n- tiny\n\n1234567")]),
        _run(ctx, rec, "consolidate_reply_1_line", P(), [C("Be brief and exact, always.")]),
        _run(ctx, rec, "consolidate_reply_8_lines", P(), [C(_EIGHT)]),
        _run(ctx, rec, "consolidate_reply_9_lines", P(), [C(_NINE)]),
        _run(ctx, rec, "consolidate_reply_bullets", P(),
             [C("- Dash bulleted synthetic note.\n• Dot bulleted synthetic note.\n"
                "  -• - Mixed bullets synthetic note.\n1. Numbered synthetic note stays.\n"
                "* Star bullet synthetic note stays.")]),
        _run(ctx, rec, "consolidate_reply_whitespace_and_breaks", P(),
             [C("\n\n   Leading spaces synthetic note.   \r\nCRLF synthetic note here.\r\n"
                " Line separator synthetic note.\x85Next line synthetic note.\t\n\f"
                "　Ideographic space synthetic note.　\n")]),
        _run(ctx, rec, "consolidate_reply_long_and_dash_only", P(),
             [C("L" * 250 + "\n----------\n" + "é" * 150 + "\n" + "\U0001F600" * 205)]),
        _run(ctx, rec, "consolidate_llm_failure", P(), [C(fail=True)]),
        _run(ctx, rec, "consolidate_keeps_other_keys",
             P(consolidated_at=_T0 - 2 * _WEEK, extra={"k": [1, 2]}, zeta="kept"), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_nan_is_due", P(consolidated_at=float("nan")), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_neg_inf_is_due", P(consolidated_at=float("-inf")), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_inf_not_due", P(consolidated_at=float("inf")), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_int_and_bool_stamp",
             P(consolidated_at=int(_T0) - _WEEK), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_bool_stamp", P(consolidated_at=True), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_str_stamp_raises", P(consolidated_at="last week"), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_null_stamp_raises", P(consolidated_at=None), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_bigint_stamp", P(consolidated_at=10 ** 30), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_neg_bigint_stamp", P(consolidated_at=-(10 ** 30)), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_huge_int_stamp_raises", P(consolidated_at=10 ** 400),
             [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_learned_is_a_str", P(learned="twelve chars"), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_entry_without_note",
             P(learned=_notes(10) + [{"added": _T0}]), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_entry_int_note",
             P(learned=_notes(10) + [{"note": 5, "added": _T0}]), [C(_GOOD3)]),
        _run(ctx, rec, "consolidate_then_again", P(learned=_notes(15)),
             [C(_GOOD3), C(_EIGHT, at=_T0 + 3600), C(_EIGHT, at=_T0 + _WEEK)]),
        _run(ctx, rec, "consolidate_rewrite_during_call", P(),
             [C(_GOOD3, during={"op": "rewrite_tool",
                                 "core": "New synthetic trait one\nNew synthetic trait two\n"
                                         "New synthetic trait three"})]),
        _run(ctx, rec, "consolidate_forget_during_call", P(consolidated_at=_T0 - 9 * 86400),
             [C(_GOOD3, during={"op": "forget"})]),
    ]


def _distill_cases(ctx, rec):
    def H(turns, pers=None):
        return {"personality.json": _pers(learned=_notes(2)) if pers is None else pers,
                "history.json": _hist(turns)}
    ok = "The user prefers short, exact answers."
    long_turns = _turns(4, "Head") + [
                  {"role": "user", "content": "U" * 150 + "\U0001F600" * 60},
                  {"role": "assistant", "content": "é" * 120},
                  {"role": "user", "content": ""},
                  {"role": "assistant", "content": None},
                  {"role": "user"},
                  {"role": "assistant", "content": 0},
                  {"role": "tool", "content": "filtered at load"},
                  {"role": "user", "content": "  keep the spaces  ", "extra": 1},
                  {"role": "assistant", "content": "Line one\nline two"}]
    return [
        _run(ctx, rec, "distill_3_turns_not_due", H(_turns(3)), [D(ok)]),
        _run(ctx, rec, "distill_4_turns", H(_turns(4)), [D(ok)]),
        _run(ctx, rec, "distill_no_history_file", {"personality.json": _pers(), "history.json": None},
             [D(ok)]),
        _run(ctx, rec, "distill_missing_personality_file",
             {"personality.json": None, "history.json": _hist(_turns(5))}, [D(ok)]),
        _run(ctx, rec, "distill_none", H(_turns(6)), [D("NONE")]),
        _run(ctx, rec, "distill_empty_reply", H(_turns(6)), [D("")]),
        _run(ctx, rec, "distill_null_content", H(_turns(6)), [D(None)]),
        _run(ctx, rec, "distill_lowercase", H(_turns(6)), [D("the user likes dry humour.")]),
        _run(ctx, rec, "distill_uppercase", H(_turns(6)), [D("THE USER WANTS NO SMALL TALK")]),
        _run(ctx, rec, "distill_the_users_quirk", H(_turns(6)), [D("The users would rather hear less.")]),
        _run(ctx, rec, "distill_not_starting_the_user", H(_turns(6)),
             [D("Sure! The user prefers brevity.")]),
        _run(ctx, rec, "distill_whitespace", H(_turns(6)),
             [D("\n\t  The user wants answers in one sentence. . \n　")]),
        _run(ctx, rec, "distill_199_chars", H(_turns(6)), [D("The user " + "x" * 190)]),
        _run(ctx, rec, "distill_200_chars", H(_turns(6)), [D("The user " + "x" * 191)]),
        _run(ctx, rec, "distill_exactly_the_user", H(_turns(6)), [D("The user.")]),
        _run(ctx, rec, "distill_the_use", H(_turns(6)), [D("The use")]),
        _run(ctx, rec, "distill_dedupes_existing",
             H(_turns(6), _pers(learned=[{"note": "The user prefers short exact answers",
                                          "added": _T0 - 100.0}] + _notes(3))),
             [D(ok)]),
        _run(ctx, rec, "distill_llm_failure_still_rate_limits", H(_turns(6)),
             [D(fail=True), D(ok, at=_T0 + 100), D(ok, at=_T0 + 900)]),
        _run(ctx, rec, "distill_rate_limit", H(_turns(6)),
             [D(ok), D("The user likes lists.", at=_T0 + 899.5),
              D("The user likes lists.", at=_T0 + 900)]),
        _run(ctx, rec, "distill_long_and_odd_turns", H(long_turns), [D(ok)]),
        _run(ctx, rec, "distill_14_turns_last_10", H(_turns(14)), [D(ok)]),
        _run(ctx, rec, "distill_int_content_raises_in_worker",
             H(_turns(4) + [{"role": "user", "content": 7}]), [D(ok)]),
        _run(ctx, rec, "distill_list_content", H(_turns(4) + [{"role": "user", "content": ["x"]}]),
             [D(ok)],
             native={"divergence": "R8-list-content", "no_request": True, "files_unchanged": True,
                     "why": "Python formats a list content with repr(); native treats any "
                            "non-str content as a malformed history and skips the distill"}),
        _run(ctx, rec, "distill_note_tool_during_call", H(_turns(6)),
             [D(ok, during={"op": "note_tool", "note": "Synthetic note added mid-call."})]),
    ]


@suite("m1_persona_llm")
def persona_llm_suite(ctx):
    J = ctx.J

    class Rec:
        calls = []
    orig = J.research_bump

    def bump(key, n=1):
        Rec.calls.append([key, n])
        return orig(key, n)
    J.research_bump = bump
    try:
        cases = _consolidation_cases(ctx, Rec) + _distill_cases(ctx, Rec)
    finally:
        J.research_bump = orig
    literals = {"name": "literals", "input": {},
                "expected": {"consolidate_system": _capture_system(ctx, "consolidate"),
                             "distill_system": _capture_system(ctx, "distill")}}
    return [literals] + cases


def _capture_system(ctx, which):
    """The system strings, seen through one real call each (not copied from the source)."""
    J = ctx.J
    seen = {}

    def fake(path, payload, timeout=120):
        seen["system"] = payload["messages"][0]["content"]
        return {"message": {"content": "NONE"}}
    J.ollama_post = fake
    ctx.reset()
    if which == "consolidate":
        with open(J.PERSONALITY_FILE, "wb") as fh:
            fh.write(_pers())
        J.personality_consolidate()
    else:
        J._last_distill = 0.0
        J._history = _turns(4)
        alive = set(threading.enumerate())
        J.personality_distill_async()
        for t in set(threading.enumerate()) - alive:
            t.join()
    return seen["system"]
