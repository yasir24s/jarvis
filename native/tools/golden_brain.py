"""M3 B1 golden suites: the Claude driver's deterministic pieces (plan: native/plan/M02-M04 §4).

Plugin for tools/golden.py. Every expected value comes from running jarvis.py's own code:

  m3_tools_list        TOOLS names in order, and _claude_allowed as _build_claude_server() sets
                       it (run with _load_claude_sdk patched to a stub, so no SDK is needed).
  m3_pop_sentences     pop_sentences(buf, force) on fixed texts ("pure/..." cases), and the same
                       texts cut into fixed chunk lists and fed through the REAL _claude_stream
                       loop by a fake SDK whose query() yields one text block per chunk
                       ("chunked/..." cases). speak is patched to a recorder, so nothing is said.
                       The loop skips empty blocks (`if block.text`), so a Swift feed must too.
  m3_claude_reason     _claude_reason(Exception(message)). The keyword groups are read from the
                       function's own constants, so every keyword is covered in source order.
  m3_backend_key       the research counter _set_backend bumps (research_bump and log patched).
  m3_history_preamble  _claude_history_preamble() with _history set per case, 0 to 13 turns.
                       A 13-turn history only exists after an untrimmed assistant append, so
                       those cases end with an assistant turn holding a string.
  m3_claude_env_path   _claude_env()["PATH"] with the child's PATH patched. The child's HOME is
                       the sandbox, so ~/.local/bin is written as ${JARVIS_HOME}/.local/bin.

Sample text uses neutral stand-ins only (Robin, Morgan, Sam).
"""
import asyncio
import dataclasses
import os
import random
import re

from golden import suite

_NAMES = ("Robin", "Morgan", "Sam")

# Characters Python's \s and str.strip() treat as whitespace; several are not ICU's \s.
_WS = {"sp": " ", "tab": "\t", "nl": "\n", "cr": "\r", "crlf": "\r\n", "vt": "\x0b",
       "ff": "\x0c", "fs": "\x1c", "gs": "\x1d", "rs": "\x1e", "us": "\x1f", "nel": "\x85",
       "nbsp": " ", "ogham": " ", "enquad": " ", "emsp": " ",
       "hair": " ", "lsep": " ", "psep": " ", "nnbsp": " ",
       "mmsp": " ", "ideo": "　"}
# Look like spacing, but are not whitespace to Python.
_NOT_WS = {"zwsp": "​", "bom": "﻿", "mvs": "᠎", "wj": "⁠"}


# ─── m3_tools_list ─────────────────────────────────────────────────────────────

class _StubSDK:
    """Just enough of claude_agent_sdk for _build_claude_server() to run to completion."""

    @staticmethod
    def tool(name, description, schema):
        return lambda handler: name

    @staticmethod
    def create_sdk_mcp_server(name, version, tools):
        return {"name": name, "version": version, "tools": list(tools)}


@suite("m3_tools_list")
def tools_list(ctx):
    J = ctx.J
    saved = (J._load_claude_sdk, J._claude_server, J._claude_allowed)
    J._load_claude_sdk = lambda: _StubSDK
    J._claude_server = None
    try:
        server = J._build_claude_server()
        allowed = list(J._claude_allowed)
    finally:
        J._load_claude_sdk, J._claude_server, J._claude_allowed = saved
    names = [t["function"]["name"] for t in J.TOOLS]
    if server["tools"] != names:
        raise RuntimeError("stub SDK saw a different tool list than TOOLS")
    return [{"name": "tools", "input": {},
             "expected": {"names": names, "allowed": allowed}}]


# ─── m3_pop_sentences ──────────────────────────────────────────────────────────

_WORDS = ("Robin", "Morgan", "Sam", "asked", "about", "the", "quarterly", "report", "and",
          "the", "garden", "plans", "for", "next", "week")


def _runon(n, sep=" "):
    """Exactly n code points of words joined by sep, with no terminal punctuation."""
    out, i = "", 0
    while len(out) < n:
        out += (sep if out else "") + _WORDS[i % len(_WORDS)]
        i += 1
    return out[:n]


