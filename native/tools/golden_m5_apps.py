"""M5 T5.8 find_apps: m5_apps (G7).

Plugin for tools/golden.py. The suite builds .app bundles in the sandbox (Info.plist bytes written
by plistlib, XML or binary, plus a missing and a corrupt one), hands the real `build_app_index`
a canned mdfind listing of them (its enrichment thread is held back), runs the real
`_enrich_app_index` on the calling thread, as A-APP-1 does, and records `_find_apps` for each
query. `_default_browser_name` is stubbed.

m5_apps
  setup/<set>      input {bundles: [{path, plist_hex}], mdfind} -> expected {index: [[low, name,
                   path]], meta: {low: kinds} or null, enrich_error}: what build_app_index and
                   _enrich_app_index produced. Each "crash" set holds one bundle that makes
                   _enrich_app_index raise (a string CFBundleURLTypes entry, a plist with no root
                   object, an array root), so APP_META stays empty: all or nothing. The main
                   set includes XML that plistlib refuses and CoreFoundation would read.
  kind_word/<n>    input {text} -> expected {kind}: _kind_word
  name_kinds/<n>   input {name} -> expected {kinds}: sorted(_name_kinds(lower(name)))
  find/<set>/<n>   input {set, enriched, query, default_browser} -> expected {text, canonical}:
                   _find_apps. Python joins a set of kinds in hash order, so `canonical` is the
                   same reply with each "(kinds)" list sorted; the native reply sorts them.
  args/<n>         input {args} -> expected {text}: execute_tool("find_apps", args) over an empty
                   index, for the falsy and non-str `query` values.
"""
import contextlib
import os
import plistlib
import subprocess
import sys
import types

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
    def __init__(self, stdout):
        self.stdout = stdout
        self.calls = []
        self.TimeoutExpired = subprocess.TimeoutExpired

    def run(self, argv, **kw):
        self.calls.append(list(argv))
        if argv != ["mdfind", "kMDItemContentType == 'com.apple.application-bundle'"]:
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        return subprocess.CompletedProcess(argv, 0, stdout=self.stdout, stderr="")


class _NoThreads:
    """jarvis.threading stand-in: build_app_index's enrichment thread never starts."""
    def __init__(self):
        self.started = []

    def Thread(self, target=None, daemon=None, **kw):
        started = self.started
        return types.SimpleNamespace(start=lambda: started.append(target.__name__))


def _browser(schemes=("http", "https"), exts=("html", "htm"), utis=(), cat=None, **extra):
    info = {"CFBundleIdentifier": "com.example.app"}
    if schemes is not None:
        info["CFBundleURLTypes"] = [{"CFBundleURLName": "Web", "CFBundleURLSchemes": list(schemes)}]
    doc = {}
    if exts:
        doc["CFBundleTypeExtensions"] = list(exts)
    if utis:
        doc["LSItemContentTypes"] = list(utis)
    if doc:
        info["CFBundleDocumentTypes"] = [doc]
    if cat:
        info["LSApplicationCategoryType"] = cat
    info.update(extra)
    return info


def _xml(body, encoding="utf-8"):
    text = ('<?xml version="1.0" encoding="%s"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">%s</plist>\n'
            % ("UTF-16" if encoding == "utf-16" else "UTF-8", body))
    return text.encode(encoding)            # "utf-16" writes a BOM


