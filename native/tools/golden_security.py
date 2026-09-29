"""M2 golden suites for the Python command guard: m2_shell, m2_applescript, m2_file_tiers,
m2_taint (M02 plan §2.1, §2.2, §4; task T2.1).

Plugin for tools/golden.py (it imports every tools/golden_*.py). Python is the oracle: every
expected value comes from calling jarvis.py's own guard functions, except the refusal strings
that live inside closures and loops, which are read from jarvis.py's own AST.

Inputs follow the M2 rules and nothing else:
  (a) a short hand list of ordinary everyday commands and AppleScripts (_EVERYDAY_*);
  (b) strings that already appear in the sources, extracted mechanically, never retyped:
      every str literal in jarvis.py (ast), and every inline code span and fenced-block line
      in native/plan/M02-M04-security-brain-chat.md (re);
  (c) every Cmnd_Alias rule in native/ops/jarvis.sudoers, prefixed with "sudo " as written.
Extracted strings containing "/Users/" are dropped (they would carry a home path).

Nothing is executed. Every suite first proves the harness's audit-hook guard is live by
firing the audit events directly (sys.audit runs the hooks and nothing else): a process
spawn and a write outside the sandbox must both be refused. m2_file_tiers additionally stubs
the gate and every write, and asserts the sandbox tree is byte-for-byte unchanged.

m2_shell        input -> _shell_risk verdict ("ok" | "confirm" | "block").
m2_applescript  input -> _dangerous_applescript result.
m2_file_tiers   _write_file / _move_file / _delete_file over everyday in-home paths and the
                _PERSIST_FILES / _PERSIST_DIRS paths, in two views of the same sandbox tree:
                "sandbox" (HOME is the harness sandbox itself, which lives under /private/var,
                so _is_system_path is true for all of it) and "home" (the same tree seen
                through a virtual home, _VIEW_HOME, that is not under any _SYS_ROOTS entry;
                jarvis's os.path is swapped for a view that maps it onto the sandbox).
                expected: decision "instant" (a stubbed write/move/trash was reached
                directly), "confirm" (the gate was called; "gate" is its description) or
                "none" (returned before acting; "reply" is that refusal or not-found string).
                "acts" lists what the instant branch would have done. Replies of instant and
                confirm cases come from the stubs, so they are recorded as null.
m2_taint        UNTRUSTED_TOOLS, EXECUTOR_TOOLS, each tool's membership, and the exact refusal
                strings (injection guard x2, run_command x2, run_applescript, PowerShell).
"""
import ast
import builtins
import contextlib
import hashlib
import os
import posixpath
import re
import sys
from pathlib import Path

from golden import suite

# ─── Inputs (a): ordinary everyday commands and scripts. The only hand-typed inputs. ───

_EVERYDAY_SHELL = [
    "open -a Safari",
    "open -a Music",
    "open -a Calendar",
    "open -a Notes",
    "open ~/Downloads",
    "ls",
    "ls -la",
    "ls ~/Documents",
    "ls -la ~/Desktop",
    "pwd",
    "git status",
    "git log --oneline -5",
    "git diff --stat",
    "git branch",
    "date",
    "date +%A",
    "cal",
    "uptime",
    "pmset -g batt",
    "df -h",
    "df -h /",
    "du -sh ~/Downloads",
    "cat ~/Documents/notes.txt",
    "head -n 20 ~/Documents/notes.txt",
    "echo hello",
    "sw_vers",
]

_EVERYDAY_APPLESCRIPT = [
    'tell application "System Events" to get name of first application process whose frontmost is true',
    "set volume output volume 50",
    "set volume output volume 20",
    "output volume of (get volume settings)",
    "set volume with output muted",
    'tell application "Safari" to activate',
    'tell application "Music" to play',
    'tell application "Music" to pause',
]

_PLAN = "native/plan/M02-M04-security-brain-chat.md"
_SUDOERS = "native/ops/jarvis.sudoers"


# ─── Guard probe ────────────────────────────────────────────────────────────────

def _assert_guard_live(where):
    """The harness's audit hook must refuse a spawn and an outside write. sys.audit only runs
    the hooks, so nothing is spawned or opened even if the guard were missing."""
    probes = (("subprocess.Popen", ("/usr/bin/true", ["/usr/bin/true"], None, None)),
              ("open", ("/" + "golden-guard-probe-never-created", "w", 0)))
    for event, args in probes:
        try:
            sys.audit(event, *args)
        except PermissionError as e:
            if "golden sandbox" in str(e):
                continue
            raise
        raise RuntimeError(f"{where}: write/process guard is not active ({event} allowed)")


