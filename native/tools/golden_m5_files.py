"""M5 T5.10/T5.11 file tools: m5_spotlight (G8) and m5_read_file (G9, the read half).

Plugin for tools/golden.py. Nothing is executed: `jarvis.subprocess` is a recorder that hands
`_spotlight` canned mdfind stdout (or raises the timeout subprocess would raise). The `recent`
cases list real files the suite creates in the sandbox home with `os.utime`-set mtimes, so the
real newest-first sort and junk filter run on real `stat` results.

m5_spotlight  input {tool, args, stdout | stdout_hex, timeout, files: [[rel, st_mtime_ns]]}
              -> expected {text, argv}: execute_tool(tool, args); argv is the recorded mdfind
              call (null when Python raised before running it).
"""
import contextlib
import os
import subprocess
import sys

from golden import suite


def _assert_guard_live(where):
    try:
        sys.audit("subprocess.Popen", "/usr/bin/true", ["/usr/bin/true"], None, None)
    except PermissionError as e:
        if "golden sandbox" in str(e):
            return
        raise
    raise RuntimeError(f"{where}: process guard is not active")


@contextlib.contextmanager
def _patched(J, **attrs):
    saved = {k: getattr(J, k) for k in attrs}
    for k, v in attrs.items():
        setattr(J, k, v)
    try:
        yield
    finally:
        for k, v in saved.items():
            setattr(J, k, v)


class _Mdfind:
    def __init__(self, stdout, timeout=False):
        self.stdout, self.timeout = stdout, timeout
        self.calls = []
        self.TimeoutExpired = subprocess.TimeoutExpired

    def run(self, argv, capture_output=False, text=False, timeout=None, **kw):
        self.calls.append(list(argv))
        if argv[0] != "mdfind":
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        if self.timeout:
            raise subprocess.TimeoutExpired(argv, timeout)
        out = self.stdout
        if isinstance(out, bytes):
            out = subprocess.Popen._translate_newlines(None, out, "utf-8", "strict")
        return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="")


def _paths(n, root="/Volumes/Work/Projects", stem="report"):
    return [f"{root}/{stem}-{i:02d}.txt" for i in range(1, n + 1)]