# (bundle file name, plist dict | raw bytes | "missing" | "corrupt", plist format)
_BUNDLES = [
    ("Safari.app", _browser(cat="public.app-category.productivity"), plistlib.FMT_XML),
    ("VLC.app", _browser(schemes=("http", "https", "rtsp"), exts=("mp4", "mkv"),
                         cat="public.app-category.video"), plistlib.FMT_BINARY),
    ("Downie.app", _browser(exts=(), cat="public.app-category.utilities"), plistlib.FMT_XML),
    ("Spark Desktop.app", _browser(schemes=("mailto", "readdle-spark"), exts=(),
                                   cat="public.app-category.productivity"), plistlib.FMT_XML),
    ("Lichess Board.app", _browser(schemes=None, exts=(), cat="public.app-category.board-games"),
     plistlib.FMT_XML),
    ("Chess.app", _browser(schemes=None, exts=("pgn",), cat="public.app-category.games"), plistlib.FMT_XML),
    ("Archive Utility.app", _browser(schemes=None, exts=("zip",), cat="public.app-category.utilities"),
     plistlib.FMT_XML),
    ("The Unarchiver.app", _browser(schemes=None, exts=("rar",), cat="public.app-category.utilities"),
     plistlib.FMT_BINARY),
    ("Arc.app", _browser(exts=(), utis=("public.html", "com.apple.webarchive")), plistlib.FMT_XML),
    ("ChatGPT Atlas.app", _browser(utis=("public.xhtml",), exts=()), plistlib.FMT_XML),
    ("ChatGPT.app", _browser(schemes=("chatgpt",), exts=(), cat="public.app-category.productivity"),
     plistlib.FMT_XML),
    ("Google Chrome.app", _browser(exts=("webloc",)), plistlib.FMT_XML),
    ("Video Downloader Pro.app", _browser(cat="public.app-category.video"), plistlib.FMT_XML),
    ("Telegram.app", _browser(schemes=("tg",), exts=(), cat="public.app-category.social-networking"),
     plistlib.FMT_BINARY),
    ("Mail.app", _browser(schemes=("mailto", "message"), exts=("eml",)), plistlib.FMT_XML),
    ("Spotify.app", _browser(schemes=("spotify",), exts=(), cat="public.app-category.music"),
     plistlib.FMT_XML),
    ("Ünïcode Notes.app", _browser(schemes=None, exts=("txt",), cat="public.app-category.productivity"),
     plistlib.FMT_XML),
    ("Xcode.app", _browser(schemes=("xcode",), exts=("swift",), cat="public.app-category.developer-tools"),
     plistlib.FMT_XML),
    ("Terminal.app", _browser(schemes=("ssh", "telnet"), exts=("command",),
                              cat="public.app-category.utilities"), plistlib.FMT_XML),
    ("Pages.app", _browser(schemes=None, exts=("pages",), cat="public.app-category.productivity"),
     plistlib.FMT_XML),
    ("Odd Types.app", _browser(schemes=None, exts=(), CFBundleURLTypes=[{}, {"CFBundleURLSchemes": []}],
                               CFBundleDocumentTypes=[{}, {"CFBundleTypeExtensions": ["HTML"]}],
                               LSApplicationCategoryType="public.app-category.weather"), plistlib.FMT_XML),
    ("Broken.app", "missing", None),
    ("Corrupt.app", "corrupt", None),
] + [(name, _xml(body), None) for name, body in (
    # plistlib's XML reader is stricter than CoreFoundation's: each of these but the last four
    # makes plistlib.load raise, so the app is classified by name alone.
    ("Key In Array.app", "<dict><key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeExtensions</key>"
                         "<array><key>html</key></array></dict></array>"
                         "<key>LSApplicationCategoryType</key><string>public.app-category.games</string></dict>"),
    ("Missing Value.app", "<dict><key>LSApplicationCategoryType</key></dict>"),
    ("Bad Integer.app", "<dict><key>N</key><integer>1.5</integer>"
                        "<key>LSApplicationCategoryType</key><string>public.app-category.games</string></dict>"),
    ("Key At Root.app", "<key>LSApplicationCategoryType</key>"),
    ("Hex Integer.app", "<dict><key>N</key><integer>0x1F</integer><key>M</key><integer> -7 </integer>"
                        "<key>LSApplicationCategoryType</key><string>public.app-category.music</string></dict>"),
    ("Duplicate Key.app", "<dict><key>LSApplicationCategoryType</key><string>public.app-category.music</string>"
                          "<key>LSApplicationCategoryType</key><string>public.app-category.news</string></dict>"),
    ("CDATA And Refs.app", "<dict><key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array>"
                           "<string>http</string><string>http&#x73;</string></array></dict></array>"
                           "<key>CFBundleDocumentTypes</key><array><dict><key>LSItemContentTypes</key><array>"
                           "<string><![CDATA[public.html]]></string></array></dict></array></dict>"),
    ("Empty Key.app", "<dict><key></key><key>LSApplicationCategoryType</key>"
                      "<string>public.app-category.travel</string></dict>"),
)] + [
    ("Entity Decl.app", b'<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist [<!ENTITY c "games">]>\n'
                        b'<plist version="1.0"><dict><key>LSApplicationCategoryType</key>'
                        b'<string>public.app-category.&c;</string></dict></plist>\n', None),
    ("Leading Space.app", b"  " + _xml("<dict><key>LSApplicationCategoryType</key>"
                                       "<string>public.app-category.games</string></dict>"), None),
    ("UTF16 Plist.app", _xml("<dict><key>LSApplicationCategoryType</key><string>public.app-category.games</string>"
                             "</dict>", "utf-16"), None),
]
_CRASH = [("Weird.app", {"CFBundleURLTypes": ["http"]}, plistlib.FMT_XML)]
_CRASH_NONE = [("No Root.app", _xml(""), None)]
_CRASH_LIST = [("List Root.app", _xml("<array><string>x</string></array>"), None)]


