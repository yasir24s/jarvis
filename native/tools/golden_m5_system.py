"""M5 T5.5/T5.6 system tools: m5_sysinfo (G15) and m5_clipboard.

Plugin for tools/golden.py. Nothing is executed: `jarvis.subprocess` is swapped for a recorder
that hands back canned command output, and `jarvis.shutil.disk_usage` for a canned reading, so
the real `_get_system_info` and `_system_report` parse exactly the text their commands would
print. The clock is the harness's frozen one (`time.time()` in the uptime line).

m5_sysinfo  input {tool, battery, cpu, wifi, memory, disk, cycle, boot, ps, now} -> expected {text}.
  Each reading is structured, so the Swift test builds the same numbers the native probes
  return: battery {percent, state} (state is the phrase pmset prints: discharging, charging,
  charged, AC attached, finishing charge) or null for no battery line; cpu is top's user field
  as printed, or null for no "CPU usage" line; wifi is networksetup's stdout; memory {memsize,
  page, free_count, speculative, inactive} (vm_stat's "Pages free" is free_count - speculative,
  host_statistics64 reports both); disk {free, total}; cycle is ioreg's CycleCount or null;
  boot is kern.boottime's sec or null; ps is `ps -Aro %cpu,comm` stdout. A reading of null for
  memory, disk or boot makes that command fail, which _system_report drops silently.
  cpu_value is the load top's field stands for: top prints the hundredths unpadded (4.08 is
  "4.8"), so where the field and "%.2f" of the value differ the native reply differs too and
  the case carries deviation "DEV-M5-01" with the native text beside Python's.
m5_clipboard  input {pbpaste_hex} -> expected {text}: execute_tool("read_clipboard") over a canned
  pbpaste stdout, decoded by subprocess's own text=True path. The native reader returns the
  same bytes (the pasteboard's public.utf8-plain-text flavor); pbpaste_hex null means the
  pasteboard holds no plain text, where pbpaste prints nothing and the native reader has no
  flavor to return.
"""
import contextlib
import subprocess
import sys
import types

from golden import suite


def _assert_guard_live(where):
    """The harness's audit hook must refuse a spawn. sys.audit only runs the hooks."""
    try:
        sys.audit("subprocess.Popen", "/usr/bin/true", ["/usr/bin/true"], None, None)
    except PermissionError as e:
        if "golden sandbox" in str(e):
            return
        raise
    raise RuntimeError(f"{where}: process guard is not active")


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


class _Runner:
    """Stands in for jarvis.subprocess. `outputs` maps an argv tuple to stdout text (or to
    bytes for text=True decoding); a missing argv raises FileNotFoundError, as a command that
    cannot run would."""

    def __init__(self, outputs):
        self.outputs = outputs
        self.calls = []
        self.TimeoutExpired = subprocess.TimeoutExpired
        self.CalledProcessError = subprocess.CalledProcessError

    def run(self, argv, capture_output=False, text=False, timeout=None, **kw):
        self.calls.append(list(argv))
        key = tuple(argv)
        if key not in self.outputs:
            raise FileNotFoundError(2, "No such file or directory", argv[0])
        out = self.outputs[key]
        if isinstance(out, bytes) and text:
            # subprocess's own text=True path: strict decode in the locale encoding (UTF-8 in
            # the child), then "\r\n" and "\r" to "\n". A decode error raises, as it would.
            out = subprocess.Popen._translate_newlines(None, out, "utf-8", "strict")
        return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="" if text else b"")


def _pmset(battery):
    if battery is None:
        return "Now drawing from 'AC Power'\n"
    tails = {"discharging": "discharging; 5:12 remaining", "charging": "charging; 1:08 remaining",
             "charged": "charged; 0:00 remaining", "AC attached": "AC attached; not charging",
             "finishing charge": "finishing charge; 0:10 remaining"}
    source = "Battery Power" if battery["state"] == "discharging" else "AC Power"
    return (f"Now drawing from '{source}'\n -InternalBattery-0 (id=4653155)\t"
            f"{battery['percent']}%; {tails[battery['state']]} present: true\n")


def _top(cpu):
    head = ("Processes: 612 total, 3 running, 609 sleeping, 3121 threads \n"
            "2026/09/28 14:30:15\nLoad Avg: 2.31, 2.10, 2.02 \n")
    if cpu is None:
        return head
    return head + f"CPU usage: {cpu}% user, 14.53% sys, 73.93% idle \nSharedLibs: 1 resident\n"


def _vm_stat(m):
    return (f"Mach Virtual Memory Statistics: (page size of {m['page']} bytes)\n"
            f"Pages free:                               {m['free_count'] - m['speculative']}.\n"
            f"Pages active:                              126693.\n"
            f"Pages inactive:                            {m['inactive']}.\n"
            f"Pages speculative:                         {m['speculative']}.\n"
            f"Pages throttled:                                0.\n")