def _texts():
    t = []
    add = lambda label, s: t.append((label, s))
    add("empty", "")
    add("space", " ")
    add("spaces3", "   ")
    add("word", "Hello")
    add("word_dot", "Hello.")
    add("word_dot_sp", "Hello. ")
    add("two", "Hello. World")
    add("two_dots", "Hello. World.")
    add("two_dots_sp", "Hello. World. ")
    add("three_marks", "Robin called! Did Morgan answer? Sam did. ")
    add("run_marks", "Wait... what?! Really?? Yes!!! ")
    add("dot_only", ".")
    add("dot_sp", ". ")
    add("dots_sp", "... ")
    add("q_sp", "? ")
    add("bang_nl", "!\n")
    add("lead_ws", "   Robin is here. Morgan too.")
    add("no_space_after", "Robin.Morgan.Sam.")
    add("decimal", "It costs 3.50 today. Tomorrow 4.25. ")
    add("abbrev", "Dr. Sam met Mr. Robin at 5 p.m. sharp. ")
    add("eg", "Bring things, e.g. a pen. Also paper.")
    add("url", "Visit example.com. Then example.org/page.html now. ")
    add("quote_after", 'Morgan said "stop." Then left. ')
    add("paren_after", "Robin nodded (twice.) Sam laughed. ")
    add("ellipsis_char", "Robin paused… then spoke. ")
    add("fullwidth_stop", "你好。再见。 ")
    add("interrobang", "Really‽ Yes. ")
    add("inverted", "¿Qué? Nada. ")
    add("nl_only", "Line one.\nLine two.\nLine three")
    add("crlf", "Line one.\r\nLine two.\r\n")
    add("tab", "One.\tTwo.\tThree")
    add("multi_ws", "One. \t \n Two.   \n\n Three.")
    add("trailing_ws_block", "Done.   \t\n")
    add("ws_only_mixed", " \n\t ")
    add("sentence_then_ws", "Sam left.  \n  ")
    add("emoji", "Robin waved \U0001F44B. Morgan smiled \U0001F600! ")
    add("combining", "Café is open. Résumé sent. ")
    add("digits_end", "Call at 10. 11 is late. ")
    add("mark_eol", "Is it done?")
    add("mark_eol_sp", "Is it done? ")
    add("mark_then_quote_sp", "Is it done?\" Yes. ")
    add("space_before_mark", "Robin left . Morgan stayed ! Sam ?")
    for k, ws in _WS.items():
        add(f"ws_{k}", f"Robin left.{ws}Morgan stayed.{ws}Sam")
        add(f"strip_{k}", f"{ws}Robin{ws}")
    for k, ch in _NOT_WS.items():
        add(f"notws_{k}", f"Robin left.{ch}Morgan stayed.{ch} Sam")
    # Around _SENT_MAX_CHARS (160): the stream-mode cut at the last " " before 160.
    for n in (150, 159, 160, 161, 162, 170, 200, 320, 481, 700):
        add(f"runon_{n}", _runon(n))
    add("runon_nl_200", _runon(200, "\n"))
    add("runon_tab_200", _runon(200, "\t"))
    add("runon_nbsp_200", _runon(200, " "))
    add("token_160", "x" * 160)
    add("token_161", "x" * 161)
    add("token_200", "x" * 200)
    add("lead_space_token", " " + "y" * 200)
    add("space_at_1", "a " + "b" * 200)
    add("space_at_159", "a" * 159 + " " + "b" * 20)
    add("space_at_160", "a" * 160 + " " + "b" * 20)
    add("space_at_161", "a" * 161 + " " + "b" * 20)
    add("spaces_at_100_159", "a" * 100 + " " + "b" * 58 + " " + "c" * 30)
    add("spaces_at_100_160", "a" * 100 + " " + "b" * 59 + " " + "c" * 30)
    add("spaces_200", " " * 200)
    add("newlines_200", "\n" * 200)
    add("sentence_then_runon", "Short one. " + _runon(300))
    add("runon_then_sentence", _runon(170) + ". Next.")
    add("emoji_runon", "\U0001F600" * 170)
    add("emoji_words", " ".join(["\U0001F600\U0001F601"] * 70))
    add("combining_runon", "é" * 100)
    add("crlf_runon", "\r\n".join(["Robin and Morgan"] * 12))
    add("long_sentences", " ".join(f"{w} said the plan for week {i} is fine."
                                   for i, w in enumerate(_NAMES * 4)))
    frags = ["Robin", "Morgan", "Sam", "the", "report", "is", "ready", "3.5", "e.g.", "Dr.",
             "ok", "\U0001F600", "é", "café", "x" * 30]
    marks = [".", "!", "?", "...", "?!", ""]
    seps = [" ", "  ", "\n", "\t", " ", " ", "\x0b", "\x85", " ", "\x1f",
            "\r\n", ""]
    rng = random.Random(20260929)
    for i in range(80):
        s = ""
        for _ in range(rng.randint(1, 40)):
            s += rng.choice(frags) + rng.choice(marks) + rng.choice(seps)
        add(f"random_{i:02d}", s)
    labels = [label for label, _ in t]
    if len(set(labels)) != len(labels):
        raise RuntimeError("duplicate text label")
    return t