# ─── Inputs (b) and (c): extracted from the sources ─────────────────────────────

def _repo(J):
    return Path(J.__file__).resolve().parent


def _jarvis_literals(J):
    """Every str literal in jarvis.py, in source order (f-string fragments excluded)."""
    tree = ast.parse(Path(J.__file__).read_text(encoding="utf-8"))
    inner = {id(v) for n in ast.walk(tree) if isinstance(n, ast.JoinedStr) for v in n.values}
    nodes = [n for n in ast.walk(tree)
             if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in inner]
    nodes.sort(key=lambda n: (n.lineno, n.col_offset))
    return [n.value for n in nodes]


_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")


def _plan_strings(J):
    """(inline code spans, fenced-block lines) of the M2 plan, in document order."""
    spans, lines, fence = [], [], None
    for line in (_repo(J) / _PLAN).read_text(encoding="utf-8").split("\n"):
        m = re.match(r"^\s*(`{3,})", line)
        if fence is None and m:
            fence = m.group(1)
            continue
        if fence is not None:
            if line.strip().startswith(fence) and not line.strip().strip("`"):
                fence = None
            elif line.strip():
                lines.append(line)
            continue
        for m in _SPAN.finditer(line):
            body = m.group(2)
            if len(body) > 1 and body[0] == " " and body[-1] == " " and body.strip():
                body = body[1:-1]                 # CommonMark: one space pair is padding
            spans.append(body)
    return spans, lines


def _sudoers_rules(J):
    """Each Cmnd_Alias entry of jarvis.sudoers, as written, prefixed with 'sudo '."""
    rules, inside = [], False
    for line in (_repo(J) / _SUDOERS).read_text(encoding="utf-8").split("\n"):
        s = line.strip()
        if not inside:
            if s.startswith("Cmnd_Alias") and "=" in s:
                inside = s.endswith("\\")
                rest = s.split("=", 1)[1].rstrip("\\").strip().rstrip(",").strip()
                if rest:
                    rules.append(rest)
            continue
        if s.startswith("#") or not s:
            continue
        more = s.endswith("\\")
        entry = s.rstrip("\\").strip().rstrip(",").strip()
        if entry:
            rules.append(entry)
        inside = more
    if not rules:
        raise RuntimeError(f"{_SUDOERS}: no Cmnd_Alias rules found")
    return ["sudo " + r for r in rules]


def _corpus(J):
    """[(source, text)], deduplicated, first source wins. Text None is the one edge input."""
    spans, lines = _plan_strings(J)
    groups = [("everyday_shell", _EVERYDAY_SHELL), ("everyday_applescript", _EVERYDAY_APPLESCRIPT),
              ("sudoers", _sudoers_rules(J)), ("jarvis_py", _jarvis_literals(J)),
              ("plan_span", spans), ("plan_block", lines)]
    seen, out = set(), [("edge", None)]
    for src, items in groups:
        for s in items:
            if s in seen or (src not in ("everyday_shell", "everyday_applescript")
                             and "/Users/" in s):
                continue
            seen.add(s)
            out.append((src, s))
    return out


def _named(corpus):
    counts, out = {}, []
    for src, s in corpus:
        i = counts.get(src, 0)
        counts[src] = i + 1
        out.append((f"{src}/{i:04d}", src, s))
    return out


# ─── m2_shell / m2_applescript ──────────────────────────────────────────────────

@suite("m2_shell")
def shell_suite(ctx):
    J = ctx.J
    _assert_guard_live("m2_shell")
    cases = [{"name": name, "input": {"cmd": s, "source": src},
              "expected": {"risk": J._shell_risk(s)}}
             for name, src, s in _named(_corpus(J))]
    _assert_guard_live("m2_shell")
    return cases


@suite("m2_applescript")
def applescript_suite(ctx):
    J = ctx.J
    _assert_guard_live("m2_applescript")
    cases = [{"name": name, "input": {"script": s, "source": src},
              "expected": {"dangerous": J._dangerous_applescript(s)}}
             for name, src, s in _named(_corpus(J))]
    _assert_guard_live("m2_applescript")
    return cases


# ─── m2_file_tiers ──────────────────────────────────────────────────────────────

_VIEW_HOME = "/jarvis-golden-home"       # absent on disk; not under any _SYS_ROOTS entry
_GATED = "(gate stub: action stashed, not run)"
_EVERYDAY_FILES = ("Documents/notes.txt", "Desktop/todo.txt", "Downloads/report.pdf")
_EVERYDAY_DIRS = ("Documents", "Desktop", "Downloads", "Pictures")
_MISSING_FILE = "Documents/ideas.txt"   # an everyday path that does not exist