def _ioreg(cycle):
    if cycle is None:
        return ""
    return ("+-o AppleSmartBattery  <class AppleSmartBattery, id 0x100000abc, registered>\n"
            "    {\n      \"BatteryData\" = {\"CycleCount\"=9999,\"DesignCapacity\"=4563}\n"
            f"      \"CycleCount\" = {cycle}\n      \"DesignCycleCount9C\" = 1000\n    }}\n")


def _outputs(inp):
    out = {("pmset", "-g", "batt"): _pmset(inp.get("battery")),
           ("top", "-l", "1", "-n", "0"): _top(inp.get("cpu")),
           ("networksetup", "-getairportnetwork", "en0"): inp.get("wifi", ""),
           ("ioreg", "-rn", "AppleSmartBattery"): _ioreg(inp.get("cycle")),
           ("ps", "-Aro", "%cpu,comm"): inp.get("ps", "")}
    if inp.get("memory") is not None:
        out[("sysctl", "-n", "hw.memsize")] = f"{inp['memory']['memsize']}\n"
        out[("vm_stat",)] = _vm_stat(inp["memory"])
    if inp.get("boot") is not None:
        out[("sysctl", "-n", "kern.boottime")] = (f"{{ sec = {inp['boot']}, usec = 997619 }} "
                                                  "Fri Sep 25 14:11:06 2026\n")
    return out


class _Shutil:
    def __init__(self, disk):
        self.disk = disk

    def disk_usage(self, path):
        if self.disk is None:
            raise FileNotFoundError(2, "No such file or directory", path)
        return types.SimpleNamespace(total=self.disk["total"], used=self.disk["total"] - self.disk["free"],
                                     free=self.disk["free"])


_GIB = 1024 ** 3
_LAPTOP = {"memory": {"memsize": 8 * _GIB, "page": 16384, "free_count": 12216, "speculative": 2146,
                      "inactive": 124383},
           "disk": {"free": 123_456_789_012, "total": 494_384_795_648},
           "battery": {"percent": 70, "state": "discharging"}, "cycle": 187,
           "boot": 1790341866,
           "cpu": "18.97", "cpu_value": 18.97,
           "wifi": "Current Wi-Fi Network: Home Net\n",
           "ps": " %CPU COMM\n 40.3 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer\n"
                 "  8.1 /usr/libexec/logd\n"}
_NOW = 1790582415                      # Mon 2026-09-28 09:00:15 London: the default epoch + 15 s


def _battery_cases():
    rows = [("discharging_70", {"percent": 70, "state": "discharging"}),
            ("charging_45", {"percent": 45, "state": "charging"}),
            ("charged_100", {"percent": 100, "state": "charged"}),
            ("ac_attached_80", {"percent": 80, "state": "AC attached"}),
            ("finishing_95", {"percent": 95, "state": "finishing charge"}),
            ("discharging_0", {"percent": 0, "state": "discharging"}),
            ("discharging_5", {"percent": 5, "state": "discharging"}),
            ("no_battery", None)]
    return [(f"battery/{n}", {"tool": "get_battery", "battery": b}) for n, b in rows]


def _cpu_cases():
    rows = [("two_decimals", "18.97", 18.97), ("low", "0.52", 0.52), ("high", "99.99", 99.99),
            ("whole_hundredths_zero", "16.0", 16.0), ("unpadded_08", "4.8", 4.08),
            ("unpadded_07_two_digit", "10.7", 10.07), ("padded_30", "12.30", 12.30),
            ("full_load", "100.0", 100.0), ("unavailable", None, None)]
    return [(f"cpu/{n}", {"tool": "get_cpu_usage", "cpu": c, "cpu_value": v}) for n, c, v in rows]


def _wifi_cases():
    rows = [("associated", "Current Wi-Fi Network: Home Net\n"),
            ("not_associated", "You are not associated with an AirPort network.\n"),
            ("empty", ""), ("whitespace", "  \n"),
            ("unicode_ssid", "Current Wi-Fi Network: Café 5G\n")]
    return [(f"wifi/{n}", {"tool": "get_wifi_status", "wifi": w}) for n, w in rows]


def _diag(name, **over):
    inp = {"tool": "run_diagnostics", **_LAPTOP, **over}
    return (f"diagnostics/{name}", inp)