# Texts also fed in chunks: the multi-sentence ones, the whitespace kinds, the 160 boundary.
_CHUNKED = ("empty", "space", "word_dot", "two", "two_dots_sp", "three_marks", "run_marks",
            "lead_ws", "decimal", "abbrev", "quote_after", "nl_only", "crlf", "multi_ws",
            "trailing_ws_block", "ws_only_mixed", "emoji", "combining", "ws_nbsp", "ws_nel",
            "ws_vt", "ws_us", "ws_lsep", "ws_crlf", "notws_zwsp", "runon_161", "runon_320",
            "runon_nl_200", "token_200", "lead_space_token", "spaces_200",
            "sentence_then_runon", "emoji_runon", "combining_runon", "crlf_runon",
            "long_sentences", "random_00", "random_01", "random_02", "random_03",
            "random_04", "random_05", "spaces_at_100_160")


def _chunkings(label, text, seed):
    yield "whole", [text]
    if len(text) <= 80:
        yield "n1", list(text)
    for n in (2, 3, 7, 16, 50):
        yield f"n{n}", [text[i:i + n] for i in range(0, len(text), n)] or [""]
    yield "words_trail", re.findall(r"\S+\s*|\s+", text) or [""]
    yield "words_lead", re.findall(r"\s*\S+|\s+", text) or [""]
    pieces = [text[i:i + 5] for i in range(0, len(text), 5)] or [""]
    yield "empties", [""] + [c for p in pieces for c in (p, "")]
    rng = random.Random(seed)
    cuts, i = [], 0
    while i < len(text):
        n = rng.randint(1, 24)
        cuts.append(text[i:i + n])
        i += n
    yield "random", cuts or [""]


@dataclasses.dataclass
class _Options:                 # _claude_stream keeps only kwargs named as fields: none here
    pass


class _TextBlock:
    def __init__(self, text):
        self.text = text


class _AssistantMessage:
    def __init__(self, content):
        self.content = content


class _ResultMessage:
    pass


class _FakeSDK:
    """Stands in for claude_agent_sdk in _claude_stream: one assistant text block per chunk.
    state["at"] is the chunk being processed, or None once the stream has ended."""
    ClaudeAgentOptions = _Options
    AssistantMessage = _AssistantMessage
    TextBlock = _TextBlock
    ResultMessage = _ResultMessage

    def __init__(self, chunks, state):
        self.chunks, self.state = chunks, state

    def query(self, prompt, options):
        async def gen():
            for i, c in enumerate(self.chunks):
                self.state["at"] = i
                yield _AssistantMessage([_TextBlock(c)])
            self.state["at"] = None
        return gen()


