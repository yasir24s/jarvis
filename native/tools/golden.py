#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Golden-fixture oracle harness for Native JARVIS (plan: native/plan/M00 §3.7).

Python jarvis.py is the oracle. Each suite imports the real module in a fresh child
interpreter, with every state constant pointed into a throwaway sandbox, and runs fixed
inputs under a frozen clock. The parent writes the results as JSON fixtures that the Swift
tests must reproduce exactly.

    golden.py list                         suites and their fixture paths
    golden.py <suite> [<suite> ...] | all  (re)generate fixtures
    golden.py --check                      exit 1 if any fixture's jarvis_py_sha256 != jarvis.py
    golden.py selftest                     harness self-check (sandbox, clock, tripwire); writes nothing
    golden.py readback <dir> <suite>       load files Swift wrote into <dir> with Python's own loaders
    flags: --allow-dirty, --out <dir> (default native/Tests/Fixtures/golden)

Registering a suite: put a module named golden_<anything>.py next to this file (M1 uses
golden_m1.py). Both the parent and every child import it, so it must not import jarvis:

    from golden import suite

    @suite("m1_kb", fixture="m1_kb.json", tz="UTC", epoch=1790582400)
    def kb(ctx):                          # ctx.J is jarvis, already sandboxed
        ctx.reset()                       # per-case: _history = [], _corr_cache = None
        ctx.at(1790582400)                # move the frozen clock
        return [{"name": "...", "input": {...}, "expected": {...}}]