def _make(root, bundles):
    out = []
    for fname, plist, fmt in bundles:
        contents = os.path.join(root, fname, "Contents")
        os.makedirs(contents, exist_ok=True)
        path = os.path.join(contents, "Info.plist")
        if plist == "missing":
            out.append({"path": os.path.join(root, fname), "plist_hex": None})
            continue
        data = (b"<?xml not a plist" if plist == "corrupt" else plist if isinstance(plist, bytes)
                else plistlib.dumps(plist, fmt=fmt))
        with open(path, "wb") as f:
            f.write(data)
        out.append({"path": os.path.join(root, fname), "plist_hex": data.hex()})
    return out


def _listing(bundles):
    """mdfind order: not sorted. Duplicates (first wins), a non-.app line, padding, a nested
    bundle path and a CRLF line exercise build_app_index's line rules."""
    paths = [b["path"] for b in bundles]
    lines = paths[::2] + paths[1::2]
    lines.insert(3, lines[0].replace("/Applications/", "/Applications/Utilities/"))   # same name: dropped
    lines.insert(5, lines[1] + "/Contents/Helpers")                                    # not .app: dropped
    lines[-1] = "  " + lines[-1] + "  "
    cut = min(8, len(lines) - 1)
    return "\n".join(lines[:cut]) + "\r\n" + "\n".join(lines[cut:]) + "\n"


_QUERIES = ["browsers", "my web browser", "browser", "the browser", "email client", "mail", "game",
            "games", "ai apps", "ai", "arc", "zzz", "", "  Notes ", "the terminal", "video player",
            "office", "utility", "music", "chat app", "safari", "chrome", "ü", "UNARCHIVER",
            "weather", "developer", "an editor", "photo"]


def _canonical(J, query):
    """_find_apps's name branch with each hit's kinds sorted (the kind branch is unchanged)."""
    q = (query or "").lower().strip()
    if J._kind_word(q) or q in J._ALL_KINDS:
        return J._find_apps(query)
    hits = []
    for low, name in J.APP_INDEX.items():
        if q in low:
            hits.append(f"{name} ({', '.join(sorted(J._app_kinds(low))) or 'app'})")
        if len(hits) >= 10:
            break
    return ("Matching apps: " + "; ".join(hits) + ".") if hits else f"Nothing installed matches {query}, sir."


def _same_up_to_kind_order(a, b):
    def parts(t):
        return sorted(sorted(p.split(", ")) if i % 2 else [p]
                      for chunk in [t] for i, p in enumerate(chunk.replace(")", "(").split("(")))
    return parts(a) == parts(b)


