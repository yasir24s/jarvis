#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Check that the jarvis.py code quoted in the M2 plan is byte-identical to jarvis.py (plan §5 A-0, T2.1).

    check_plan_verbatim.py [<plan.md> [<jarvis.py>]]

Takes every ```python block in plan §2.2 (from the "### 2.2" heading to the next "##" or "###"
heading) and checks that its bytes occur in jarvis.py as whole lines: the block, from the start
of its first line to the end of its last, must match a run of jarvis.py lines exactly. Both files
are read as bytes and never written. Defaults: the plan and jarvis.py of the repo this script
lives in.

stdout is "ok N/N" when every block is verbatim. Otherwise it prints one line per mismatching
block, naming it by the first name the block assigns or defines and its plan line, and never
its content. Exit 0 when all match, 1 on a mismatch, 2 on a usage error.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_PLAN = REPO / "native" / "plan" / "M02-M04-security-brain-chat.md"
DEFAULT_JARVIS = REPO / "jarvis.py"
_NAME = re.compile(rb"^\s*(?:async\s+)?def\s+(\w+)|^\s*(\w+)\s*=")


def section_blocks(plan):
    """[(first plan line of the block body, body bytes)] for the ```python blocks of §2.2."""
    lines = plan.split(b"\n")
    start = next((i for i, l in enumerate(lines) if l.startswith(b"### 2.2 ")), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith(b"## ") or lines[i].startswith(b"### ")), len(lines))
    blocks, body, first = [], None, 0
    for i in range(start + 1, end):
        l = lines[i]
        if body is None:
            if l.strip() == b"```python":
                body, first = [], i + 2           # 1-based line of the first body line
        elif l.strip() == b"```":
            blocks.append((first, b"\n".join(body)))
            body = None
        else:
            body.append(l)
    if body is not None:
        return None                               # unterminated fence
    return blocks


def block_name(first, body):
    for l in body.split(b"\n"):
        m = _NAME.match(l)
        if m:
            return f"{(m.group(1) or m.group(2)).decode()} (plan line {first})"
    return f"block (plan line {first})"


def main(argv):
    if len(argv) > 2:
        sys.stderr.write("usage: check_plan_verbatim.py [<plan.md> [<jarvis.py>]]\n")
        return 2
    plan_path = Path(argv[0]) if argv else DEFAULT_PLAN
    jarvis_path = Path(argv[1]) if len(argv) > 1 else DEFAULT_JARVIS
    try:
        plan, src = plan_path.read_bytes(), jarvis_path.read_bytes()
    except OSError as e:
        sys.stderr.write(f"check_plan_verbatim.py: {e.strerror}: {e.filename}\n")
        return 2
    blocks = section_blocks(plan)
    if not blocks:
        sys.stderr.write("check_plan_verbatim.py: no complete ```python blocks under §2.2\n")
        return 2
    haystack = b"\n" + src + b"\n"
    bad = [block_name(first, body) for first, body in blocks
           if b"\n" + body + b"\n" not in haystack]
    if bad:
        for name in bad:
            print(name)
        return 1
    print(f"ok {len(blocks)}/{len(blocks)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