class _Rec:
    def __init__(self):
        self.gate, self.acts = [], []


class _FakeFile:
    def __init__(self, rec):
        self.rec = rec

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def write(self, s):
        self.rec.acts.append(["write", s])
        return len(s)


class _OsView:
    """Stands in for jarvis's `os`: reads pass through, every mutation is recorded only."""

    def __init__(self, path, rec):
        self.path, self._rec = path, rec

    def __getattr__(self, n):
        return getattr(os, n)

    def _record(self, op):
        def stub(*args, **kw):
            self._rec.acts.append([op, *[os.fspath(a) for a in args]])
        return stub

    makedirs = property(lambda self: self._record("makedirs"))
    mkdir = property(lambda self: self._record("mkdir"))
    remove = property(lambda self: self._record("remove"))
    unlink = property(lambda self: self._record("unlink"))
    rmdir = property(lambda self: self._record("rmdir"))
    rename = property(lambda self: self._record("rename"))
    replace = property(lambda self: self._record("replace"))


class _ShutilView:
    def __init__(self, rec):
        self._rec = rec

    def move(self, s, d):
        self._rec.acts.append(["move", os.fspath(s), os.fspath(d)])

    def rmtree(self, p, *a, **k):
        self._rec.acts.append(["rmtree", os.fspath(p)])

    def __getattr__(self, n):
        raise AttributeError(f"shutil.{n} is not stubbed for m2_file_tiers")


class _HomeView:
    """os.path for the "home" view: _VIEW_HOME is the sandbox, seen under another name.
    exists / isdir / realpath answer from the real sandbox tree; everything else is posixpath."""

    def __init__(self, sandbox):
        self.sb = sandbox

    def __getattr__(self, n):
        return getattr(posixpath, n)

    def _real(self, p):
        p = os.fspath(p)
        if p == _VIEW_HOME or p.startswith(_VIEW_HOME + "/"):
            return self.sb + p[len(_VIEW_HOME):]
        return p

    def _virtual(self, p):
        if p == self.sb or p.startswith(self.sb + "/"):
            return _VIEW_HOME + p[len(self.sb):]
        return p

    def exists(self, p):
        return os.path.exists(self._real(p))

    def isdir(self, p):
        return os.path.isdir(self._real(p))

    def realpath(self, p, **kw):
        return self._virtual(os.path.realpath(self._real(p), **kw))

    def expanduser(self, p):
        p = os.fspath(p)
        return _VIEW_HOME + p[1:] if p == "~" or p.startswith("~/") else p


@contextlib.contextmanager
def _patched(J, **attrs):
    missing = object()
    saved = {k: J.__dict__.get(k, missing) for k in attrs}
    for k, v in attrs.items():
        setattr(J, k, v)
    try:
        yield
    finally:
        for k, v in saved.items():
            if v is missing:
                delattr(J, k)
            else:
                setattr(J, k, v)


def _tree_snapshot(root):
    snap = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for n in [*dirnames, *sorted(filenames)]:
            p = os.path.join(dirpath, n)
            st = os.lstat(p)
            if os.path.isdir(p) and not os.path.islink(p):
                snap[p] = ("dir", st.st_mtime_ns)
            else:
                with open(p, "rb") as f:
                    snap[p] = (st.st_size, st.st_mtime_ns, hashlib.sha256(f.read()).hexdigest())
        snap[dirpath] = ("dir", os.lstat(dirpath).st_mtime_ns)
    return snap


def _build_tree(J, sb):
    """Create the everyday files and the persistence targets inside the sandbox (setup)."""
    made = []
    for d in (*_EVERYDAY_DIRS, *J._PERSIST_DIRS):
        os.makedirs(os.path.join(sb, d), exist_ok=True)
        made.append(d + "/")
    for f in (*_EVERYDAY_FILES, *J._PERSIST_FILES):
        with open(os.path.join(sb, f), "w", encoding="utf-8"):
            pass
        made.append(f)
    return sorted(made)