Exit codes: 1 check/suite failure, 2 wrong interpreter or unsafe sandbox, 3 real state touched.
"""
import sys

_FRAMEWORK = "/Library/Frameworks/Python.framework/"
_INTERPRETER = _FRAMEWORK + "Versions/3.14/bin/python3"
if sys.version_info[:2] != (3, 14) or not sys.executable.startswith(_FRAMEWORK):
    sys.stderr.write(f"golden.py: needs Python 3.14 from {_FRAMEWORK} (it has JARVIS's deps); "
                     f"run {_INTERPRETER} (this is {sys.executable}, "
                     f"{sys.version.split()[0]})\n")
    sys.exit(2)

sys.dont_write_bytecode = True            # importing jarvis must not write the repo's __pycache__
sys.modules.setdefault("golden", sys.modules[__name__])   # plugins share this registry

import ast
import datetime as _dt
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import threading
import time as _time
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).resolve()
TOOLS_DIR = SCRIPT.parent
JARVIS_PY = REPO / "jarvis.py"
DEFAULT_OUT = REPO / "native" / "Tests" / "Fixtures" / "golden"
GENERATOR = "native/tools/golden.py"
SCHEMA = 1
DEFAULT_EPOCH = 1790582400
DEFAULT_TZ = "Europe/London"
CHILD_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
HOME_LEAK = re.compile(r"/Users/[A-Za-z0-9._-]+/")
RESULT_NAME = ".golden-result.json"

# Every jarvis.py constant naming a state path, and where it lives inside the sandbox.
# The key set is asserted against dir(jarvis) on every run, so a new *_FILE / RESEARCH_*
# constant fails the harness instead of writing real state.
STATE_CONSTANTS = {
    "LOG_FILE": "logs/jarvis.log",
    "KB_FILE": "knowledge.json",
    "HIST_FILE": "history.json",
    "CORR_FILE": "corrections.json",
    "CHANGELOG_FILE": "CHANGELOG.md",
    "PROFILE_FILE": "profile.json",
    "PERSONALITY_FILE": "personality.json",
    "EMOTIONS_FILE": "emotions.json",
    "PROACTIVE_FILE": "proactive.json",
    "ALARMS_FILE": "alarms.json",
    "VOICEPRINT_FILE": "voiceprint.npy",
    "RESEARCH_DIR": "research",
    "RESEARCH_METRICS": "research/metrics.jsonl",
    "RESEARCH_USAGE": "research/usage.json",
}
# Runtime paths built inline as os.path.join(HERE, "<name>") inside functions.
LITERAL_FILES = ("jarvis_notes.txt", "audd_key.txt")
# Real files the tripwire watches besides *.json, research/ and logs/.
_TRIPWIRE_EXTRA = ("CHANGELOG.md", "voiceprint.npy", "jarvis_notes.txt", "audd_key.txt",
                   ".jarvis.lock")
_NO_HASH = {"audd_key.txt"}               # secret: stat it, never read it
_RESERVED = {"all", "list", "selftest", "readback"}


# ─── Registry ───────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Suite:
    name: str
    run: object                           # callable(ctx) -> list of {"name", "input", "expected"}
    fixture: str                          # file name inside --out
    tz: str
    epoch: float
    env: tuple                            # sorted (JARVIS_*, value) pairs for the child env
    readback: object                      # callable(ctx, Path) -> list of mismatch strings, or None
    source: str                           # module that registered it


SUITES = {}


def suite(name, *, fixture=None, tz=DEFAULT_TZ, epoch=DEFAULT_EPOCH, env=None, readback=None):
    """Decorator: register `fn(ctx) -> cases` as a golden suite.

    fixture   file name in --out (default "<name>.golden.json")
    tz        TZ for the child interpreter (time.tzset() runs before import jarvis)
    epoch     where the frozen clock starts; ctx.at(e) moves it per case
    env       extra child env, JARVIS_* names only (for suites about env parsing)
    readback  fn(ctx, dir) -> [mismatch, ...] for `golden.py readback <dir> <name>`
    """
    if not re.fullmatch(r"[a-z0-9_]+", name) or name in _RESERVED:
        raise ValueError(f"bad suite name {name!r}")
    fixture = fixture or f"{name}.golden.json"
    if "/" in fixture or not fixture.endswith(".json"):
        raise ValueError(f"suite {name}: fixture must be a bare *.json file name")
    env = dict(env or {})
    bad = [k for k in env if not k.startswith("JARVIS_")]
    if bad:
        raise ValueError(f"suite {name}: env overrides must be JARVIS_* (got {bad})")

    def deco(fn):
        if name in SUITES:
            raise ValueError(f"suite {name!r} registered twice ({SUITES[name].source}, "
                             f"{fn.__module__})")
        SUITES[name] = Suite(name, fn, fixture, tz, float(epoch), tuple(sorted(env.items())),
                             readback, "golden" if fn.__module__ == "__main__" else fn.__module__)
        return fn
    return deco


def _load_plugins():
    for path in sorted(TOOLS_DIR.glob("golden_*.py")):
        if path.stem in sys.modules:
            continue
        spec = importlib.util.spec_from_file_location(path.stem, path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[path.stem] = mod
        spec.loader.exec_module(mod)


# ─── Deterministic clock (installed in the child before suite code) ─────────────

SHIM = None


class ShimTime:                           # jarvis.time = ShimTime(epoch)
    def __init__(self, epoch): self.now = float(epoch)
    def time(self): return self.now
    def sleep(self, s): self.now += max(0.0, float(s))      # never really sleeps
    def localtime(self, t=None): return _time.localtime(self.now if t is None else t)
    def strftime(self, fmt, t=None):
        return _time.strftime(fmt, t if t is not None else _time.localtime(self.now))
    def monotonic(self): return self.now
    def __getattr__(self, n): return getattr(_time, n)     # everything else passes through


class FrozenDateTime(_dt.datetime):       # jarvis.datetime = FrozenDateTime
    @classmethod
    def now(cls, tz=None): return cls.fromtimestamp(SHIM.now, tz)


class Ctx:
    """What a suite receives. `original` holds jarvis's import-time HERE and state
    constants (plain strings, captured before sandboxing); nothing else is real."""

    def __init__(self, J, sandbox, clock, original, suite):
        self.J, self.sandbox, self.clock, self.original, self.suite = (
            J, sandbox, clock, original, suite)

    def reset(self):
        self.J._history = []
        self.J._corr_cache = None

    def at(self, epoch):
        self.clock.now = float(epoch)


# ─── Child: sandbox, guard, run one suite ───────────────────────────────────────

class HarnessError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def _under(path, root):
    return path == root or path.startswith(root + os.sep)


def _install_write_guard(sandbox):
    """Audit hook: after sandboxing, the child may write only inside the sandbox (plus
    /dev/null) and may not start processes. Defence in depth behind the constant swap."""
    root = os.path.realpath(sandbox)
    busy = threading.local()
    write_bits = os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_TRUNC
    path_events = {"os.rename": (0, 1), "os.remove": (0,), "os.rmdir": (0,), "os.mkdir": (0,),
                   "os.truncate": (0,), "os.chmod": (0,), "os.chown": (0,), "os.utime": (0,),
                   "os.chflags": (0,), "os.lchmod": (0,), "os.link": (1,), "os.symlink": (1,),
                   "shutil.rmtree": (0,), "shutil.copyfile": (1,), "shutil.copytree": (1,),
                   "shutil.move": (0, 1)}      # argument positions that get written
    spawn_events = {"subprocess.Popen", "os.system", "os.posix_spawn", "os.exec", "os.spawn",
                    "os.fork", "os.forkpty", "pty.spawn"}

    def allowed(p):
        if p is None or isinstance(p, int):
            return True                   # an already-open fd / default argument
        rp = os.path.realpath(os.fsdecode(p))
        return rp == "/dev/null" or _under(rp, root)

    def check(p, event):
        if not allowed(p):
            raise PermissionError(f"golden sandbox: {event} outside the sandbox: {p}")

    def hook(event, args):
        if getattr(busy, "on", False):
            return
        if event == "open":
            path, mode, flags = args
            writing = ((isinstance(mode, str) and any(c in mode for c in "wax+"))
                       or (isinstance(flags, int) and flags & write_bits))
            if not writing:
                return
            busy.on = True
            try:
                check(path, "write")
            finally:
                busy.on = False
        elif event in path_events:
            busy.on = True
            try:
                for i in path_events[event]:
                    check(args[i] if i < len(args) else None, event)
            finally:
                busy.on = False
        elif event in spawn_events:
            raise PermissionError(f"golden sandbox: suites must not start processes ({event})")

    sys.addaudithook(hook)


def _inline_here_joins(source):
    """Relative paths of os.path.join(HERE, "<lit>", ...) calls not assigned at module level."""
    tree = ast.parse(source)
    top = {id(n.value) for n in tree.body if isinstance(n, ast.Assign)}
    found = set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.Call) and id(node) not in top
                and ast.unparse(node.func) == "os.path.join" and node.args
                and isinstance(node.args[0], ast.Name) and node.args[0].id == "HERE"
                and all(isinstance(a, ast.Constant) and isinstance(a.value, str)
                        for a in node.args[1:])):
            found.add("/".join(a.value for a in node.args[1:]))
    return found


def _sandbox_jarvis(sandbox, epoch):
    """Import jarvis, verify its constant set, repoint all state into `sandbox`, install the
    clock and the write guard. Returns (J, clock, original). Nothing jarvis-defined runs
    between the import and the constant swap."""
    global SHIM
    sb = Path(sandbox)
    if os.environ.get("HOME") != str(sb):
        raise HarnessError(2, "child HOME is not the sandbox")
    _time.tzset()
    sys.path.insert(0, str(REPO))
    import jarvis as J

    found = sorted(n for n in dir(J) if n.endswith("_FILE") or n.startswith("RESEARCH_"))
    if found != sorted(STATE_CONSTANTS):
        raise HarnessError(2, f"jarvis.py state constants changed: jarvis has {found}, "
                              f"golden.py sandboxes {sorted(STATE_CONSTANTS)} -- add the new "
                              f"constant to STATE_CONSTANTS before running anything")
    original = {"HERE": J.HERE, **{n: getattr(J, n) for n in STATE_CONSTANTS}}

    (sb / "research").mkdir()
    (sb / "logs").mkdir()
    (sb / "tmp").mkdir()
    shutil.copy2(JARVIS_PY, sb / "jarvis.py")    # research_snapshot reads HERE/jarvis.py
    J.HERE = str(sb)
    J._HOME = str(sb)                            # _in_home() uses the import-time value
    for name, rel in STATE_CONSTANTS.items():
        setattr(J, name, str(sb / rel))
    J._history = []                              # import loaded the REAL history.json
    J._corr_cache = None
    tempfile.tempdir = str(sb / "tmp")

    for name, rel in STATE_CONSTANTS.items():
        have = os.path.relpath(original[name], original["HERE"])
        if have != rel:
            raise HarnessError(2, f"sandbox layout disagrees with jarvis.py: {name} is {have!r} "
                                  f"in jarvis.py, {rel!r} in golden.py")
        if not _under(getattr(J, name), str(sb)):
            raise HarnessError(2, f"{name} is not inside the sandbox")
    if os.path.expanduser("~") != str(sb) or J._HOME != str(sb) or J.HERE != str(sb):
        raise HarnessError(2, "HOME / _HOME / HERE not pointed at the sandbox")

    SHIM = ShimTime(epoch)
    J.time = SHIM
    J.datetime = FrozenDateTime
    _install_write_guard(sb)
    return J, SHIM, original


def _check_cases(name, cases):
    if not isinstance(cases, list) or not cases:
        raise HarnessError(1, f"suite {name} returned no cases")
    seen = set()
    for c in cases:
        if not isinstance(c, dict) or not {"name", "input", "expected"} <= set(c):
            raise HarnessError(1, f"suite {name}: case missing name/input/expected: {c!r:.200}")
        if not isinstance(c["name"], str) or c["name"] in seen:
            raise HarnessError(1, f"suite {name}: case name missing or duplicated: {c['name']!r}")
        seen.add(c["name"])


def _child_selftest(ctx):
    J, sb, epoch = ctx.J, str(ctx.sandbox), ctx.clock.now
    passed = []

    def ok(cond, what):
        if not cond:
            raise HarnessError(1, f"selftest FAILED: {what}")
        passed.append(what)

    ok(all(getattr(J, n) == os.path.join(sb, r) for n, r in STATE_CONSTANTS.items()),
       f"all {len(STATE_CONSTANTS)} state constants point into the sandbox")
    ok(J.HERE == sb and J._HOME == sb and os.path.expanduser("~") == sb,
       "HERE, _HOME and HOME are the sandbox")
    ok(J._history == [] and J._corr_cache is None, "_history and _corr_cache reset")

    ok(J.time.time() == epoch and J.datetime.now() == _dt.datetime.fromtimestamp(epoch),
       "time.time() and datetime.now() read the frozen clock")
    real0 = _time.monotonic()
    J.time.sleep(3600)
    ok(_time.monotonic() - real0 < 1.0 and J.time.time() == epoch + 3600
       and J.datetime.now() == _dt.datetime.fromtimestamp(epoch + 3600),
       "time.sleep(3600) advanced the frozen clock without sleeping")
    ok(J.time.strftime("%Y-%m-%d %H") == _time.strftime("%Y-%m-%d %H",
                                                         _time.localtime(epoch + 3600)),
       "time.strftime() formats the frozen clock")
    ctx.at(epoch)

    J.research_bump("x")
    J.research_bump("x")
    day = _time.strftime("%Y-%m-%d", _time.localtime(epoch))
    with open(os.path.join(sb, "research", "usage.json"), encoding="utf-8") as f:
        usage = json.load(f)
    ok(usage == {day: {"x": 2}}, f"research_bump('x') x2 -> sandbox research/usage.json == "
                                 f"{{{day!r}: {{'x': 2}}}}")

    # The probe's directory does not exist, so even a broken guard cannot create anything.
    probe_dir = REPO / "native" / "tools" / "__golden_guard_probe__"
    ok(not probe_dir.exists(), "guard probe directory is absent")
    for how in ("open", "os.open"):
        try:
            if how == "open":
                open(probe_dir / "probe", "w").close()
            else:
                os.close(os.open(probe_dir / "probe", os.O_WRONLY | os.O_CREAT, 0o600))
            got = "no error"
        except PermissionError as e:
            got = "guard" if "golden sandbox" in str(e) else f"PermissionError {e}"
        except OSError as e:
            got = type(e).__name__
        ok(got == "guard", f"write guard refuses {how}() outside the sandbox (got: {got})")
    try:
        subprocess.run(["/usr/bin/true"], check=False)
        got = "ran"
    except PermissionError as e:
        got = "guard" if "golden sandbox" in str(e) else str(e)
    ok(got == "guard", f"write guard refuses subprocess (got: {got})")
    return passed


def _child(argv):
    action, name, sandbox, epoch = argv[0], argv[1], argv[2], float(argv[3])
    extra = argv[4:]
    _load_plugins()
    J, clock, original = _sandbox_jarvis(sandbox, epoch)
    s = SUITES.get(name)
    if action != "selftest" and s is None:
        raise HarnessError(1, f"unknown suite {name!r}")
    ctx = Ctx(J, Path(sandbox), clock, original, s)
    threads = threading.active_count()
    out = {"python": platform.python_version(),
           "jarvis_py_sha256": hashlib.sha256(Path(J.__file__).read_bytes()).hexdigest(),
           "clock": {"epoch": float(epoch), "tz": os.environ["TZ"],
                     "local": _time.strftime("%Y-%m-%d %H:%M:%S", _time.localtime(epoch))}}
    if action == "generate":
        cases = s.run(ctx)
        _check_cases(name, cases)
        out["cases"] = cases
    elif action == "selftest":
        out["passed"] = _child_selftest(ctx)
    elif action == "readback":
        if s.readback is None:
            raise HarnessError(1, f"suite {name} has no readback")
        out["mismatches"] = list(s.readback(ctx, Path(extra[0]).resolve()))
    else:
        raise HarnessError(2, f"unknown child action {action!r}")
    if threading.active_count() > threads:
        raise HarnessError(1, f"suite {name} started threads "
                              f"({threads} -> {threading.active_count()})")
    with open(Path(sandbox) / RESULT_NAME, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, allow_nan=False)


# ─── Parent: tripwire, child runner, fixture writer ─────────────────────────────

def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _snapshot(root, rels):
    """{relative path: (size, mtime_ns, sha256) or None if absent}."""
    snap = {}
    for rel in sorted(set(rels)):
        p = root / rel
        try:
            st = p.stat()
        except FileNotFoundError:
            snap[rel] = None
            continue
        if p.is_dir():
            snap[rel] = ("dir", st.st_mtime_ns, None)
        else:
            digest = None if p.name in _NO_HASH else _sha256(p)
            snap[rel] = (st.st_size, st.st_mtime_ns, digest)
    return snap


def _tripwire_paths(root):
    rels = [p.name for p in root.glob("*.json")]
    rels += list(STATE_CONSTANTS.values()) + list(_TRIPWIRE_EXTRA)
    for d in ("research", "logs"):
        rels.append(d)
        if (root / d).is_dir():
            rels += [str(p.relative_to(root)) for p in (root / d).rglob("*")]
    return rels


def _tripwire(root=REPO):
    return _snapshot(root, _tripwire_paths(root))


def _touched(before, after):
    return sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))


def _assert_untouched(before, root=REPO):
    after = _tripwire(root)
    touched = _touched(before, after)
    if touched:
        for rel in touched:
            sys.stderr.write(f"REAL STATE TOUCHED: {rel}\n")
        raise HarnessError(3, "real state changed during the run; nothing was written")
    watched = sum(1 for v in after.values() if v is not None)
    print(f"tripwire: {watched} real state paths unchanged (size, mtime_ns, sha256)")


def _real_home():
    return os.path.expanduser("~")


def _tokens(sandbox):
    pairs = {str(sandbox): "${JARVIS_HOME}", os.path.realpath(sandbox): "${JARVIS_HOME}",
             str(REPO): "${JARVIS_HOME}", os.path.realpath(REPO): "${JARVIS_HOME}",
             _real_home(): "${HOME}", os.path.realpath(_real_home()): "${HOME}"}
    return sorted(pairs.items(), key=lambda kv: -len(kv[0]))


def _tokenize(obj, tokens):
    if isinstance(obj, str):
        for raw, tok in tokens:
            obj = obj.replace(raw, tok)
        return obj
    if isinstance(obj, list):
        return [_tokenize(v, tokens) for v in obj]
    if isinstance(obj, dict):
        return {_tokenize(k, tokens): _tokenize(v, tokens) for k, v in obj.items()}
    return obj


def _run_child(action, s, extra=()):
    tz = s.tz if s else DEFAULT_TZ
    epoch = s.epoch if s else float(DEFAULT_EPOCH)
    sandbox = Path(tempfile.mkdtemp(prefix="jarvis-golden-")).resolve()
    if not _under(str(sandbox), os.path.realpath(tempfile.gettempdir())):
        raise HarnessError(2, f"sandbox {sandbox} is not under the temp dir")
    env = {"PATH": CHILD_PATH, "HOME": str(sandbox), "LANG": "en_US.UTF-8",
           "LC_ALL": "en_US.UTF-8", "TZ": tz, **dict(s.env if s else ())}
    try:
        proc = subprocess.run([sys.executable, str(SCRIPT), "--_child", action,
                               s.name if s else "-", str(sandbox), repr(epoch), *extra],
                              env=env, cwd=str(sandbox), capture_output=True, text=True)
        label = s.name if s else action
        if proc.returncode != 0:
            tail = "\n".join((proc.stderr or proc.stdout).strip().splitlines()[-15:])
            raise HarnessError(proc.returncode if proc.returncode in (1, 2) else 1,
                               f"{label}: child failed (exit {proc.returncode})\n"
                               f"{_tokenize(tail, _tokens(sandbox))}")
        result = json.loads((sandbox / RESULT_NAME).read_text(encoding="utf-8"))
        return result, sandbox
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def _git(*args):
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True)


def _jarvis_dirty():
    return _git("diff", "--quiet", "HEAD", "--", "jarvis.py").returncode != 0


def _jarvis_commit():
    """Last commit that touched jarvis.py (not HEAD: unrelated commits must not change
    fixture bytes)."""
    return _git("log", "-1", "--format=%H", "--", "jarvis.py").stdout.strip()[:7]


def _render(s, result, sandbox, dirty):
    sha = _sha256(JARVIS_PY)
    if result["jarvis_py_sha256"] != sha:
        raise HarnessError(1, f"{s.name}: jarvis.py changed while the suite ran")
    envelope = {
        "schema": SCHEMA,
        "suite": s.name,
        "generator": GENERATOR,
        "generated_from": {"jarvis_py_sha256": sha, "git_head": _jarvis_commit(),
                           "jarvis_py_dirty": dirty, "python": result["python"]},
        "clock": result["clock"],
        "cases": result["cases"],
    }
    text = json.dumps(_tokenize(envelope, _tokens(sandbox)), indent=1, ensure_ascii=False,
                      allow_nan=False) + "\n"
    leak = HOME_LEAK.search(text)
    if leak:
        raise HarnessError(1, f"{s.name}: fixture still contains a home path ({leak.group(0)})")
    return text


def _pick(names):
    if names == ["all"]:
        return [SUITES[n] for n in sorted(SUITES)]
    unknown = [n for n in names if n not in SUITES]
    if unknown:
        raise HarnessError(1, f"unknown suite(s) {unknown}; known: {sorted(SUITES)}")
    return [SUITES[n] for n in names]


def _generate_texts(suites, dirty):
    texts = {}
    for s in suites:
        result, sandbox = _run_child("generate", s)
        texts[s.name] = _render(s, result, sandbox, dirty)
    return texts


def _rel(p):
    try:
        return str(Path(p).resolve().relative_to(REPO))
    except ValueError:
        return str(p)


def cmd_generate(names, out, allow_dirty):
    suites = _pick(names)
    dirty = _jarvis_dirty()
    if dirty and not allow_dirty:
        raise HarnessError(1, "jarvis.py has uncommitted changes; commit it first or pass "
                              "--allow-dirty (records jarvis_py_dirty: true)")
    before = _tripwire()
    try:
        texts = _generate_texts(suites, dirty)
    finally:
        _assert_untouched(before)
    out.mkdir(parents=True, exist_ok=True)
    for s in suites:
        path, text = out / s.fixture, texts[s.name]
        if path.exists() and path.read_text(encoding="utf-8") == text:
            print(f"{s.name}: unchanged {_rel(path)} ({len(json.loads(text)['cases'])} cases)")
            continue
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
        print(f"{s.name}: wrote {_rel(path)} ({len(json.loads(text)['cases'])} cases)")
    return 0


def cmd_list(out):
    for n in sorted(SUITES):
        s = SUITES[n]
        print(f"{n:<12} {_rel(out / s.fixture):<48} tz={s.tz} epoch={s.epoch!r} [{s.source}]")
    return 0


def cmd_check(out):
    sha = _sha256(JARVIS_PY)
    fresh = 0
    for n in sorted(SUITES):
        path = out / SUITES[n].fixture
        try:
            gen = json.loads(path.read_text(encoding="utf-8"))["generated_from"]
            got = gen["jarvis_py_sha256"]
        except FileNotFoundError:
            print(f"{n}: MISSING {_rel(path)}")
            continue
        except (ValueError, KeyError, TypeError) as e:
            print(f"{n}: UNREADABLE {_rel(path)} ({e})")
            continue
        if got == sha:
            fresh += 1
            note = " (generated from a dirty jarvis.py)" if gen.get("jarvis_py_dirty") else ""
            print(f"{n}: fresh{note}")
        else:
            print(f"{n}: STALE (fixture {got[:12]}, jarvis.py {sha[:12]})")
    print(f"check: {fresh}/{len(SUITES)} fixtures fresh against jarvis.py {sha[:12]}")
    return 0 if fresh == len(SUITES) else 1


def cmd_selftest():
    before = _tripwire()
    try:
        with tempfile.TemporaryDirectory(prefix="jarvis-golden-selftest-") as d:
            root = Path(d)
            (root / "research").mkdir()
            (root / "emotions.json").write_text("{}\n")
            (root / "research" / "usage.json").write_text("{}\n")
            snap = _tripwire(root)
            (root / "emotions.json").write_text('{"x": 1}\n')
            (root / "research" / "metrics.jsonl").write_text("{}\n")
            seen = _touched(snap, _tripwire(root))
            if seen != ["emotions.json", "research", "research/metrics.jsonl"]:
                raise HarnessError(1, f"selftest FAILED: tripwire missed changes (saw {seen})")
            print("selftest: tripwire detects a rewrite and a new file (scratch dir)")

        result, _ = _run_child("selftest", None)
        for line in result["passed"]:
            print(f"selftest: {line}")
        print(f"selftest: frozen clock at {result['clock']}")

        suites = [SUITES[n] for n in sorted(SUITES)]
        first, second = _generate_texts(suites, False), _generate_texts(suites, False)
        with tempfile.TemporaryDirectory(prefix="jarvis-golden-a-") as a, \
                tempfile.TemporaryDirectory(prefix="jarvis-golden-b-") as b:
            for s in suites:
                (Path(a) / s.fixture).write_text(first[s.name], encoding="utf-8")
                (Path(b) / s.fixture).write_text(second[s.name], encoding="utf-8")
                same = subprocess.run(["/usr/bin/cmp", "-s", str(Path(a) / s.fixture),
                                       str(Path(b) / s.fixture)]).returncode == 0
                if not same:
                    raise HarnessError(1, f"selftest FAILED: {s.name} is not byte-reproducible")
        print(f"selftest: fixture writer byte-reproducible for {', '.join(s.name for s in suites)}"
              f" (two fresh sandboxes, cmp)")
    finally:
        _assert_untouched(before)
    print("selftest: OK")
    return 0


def cmd_readback(directory, name):
    s = _pick([name])[0]
    if s.readback is None:
        raise HarnessError(1, f"suite {name} has no readback")
    before = _tripwire()
    try:
        result, _ = _run_child("readback", s, (str(Path(directory).resolve()),))
    finally:
        _assert_untouched(before)
    for m in result["mismatches"]:
        print(f"readback {name}: MISMATCH {m}")
    print(f"readback {name}: {'OK' if not result['mismatches'] else 'FAILED'}")
    return 1 if result["mismatches"] else 0


# ─── Suites ─────────────────────────────────────────────────────────────────────

@suite("paths")
def paths_suite(ctx):
    """os.path.relpath(<constant>, HERE) for every state constant, from the values jarvis
    computed at import (before the sandbox swap), plus the two inline literal files."""
    here = ctx.original["HERE"]
    cases = [{"name": c, "input": {"constant": c},
              "expected": {"relative": os.path.relpath(ctx.original[c], here)}}
             for c in STATE_CONSTANTS]
    inline = _inline_here_joins((ctx.sandbox / "jarvis.py").read_text(encoding="utf-8"))
    for lit in LITERAL_FILES:
        if lit not in inline:
            raise HarnessError(1, f'paths: os.path.join(HERE, "{lit}") no longer in jarvis.py')
        cases.append({"name": lit, "input": {"literal": lit},
                      "expected": {"relative": os.path.relpath(os.path.join(here, lit), here)}})
    return cases


# ─── CLI ────────────────────────────────────────────────────────────────────────

def main(argv):
    if argv[:1] == ["--_child"]:
        _child(argv[1:])
        return 0
    _load_plugins()
    import argparse
    ap = argparse.ArgumentParser(prog="golden.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="exit 1 if any fixture is stale")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="generate from an uncommitted jarvis.py (recorded in the fixture)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="fixture directory")
    ap.add_argument("words", nargs="*", help="list | selftest | readback <dir> <suite> | "
                                             "<suite> ... | all")
    a = ap.parse_args(argv)
    out = a.out.resolve()
    if a.check:
        if a.words:
            ap.error("--check takes no suite names")
        return cmd_check(out)
    if not a.words:
        ap.error("nothing to do (try: golden.py list)")
    if a.words == ["list"]:
        return cmd_list(out)
    if a.words == ["selftest"]:
        return cmd_selftest()
    if a.words[0] == "readback":
        if len(a.words) != 3:
            ap.error("usage: golden.py readback <dir> <suite>")
        return cmd_readback(a.words[1], a.words[2])
    return cmd_generate(a.words, out, a.allow_dirty)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except HarnessError as e:
        sys.stderr.write(f"golden.py: {e}\n")
        sys.exit(e.code)