def _feed_claude_stream(J, chunks):
    """(sentences spoken after each chunk, sentences from the final force flush, return value)."""
    state = {"at": None}
    steps, final = [[] for _ in chunks], []

    def speak(s):
        (final if state["at"] is None else steps[state["at"]]).append(s)

    saved = J.speak
    J.speak = speak
    try:
        text = asyncio.run(J._claude_stream(_FakeSDK(chunks, state), "", "", None, []))
    finally:
        J.speak = saved
    return steps, final, text


def _feed_direct(J, chunks):
    """The same feed written out, as a cross-check on the fake SDK."""
    buf, steps = "", []
    for c in chunks:
        got = []
        if c:
            buf += c
            got, buf = J.pop_sentences(buf)
        steps.append(got)
    final, _ = J.pop_sentences(buf, force=True)
    return steps, final


@suite("m3_pop_sentences")
def pop_sentences(ctx):
    J = ctx.J
    cases = [{"name": "constants", "input": {},
              "expected": {"boundary": J._SENT_BOUNDARY.pattern,
                           "max_chars": J._SENT_MAX_CHARS}}]
    texts = _texts()
    for label, text in texts:
        for force in (False, True):
            out, rest = J.pop_sentences(text, force)
            cases.append({"name": f"pure/{label}/{'force' if force else 'stream'}",
                          "input": {"buf": text, "force": force},
                          "expected": {"sentences": out, "rest": rest}})
    by_label = dict(texts)
    for seed, label in enumerate(_CHUNKED):
        for scheme, chunks in _chunkings(label, by_label[label], 7000 + seed):
            steps, final, text = _feed_claude_stream(J, chunks)
            if (steps, final) != _feed_direct(J, chunks):
                raise RuntimeError(f"chunked/{label}/{scheme}: fake SDK feed diverged")
            cases.append({"name": f"chunked/{label}/{scheme}", "input": {"chunks": chunks},
                          "expected": {"steps": steps, "final": final, "text": text}})
    return cases


# ─── m3_claude_reason ──────────────────────────────────────────────────────────

def _reason_groups(J):
    """The keyword tuples in _claude_reason, in source order."""
    groups = [c for c in J._claude_reason.__code__.co_consts
              if isinstance(c, tuple) and c and all(isinstance(k, str) for k in c)]
    if not groups:
        raise RuntimeError("no keyword tuples found in _claude_reason")
    return groups


@suite("m3_claude_reason")
def claude_reason(ctx):
    J = ctx.J
    groups = _reason_groups(J)
    msgs = []
    for g, keys in enumerate(groups):
        for k in keys:
            msgs += [(f"kw/{g}/{k}", k),
                     (f"kw_upper/{g}/{k}", f"Error: {k.upper()} occurred"),
                     (f"kw_embedded/{g}/{k}", f"xx{k}yy")]
    for i in range(len(groups)):
        for j in range(len(groups)):
            if i != j:
                msgs.append((f"collide/{i}_{j}", f"{groups[j][0]} and then {groups[i][-1]}"))
    msgs += [("empty", ""), ("spaces", "   "), ("newline", "\n"), ("tab_nl", "\t\n "),
             ("unknown_short", "Something odd happened"),
             ("unknown_padded", "   Something odd happened  \n"),
             ("unknown_80", "u" * 80), ("unknown_81", "v" * 81),
             ("unknown_long", "  " + "Morgan saw an odd failure in the helper process; " * 3),
             ("unknown_long_astral", "\U0001F600 odd " * 30),
             ("unknown_long_combining", "é" * 60),
             ("trap_generate", "Could not generate a reply"),
             ("trap_accurate", "The answer was not accurate"),
             ("trap_moderate", "moderate load"),
             ("trap_cancelled", "Task was Cancelled by Sam"),
             ("trap_clinotfound", "CLINotFoundError: Claude Code not installed"),
             ("trap_enoent", "spawn claude ENOENT"),
             ("trap_http401", "HTTP 401 Unauthorized"),
             ("trap_14030", "error id 14030"),
             ("trap_overloaded", "Error code: 529 overloaded_error"),
             ("trap_refused", "Connection refused"),
             ("trap_resolve", "getaddrinfo failed: could not resolve host"),
             ("trap_unreachable", "Network is unreachable"),
             ("trap_timed_out", "Request timed out after 45000 ms"),
             ("trap_timeouterror", "TimeoutError"),
             ("trap_credit", "Your credit balance is too low"),
             ("trap_login", "Invalid API key. Please run /login"),
             ("trap_exit1", "Command failed with exit code 1"),
             ("lower_dotted_i", "İnsufficient funds for Robin"),
             ("lower_fullwidth", "ＲＡＴＥ exceeded"),
             ("lower_sharp_s", "STRAßE closed"),
             ("lower_kelvin", "KK status")]
    cases = []
    for name, msg in msgs:
        cases.append({"name": name, "input": {"message": msg},
                      "expected": {"reason": J._claude_reason(Exception(msg))}})
    return cases


