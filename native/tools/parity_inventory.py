#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Inventory of what jarvis.py exposes, checked against native/PARITY.md (plan: M00 §3.8).

Reads jarvis.py with ast + regex, never imports it: tool names in TOOLS, os.environ.get("…")
names, module-level *_FILE / RESEARCH_* constants, inline os.path.join(HERE, "<name>")
files, and the "# ───" section banners with their line numbers.

    parity_inventory.py --emit     print the PARITY skeleton rows jarvis.py implies
    parity_inventory.py --check    exit 1 listing every name in jarvis.py missing from
                                   PARITY.md, and every PARITY name no longer in jarvis.py
"""
import sys

_FRAMEWORK = "/Library/Frameworks/Python.framework/"
_INTERPRETER = _FRAMEWORK + "Versions/3.14/bin/python3"
if sys.version_info[:2] != (3, 14) or not sys.executable.startswith(_FRAMEWORK):
    sys.stderr.write(f"parity_inventory.py: needs Python 3.14 from {_FRAMEWORK}; run "
                     f"{_INTERPRETER} (this is {sys.executable}, {sys.version.split()[0]})\n")
    sys.exit(2)
sys.dont_write_bytecode = True

import argparse
import ast
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
JARVIS_PY = REPO / "jarvis.py"
PARITY_MD = REPO / "native" / "PARITY.md"

# os.environ.get names that are platform plumbing, not settings (plan M00 §3.8).
ENV_NON_ROWS = {"PATH", "APPDATA", "PROGRAMDATA"}
# Inline HERE files that are not state: research_snapshot() measures the program's own source.
FILE_NON_ROWS = {"jarvis.py"}
# PARITY rows that are native additions, so jarvis.py is not expected to have them.
NATIVE_ONLY = {"JARVIS_HOME",           # Settings: "native-only, additive: state-root override"
               ".jarvis.lock"}          # State files: "single-instance lock (new, …)"

BANNER = re.compile(r"^# ─── (.+?) ─+\s*$")
TICK = re.compile(r"`([^`]+)`")


# ─── jarvis.py ──────────────────────────────────────────────────────────────────

def _join_parts(node, bases):
    """os.path.join(<base>, "lit", ...) → "base-rel/lit/..." for base in `bases`, else None."""
    if not (isinstance(node, ast.Call) and ast.unparse(node.func) == "os.path.join"
            and node.args and isinstance(node.args[0], ast.Name) and node.args[0].id in bases
            and all(isinstance(a, ast.Constant) and isinstance(a.value, str)
                    for a in node.args[1:])):
        return None
    prefix = bases[node.args[0].id]
    return "/".join(([prefix] if prefix else []) + [a.value for a in node.args[1:]])


def inventory(source):
    tree = ast.parse(source)
    lines = source.splitlines()

    tools = {}                                   # name -> (line, description)
    def collect_tools(node):
        for d in ast.walk(node):
            if isinstance(d, ast.Dict):
                keys = {k.value: v for k, v in zip(d.keys, d.values)
                        if isinstance(k, ast.Constant)}
                name = keys.get("name")
                if (isinstance(name, ast.Constant) and isinstance(name.value, str)
                        and "description" in keys):
                    desc = keys["description"]
                    text = desc.value if isinstance(desc, ast.Constant) else ast.unparse(desc)
                    tools.setdefault(name.value, (d.lineno, " ".join(str(text).split())))

    for node in ast.walk(tree):
        if (isinstance(node, (ast.Assign, ast.AugAssign))
                and any(isinstance(t, ast.Name) and t.id == "TOOLS"
                        for t in (node.targets if isinstance(node, ast.Assign) else [node.target]))):
            collect_tools(node.value)
        elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
              and isinstance(node.func.value, ast.Name) and node.func.value.id == "TOOLS"
              and node.func.attr in ("append", "insert", "extend")):
            for a in node.args:
                collect_tools(a)

    env = {}                                     # name -> first line
    for node in ast.walk(tree):
        if (isinstance(node, ast.Call) and ast.unparse(node.func) == "os.environ.get"
                and node.args and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str)):
            env.setdefault(node.args[0].value, node.lineno)

    bases = {"HERE": ""}
    state = {}                                   # constant -> (line, relative path or None)
    module_joins = {}                            # relative path -> constant (all HERE joins)
    top_values = set()
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 \
                and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            top_values.add(id(node.value))
            rel = _join_parts(node.value, bases)
            if rel is not None:
                bases[name] = rel
                module_joins[rel] = name
            if name.endswith("_FILE") or name.startswith("RESEARCH_"):
                state[name] = (node.lineno, rel)

    literal = {}                                 # relative path -> first line
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and id(node) not in top_values:
            rel = _join_parts(node, {"HERE": ""})
            if rel is not None:
                literal.setdefault(rel, node.lineno)

    banners = [(i, m.group(1).strip()) for i, text in enumerate(lines, 1)
               if (m := BANNER.match(text))]
    return {"tools": tools, "env": env, "state": state, "module_joins": module_joins,
            "literal": literal, "banners": banners}


# ─── PARITY.md ──────────────────────────────────────────────────────────────────

def parity_sections(text):
    """{section key: {"heading": str, "rows": [[cell, ...], ...]}} for the tables we check."""
    keys = {"Tools": "tools", "Settings": "env", "State files": "state", "Subsystems": "banners"}
    out, cur = {}, None
    for line in text.splitlines():
        if line.startswith("## "):
            title = line[3:].strip()
            cur = next((v for k, v in keys.items() if title.startswith(k)), None)
            if cur:
                out[cur] = {"heading": title, "rows": []}
        elif cur and line.startswith("|") and not re.match(r"^\|[\s|:-]+\|$", line):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if cells and cells[0] in ("☐", "☑", "✓", "x", "X", "✅", ""):
                out[cur]["rows"].append(cells)
    return out


def _first_tick(cell):
    m = TICK.search(cell)
    return m.group(1) if m else None


def check(inv, sec):
    missing, extra = [], []

    tool_rows = {t for r in sec["tools"]["rows"] if len(r) > 1 and (t := _first_tick(r[1]))}
    tool_heading = set(TICK.findall(sec["tools"]["heading"]))
    for name, (line, _) in sorted(inv["tools"].items()):
        if name not in tool_rows | tool_heading:
            missing.append(f"tool `{name}` (jarvis.py:{line})")
    extra += [f"tool `{t}`" for t in sorted(tool_rows - set(inv["tools"]))]

    env_rows = {v for r in sec["env"]["rows"] if len(r) > 1 and (v := _first_tick(r[1]))}
    for name, line in sorted(inv["env"].items()):
        if name not in env_rows and name not in ENV_NON_ROWS:
            missing.append(f"env `{name}` (jarvis.py:{line})")
    extra += [f"env `{v}`" for v in sorted(env_rows - set(inv["env"]) - NATIVE_ONLY)]

    state_rows = sec["state"]["rows"]
    files = {f for r in state_rows if len(r) > 1 and (f := _first_tick(r[1]))}
    state_ticks = {t for r in state_rows for c in r[1:3] for t in TICK.findall(c)}
    for name, (line, rel) in sorted(inv["state"].items()):
        covered = (name in state_ticks or rel in files
                   or (rel is not None and any(f.startswith(rel + "/") for f in files)))
        if not covered:
            missing.append(f"state constant `{name}` → `{rel}` (jarvis.py:{line})")
    for rel, line in sorted(inv["literal"].items()):
        if rel not in files and rel not in FILE_NON_ROWS:
            missing.append(f"file `{rel}` (jarvis.py:{line})")
    known_files = set(inv["module_joins"]) | set(inv["literal"])
    extra += [f"file `{f}`" for f in sorted(files - known_files - NATIVE_ONLY)]
    consts = {t for t in state_ticks if re.fullmatch(r"[A-Z_]+_FILE|RESEARCH_[A-Z_]+", t)}
    extra += [f"state constant `{c}`" for c in sorted(consts - set(inv["state"]))]

    # PARITY may annotate a banner with its native fate: "HUD wrapper → native NSPanel (M13)".
    titles = {r[2] for r in sec["banners"]["rows"] if len(r) > 2 and r[1].isdigit()}
    same = lambda row, banner: row == banner or row.startswith(banner + " → ")
    for line, title in inv["banners"]:
        if not any(same(r, title) for r in titles):
            missing.append(f"section “{title}” (jarvis.py:{line})")
    extra += [f"section “{r}”" for r in sorted(titles)
              if not any(same(r, b) for _, b in inv["banners"])]
    return missing, extra


def emit(inv):
    print(f"## Tools ({len(inv['tools'])})\n")
    for name, (_, desc) in inv["tools"].items():
        short = desc if len(desc) <= 150 else desc[:149].rstrip() + " …"
        print(f"| ☐ | `{name}` |  |  | {short.replace('|', '/')} | |")
    print(f"\n## Settings ({len(inv['env'])} os.environ.get names, "
          f"{len(set(inv['env']) - ENV_NON_ROWS)} after the non-row allowlist)\n")
    for name in sorted(set(inv["env"]) - ENV_NON_ROWS):
        print(f"| ☐ | `{name}` |  | |")
    print("\n## State files\n")
    for name, (line, rel) in inv["state"].items():
        print(f"| ☐ | `{rel}` | `{name}` | |")
    for rel, line in inv["literal"].items():
        if rel not in FILE_NON_ROWS:
            print(f"| ☐ | `{rel}` | inline, jarvis.py:{line} | |")
    print(f"\n## Subsystems ({len(inv['banners'])})\n")
    for line, title in inv["banners"]:
        print(f"| ☐ | {line} | {title} | |")


def main(argv):
    ap = argparse.ArgumentParser(prog="parity_inventory.py", description=__doc__.split("\n\n")[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--emit", action="store_true", help="print PARITY skeleton rows")
    mode.add_argument("--check", action="store_true", help="diff jarvis.py against PARITY.md")
    a = ap.parse_args(argv)
    inv = inventory(JARVIS_PY.read_text(encoding="utf-8"))
    if a.emit:
        emit(inv)
        return 0
    sec = parity_sections(PARITY_MD.read_text(encoding="utf-8"))
    absent = [k for k in ("tools", "env", "state", "banners") if k not in sec]
    if absent:
        print(f"PARITY.md is missing section(s): {absent}")
        return 1
    missing, extra = check(inv, sec)
    for m in missing:
        print(f"MISSING from PARITY.md: {m}")
    for e in extra:
        print(f"NOT IN jarvis.py: {e}")
    print(f"parity: {len(inv['tools'])} tools, {len(inv['env'])} env names "
          f"({len(ENV_NON_ROWS)} allowlisted), {len(inv['state'])} state constants, "
          f"{len(inv['literal'])} inline files, {len(inv['banners'])} sections; "
          f"{len(missing)} missing, {len(extra)} stale")
    return 1 if missing or extra else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
