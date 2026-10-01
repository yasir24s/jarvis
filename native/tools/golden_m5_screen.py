"""M5 T5.7 screen tools: m5_screen (G17 OCR, see_screen, take_screenshot).

Plugin for tools/golden.py. The images are tools/render_ocr_fixtures.swift's PNGs in
Tests/Fixtures/golden/m5_ocr, committed, so the real `_ocr_image` (Vision through PyObjC) and the
native Vision request read identical pixels; both run on this Mac's Vision, so the text is
compared exactly. Nothing captures the screen: `jarvis.subprocess` is a recorder whose
`screencapture` copies a fixture image to the requested path, or writes nothing for a failed
capture.

m5_screen
  ocr/<image>         input {image, sha256}           -> expected {text}: _ocr_image(path)
  see_screen/<case>   input {image or null}           -> expected {text}: execute_tool("see_screen"),
                      which captures to $TMPDIR/jarvis_screen.png, OCRs it, unlinks it, then
                      `[:3500] or "Screen not accessible."`
  screenshot/<case>   input {epoch, saved}            -> expected {text, argv}: execute_tool(
                      "take_screenshot") at a pinned clock; argv is the recorded screencapture
                      call, whose path carries the strftime stamp.
"""
import contextlib
import hashlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from golden import suite

IMAGES = Path(__file__).resolve().parents[1] / "Tests" / "Fixtures" / "golden" / "m5_ocr"
NAMES = ("plain", "code", "columns", "dark", "blank")


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


class _Screencapture:
    """Stands in for jarvis.subprocess: `screencapture ... <path>` copies `image` to path (the
    last argument), or writes nothing when image is None."""

    def __init__(self, image):
        self.image = image
        self.calls = []
        self.TimeoutExpired = subprocess.TimeoutExpired

    def run(self, argv, **kw):
        self.calls.append(list(argv))
        if argv[0] != "screencapture":
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        if self.image is not None:
            os.makedirs(os.path.dirname(argv[-1]), exist_ok=True)
            shutil.copyfile(IMAGES / f"{self.image}.png", argv[-1])
        return subprocess.CompletedProcess(argv, 0, stdout=b"", stderr=b"")


def _sha(name):
    return hashlib.sha256((IMAGES / f"{name}.png").read_bytes()).hexdigest()


@suite("m5_screen")
def screen(ctx):
    J = ctx.J
    _assert_guard_live("m5_screen")
    cases = []
    for name in NAMES:
        text = J._ocr_image(str(IMAGES / f"{name}.png"))
        cases.append({"name": f"ocr/{name}", "input": {"image": f"m5_ocr/{name}.png", "sha256": _sha(name)},
                      "expected": {"text": text}})
    for name in (*NAMES, None):
        fake = _Screencapture(name)
        with _patched(J, subprocess=fake):
            text = J.execute_tool("see_screen", {})
        tmp = os.path.join(J.tempfile.gettempdir(), "jarvis_screen.png")
        if fake.calls != [["screencapture", "-x", "-t", "png", tmp]] or os.path.exists(tmp):
            raise RuntimeError(f"see_screen/{name}: unexpected calls {fake.calls} or temp file left")
        cases.append({"name": f"see_screen/{name or 'capture_fails'}",
                      "input": {"image": f"m5_ocr/{name}.png" if name else None},
                      "expected": {"text": text}})

    def wall(y, mo, d, h, mi, s, frac=0.0):
        return time.mktime((y, mo, d, h, mi, s, 0, 0, -1)) + frac

    shots = [("saved_p1", wall(2026, 9, 28, 14, 30, 15, 0.123456), True),
             ("saved_single_digits", wall(2026, 9, 5, 9, 5, 7), True),
             ("saved_year_end", wall(2026, 12, 31, 23, 59, 59, 0.999), True),
             ("failed", wall(2026, 9, 28, 14, 30, 15, 0.123456), False)]
    for name, epoch, saved in shots:
        ctx.at(epoch)
        fake = _Screencapture("plain" if saved else None)
        with _patched(J, subprocess=fake):
            text = J.execute_tool("take_screenshot", {})
        if len(fake.calls) != 1:
            raise RuntimeError(f"screenshot/{name}: expected one screencapture call, got {fake.calls}")
        path = fake.calls[0][-1]
        if saved:
            os.remove(path)
        cases.append({"name": f"screenshot/{name}", "input": {"epoch": epoch, "saved": saved},
                      "expected": {"text": text, "argv": fake.calls[0]}})
    _assert_guard_live("m5_screen")
    return cases