def _tier_calls(J):
    """[(case tail, fn name, args)] for one view. Paths are what a tool call would pass."""
    tilde = lambda rel: "~/" + rel
    everyday = [tilde(p) for p in (*_EVERYDAY_FILES, *_EVERYDAY_DIRS, _MISSING_FILE)]
    persist = [tilde(p) for p in (*J._PERSIST_FILES, *J._PERSIST_DIRS)]
    inside = [tilde(os.path.join(d, os.path.basename(_EVERYDAY_FILES[0])))
              for d in J._PERSIST_DIRS]       # the everyday file name, inside each persist dir
    paths = [*everyday, "~", "", *persist, *inside]
    src = tilde(_EVERYDAY_FILES[0])
    calls = []
    for p in paths:
        calls.append(("_write_file", [p, ""]))
    for p in paths:
        calls.append(("_delete_file", [p, False]))
        calls.append(("_delete_file", [p, True]))
    for d in [tilde("Desktop"), tilde(_EVERYDAY_FILES[1]), tilde(_MISSING_FILE), "~",
              *persist, *inside]:
        calls.append(("_move_file", [src, d]))
    for s in persist:
        calls.append(("_move_file", [s, tilde("Documents")]))
    calls.append(("_move_file", [tilde(_MISSING_FILE), tilde("Desktop")]))
    calls.append(("_move_file", ["", tilde("Desktop")]))
    calls.append(("_move_file", ["~", tilde("Documents")]))
    return calls


def _run_view(J, view, sb, tree):
    home = _VIEW_HOME if view == "home" else sb
    cases = []
    saved_written = set(J._written_this_session)
    before = _tree_snapshot(sb)
    try:
        for i, (fn, args) in enumerate(_tier_calls(J)):
            rec = _Rec()

            def gate(desc, _fn, rec=rec):
                rec.gate.append(desc)
                return _GATED

            def to_trash(path, rec=rec):
                rec.acts.append(["trash", os.fspath(path)])
                return True

            def fake_open(path, mode="r", *a, rec=rec, **k):
                rec.acts.append(["open", os.fspath(path), mode])
                return _FakeFile(rec)

            path_mod = _HomeView(sb) if view == "home" else posixpath
            J._written_this_session.clear()
            with _patched(J, os=_OsView(path_mod, rec), shutil=_ShutilView(rec), open=fake_open,
                          _gate=gate, _to_trash=to_trash, _HOME=home, log=lambda *a, **k: None):
                reply = getattr(J, fn)(*args)
            if rec.gate and rec.acts:
                raise RuntimeError(f"{fn}{args}: both gated and acted")
            if "golden sandbox" in str(reply):
                raise RuntimeError(f"{fn}{args}: an unstubbed write reached the guard")
            decision = "confirm" if rec.gate else "instant" if rec.acts else "none"
            cases.append({
                "name": f"{view}/{i:03d}/{fn}",
                "input": {"view": view, "home": home, "fn": fn, "args": args, "tree": tree},
                "expected": {"decision": decision,
                             "reply": reply if decision == "none" else None,
                             "gate": rec.gate[0] if rec.gate else None, "acts": rec.acts}})
    finally:
        J._written_this_session.clear()
        J._written_this_session.update(saved_written)
    after = _tree_snapshot(sb)
    if after != before:
        changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
        raise RuntimeError(f"m2_file_tiers ({view}): sandbox changed: {changed[:10]}")
    return cases


@suite("m2_file_tiers")
def file_tiers_suite(ctx):
    J, sb = ctx.J, os.path.realpath(str(ctx.sandbox))
    _assert_guard_live("m2_file_tiers")
    if J._HOME != sb or os.path.expanduser("~") != sb:
        raise RuntimeError("m2_file_tiers: HOME is not the harness sandbox")
    if any(_VIEW_HOME == r or _VIEW_HOME.startswith(r + os.sep) for r in J._SYS_ROOTS) \
            or os.path.lexists(_VIEW_HOME):
        raise RuntimeError("m2_file_tiers: _VIEW_HOME must be absent and outside _SYS_ROOTS")
    tree = _build_tree(J, sb)
    cases = _run_view(J, "sandbox", sb, tree) + _run_view(J, "home", sb, tree)
    if J._HOME != sb or J.os is not os or J.shutil.__name__ != "shutil" or "open" in J.__dict__:
        raise RuntimeError("m2_file_tiers: a stub was not restored")
    _assert_guard_live("m2_file_tiers")
    return cases


# ─── m2_taint ───────────────────────────────────────────────────────────────────

def _func(tree, name):
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == name:
            return n
    raise RuntimeError(f"jarvis.py: no function {name}")


def _if_body(fn_node, test_src):
    """The statements of the `if <test_src>:` inside fn_node."""
    for n in ast.walk(fn_node):
        if isinstance(n, ast.If) and ast.unparse(n.test) == test_src:
            return n.body
    raise RuntimeError(f"jarvis.py {fn_node.name}: no `if {test_src}:`")


