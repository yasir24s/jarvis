#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Writes Sources/JarvisTools/Catalog/ToolCatalog.swift from the m3_tool_schemas fixture
(plan: native/plan/M02-M04 §3.7, task T3.3).

The fixture is made by `tools/golden.py m3_tool_schemas`, which runs the real
_build_claude_server() and records what it hands the SDK for each tool. This script only
reads that JSON; it never imports jarvis. The Swift file keeps the 46 tools in TOOLS order,
with each description verbatim and each schema as Python's json.dumps() prints it, so the
key order is Python's. ToolCatalogTests checks the Swift file against the fixture.

    gen_tool_catalog.py          regenerate ToolCatalog.swift
"""
import json
import sys
from pathlib import Path

NATIVE = Path(__file__).resolve().parent.parent
FIXTURE = NATIVE / "Tests" / "Fixtures" / "golden" / "m3_tool_schemas.golden.json"
OUTPUT = NATIVE / "Sources" / "JarvisTools" / "Catalog" / "ToolCatalog.swift"


def swift_string(s):
    """A Swift string literal for s: plain, else raw (#"..."#), else escaped."""
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F or ch in "  " for ch in s):
        out = []
        for ch in s:
            if ch == "\\":
                out.append("\\\\")
            elif ch == '"':
                out.append('\\"')
            elif ch == "\n":
                out.append("\\n")
            elif ch == "\r":
                out.append("\\r")
            elif ch == "\t":
                out.append("\\t")
            elif ord(ch) < 0x20 or ord(ch) == 0x7F or ch in "  ":
                out.append("\\u{%x}" % ord(ch))
            else:
                out.append(ch)
        return '"' + "".join(out) + '"'
    if '"' not in s and "\\" not in s:
        return f'"{s}"'
    hashes = "#"
    while ('"' + hashes) in s or ("\\" + hashes) in s:
        hashes += "#"
    return f'{hashes}"{s}"{hashes}'


def main():
    envelope = json.loads(FIXTURE.read_text(encoding="utf-8"))
    if envelope.get("suite") != "m3_tool_schemas":
        sys.exit(f"{FIXTURE.name}: not the m3_tool_schemas fixture")
    cases = envelope["cases"]
    if [c["input"]["index"] for c in cases] != list(range(len(cases))):
        sys.exit(f"{FIXTURE.name}: cases are not in TOOLS order")
    sha = envelope["generated_from"]["jarvis_py_sha256"]

    lines = [
        "// GENERATED FILE: do not edit. Made by native/tools/gen_tool_catalog.py from",
        "// native/Tests/Fixtures/golden/m3_tool_schemas.golden.json; rerun the script to update.",
        f"// Source: jarvis.py sha256 {sha}.",
        "",
        "/// The Python TOOLS in TOOLS order, as MCP tools/list serves them (plan §3.7). Each",
        "/// `parametersJSON` is Python's `json.dumps(parameters or {\"type\": \"object\", \"properties\": {}})`,",
        "/// so its key order is Python's. Tools with no Swift body yet are listed all the same.",
        "public enum ToolCatalog {",
        "    public static let tools: [ToolSchema] = [",
    ]
    for c in cases:
        e = c["expected"]
        if c["name"] != e["name"]:
            sys.exit(f"{FIXTURE.name}: case {c['name']!r} holds tool {e['name']!r}")
        lines += [
            "        ToolSchema(",
            f"            name: {swift_string(e['name'])},",
            f"            description: {swift_string(e['description'])},",
            f"            parametersJSON: {swift_string(json.dumps(e['parameters']))}),",
        ]
    lines += ["    ]", "}", ""]

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(NATIVE)} ({len(cases)} tools)")


if __name__ == "__main__":
    main()