@suite("m5_apps")
def apps(ctx):
    J = ctx.J
    _assert_guard_live("m5_apps")
    cases = []
    sets = {}
    for set_name, bundles in (("main", _BUNDLES), ("crash", _BUNDLES[:3] + _CRASH),
                              ("crash_none", _BUNDLES[:2] + _CRASH_NONE), ("crash_list", _BUNDLES[:2] + _CRASH_LIST)):
        root = os.path.join(str(ctx.sandbox), set_name, "Applications")
        made = _make(root, bundles)
        listing = _listing(made)
        fake, threads = _Mdfind(listing), _NoThreads()
        with _patched(J, subprocess=fake, threading=threads):
            J.APP_META = {}
            J.build_app_index()
        if threads.started != ["_enrich_app_index"]:
            raise RuntimeError(f"{set_name}: build_app_index did not ask for enrichment: {threads.started}")
        index = [[low, name, J.APP_PATHS[low]] for low, name in J.APP_INDEX.items()]
        error = None
        try:
            J._enrich_app_index()
        except Exception as e:                       # the real thread would die here
            error = f"{type(e).__name__}: {e}"
        meta = {low: m["kinds"] for low, m in J.APP_META.items()} if J.APP_META else None
        sets[set_name] = (dict(J.APP_INDEX), dict(J.APP_PATHS), dict(J.APP_META))
        cases.append({"name": f"setup/{set_name}", "input": {"bundles": made, "mdfind": listing},
                      "expected": {"index": index, "meta": meta, "enrich_error": error}})
    if sets["main"][2] == {} or any(sets[n][2] != {} for n in ("crash", "crash_none", "crash_list")):
        raise RuntimeError("expected the main set to enrich and the crash sets not to")

    for i, text in enumerate(["browsers", "My Web Browser", "  the browser ", "a game", "an  editor",
                              "the", "mythe browser", "", None, "web browsers", "email", "mail client",
                              "photos app", "word processor", "notes app", "the the browser"]):
        cases.append({"name": f"kind_word/{i:02d}", "input": {"text": text},
                      "expected": {"kind": J._kind_word(text)}})
    for i, name in enumerate(["Safari", "Archive Utility", "The Unarchiver", "Arc", "ChatGPT Atlas",
                              "Tor Browser", "Visual Studio Code", "Microsoft Outlook", "iTerm",
                              "Notes-ish", "Messages", "Zoom.us", "Ünïcode Notes", "Arc2", "_arc",
                              "Mail Merge", "", "Opera GX", "Claude", "Word"]):
        cases.append({"name": f"name_kinds/{i:02d}", "input": {"name": name},
                      "expected": {"kinds": sorted(J._name_kinds(name.lower()))}})

    for set_name, enriched in (("main", True), ("main", False), ("crash", False), ("empty", False)):
        index, paths, meta = sets.get(set_name, ({}, {}, {}))
        for default in (["Safari", "", "Firefox"] if (set_name, enriched) == ("main", True) else ["Safari"]):
            queries = _QUERIES if default == "Safari" else ["browsers", "browser"]
            for q in queries:
                J.APP_INDEX, J.APP_PATHS = dict(index), dict(paths)
                J.APP_META = dict(meta) if enriched else {}
                with _patched(J, _default_browser_name=lambda d=default: d):
                    text = J._find_apps(q)
                    canonical = _canonical(J, q)
                if not _same_up_to_kind_order(text, canonical):
                    raise RuntimeError(f"canonical form differs beyond kind order: {text!r} / {canonical!r}")
                label = "enriched" if enriched else "unenriched"
                cases.append({"name": f"find/{set_name}/{label}/{default or 'none'}/{q!r}",
                              "input": {"set": set_name, "enriched": enriched, "query": q,
                                        "default_browser": default},
                              "expected": {"text": text, "canonical": canonical}})
    # execute_tool's argument handling over an empty index: `(query or "").lower()`.
    J.APP_INDEX, J.APP_PATHS, J.APP_META = {}, {}, {}
    for i, args in enumerate([{"query": 5}, {"query": None}, {"query": False}, {"query": []},
                              {"query": 0}, {"query": 0.0}, {"query": {}}, {"query": ""}, {},
                              {"query": ["a"]}, {"query": True}, {"query": {"a": 1}}]):
        with _patched(J, emotion_event=lambda *a, **k: None):
            text = J.execute_tool("find_apps", args)
        cases.append({"name": f"args/{i:02d}", "input": {"args": args}, "expected": {"text": text}})
    _assert_guard_live("m5_apps")
    return cases