def _diagnostics_cases():
    day, hour = 86400, 3600
    return [
        _diag("laptop"),
        _diag("desktop_no_battery", battery=None, cycle=None),
        _diag("cpu_unavailable", cpu=None, cpu_value=None),
        _diag("cpu_unpadded", cpu="4.8", cpu_value=4.08),
        _diag("wifi_empty", wifi=""),
        _diag("wifi_not_associated", wifi="You are not associated with an AirPort network.\n"),
        _diag("memory_fails", memory=None),
        _diag("disk_fails", disk=None),
        _diag("boot_fails", boot=None),
        _diag("ps_header_only", ps=" %CPU COMM\n"),
        _diag("ps_empty", ps=""),
        _diag("ps_one_field", ps=" %CPU COMM\n 12.0\n"),
        _diag("ps_spaces_in_name", ps=" %CPU COMM\n 99.5 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n"),
        _diag("ps_half_to_even", ps=" %CPU COMM\n  2.5 /usr/sbin/cfprefsd\n"),
        _diag("ps_zero", ps=" %CPU COMM\n  0.0 launchd\n"),
        _diag("uptime_1h", boot=_NOW - hour - 5),
        _diag("uptime_0h", boot=_NOW - 59),
        _diag("uptime_1d_1h", boot=_NOW - day - hour),
        _diag("uptime_2d_0h", boot=_NOW - 2 * day - 1),
        _diag("uptime_1d_2h", boot=_NOW - day - 2 * hour - 17),
        _diag("uptime_future_boot", boot=_NOW + 30),
        _diag("memory_16g_round", memory={"memsize": 16 * _GIB, "page": 16384, "free_count": 262144 + 3276,
                                          "speculative": 3276, "inactive": 65536}),
        _diag("memory_all_free", memory={"memsize": 8 * _GIB, "page": 16384, "free_count": 524288,
                                        "speculative": 0, "inactive": 0}),
        _diag("memory_page_4k", memory={"memsize": 8 * _GIB, "page": 4096, "free_count": 400000,
                                       "speculative": 1000, "inactive": 300000}),
        _diag("disk_half_gib", disk={"free": _GIB // 2, "total": 3 * _GIB // 2}),
        _diag("disk_two_and_half", disk={"free": 5 * _GIB // 2, "total": 7 * _GIB // 2}),
        _diag("cycle_absent_battery_present", cycle=None),
        _diag("charging", battery={"percent": 45, "state": "charging"}),
        _diag("everything_fails", battery=None, cycle=None, cpu=None, cpu_value=None, wifi="",
              memory=None, disk=None, boot=None, ps=""),
    ]


@suite("m5_sysinfo")
def sysinfo(ctx):
    J = ctx.J
    _assert_guard_live("m5_sysinfo")
    cases = []
    for name, inp in _battery_cases() + _cpu_cases() + _wifi_cases() + _diagnostics_cases():
        inp = {**inp, "now": _NOW}
        ctx.at(inp["now"])
        runner = _Runner(_outputs(inp))
        with _patched(J, subprocess=runner, shutil=_Shutil(inp.get("disk"))):
            text = J.execute_tool(inp["tool"], {})
        expected = {"text": text}
        if inp.get("cpu") is not None and inp.get("cpu_value") is not None:
            native = f"{inp['cpu_value']:.2f}"
            if native != inp["cpu"]:
                expected["deviation"] = "DEV-M5-01"
                expected["native_text"] = text.replace(f"CPU user load {inp['cpu']} percent.",
                                                       f"CPU user load {native} percent.")
                if expected["native_text"] == text:
                    raise RuntimeError(f"{name}: the CPU sentence is not in the reply")
        cases.append({"name": name, "input": inp, "expected": expected})
    _assert_guard_live("m5_sysinfo")
    return cases


def _clipboard_rows():
    x = "x"
    return [
        ("plain", b"hello world"),
        ("empty", b""),
        ("no_plain_text", None),
        ("crlf", b"a\r\nb\r\nc"),
        ("lone_cr", b"a\rb\rc"),
        ("cr_crlf_mix", b"a\r\r\nb\n\rc"),
        ("trailing_cr", b"abc\r"),
        ("unicode", "Café — naïve ☕".encode()),
        ("emoji_astral", ("😀" * 10).encode()),
        ("bom_kept", b"\xef\xbb\xbfhi"),
        ("nul", b"a\x00b"),
        ("other_line_breaks_kept", "a\u2028b\x85c\x0bd\x0ce".encode()),
        ("exactly_3500", (x * 3500).encode()),
        ("over_3500", (x * 3600).encode()),
        ("astral_at_boundary", (x * 3499 + "😀" + "tail").encode()),
        ("combining_split_at_boundary", (x * 3499 + "e\u0301").encode()),
        ("crlf_at_boundary", (x * 3499 + "\r\ny").encode()),
        ("translation_before_slice", ("\r\n" * 3000 + "end").encode()),
        ("flags_cut_mid_pair", ("x" + "🇬🇧" * 2000).encode()),
        ("large", ("y" * 20000).encode()),
        ("invalid_utf8", b"abc\xff"),
        ("utf8_surrogate", b"\xed\xa0\x80"),
        ("overlong", b"\xc0\xaf"),
        ("truncated_sequence", b"ok\xe2\x82"),
    ]


@suite("m5_clipboard")
def clipboard(ctx):
    J = ctx.J
    _assert_guard_live("m5_clipboard")
    cases = []
    for name, raw in _clipboard_rows():
        runner = _Runner({("pbpaste",): raw if raw is not None else b""})
        with _patched(J, subprocess=runner):
            text = J.execute_tool("read_clipboard", {})
        if runner.calls != [["pbpaste"]]:
            raise RuntimeError(f"{name}: expected one pbpaste call, got {runner.calls}")
        cases.append({"name": f"clipboard/{name}",
                      "input": {"pbpaste_hex": raw.hex() if raw is not None else None},
                      "expected": {"text": text}})
    _assert_guard_live("m5_clipboard")
    return cases