# ─── m3_backend_key ────────────────────────────────────────────────────────────

@suite("m3_backend_key")
def backend_key(ctx):
    J = ctx.J
    names = ["claude", "claude (partial)", "claude (claude-opus-5-5)", "local (qwen2.5:3b)",
             "local (apple-foundation-model)",
             "Claude (Opus 5.5)", "local (llama3.2 über-modèle)", "__x__ -- y"]
    bumped = []
    saved = (J.research_bump, J.log, dict(J.LAST_BACKEND))
    J.research_bump = lambda key, *a, **kw: bumped.append(key)
    J.log = lambda *a, **kw: None
    cases = []
    try:
        for name in names:
            bumped.clear()
            J._set_backend(name)
            if len(bumped) != 1:
                raise RuntimeError(f"_set_backend({name!r}) bumped {bumped!r}")
            cases.append({"name": name, "input": {"name": name},
                          "expected": {"key": bumped[0]}})
    finally:
        J.research_bump, J.log = saved[0], saved[1]
        J.LAST_BACKEND.clear()
        J.LAST_BACKEND.update(saved[2])
    return cases


# ─── m3_history_preamble ───────────────────────────────────────────────────────

_MISSING = object()


def _turn(role, content):
    return {"role": role} if content is _MISSING else {"role": role, "content": content}


def _history(n, content_for, role_for=None):
    """n turns ending with the just-appended user turn (n <= 12); 13 ends with an assistant."""
    turns = []
    for i in range(n):
        back = n - 1 - i                             # 0 = the last turn
        role = role_for(i) if role_for else ("user" if back % 2 == 0 else "assistant")
        turns.append(_turn(role, content_for(i)))
    if n == 13:
        turns[-1] = {"role": "assistant", "content": f"{_NAMES[0]} got the last word."}
    return turns