def _cases(home):
    def listing(paths):
        return "".join(p + "\n" for p in paths)

    plain = [
        ("search/report", "search_files", {"query": "report"}, listing(_paths(3))),
        ("search/zero_hits", "search_files", {"query": "nothing here"}, ""),
        ("search/six_hits", "search_files", {"query": "report"}, listing(_paths(6))),
        ("search/seven_hits", "search_files", {"query": "report"}, listing(_paths(7))),
        ("search/twenty_hits", "search_files", {"query": "report"}, listing(_paths(20))),
        ("search/quote", "search_files", {"query": "it's"}, listing(["/Volumes/Work/it's here.txt"])),
        ("search/backslash", "search_files", {"query": "a\\b"}, listing(["/Volumes/Work/a\\b.txt"])),
        ("search/both_escapes", "search_files", {"query": " x\\'y "}, ""),
        ("search/whitespace_query", "search_files", {"query": "   "}, listing(_paths(2))),
        ("search/empty_query", "search_files", {"query": ""}, listing(_paths(2))),
        ("search/no_args", "search_files", {}, ""),
        ("search/blank_lines", "search_files", {"query": "report"},
         "\n  \n" + listing(_paths(2)) + "\t\n"),
        ("search/crlf_and_cr", "search_files", {"query": "report"},
         "/Volumes/Work/a.txt\r\n/Volumes/Work/b.txt\r/Volumes/Work/c.txt\n"),
        ("search/other_line_breaks", "search_files", {"query": "odd"},
         "/Volumes/Work/odd name.txt\n/Volumes/Work/odd\x0bvt.txt\n/Volumes/Work/odd\x85nel.txt\n"),
        ("search/unicode_names", "search_files", {"query": "café"},
         listing(["/Volumes/Work/café menu.pdf", "/Volumes/Work/日本語.txt", "/Volumes/Work/😀.png"])),
        ("search/trailing_slash_dir", "search_files", {"query": "proj"}, listing(["/Volumes/Work/Projects/"])),
        ("search/non_str_query", "search_files", {"query": 5}, None),
        ("search/falsy_query", "search_files", {"query": 0}, ""),
        ("search/none_query", "search_files", {"query": None}, listing(_paths(1))),
        ("find/kind_pdf", "find_files", {"query": "", "kind": "pdf"}, listing(_paths(2))),
        ("find/kind_with_query", "find_files", {"query": "tax", "kind": "spreadsheet"}, listing(_paths(1))),
        ("find/unknown_kind", "find_files", {"query": "x", "kind": "nosuchkind"}, ""),
        ("find/kind_case_sensitive", "find_files", {"query": "x", "kind": "PDF"}, ""),
        ("find/kind_only_unknown", "find_files", {"kind": "nosuchkind"}, ""),
        ("find/kind_int", "find_files", {"query": "x", "kind": 5}, ""),
        ("find/kind_list", "find_files", {"query": "x", "kind": ["pdf"]}, None),
        ("find/kind_empty_list", "find_files", {"query": "x", "kind": []}, ""),
        ("find/kind_dict", "find_files", {"query": "x", "kind": {"a": 1}}, None),
        ("find/every_kind_code", "find_files", {"query": "main", "kind": "code"}, listing(_paths(1))),
        ("find/kind_app", "find_files", {"query": "", "kind": "app"}, listing(["/Applications/Safari.app"])),
    ]
    out = [(n, t, a, s, False, []) for n, t, a, s in plain]
    out += [
        ("search/timeout", "search_files", {"query": "report"}, "", True, []),
        ("find/timeout_recent", "find_files", {"query": "it's", "recent": True}, "", True, []),
        ("search/invalid_utf8_start", "search_files", {"query": "x"}, b"/Volumes/Work/ok\n/bad\xff\n", False, []),
        ("search/invalid_utf8_continuation", "search_files", {"query": "x"}, b"/a\xe2\x28\xa1\n", False, []),
        ("search/invalid_utf8_truncated", "search_files", {"query": "x"}, b"/Volumes/Work/ok\n/b\xe2\x82", False, []),
        ("search/invalid_utf8_surrogate", "search_files", {"query": "x"}, b"/s\xed\xa0\x80\n", False, []),
        ("search/invalid_utf8_overlong", "search_files", {"query": "x"}, b"/o\xc0\xaf\n", False, []),
        ("search/invalid_utf8_f4_range", "search_files", {"query": "x"}, b"/f\xf4\x90\x80\x80\n", False, []),
        ("search/invalid_utf8_third_byte", "search_files", {"query": "x"}, b"ab\xe2\x82(\n", False, []),
        ("search/invalid_utf8_fourth_byte", "search_files", {"query": "x"}, b"\xf0\x9f\x98(\n", False, []),
        ("search/invalid_utf8_truncated_four", "search_files", {"query": "x"}, b"/x\n\xf0\x9f", False, []),
        ("search/invalid_utf8_f5", "search_files", {"query": "x"}, b"\xf5\x80\n", False, []),
        ("search/invalid_utf8_after_valid_three", "search_files", {"query": "x"}, b"\xed\x9f\xbf\xed\xa0\n", False, []),
    ]

    # recent: real files in the sandbox home. Junk is filtered before the sort; a listed path
    # that does not exist sorts as mtime 0; equal mtimes keep mdfind order.
    files = [("Documents/plan.txt", 1790500000.25), ("Documents/notes.md", 1790590000.5),
             ("Desktop/photo.png", 1790590000.5), ("Downloads/old.zip", 1789000000.0),
             ("Documents/Library/inside.txt", 1790599999.0), ("Library/Caches/x.txt", 1790599999.0),
             ("Documents/.hidden.txt", 1790599999.0), ("Documents/build.LOG", 1790599999.0),
             ("Documents/state.db-wal", 1790599999.0), ("Documents/app.Plist", 1790599999.0),
             ("Projects/node_modules/a.js", 1790599999.0), ("Projects/.git/HEAD", 1790599999.0),
             ("Projects/__pycache__/m.pyc", 1790599999.0), ("Documents/same-a.txt", 1790580000.0),
             ("Documents/same-b.txt", 1790580000.0), (".Trash/gone.txt", 1790599999.0),
             ("Documents/near-1.txt", 1790580000.0000001), ("Documents/near-2.txt", 1790580000.0000002)]
    listed = [f"{home}/{rel}" for rel, _ in files] + [f"{home}/Documents/missing.txt", f"{home}/Documents/"]
    many = [(f"Documents/bulk-{i:02d}.txt", 1790500000.0 + i * 37) for i in range(15)]
    out += [
        ("find/recent_all", "find_files", {"recent": True}, "".join(p + "\n" for p in listed), False, files),
        ("find/recent_query_kind", "find_files", {"query": "notes", "kind": "document", "recent": True},
         "".join(p + "\n" for p in listed[:3]), False, files),
        ("find/recent_string_false_is_true", "find_files", {"query": "plan", "recent": "false"},
         f"{home}/Documents/plan.txt\n", False, files),
        ("find/recent_zero_is_false", "find_files", {"query": "plan", "recent": 0},
         f"{home}/Documents/plan.txt\n", False, files),
        ("find/recent_twelve_of_fifteen", "find_files", {"query": "bulk", "recent": True},
         "".join(f"{home}/{rel}\n" for rel, _ in many), False, many),
        ("find/recent_only_junk", "find_files", {"recent": True},
         f"{home}/Library/Caches/x.txt\n{home}/Documents/.hidden.txt\n", False, files),
    ]
    return out


@suite("m5_spotlight")
def spotlight(ctx):
    J = ctx.J
    home = os.path.expanduser("~")
    _assert_guard_live("m5_spotlight")
    made = set()
    cases = []
    for name, tool, args, stdout, timeout, files in _cases(home):
        for rel, mtime in files:
            path = os.path.join(home, rel)
            if path not in made:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(rel)
                os.utime(path, (mtime, mtime))
                made.add(path)
        fake = _Mdfind(stdout if stdout is not None else "", timeout)
        with _patched(J, subprocess=fake, emotion_event=lambda *a, **k: None):
            text = J.execute_tool(tool, args)
        if len(fake.calls) > 1:
            raise RuntimeError(f"{name}: more than one mdfind call: {fake.calls}")
        inp = {"tool": tool, "args": args, "timeout": timeout,
               "files": [[rel, os.stat(os.path.join(home, rel)).st_mtime_ns] for rel, _ in files]}
        if isinstance(stdout, bytes):
            inp["stdout_hex"] = stdout.hex()
        else:
            inp["stdout"] = stdout or ""
        cases.append({"name": name, "input": inp,
                      "expected": {"text": text, "argv": fake.calls[0] if fake.calls else None}})
    _assert_guard_live("m5_spotlight")
    return cases
