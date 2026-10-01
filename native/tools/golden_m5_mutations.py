"""G9 mutation oracle: real Python bodies, with paths mapped into the harness sandbox.

The virtual home/outside roots avoid weakening the harness's write guard. Swift replays
these relative trees under its temporary in-home and Shared roots. Trash is faked.
"""
import builtins
import errno
import os
import posixpath
import shutil
import types
from pathlib import Path

from golden import suite
from golden_m5_system import _assert_guard_live, _patched


@suite("m5_file_mutations")
def mutations(ctx):
    _assert_guard_live("m5_file_mutations")
    vectors = [
        ("write/new_nested", "write_file", {"path": "@HOME@/nested/a.txt", "content": "hello 🙂\n"}, [], True),
        ("write/overwrite_home", "write_file", {"path": "@HOME@/a.txt", "content": "new"}, [["h/a.txt", "old"]], True),
        ("write/overwrite_outside", "write_file", {"path": "@OUTSIDE@/a.txt", "content": "new"}, [["o/a.txt", "old"]], True),
        ("write/empty", "write_file", {"path": "", "content": "x"}, [], True),
        ("write/directory", "write_file", {"path": "@HOME@/dir", "content": "x"}, [["h/dir/", None]], True),
        ("write/startup", "write_file", {"path": "@HOME@/.zshrc", "content": "fixture"}, [], True),
        ("delete/trash", "delete_file", {"path": "@HOME@/a.txt"}, [["h/a.txt", "old"]], True),
        ("delete/trash_fails", "delete_file", {"path": "@HOME@/a.txt"}, [["h/a.txt", "old"]], False),
        ("delete/error_name", "delete_file", {"path": "@HOME@/error.txt"}, [["h/error.txt", "old"]], True),
        ("delete/permanent", "delete_file", {"path": "@HOME@/a.txt", "permanent": True}, [["h/a.txt", "old"]], True),
        ("delete/outside", "delete_file", {"path": "@OUTSIDE@/a.txt"}, [["o/a.txt", "old"]], True),
        ("delete/missing", "delete_file", {"path": "@HOME@/missing"}, [], True),
        ("delete/home", "delete_file", {"path": "~"}, [], True),
        ("delete/system", "delete_file", {"path": "/etc/hosts"}, [], True),
        ("delete/private", "delete_file", {"path": "/private/tmp/x"}, [], True),
        ("delete/link_dir", "delete_file", {"path": "@HOME@/link", "permanent": True}, [["h/dir/", None], ["h/link", {"link": "dir"}]], True),
        ("move/rename", "move_file", {"src": "@HOME@/a.txt", "dst": "@HOME@/b.txt"}, [["h/a.txt", "old"]], True),
        ("move/into_directory", "move_file", {"src": "@HOME@/a.txt", "dst": "@HOME@/dir"}, [["h/a.txt", "old"], ["h/dir/", None]], True),
        ("move/clobber", "move_file", {"src": "@HOME@/a.txt", "dst": "@HOME@/b.txt"}, [["h/a.txt", "new"], ["h/b.txt", "old"]], True),
        ("move/outside", "move_file", {"src": "@HOME@/a.txt", "dst": "@OUTSIDE@/a.txt"}, [["h/a.txt", "old"]], True),
        ("move/trailing_slash", "move_file", {"src": "@HOME@/dir/", "dst": "@HOME@/other/"}, [["h/dir/", None], ["h/other/", None]], True),
        ("move/system", "move_file", {"src": "/etc/hosts", "dst": "@HOME@/hosts"}, [], True),
        # shutil.move's own checks and its copy fallback (plan §3.5 PyShutil.move).
        ("move/exists_in_directory", "move_file", {"src": "@HOME@/a.txt", "dst": "@HOME@/dir"}, [["h/a.txt", "new"], ["h/dir/a.txt", "old"]], True),
        ("move/into_itself", "move_file", {"src": "@HOME@/dir", "dst": "@HOME@/dir/sub"}, [["h/dir/sub/", None]], True),
        ("move/missing_parent", "move_file", {"src": "@HOME@/a.txt", "dst": "@HOME@/nope/a.txt"}, [["h/a.txt", "old"]], True),
        ("move/cross_device_file", "move_file", {"src": "@HOME@/a.txt", "dst": "@OUTSIDE@/b.txt"}, [["h/a.txt", "old"]], True),
        ("move/cross_device_dir", "move_file", {"src": "@HOME@/dir", "dst": "@OUTSIDE@/moved"}, [["h/dir/x.txt", "x"], ["h/dir/link", {"link": "x.txt"}]], True),
        ("move/cross_device_link", "move_file", {"src": "@HOME@/link", "dst": "@OUTSIDE@/link"}, [["h/a.txt", "old"], ["h/link", {"link": "a.txt"}]], True),
    ]
    # rename(2) fails with EXDEV for these, as across volumes; shutil then copies and deletes.
    exdev = {"move/cross_device_file", "move/cross_device_dir", "move/cross_device_link"}
    # DEV-M5-04 (proposed): the guard takes basenames from absolute paths, so a trailing "/"
    # still names the folder in native's gate and reply, where Python's basename gives "".
    deviations = {"move/trailing_slash"}
    cases = []
    for index, (name, tool, args, setup, trash_ok) in enumerate(vectors):
        root = ctx.sandbox / f"mutation-{index}"
        (root / "h").mkdir(parents=True); (root / "o").mkdir()
        for rel, value in setup:
            path = root / rel
            if rel.endswith("/"):
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(value, dict): path.symlink_to(value["link"])
                else: path.write_text(value, encoding="utf-8")
        home, outside = "/jarvis-fixture/home", "/jarvis-fixture/outside"
        def real(path):
            for virtual, folder in ((home, "h"), (outside, "o")):
                if path == virtual or path.startswith(virtual + "/"):
                    return str(root / folder) + path[len(virtual):]
            raise AssertionError(f"mutation attempted outside fixture roots: {path}")
        def virtual(path):
            return str(path).replace(str(root / "h"), home).replace(str(root / "o"), outside)
        class Paths:
            sep = "/"
            def __getattr__(self, key): return getattr(posixpath, key)
            def expanduser(self, path): return home + path[1:] if path == "~" or path.startswith("~/") else path
            def abspath(self, path): return posixpath.normpath(path if path.startswith("/") else home + "/" + path)
            def realpath(self, path):
                return virtual(os.path.realpath(real(path))) if path.startswith("/jarvis-fixture/") else path
            def exists(self, path):
                return True if path in ("/etc/hosts", "/private/tmp/x") else os.path.exists(real(path))
            def isdir(self, path): return os.path.isdir(real(path))
        paths = Paths()
        fake_os = types.SimpleNamespace(path=paths, sep="/", makedirs=lambda p, **kw: os.makedirs(real(p), **kw),
                                        remove=lambda p: os.remove(real(p)))
        def move(s, d):
            if name not in exdev:
                return shutil.move(real(s), real(d))
            rename = os.rename
            def cross_device(a, b, *args, **kw):
                raise OSError(errno.EXDEV, os.strerror(errno.EXDEV), a, b)
            os.rename = cross_device
            try:
                return shutil.move(real(s), real(d))
            finally:
                os.rename = rename
        fake_shutil = types.SimpleNamespace(rmtree=lambda p: shutil.rmtree(real(p)), move=move)
        def trash(path):
            if trash_ok:
                target = real(path)
                if os.path.isdir(target): shutil.rmtree(target)
                else: os.remove(target)
            return trash_ok
        pending = []
        def gate(desc, fn):
            pending.append((desc, fn))
            return "GATED"
        arguments = {k: v.replace("@HOME@", home).replace("@OUTSIDE@", outside) if isinstance(v, str) else v for k, v in args.items()}
        with _patched(ctx.J, os=fake_os, shutil=fake_shutil, _HOME=home, _written_this_session=set(),
                      _gate=gate, _to_trash=trash, IS_WIN=False, emotion_event=lambda *a, **k: None,
                      open=lambda p, *a, **kw: builtins.open(real(p), *a, **kw)):
            reply = ctx.J.execute_tool(tool, arguments)
            desc = pending[0][0] if pending else None
            after = pending[0][1]() if pending else reply
            repeat = ctx.J.execute_tool(tool, arguments) if name == "write/overwrite_outside" else None
        def tokens(text):
            return virtual(text).replace(home, "@HOME@").replace(outside, "@OUTSIDE@") if text is not None else None
        tree = {}
        for path in sorted(root.rglob("*")):
            rel = path.relative_to(root).as_posix()
            if rel in ("h", "o"): continue
            if path.is_symlink(): tree[rel] = {"link": os.readlink(path)}
            elif path.is_dir(): tree[rel + "/"] = None
            else: tree[rel] = path.read_bytes().hex()
        inp = {"tool": tool, "args": args, "setup": setup, "trash_ok": trash_ok}
        if name in exdev:
            inp["exdev"] = True
        expected = {"gate": tokens(desc), "text": tokens(after), "repeat": tokens(repeat), "tree": tree}
        if name in deviations:
            # Native names come from the normalised absolute paths.
            src_name = posixpath.basename(posixpath.normpath(arguments["src"]))
            dst_name = posixpath.basename(posixpath.normpath(arguments["dst"]))
            expected["deviation"] = "DEV-M5-04"
            expected["native_gate"] = f"That will overwrite {dst_name}"
            expected["native_text"] = f"Moved {src_name} to {dst_name}, sir."
            if (expected["native_gate"], expected["native_text"]) == (expected["gate"], expected["text"]):
                raise RuntimeError(f"{name}: marked as a deviation but native and Python agree")
        cases.append({"name": name, "input": inp, "expected": expected})
    _assert_guard_live("m5_file_mutations")
    return cases