@suite("m3_history_preamble")
def history_preamble(ctx):
    J = ctx.J
    gaps = ["", "   ", None, _MISSING, "\n\t"]
    shapes = [
        ("alt", lambda i: f"{_NAMES[i % 3]} turn {i}", None),
        ("padded", lambda i: f"  {_NAMES[i % 3]} said:\n  line two {i}\t ", None),
        ("gaps", lambda i: gaps[i // 3 % len(gaps)] if i % 3 == 1 else f"{_NAMES[i % 3]} {i}",
         None),
        ("all_user", lambda i: f"{_NAMES[i % 3]} asks {i}", lambda i: "user"),
        ("all_assistant", lambda i: f"reply {i}", lambda i: "assistant"),
    ]
    hists = []
    for label, content_for, role_for in shapes:
        for n in range(14):
            hists.append((f"{label}/{n}", _history(n, content_for, role_for)))
    hists += [
        ("all_empty/7", _history(7, lambda i: "")),
        ("all_none/4", _history(4, lambda i: None)),
        ("all_missing/5", _history(5, lambda i: _MISSING)),
        ("only_last_nonempty/8", _history(8, lambda i: "last" if i == 7 else "")),
        ("only_first_nonempty/8", _history(8, lambda i: "first" if i == 0 else "")),
        ("only_window_start/8", _history(8, lambda i: "second" if i == 1 else "")),
        ("unicode_ws/6", _history(6, lambda i: f" {_NAMES[i % 3]} \x85")),
        ("inner_blank_lines/3", _history(3, lambda i: f"{_NAMES[i]}\n\n\nend")),
    ]
    cases = []
    for name, turns in hists:
        if len(turns) == 13 and not (turns[-1]["role"] == "assistant"
                                     and isinstance(turns[-1].get("content"), str)):
            raise RuntimeError(f"{name}: a 13-turn history must end with an assistant string")
        ctx.reset()
        J._history = [dict(t) for t in turns]
        cases.append({"name": name, "input": {"history": turns},
                      "expected": {"preamble": J._claude_history_preamble()}})
    ctx.reset()
    return cases


# ─── m3_claude_env_path ────────────────────────────────────────────────────────

@suite("m3_claude_env_path")
def claude_env_path(ctx):
    J = ctx.J
    home = os.path.expanduser("~")
    parents = [("unset", None), ("empty", ""),
               ("system", "/usr/bin:/bin:/usr/sbin:/sbin"),
               ("has_local_bin", f"{home}/.local/bin:/usr/bin:/bin"),
               ("homebrew_twice", "/opt/homebrew/bin:/usr/bin:/opt/homebrew/bin:/bin"),
               ("trailing_colon", "/usr/bin:/bin:")]
    saved = os.environ.get("PATH")
    cases = []
    try:
        for name, value in parents:
            if value is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = value
            cases.append({"name": name, "input": {"PATH": value, "HOME": home},
                          "expected": {"PATH": J._claude_env()["PATH"]}})
    finally:
        if saved is None:
            os.environ.pop("PATH", None)
        else:
            os.environ["PATH"] = saved
    return cases


# ─── m3_claude_config_* ────────────────────────────────────────────────────────
# The CLAUDE_* constants are read at import, so each environment is its own suite; the child
# starts from a clean env plus the suite's JARVIS_* overrides.

_CONFIG_KEYS = ("JARVIS_USE_CLAUDE", "JARVIS_CLAUDE_MODEL", "JARVIS_CLAUDE_EFFORT",
                "JARVIS_CLAUDE_MAX_TURNS", "JARVIS_CLAUDE_TIMEOUT_MS")


def _claude_config(ctx):
    J = ctx.J
    env = {k: os.environ[k] for k in _CONFIG_KEYS if k in os.environ}
    return [{"name": "config", "input": {"env": env},
             "expected": {"enabled": J.CLAUDE_ENABLED, "model": J.CLAUDE_MODEL,
                          "effort": J.CLAUDE_EFFORT, "max_turns": J.CLAUDE_MAX_TURNS,
                          "timeout_ms": J.CLAUDE_TIMEOUT_MS}}]


suite("m3_claude_config_default")(_claude_config)
suite("m3_claude_config_set", env={
    "JARVIS_USE_CLAUDE": "0", "JARVIS_CLAUDE_MODEL": "  claude-sonnet-test \n",
    "JARVIS_CLAUDE_EFFORT": " high ", "JARVIS_CLAUDE_MAX_TURNS": " 9 ",
    "JARVIS_CLAUDE_TIMEOUT_MS": " 30000 "})(_claude_config)
suite("m3_claude_config_blank", env={
    "JARVIS_USE_CLAUDE": "", "JARVIS_CLAUDE_MODEL": "   ", "JARVIS_CLAUDE_EFFORT": "\t ",
    "JARVIS_CLAUDE_MAX_TURNS": "", "JARVIS_CLAUDE_TIMEOUT_MS": ""})(_claude_config)
suite("m3_claude_config_other", env={
    "JARVIS_USE_CLAUDE": "false", "JARVIS_CLAUDE_MODEL": "claude-opus-5-5",
    "JARVIS_CLAUDE_EFFORT": "max", "JARVIS_CLAUDE_MAX_TURNS": "+12"})(_claude_config)