def _strs(body, kind):
    """Str constants in body, in source order: Return values, Assign values, or the value of
    a dict's "text" key."""
    found = []
    for n in (m for s in body for m in ast.walk(s)):
        if kind == "return" and isinstance(n, ast.Return):
            found.append(n.value)
        elif kind == "assign" and isinstance(n, ast.Assign):
            found.append(n.value)
        elif kind == "dict_text" and isinstance(n, ast.Dict):
            found += [v for k, v in zip(n.keys, n.values)
                      if isinstance(k, ast.Constant) and k.value == "text"]
    found = [c for c in found if isinstance(c, ast.Constant) and isinstance(c.value, str)]
    return [c.value for c in sorted(found, key=lambda c: (c.lineno, c.col_offset))]


def _refusals(J):
    tree = ast.parse(Path(J.__file__).read_text(encoding="utf-8"))
    site = lambda fn, test, kind: _strs(_if_body(_func(tree, fn), test), kind)
    rc = site("_run_command", "risk == 'block'", "return")
    got = {
        "run_command": rc,
        "injection/claude": site("_build_claude_server",
                                 "tool_name in EXECUTOR_TOOLS and _claude_taint['tainted']",
                                 "dict_text"),
        "injection/local": site("process_command", "name in EXECUTORS and tainted", "assign"),
        "run_applescript/block": site("execute_tool", "_dangerous_applescript(s)", "return"),
        "run_powershell/block": site("_run_powershell_tool", "_dangerous_shell(script)",
                                     "return"),
    }
    for k, v in got.items():
        if len(v) != (2 if k == "run_command" else 1):
            raise RuntimeError(f"jarvis.py refusal site {k}: found {len(v)} strings")
    return {"run_command/sudo": rc[0], "run_command/block": rc[1],
            **{k: v[0] for k, v in got.items() if k != "run_command"}}


@suite("m2_taint")
def taint_suite(ctx):
    J = ctx.J
    _assert_guard_live("m2_taint")
    untrusted, executor = set(J.UNTRUSTED_TOOLS), set(J.EXECUTOR_TOOLS)
    cases = [
        {"name": "sets/untrusted", "input": {"set": "UNTRUSTED_TOOLS"},
         "expected": {"members": sorted(untrusted)}},
        {"name": "sets/executor", "input": {"set": "EXECUTOR_TOOLS"},
         "expected": {"members": sorted(executor)}},
    ]
    names = [t["function"]["name"] for t in J.TOOLS]
    names += sorted((untrusted | executor) - set(names))
    for n in names:
        cases.append({"name": f"tool/{n}", "input": {"tool": n},
                      "expected": {"untrusted": n in untrusted, "executor": n in executor}})

    refusals = _refusals(J)
    for site, text in refusals.items():
        cases.append({"name": f"refusal/{site}", "input": {"site": site, "how": "source"},
                      "expected": {"text": text}})

    # Runtime cross-checks where the refusal is reachable with every side effect stubbed:
    # the first corpus input of each kind, run through the real function.
    def never(*a, **k):
        raise RuntimeError("m2_taint: an executor stub was reached")

    corpus = [s for _, s in _corpus(J) if isinstance(s, str)]
    sudo_block = next((s for s in corpus if J._shell_risk(s) == "block"
                       and re.search(r"\bsudo\b", s)), None)
    plain_block = next((s for s in corpus if J._shell_risk(s) == "block"
                        and not re.search(r"\bsudo\b", s)), None)
    as_block = next((s for s in _EVERYDAY_APPLESCRIPT if J._dangerous_applescript(s)), None)
    with _patched(J, _exec_shell=never, _gate=never, _run_applescript=never,
                  log=lambda *a, **k: None):
        for site, cmd in (("run_command/sudo", sudo_block), ("run_command/block", plain_block)):
            if cmd is None:
                continue
            reply = J._run_command(cmd)
            if reply != refusals[site]:
                raise RuntimeError(f"m2_taint: runtime {site} differs from the source string")
            cases.append({"name": f"runtime/{site}", "input": {"site": site, "cmd": cmd},
                          "expected": {"text": reply}})
        if as_block is not None:
            reply = J.execute_tool("run_applescript", {"script": as_block})
            if reply != refusals["run_applescript/block"]:
                raise RuntimeError("m2_taint: runtime run_applescript refusal differs")
            cases.append({"name": "runtime/run_applescript/block",
                          "input": {"site": "run_applescript/block", "script": as_block},
                          "expected": {"text": reply}})
    _assert_guard_live("m2_taint")
    return cases
