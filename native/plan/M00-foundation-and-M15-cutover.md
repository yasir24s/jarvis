# M0 + M15 — Foundation (package, build, signing, oracle, exclusion guard, logging) and Parity audit & cutover
## 1. Goal and scope (in / explicitly out)

**Path convention for this file.** Every path is written `~/…` or repo-relative. The repo
pre-commit hook (`~/jarvis/.githooks/pre-commit`, regex `(/Users/[A-Za-z0-9._-]+/)`) blocks
any added line containing an absolute home path, so this plan, every script and every
fixture must use `$HOME`, `~`, or a token. "Repo" = `~/jarvis`; "native" = `~/jarvis/native`.

### M0 — Foundation. Goal
A signed, launchable, do-nothing-yet native JARVIS that already obeys the rules that later
milestones rely on: it shares real state safely (it resolves the real state root, never runs
alongside Python, writes byte-compatible JSON atomically) and it is checked against Python
by an oracle harness from day one.

**In scope (M0):**
1. Corrections to `native/ROADMAP.md`, `native/PARITY.md`, `native/Package.swift` (§3.1),
   applied by the M0 executor as exact text replacements.
2. Package layout and target plan (§3.2) — M0 creates `JarvisCore`, `JarvisApp`,
   `JarvisTestSupport`, `JarvisCoreTests`; the target-add schedule for later milestones.
3. `native/scripts/build-app.sh` (release build → `native/dist/JARVIS.app` → sign with the
   stable identity from `~/jarvis/.signing/config`), `native/Resources/Info.plist`,
   `native/Resources/JARVIS.entitlements` (§3.3).
4. The bundle-coexistence convention for three bundles sharing `com.jarvis.assistant` (§3.4).
5. The mutual-exclusion guard: `InstanceLock` in Swift + the minimal additive patch to
   `jarvis.py` `main()` (§3.5).
6. Python-compat primitives every later milestone needs: `PyJSON` (order-preserving parse +
   byte-exact `json.dumps`), `AtomicFile`, `PyTime` (`strftime` subset, `isoformat`),
   `PyMath.round`, `StatePaths`, `JarvisClock` (§3.6).
7. `native/tools/golden.py` oracle harness + first fixtures (`pyjson`, `pytime`, `pyround`,
   `paths`) and the `readback` reverse-oracle mode (§3.7, §4).
8. `native/tools/parity_inventory.py` — regenerates/checks the PARITY inventory against the
   current `jarvis.py` (§3.8).
9. Logging (`JarvisLog`: `logs/jarvis.log` file sink + `os.Logger`) and the process layout /
   activation policy (§3.9), with a minimal `MenuBarExtra` (status + Quit) so the agent app
   is observable. `--version`, `--selftest`, `--permissions` headless modes.

**Explicitly out of M0:** any state *store* logic (personality/emotions/… are M1 — M0 only
provides the primitives), prompts, tools, brain, voice, HUD, chat window (M4), app icon
(`jarvis_icon.png` → `.icns` is deferred to M4/M13), ONNX Runtime linking (M10), Keychain
item creation for ElevenLabs (W7/M8 — M0 only confirms no entitlement is needed, §7),
making Python's own writes atomic (flagged §8, not done), any change to `~/jarvis-swift`.

### M15 — Parity audit & cutover. Goal
Prove parity row-by-row with evidence, publish a fair RAM comparison (a dissertation data
point), swap the LaunchAgent to the native bundle, re-grant only the TCC services that are
genuinely new, and keep a one-command rollback to Python.

**In scope (M15):** `native/tools/parity_audit.py`; the evidence format for every PARITY row;
`native/scripts/ram-bench.sh` + methodology (§3.10); `native/scripts/switch-impl.sh
{python|native|status}` (LaunchAgent swap + rollback, §3.11); TCC re-grant checklist (§7).

**Explicitly out of M15:** deleting or archiving Python JARVIS (`jarvis.py` stays the oracle
and the rollback target), deleting `~/jarvis-swift` or its bundle (user decision, §8),
`.pkg`/DMG packaging (`build_pkg.sh`, `build_dmg.sh` stay Python-only), Windows.

**Standing constraint for every executor of this plan:** Python voice JARVIS is stopped on
purpose. Do not `launchctl load/bootstrap/kickstart` it and do not run `jarvisctl start`
except inside the M15 steps that say so *and* after the user has said yes in this session.
## 2. Python reference

All `jarvis.py` line numbers are at git HEAD `68cd112` (5,762 lines). Re-check with
`grep -n` before relying on them if `jarvis.py` has changed (`git -C ~/jarvis log -1 -- jarvis.py`).

### 2.1 State paths and module-level state (what golden.py must sandbox / reset)

| function/constant | file:lines | behaviour in one line | notes |
|---|---|---|---|
| `HERE` | jarvis.py:68 | `os.path.dirname(os.path.abspath(__file__))` — repo root | Runtime paths are derived from it (3976, 4118, 2487) → golden.py reassigns `jarvis.HERE` too |
| `LOG_FILE` | jarvis.py:74 | `os.path.join(HERE, "logs", "jarvis.log")` | native file sink appends to the same file (§3.9) |
| `KB_FILE`, `HIST_FILE`, `CORR_FILE`, `CHANGELOG_FILE` | jarvis.py:99-102 | `knowledge.json`, `history.json`, `corrections.json`, `CHANGELOG.md` under HERE | |
| `PROFILE_FILE` | jarvis.py:2048 | `profile.json` | file does not exist yet on this machine (created on demand) |
| `PERSONALITY_FILE` | jarvis.py:2133 | `personality.json` | path is embedded in prompt text at runtime (2236) |
| `EMOTIONS_FILE` | jarvis.py:2292 | `emotions.json` | |
| `RESEARCH_DIR`, `RESEARCH_METRICS`, `RESEARCH_USAGE` | jarvis.py:2438-2440 | `research/`, `research/metrics.jsonl`, `research/usage.json` | the sacred dataset |
| `PROACTIVE_FILE` | jarvis.py:2525 | `proactive.json` | does not exist yet on this machine |
| `ALARMS_FILE` | jarvis.py:3987 | `alarms.json` | |
| `VOICEPRINT_FILE` | jarvis.py:5134 | `voiceprint.npy` (NumPy .npy, 1,152 bytes here) | binary; M10 owns the format |
| `jarvis_notes.txt` | jarvis.py:3976 | `open(os.path.join(HERE, "jarvis_notes.txt"), "a", encoding="utf-8")` fallback notes file | **missing from PARITY.md state table** |
| `audd_key.txt` | jarvis.py:4118 | `open(os.path.join(HERE, "audd_key.txt"))` AudD token | **missing from PARITY.md**; secret — never read by tests |
| `SYSTEM_PROMPT` (changelog clause) | jarvis.py:158 | `f"call read_file with path {CHANGELOG_FILE} — never answer from memory or "` | evaluated **at import**: reassigning `CHANGELOG_FILE` afterwards does not change it → fixtures need path tokens (§3.7) |
| personality prompt clause | jarvis.py:2236 | `out += (f" Your personality lives in {PERSONALITY_FILE} and is YOURS to author: "` | evaluated at call time → shows the sandbox path |
| `_corr_cache = None` | jarvis.py:821 | corrections cache | golden.py resets to `None` per case |
| `_history = _history_load()` | jarvis.py:4675 | **reads the real `history.json` at import** | golden.py must reset `jarvis._history = []` (or sandbox-load) before any suite |
| `ANTHROPIC_API_KEY` pop | jarvis.py:4835 | `if os.environ.pop("ANTHROPIC_API_KEY", None) is not None:` — at import | import side effect on the golden.py process env only; harmless |
| env-derived constants | jarvis.py (28 module-level `os.environ.get` assignments, e.g. 77-78, 82-83, 88-96) | read **at import** | golden.py runs `jarvis` import in a scrubbed env (§3.7) so defaults are what gets captured |

### 2.2 Serialisation (the byte-compat contract native must meet)

Python never writes atomically: every site is `open(path, "w")` + `json.dump(...)` (truncate in
place). No file ends with a newline (checked: `tail -c1` of history/emotions/personality/usage
is `]`/`}`). Default `ensure_ascii=True` everywhere.

| function/constant | file:lines | behaviour in one line | notes |
|---|---|---|---|
| `_corrections_save` | jarvis.py:834-841 | `json.dump(_corr_cache, f, indent=1)`, capped `pairs[-200:]` | indent=1 → item sep `","`, key sep `": "` |
| `kb_save` | jarvis.py:1999-2002 | `with open(KB_FILE, "w") as f: json.dump(kb, f, indent=1)` | |
| `profile_save` | jarvis.py:2057-2060 | `json.dump(p, f, indent=1)` | |
| `personality_save` | jarvis.py:2177-2182 | `json.dump(p, f, indent=1)` | |
| `_emotions_save` | jarvis.py:2315-2320 | `json.dump(e, f, indent=1)` | |
| `research_bump` | jarvis.py:2443-2456 | `u.setdefault(day, {})[key] = u.get(day, {}).get(key, 0) + n` then `json.dump(u, f, indent=1)`; day = `time.strftime("%Y-%m-%d")` (2446) | under `_research_lock` (2441) |
| `research_snapshot` | jarvis.py:2476-2514 | appends `json.dumps(snap) + "\n"` to metrics.jsonl (2511); `"code": {"bytes": os.path.getsize(me), "lines": code_lines, ...}` with `me = os.path.join(HERE, "jarvis.py")` (2487); `"emotions": {k: round(v, 3) ...}` | default separators `", "`/`": "`; **meaning of `code.*` for native is an open question (§8)** |
| `_research_last_date` | jarvis.py:2516-2523 | reads the last 8,192 bytes of metrics.jsonl, returns last line's `date` | native must use the same rule so a switch never produces two snapshots for one day |
| proactive state | jarvis.py:2545-2546 | `json.dump(st, f)` (no indent) | |
| `_alarms_save` | jarvis.py:3994-3997 | `with open(ALARMS_FILE, "w") as f: json.dump(a, f)` | no indent; entries `{"time": dt.isoformat(), "label": ...}` (2947, 4059) |
| `_history_save` | jarvis.py:4668-4673 | `json.dump(_history[-12:], f)` | no indent |

### 2.3 Time (what the shim must cover)

| function/constant | file:lines | behaviour in one line | notes |
|---|---|---|---|
| `from datetime import datetime, timedelta` | jarvis.py:26 | module-level name `datetime` | shim by `jarvis.datetime = FrozenDateTime` (verified: subclass `now()` patch works, arithmetic stays in subclass) |
| `datetime.now()` | 16 call sites, e.g. 544, 1280, 2903, 3090, 3426, 4097, 5538, 5723 | wall clock | |
| `time.time()` | 38 call sites | epoch | |
| `time.strftime(...)` | jarvis.py:2446, 2479, 2540-2541, 2566 | `"%Y-%m-%d"`, `"%H"` from the real local clock | shim must implement `strftime(fmt, t=None)` from the shim epoch |
| `time.sleep` | 18 call sites | | shim advances the fake clock, never sleeps |
| strftime directives used anywhere | grep of all format strings | `%A %B %H %I %M %S %Y %d %m %p`; formats `"It is %I:%M %p on %A, %B %d."` (1280), `"%Y-%m-%d at %H.%M.%S"` (3426), `'%I:%M %p'` + `.lstrip('0')` (3098), `f"{datetime.now():%Y-%m-%d %H:%M}"` (3977) | the `pytime` golden suite covers exactly this set |
| `isoformat` / `fromisoformat` | jarvis.py:2947, 3857, 4028-4029, 4039-4042, 4059, 4087, 4100, 4105 | naive local ISO strings as alarm keys | `pytime` suite covers naive isoformat incl. microseconds |

### 2.4 Process, logging, activation policy

| function/constant | file:lines | behaviour in one line | notes |
|---|---|---|---|
| `_Tee` | jarvis.py:493-502 | writes every chunk to all streams, swallowing per-stream errors | |
| `install_logging` | jarvis.py:504-515 | `open(LOG_FILE, "a", buffering=1, encoding="utf-8", errors="replace")`; tees `sys.stdout`/`sys.stderr` to it | under the LaunchAgent stdout is `logs/jarvis.boot.log`, so Python writes every line twice (boot.log is 935 KB vs jarvis.log 697 KB) |
| `log` | jarvis.py:517 | `def log(msg): print(f"[JARVIS] {msg}")` — no timestamp | |
| start banner | jarvis.py:5723 | `print(f"\n===== JARVIS starting {datetime.now():%Y-%m-%d %H:%M:%S} =====")` | native prints `===== JARVIS (native) starting … =====` so eras are distinguishable in the shared log |
| `main` | jarvis.py:5721-5758 | `install_logging()` → banner → HUD via `webview.start(_boot)` or headless `run_assistant(Hud(None))` | **the lock patch goes between 5722 and 5723** (§3.5) |
| `run_assistant` start | jarvis.py:5441-5486 | keep-awake `caffeinate -i -w <pid>` (5448-5459), `ensure_ollama()`, `build_app_index()`, 7 daemon threads (5466-5472) | first state reads/writes happen here → lock must be held before `run_assistant` |
| `_apply_overlay_main` | jarvis.py:5357-5401 | on the MAIN thread: `NSApplication.sharedApplication().setActivationPolicy_(1)  # Accessory: no Dock icon` (5367) + overlay styling | |
| `style_overlay_window` | jarvis.py:5424-5437 | `AppHelper.callAfter(_apply_overlay_main)` and again `AppHelper.callLater(1.5, _apply_overlay_main)` "in case pywebview re-asserts Regular policy on first paint" | the hard-won lesson: set on main thread, and re-assert after the first window appears |
| py2app bundle Info.plist | `~/jarvis/dist/JARVIS.app/Contents/Info.plist` (from `~/jarvis/setup.py`) | `CFBundleIdentifier com.jarvis.assistant`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSCalendarsFullAccessUsageDescription`, `NSCalendarsUsageDescription`; **no `LSUIElement`, no `NSAppleEventsUsageDescription`** | alias-mode build (`PyOptions.alias = true`): it runs the live `jarvis.py`, so the lock patch takes effect without rebuilding |

### 2.5 Install, signing, LaunchAgent, control

| function/constant | file:lines | behaviour in one line | notes |
|---|---|---|---|
| `setup-signing.sh` | ~/jarvis/setup-signing.sh:30 (`CONFIG="$CONFIG_DIR/config"`) | creates a self-signed identity once in a dedicated keychain; writes `KEYCHAIN`, `KEYCHAIN_PASSWORD`, `IDENTITY` (SHA-1) to `.signing/config` | **never print that file**. `IDENTITY` is the leaf-cert SHA-1, which is exactly the `H"…"` in the designated requirement → printing the DR prints `IDENTITY` |
| install.sh signing | ~/jarvis/install.sh:57-63 | `source .signing/config`; `security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"`; `codesign --force --deep --sign "$IDENTITY" --keychain "$KEYCHAIN" dist/JARVIS.app` | no hardened runtime |
| install.sh LaunchAgent | ~/jarvis/install.sh:90-112 | writes `~/Library/LaunchAgents/com.jarvis.assistant.plist`; `launchctl unload` + `load` | template lacks the user's later env edits |
| installed LaunchAgent | ~/Library/LaunchAgents/com.jarvis.assistant.plist | Label `com.jarvis.assistant`; ProgramArguments = `~/jarvis/dist/JARVIS.app/Contents/MacOS/JARVIS` (direct exec); env `JARVIS_STT=whisper`, `JARVIS_WHISPER=small.en`, `LANG`/`LC_ALL=en_US.UTF-8`, `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `PYTHONUNBUFFERED=1`; `RunAtLoad`, `KeepAlive`, `ThrottleInterval 10`; stdout/err → `logs/jarvis.boot.log`/`.err` | currently **not loaded** (`launchctl print gui/501/com.jarvis.assistant` → "Could not find service") |
| `jarvisctl` | ~/jarvis/jarvisctl:1-26 | `start`/`stop`/`restart` via `launchctl load/unload`; `status` = `launchctl list` + `tail -1 logs/jarvis.log`; `test` execs the bundle binary in the terminal | `status`/`logs` read `logs/jarvis.log` → native writing the same file keeps them working |
| prototype build | ~/jarvis-swift/build.sh:22-53 | `swift build -c release … -Xlinker -rpath -Xlinker @executable_path/../Frameworks` (23-25); copy ORT dylib to `Contents/Frameworks/libonnxruntime.1.dylib` (41); sign dylib (45) then app with entitlements (47); prints DR (53) | salvage pattern, **but** (a) it sources `~/jarvis-swift/.signing/config`, whose `IDENTITY` differs from `~/jarvis/.signing/config` (same keychain) — verified: the two bundles' DRs differ; (b) line 53 prints the DR, i.e. the identity hash |
| prototype Info.plist | ~/jarvis-swift/Resources/Info.plist:1-34 | `LSUIElement true`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSAppleEventsUsageDescription`, `LSMinimumSystemVersion 14.0` | |
| prototype entitlements | ~/jarvis-swift/Resources/jarvis.entitlements:1-16 | `com.apple.security.app-sandbox` false, `device.audio-input` true, `automation.apple-events` true; comment: no hardened runtime because library validation would reject the self-signed ORT dylib | |
| prototype jarvisctl | ~/jarvis-swift/jarvisctl | dev label `com.jarvis.assistant.swift-dev`; its PATH `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` **lacks `/usr/sbin:/sbin`** (`ioreg`, `networksetup`, `scutil`, `system_profiler`, `ifconfig`, `ping` live there) | the bug the native LaunchAgent must not repeat |
| ORT dylib | ~/jarvis-swift/Resources/libonnxruntime.1.26.0.dylib | 28,800,472 bytes, ad-hoc linker-signed, install name `@rpath/libonnxruntime.1.dylib`, sha256 `f175df60b5ef3dffb825af963f4ea44cd9d24b8cbbb6ceba678453c816597242` | not committed anywhere; M10 vendors it (§3.2) |
## 3. Swift design

### 3.1 Critical review of ROADMAP.md, PARITY.md, Package.swift (applied in task T0.1)

Each item: the defect, then the exact replacement. "Old" strings are verbatim from the
files as they are now (uncommitted, 2026-09-28); the executor replaces old → new exactly.

**ROADMAP.md**

- **R1 — rule 3 predates "dev builds share real state"** and omits the mutual-exclusion
  guard, test sandboxing, and the fact that Python itself does not write atomically.
  Old (lines 36-38):
  ```
  3. **State files are shared, byte-compatible.** Native JARVIS reads and writes the same
     JSON files in the repo root as Python JARVIS (`personality.json`, `emotions.json`, …),
     with atomic writes. Either implementation must be able to pick up where the other left off.
  ```
  New:
  ```
  3. **State is shared, byte-compatible and single-writer.** Every native build — dev included —
     is bundle id `com.jarvis.assistant`, signed with the stable identity in
     `~/jarvis/.signing/config`, and reads/writes the REAL state files in the repo root and the
     real dataset; there is no separate dev state. Therefore: (a) every write is byte-identical
     to Python's `json.dump` of the same value (indent/separators/`ensure_ascii`/float repr/key
     order, no trailing newline) and atomic (temp file in the same directory + `rename(2)`);
     (b) Python and native JARVIS never run at the same time — both hold an exclusive `flock`
     on `~/jarvis/.jarvis.lock` for their whole life, and native also refuses to start while a
     lock-less Python JARVIS process is alive; (c) unit tests only ever touch temp-dir
     sandboxes (`JarvisTestSupport.Sandbox`) and `StatePaths.live()` throws outside the signed
     app bundle; (d) Python must be able to load everything native writes (`golden.py
     readback`). Either implementation can then pick up where the other left off.
  ```
- **R2 — rule 5 over-restricts and under-specifies the interpreter** (orchestrator correction).
  Old (lines 41-43):
  ```
  5. **No new package installs** without the user (org package routing is not configured).
     Everything here uses the Apple SDK, the salvaged ONNX Runtime dylib, and the Python
     already installed (for the oracle and one-off model export only).
  ```
  New:
  ```
  5. **Installs need the user.** Package managers governed by the org's JFrog routing (npm,
     PyPI/pip, Maven, Gradle, Go, Docker, Helm, NuGet) are blocked until that routing is
     configured. Any other install (Homebrew, remote SwiftPM dependencies, downloaded
     binaries — e.g. `brew install espeak-ng`) needs the user's explicit approval in the
     session; never assume it. The plan itself uses only the Apple SDK, the salvaged ONNX
     Runtime dylib, and the installed Python — specifically
     `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3` (Homebrew's `python3`
     lacks JARVIS's deps) — for the oracle and one-off model export only.
  ```
- **R3 — TTS row is wrong** (orchestrator correction; confirmed in source: `get_piper()`,
  jarvis.py:653-664, does `from piper import PiperVoice` in-process). Old (line 23):
  ```
  | Piper (subprocess)        | Piper (subprocess, kept — system en-GB voices are default-quality only) | M8 |
  ```
  New:
  ```
  | Piper (`piper-tts` 1.4.2, in-process; espeak-ng inside `piper/espeakbridge.so`; 356 MB peak RSS, 1.3 s load, 0.25 s/sentence — orchestrator-measured) | ElevenLabs streaming TTS over HTTPS (API key in the login Keychain) primary, Piper as the offline/failure fallback — mechanism per the M8 plan | M8 |
  ```
  And M8 (line 97). Old: `- **M8 — Voice out.** Piper + native pitch/tempo, sentence streaming, `say` fallback.`
  New: `- **M8 — Voice out.** ElevenLabs streaming TTS (key in Keychain) primary; Piper fallback when offline or on ElevenLabs failure; native pitch/tempo where it applies; sentence streaming; `say` last resort.`
- **R4 — the FoundationModels RAM claim is the rigged comparison the M15 benchmark must
  avoid.** 21 MB is the *client's* RSS; inference runs in `TGOnDeviceInferenceProviderService`
  (seen running here, alongside `modelmanagerd`, `generativeexperiencesd`). Old (line 18) cell
  `2026-09-28 ✅ 5.3 s cold, 21 MB RSS` → New cell
  `2026-09-28 ✅ 5.3 s cold, 21 MB client RSS (inference daemon not counted — see M15)`.
- **R5 — rule 4 measures the wrong thing.** Old (line 40):
  `   system services. Measure RSS at every milestone that adds a subsystem (`PARITY.md` §RAM).`
  New:
  `   system services. At every milestone that adds a subsystem, measure phys_footprint (primary) and RSS (continuity) of the JARVIS process tree AND of the system daemons it wakes (`PARITY.md` §RAM, method in `plan/M00-foundation-and-M15-cutover.md` §3.10).`
- **R6 — layout block is incomplete.** Replace the whole fenced block under
  `## Layout (`native/`)` (lines 50-64) with:
  ```
  Package.swift
  Resources/        Info.plist, JARVIS.entitlements                     (copied into the bundle)
  Sources/
    JarvisCore/     state primitives (PyJSON, AtomicFile, PyTime, StatePaths, InstanceLock,
                    JarvisLog), then persona, emotions, profile, KB, corrections, prompt builder,
                    research logger, security guards, fast-path router      (Foundation only)
    JarvisBrain/    Claude CLI driver, MCP tool server (Unix socket), FoundationModels fallback  (M3)
    JarvisTools/    the 46 tools (EventKit, Vision, ScreenCaptureKit, Contacts, AppKit services) (M5)
    JarvisVoice/    mic (AVAudioEngine + voice processing/AEC), STT, TTS, wake word, speaker ID   (M8)
    COnnxRuntime/   system-library module over the ORT C API headers                            (M10)
    JarvisApp/      the app: menu bar, chat window, HUD, loops, lifecycle   (SwiftUI/AppKit)
  Tests/
    JarvisTestSupport/  Sandbox + golden-fixture loader (a regular target, Foundation only)
    JarvisCoreTests/ …  (one test target per source target)
    Fixtures/golden/    <suite>.golden.json produced by tools/golden.py from the Python oracle
  tools/golden.py            Python oracle → golden fixtures; `readback` checks native-written files
  tools/parity_inventory.py  regenerates / checks the PARITY.md inventory against jarvis.py
  tools/parity_audit.py      M15: fails unless every PARITY row has valid evidence
  scripts/build-app.sh       swift build → dist/JARVIS.app → sign with ~/jarvis/.signing/config
  scripts/switch-impl.sh     M15: LaunchAgent → python | native | status (one-command rollback)
  scripts/ram-bench.sh       M15: phys_footprint/RSS sampler for the RAM comparison
  plan/                      executor plans (this directory)
  dist/                      build output (gitignored by the repo's `dist/` rule)
  ```
- **R7 — M0 line omits most of M0.** Old (lines 71-72):
  ```
  - **M0 — Foundation.** Roadmap, parity checklist, package scaffold, Python oracle harness,
    first golden fixtures, `swift build` + `swift test` green.
  ```
  New:
  ```
  - **M0 — Foundation.** Roadmap, parity checklist (+ generator), package scaffold, signed
    bundle build (stable identity from `~/jarvis/.signing/config`, never jarvis-swift's),
    single-instance guard in both implementations (additive `jarvis.py` patch), Python-compat
    primitives (PyJSON, AtomicFile, PyTime, PyMath.round), logging, accessory activation
    policy, Python oracle harness + first golden fixtures, `swift build` + `swift test` green.
  ```
- **R8 — M15 line omits rollback and the honest-measurement rule.** Old (lines 110-111):
  ```
  - **M15 — Parity audit & cutover.** Every `PARITY.md` row ticked with evidence; RAM
    benchmark vs Python (a dissertation data point); LaunchAgent swap; TCC re-grant.
  ```
  New:
  ```
  - **M15 — Parity audit & cutover.** Every `PARITY.md` row ticked with evidence
    (`tools/parity_audit.py` green); RAM benchmark vs Python — phys_footprint of each whole
    process tree plus the system daemons each leans on (a dissertation data point; running
    Python and Ollama for it needs the user's go-ahead); LaunchAgent swap; TCC re-grant of
    only the genuinely new services; one-command rollback (`scripts/switch-impl.sh python`).
  ```
- **R9 — no rule about fixture file names vs `.gitignore`.** The repo `.gitignore` ignores
  `personality.json`, `knowledge.json`, `history.json`, `emotions.json`, `proactive.json`,
  `alarms.json`, `corrections.json`, `profile.json` at **any depth**, plus `*_config.json`,
  `*key*.txt`, `*.wav`, `research/`, `logs/`, `build/`, `dist/` (verified with
  `git check-ignore -v`: `native/Tests/Fixtures/golden/personality.json`,
  `…/emotions_config.json` and `…/audio/wake.wav` are all ignored). `native/.build/` is **not**
  ignored. Append to rule 1 (after "…proves nothing."):
  ` Fixtures are named `<suite>.golden.json`; never name a fixture after a state file, and audio fixtures (M10/M11) need an explicit `.gitignore` negation.`

**PARITY.md**

- **P1 — state table misses files.** After the row `| ☐ | `research/usage.json` | dataset — per-day counters | |` (line 110) add:
  ```
  | ☐ | `jarvis_notes.txt` | fallback notes file, jarvis.py:3976 (append, UTF-8) | |
  | ☐ | `audd_key.txt` | AudD token (secret; `AUDD_API_KEY` alternative), jarvis.py:4118 | |
  | ☐ | `logs/jarvis.log` | `LOG_FILE` — shared human log, same `[JARVIS] …` line format | |
  | ☐ | `.jarvis.lock` | single-instance lock (new, both implementations) | |
  | ☐ | `voices/en_GB-alan-medium.onnx` (+`.json`) | `PIPER_MODEL`/`PIPER_CONFIG` — Piper fallback asset | |
  ```
- **P2 — settings table lacks native-only additions and secrets.** After the
  `JARVIS_WHISPER_PROMPT` row add:
  ```
  | ☐ | `JARVIS_HOME` | native-only, additive: state-root override (LaunchAgent sets it) | |
  ```
  and add a new table after the settings table:
  ```
  ## Secrets & auth (never in env files, never logged)

  | ✓ | Secret | Where | Evidence |
  |---|---|---|---|
  | ☐ | Claude subscription OAuth | `claude` CLI's own store; `ANTHROPIC_API_KEY` stripped from the child env (jarvis.py:4835) | |
  | ☐ | AudD token | `audd_key.txt` or `AUDD_API_KEY` | |
  | ☐ | ElevenLabs API key | login Keychain generic password (M8 plan) | |
  | ☐ | Signing identity | `~/jarvis/.signing/config` (`KEYCHAIN`, `KEYCHAIN_PASSWORD`, `IDENTITY`) — build only | |
  ```
- **P3 — rows that can never be ticked as written.** Replace
  `| ☐ | 583 | Windows platform helpers | |` with `| ☐ | 583 | Windows platform helpers | N/A — Windows not ported (needs user sign-off) |`;
  `| ☐ | 4656 | Ollama brain | |` with `| ☐ | 4656 | Ollama brain → FoundationModels fallback (M3) | |`;
  `| ☐ | 5323 | HUD wrapper | |` with `| ☐ | 5323 | HUD wrapper → native NSPanel (M13) | |`.
- **P4 — the RAM table measures RSS only**, which hides compressed memory and every daemon.
  Replace the table under `## RAM (measured, not estimated)` with:
  ```
  Method: `plan/M00-foundation-and-M15-cutover.md` §3.10. Footprint = phys_footprint (MB), median of samples.

  | Configuration | Py own | Py tree+helpers | Py daemons | Native own | Native tree+helpers | Native daemons | Py RSS | Native RSS | Sys delta Py / Native | Date |
  |---|---|---|---|---|---|---|---|---|---|---|
  | Idle, listening for wake word | | | | | | | | | | |
  | Mid-conversation (Claude backend) | | | | | | | | | | |
  | Offline fallback answering | | | | | | | | | | |
  | Text chat only, window open | | | | | | | | | | |
  ```
- **P5 — "Generated … so nothing is omitted by hand" but no generator is committed.** Old
  (lines 3-4 first sentence) `Generated from `jarvis.py` @ `68cd112` by reading `TOOLS`, `os.environ.get`, `*_FILE` and`
  `the `# ───` section banners, so nothing is omitted by hand.` → New:
  `Generated from `jarvis.py` @ `68cd112` by `tools/parity_inventory.py` (reads `TOOLS`, `os.environ.get`, `*_FILE`, `os.path.join(HERE, "…")` literals and the `# ───` section banners); `tools/parity_inventory.py --check` fails if jarvis.py has grown anything this file lacks.`
- **P6 — behaviour checklist misses two cross-implementation behaviours.** Append to
  `## Behaviours not visible in the tool list`:
  ```
  - [ ] Single-instance guard: native and Python never run together (`.jarvis.lock` + process check)
  - [ ] Daily research snapshot never duplicated across an implementation switch (`_research_last_date` rule, jarvis.py:2516)
  - [ ] Activation policy is Accessory (no Dock icon) from launch, re-asserted after the first window
  ```

**Package.swift**

- **S1 — the header comment's rule is unworkable.** JarvisTools needs AppKit *services*
  (`NSWorkspace` for find_apps/open, `NSPasteboard` for clipboard, `NSRunningApplication`).
  Old (lines 2-3):
  ```
  // Native JARVIS — see ROADMAP.md. Targets are added as their milestone lands; every
  // target except JarvisApp stays free of AppKit/SwiftUI so it can be unit-tested headless.
  ```
  New:
  ```
  // Native JARVIS — see ROADMAP.md. Targets are added as their milestone lands. JarvisCore is
  // Foundation-only; JarvisBrain and JarvisVoice never import AppKit/SwiftUI; JarvisTools may
  // use AppKit services (NSWorkspace, NSPasteboard) but never SwiftUI or the app lifecycle.
  // Only JarvisApp owns UI and the run loop, so everything else is unit-testable headless.
  ```
- **S2 — no shared test-support target** (fixture loader + sandbox would be copied into every
  test target). Add `JarvisTestSupport` (§3.2).
- **S3 — declared targets have no source directories**, so `swift build` fails today
  ("target 'JarvisCore' … has no sources" class of error — not run here, `swift build` is
  off-limits for planning). T0.3 creates them. No other change: tools-version 6.2 already
  implies Swift 6 language mode (strict concurrency) and `.macOS("26.0")` is valid.
### 3.2 Package layout and target schedule

M0 `native/Package.swift` (complete file after T0.3):
```swift
// swift-tools-version: 6.2
// <S1 header comment from §3.1>
import PackageDescription

let package = Package(
    name: "JARVIS",
    platforms: [
        .macOS("26.0")   // SpeechAnalyzer, FoundationModels
    ],
    products: [
        .executable(name: "JARVIS", targets: ["JarvisApp"]),
    ],
    targets: [
        // State primitives + (from M1) persona, emotions, prompt, dataset, security, routing.
        .target(name: "JarvisCore"),

        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore"]
        ),

        // Sandbox + golden-fixture loader shared by every test target. Foundation only —
        // it must NOT import Testing (Testing.framework is only on the test targets' search path).
        .target(
            name: "JarvisTestSupport",
            dependencies: ["JarvisCore"],
            path: "Tests/JarvisTestSupport"
        ),

        // Golden fixtures live in Tests/Fixtures and are located via #filePath, not
        // bundled as resources — they are produced by tools/golden.py from Python JARVIS.
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore", "JarvisTestSupport"]
        ),
    ]
)
```

Target schedule (dependency direction is strictly App → {Brain, Tools, Voice} → Core; Brain
never imports Tools — the tool registry protocol lives in Core and App wires them):

| Target | Kind | Added in | Depends on | Apple frameworks | Test target |
|---|---|---|---|---|---|
| `JarvisCore` | target | M0 | — | Foundation, os (Logger), Synchronization | `JarvisCoreTests` (M0) |
| `JarvisApp` | executableTarget (product `JARVIS`) | M0 | Core (+ Brain/Tools/Voice as they land) | SwiftUI, AppKit | — (logic lives below it) |
| `JarvisTestSupport` | target at `Tests/JarvisTestSupport` | M0 | Core | Foundation | — |
| `JarvisBrain` | target | M3 | Core | Foundation, FoundationModels | `JarvisBrainTests` (M3) |
| `JarvisTools` | target | M5 (extended M6) | Core | AppKit services, EventKit, Contacts, Vision, ScreenCaptureKit, CoreWLAN, IOKit | `JarvisToolsTests` (M5) |
| `JarvisVoice` | target | M8 (TTS), extended M9–M12 | Core; + `COnnxRuntime` from M10 | AVFoundation, Speech (M9) | `JarvisVoiceTests` (M8) |
| `COnnxRuntime` | `.systemLibrary(name: "COnnxRuntime", path: "Sources/COnnxRuntime/include")` | M10 (first ONNX consumer: speaker verification) | — | — | via `JarvisVoiceTests` |

ONNX Runtime convention (fixed now so M10/M11 don't reinvent it): headers + `module.modulemap`
are copied once from `~/jarvis-swift/Sources/COnnxRuntime/include/` into
`native/Sources/COnnxRuntime/include/` and committed (small text). The 28.8 MB dylib is **not**
committed: `native/scripts/vendor-ort.sh` (M10) copies
`~/jarvis-swift/Resources/libonnxruntime.1.26.0.dylib` to `native/Vendor/onnxruntime/lib/`
(gitignored) after checking the sha256 in §2.5, so native stops depending on the archived
prototype's tree. Linking: `-Xlinker -L native/Vendor/onnxruntime/lib` passed by
`build-app.sh` and by a `native/scripts/test.sh` wrapper (never an absolute path in
`Package.swift` — the pre-commit hook would block it).

### 3.3 Bundle build: `native/scripts/build-app.sh`, Info.plist, entitlements

`native/scripts/build-app.sh` (bash, `set -euo pipefail`), modelled on
`~/jarvis-swift/build.sh:22-53` with four deliberate differences (marked ◆):

```
NATIVE="$(cd "$(dirname "$0")/.." && pwd)"; REPO="$(cd "$NATIVE/.." && pwd)"
CONFIG="$REPO/.signing/config"                      # ◆ the PYTHON app's identity, never ~/jarvis-swift/.signing
[[ -f "$CONFIG" ]] || { echo "error: $CONFIG missing — run $REPO/setup-signing.sh once" >&2; exit 1; }
set +x; source "$CONFIG"                            # defines KEYCHAIN, KEYCHAIN_PASSWORD, IDENTITY — never echo them
JOBS="${JOBS:-2}"                                   # ◆ 8 GB machine: cap compiler parallelism
swift build -c release --package-path "$NATIVE" --product JARVIS -j "$JOBS" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    ${ORT_LIB:+-Xlinker -L"$ORT_LIB"}               # ORT_LIB set only from M10
BIN="$(swift build -c release --package-path "$NATIVE" --show-bin-path)/JARVIS"
STAGE="$NATIVE/dist/.JARVIS.app.staging"; APP="$NATIVE/dist/JARVIS.app"
rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$BIN" "$STAGE/Contents/MacOS/JARVIS"
cp "$NATIVE/Resources/Info.plist" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$REPO" rev-list --count HEAD)" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
if otool -L "$BIN" | grep -q libonnxruntime; then   # only once M10 links ORT
    cp "$ORT_LIB/libonnxruntime.1.26.0.dylib" "$STAGE/Contents/Frameworks/libonnxruntime.1.dylib"
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
for d in "$STAGE"/Contents/Frameworks/*.dylib; do [[ -e "$d" ]] || continue
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$d"; done      # inner first, no --deep
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" \
    --entitlements "$NATIVE/Resources/JARVIS.entitlements" "$STAGE"
codesign --verify --strict --verbose=1 "$STAGE"
# ◆ TCC continuity check WITHOUT printing the DR (the DR's leaf hash IS $IDENTITY):
dr() { codesign -d -r- "$1" 2>&1 | grep '^designated' | shasum -a 256 | cut -c1-64; }
PY_APP="$REPO/dist/JARVIS.app"
if [[ -d "$PY_APP" ]]; then
    [[ "$(dr "$STAGE")" == "$(dr "$PY_APP")" ]] && echo "DR matches Python bundle: yes" \
        || { echo "error: DR differs from the Python bundle — TCC grants would split" >&2; exit 1; }
fi
rm -rf "$APP"; mv "$STAGE" "$APP"                   # ◆ swap only after a verified signature
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature size|TeamIdentifier)'   # no Authority/DR lines
echo "Built: $APP"
```

Rules: never `codesign -s -` (ad-hoc → new DR every build → TCC resets); never `--deep`;
never `--options runtime` (hardened runtime + library validation rejects the self-signed ORT
dylib — same reasoning as `~/jarvis-swift/Resources/jarvis.entitlements`); never print
`KEYCHAIN_PASSWORD`, `IDENTITY` or the DR. `set -x` must never be enabled in this script.

`native/Resources/Info.plist` — every key needed across ALL milestones, added once in M0 so
the bundle's Info.plist does not churn (usage strings are inert until an API asks):

| Key | Value | Needed by |
|---|---|---|
| `CFBundleIdentifier` | `com.jarvis.assistant` | shared TCC/state identity (decision) |
| `CFBundleName` / `CFBundleDisplayName` / `CFBundleExecutable` | `JARVIS` | |
| `CFBundlePackageType` / `CFBundleInfoDictionaryVersion` | `APPL` / `6.0` | |
| `CFBundleShortVersionString` | `2.0.0` (open question §8) | |
| `CFBundleVersion` | set by build-app.sh to `git rev-list --count HEAD` | monotonic |
| `LSMinimumSystemVersion` | `26.0` | matches `Package.swift` |
| `LSUIElement` | `true` | agent app from the first instant (plus the runtime policy call, §3.9) |
| `NSPrincipalClass` | `NSApplication` | |
| `NSHumanReadableCopyright` | `Local-first voice assistant. Runs on this Mac.` | |
| `NSMicrophoneUsageDescription` | `JARVIS listens for your voice commands so it can respond and control your Mac.` (Python's text) | M9 |
| `NSSpeechRecognitionUsageDescription` | `JARVIS transcribes your spoken commands.` (Python's text) | M9 (SpeechTranscriber; keep even if the new API turns out not to need it — unverified) |
| `NSAppleEventsUsageDescription` | `JARVIS controls other apps on your behalf when you ask it to.` (prototype text) | M5/M6 (Music, Messages, Mail, Notes, Reminders, Contacts, System Events, Safari/Chrome) — **absent from the Python bundle** |
| `NSCalendarsFullAccessUsageDescription` | `JARVIS reads and adds your calendar events when you ask (via EventKit).` (Python's text) | M6 get_calendar/create_event |
| `NSCalendarsUsageDescription` | `JARVIS reads and adds your calendar events when you ask.` (Python's text) | legacy key, harmless |
| `NSRemindersFullAccessUsageDescription` | `JARVIS adds reminders when you ask.` | M6 only if EventKit replaces Python's AppleScript to Reminders (jarvis.py:2955-2959) |
| `NSContactsUsageDescription` | `JARVIS looks up a contact's number or email when you ask.` | M6 only if Contacts.framework replaces AppleScript (jarvis.py:3153, 3181) |
| `NSDesktopFolderUsageDescription` / `NSDocumentsFolderUsageDescription` / `NSDownloadsFolderUsageDescription` | `JARVIS reads, moves and saves files there when you ask.` | M5 file tools; screenshots to ~/Desktop (jarvis.py:3427) |
| `NSRemovableVolumesUsageDescription` / `NSNetworkVolumesUsageDescription` | same text | M5 search/read beyond home |
| `NSLocationWhenInUseUsageDescription` | — **not added**: Python's get_location is IP-based ("via IP"); add only if M6 chooses CoreLocation | |
| `NSAppTransportSecurity` | — **not added**: all planned endpoints are HTTPS (BBC feed default jarvis.py:3279, ElevenLabs); the only `http://` in jarvis.py is Ollama at jarvis.py:76, which native drops. A user-set `http://` `JARVIS_NEWS_FEED` would be blocked by ATS — open question §8 | |

No usage key exists (grant is manual/system-prompted) for: Screen Recording (ScreenCaptureKit /
`screencapture`), Accessibility / PostEvent (CGEvent typing), Full Disk Access (Messages
`chat.db`), notifications (UNUserNotificationCenter authorization). See §7.

`native/Resources/JARVIS.entitlements` — copy of `~/jarvis-swift/Resources/jarvis.entitlements`
verbatim (app-sandbox false, `com.apple.security.device.audio-input` true,
`com.apple.security.automation.apple-events` true, comment kept). No keychain-access-groups,
no network entitlement: a non-sandboxed app uses the legacy file-based login keychain via
`SecItemAdd`/`SecItemCopyMatching` with `kSecClassGenericPassword` without entitlements, and has
unrestricted outbound network. **Do not set `kSecUseDataProtectionKeychain`** — the data
protection keychain needs an application-identifier entitlement, which a self-signed identity
without a provisioning profile cannot carry. The keychain item's ACL trusts the app by DR, so
the stable identity also keeps "Always Allow" valid across rebuilds (W7 owns item creation).

### 3.4 Three bundles, one bundle id — the coexistence convention

Verified on disk (`mdfind 'kMDItemCFBundleIdentifier == "com.jarvis.assistant"'`):
`~/jarvis/dist/JARVIS.app` (Python, py2app alias) and `~/jarvis-swift/dist/JARVIS.app`
(archived prototype). `~/jarvis/native/dist/JARVIS.app` will be the third. TCC keys grants on
client = bundle id **plus** the stored code requirement; LaunchServices resolves "the app for
`com.jarvis.assistant`" to one of the registered bundles (notification clicks, `open -b`,
`tell application id`, System Settings' privacy list).

Measured facts: the Python bundle and the native bundle (signed per §3.3) share the DR
`identifier "com.jarvis.assistant" and certificate leaf = H"<IDENTITY>"`. The prototype
bundle's DR **differs** (its `.signing/config` has the same `KEYCHAIN`/`KEYCHAIN_PASSWORD`
but a different `IDENTITY`). So:

1. Native and Python are one TCC client: grants made to either apply to both. Intended
   (shared-state decision) — but it also means **never run `tccutil reset … com.jarvis.assistant`**
   (it resets Python's grants too) and treat any TCC prompt for JARVIS as affecting both.
2. The prototype bundle is a hazard: if anything launches it and it requests a TCC service,
   TCC sees `com.jarvis.assistant` with a different requirement and may re-prompt / replace the
   stored requirement, silently breaking both real bundles. Mitigation without modifying the
   prototype: unregister it from LaunchServices,
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u ~/jarvis-swift/dist/JARVIS.app`
   (T0.2; ask the user first whether they would rather delete/rename that build artefact — §8).
3. Nothing ever launches JARVIS by bundle id or by name. Launch paths are: LaunchAgent
   direct-exec of an absolute `Contents/MacOS/JARVIS` path; dev GUI runs via
   `open -n ~/jarvis/native/dist/JARVIS.app` (LaunchServices launch → TCC attributes to JARVIS);
   headless flags (`--version`, `--selftest`) may be exec'd from a terminal because they touch
   no TCC service. Never exec the GUI app from Terminal: the terminal becomes the TCC
   "responsible process" and prompts/grants land on Terminal, not JARVIS.
4. After each build, `build-app.sh` does **not** call `lsregister -f` (so the dev build does not
   become LaunchServices' preferred JARVIS while Python is production). At cutover,
   `switch-impl.sh native` runs `lsregister -f` on the native bundle; `switch-impl.sh python`
   runs it on the Python bundle. Which bundle LaunchServices prefers is observable with
   `lsregister -dump | grep -B2 -A8 'identifier: *com.jarvis.assistant'` (heavy output, run once).

### 3.5 Mutual-exclusion guard (Python ⇄ native)

Mechanism: BSD `flock(LOCK_EX | LOCK_NB)` on `~/jarvis/.jarvis.lock`, held for the life of
the process. Chosen because the kernel drops the lock when the holder dies (no stale lock, no
PID-reuse bugs) and both languages have it (`fcntl.flock` / Darwin `flock(2)`). Lock file
content, rewritten by the holder after acquiring: one line `"<impl> <pid> <epoch>\n"` with
`impl ∈ {python, native}` (diagnostic only — correctness comes from the flock, not the text).

- The fd must not leak into children (a surviving `claude`/Piper child would keep the lock):
  native opens with `O_RDWR | O_CREAT | O_CLOEXEC`, mode `0600`; Python's `os.open` fds are
  non-inheritable by default (PEP 446) and `subprocess` closes fds.
- flock is per open-file-description, so two opens in one process conflict — this is what
  makes the lock unit-testable in-process.
- Belt and braces (native only): before taking the lock, `InstanceLock.foreignJarvisProcesses`
  scans `proc_listallpids` + `proc_pidpath` for `<root>/dist/JARVIS.app/Contents/MacOS/JARVIS`
  and `sysctl(KERN_PROCARGS2)` argv containing `<root>/jarvis.py`. Any hit while the lock is
  free means a pre-patch Python is running → refuse exactly as if the lock were held.
- Behaviour when held: launched by launchd (env `XPC_SERVICE_NAME == "com.jarvis.assistant"`)
  → log once `"[JARVIS] Another JARVIS (<holder>) holds .jarvis.lock — waiting."` and poll every
  5 s (avoids KeepAlive thrash; starts automatically when the other exits). Launched any other
  way → log the same line with `— exiting.` and exit status 75 (`EX_TEMPFAIL`).
- Order at startup: logging → lock → anything that reads/writes state. Headless
  `--version`/`--permissions` never take the lock; `--selftest` takes it only to report
  whether it is free (then releases) and never writes state.
- `.gitignore`: add `.jarvis.lock` (T0.1).

**Minimal additive `jarvis.py` patch** (T0.8). Insert a new function directly above
`def main():` (jarvis.py:5721) and one call between `install_logging()` (5722) and the banner
`print` (5723). Nothing else changes; on Windows it is a no-op.
```python
_instance_lock_fd = None

def acquire_instance_lock():
    """Single-instance guard shared with native JARVIS: both hold an flock on .jarvis.lock
    for their whole life, so the two never write the shared state files at the same time."""
    global _instance_lock_fd
    if IS_WIN:
        return
    import fcntl
    fd = os.open(os.path.join(HERE, ".jarvis.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    warned = False
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if not warned:
                log("Another JARVIS instance holds .jarvis.lock — waiting.")
                warned = True
            time.sleep(5)
    os.ftruncate(fd, 0)
    os.write(fd, f"python {os.getpid()} {int(time.time())}\n".encode())
    _instance_lock_fd = fd   # keep open (and locked) until the process exits
```
and in `main()`:
```python
def main():
    install_logging()
    acquire_instance_lock()
    print(f"\n===== JARVIS starting {datetime.now():%Y-%m-%d %H:%M:%S} =====")
```
Python always waits (it is only ever started by its LaunchAgent or `jarvisctl test`); that
keeps the patch to one behaviour. Because the py2app bundle is an alias build, this takes
effect on the next Python start without rebuilding. golden.py imports `jarvis` but never calls
`main()`, so it never takes the real lock (it runs fully sandboxed, §3.7).

### 3.6 JarvisCore primitives (M0) — files, types, signatures

All in `native/Sources/JarvisCore/Support/`. Everything is a value type or an immutable
`final class`, `Sendable`, nonisolated; nothing here touches the main actor.

**`StatePaths.swift`**
```swift
public struct StatePaths: Sendable, Equatable {
    public let root: URL
    public init(root: URL)                                  // no validation (tests, sandboxes)
    /// The real state root. Order: env JARVIS_HOME, else <bundle>/../../.. (native/dist/JARVIS.app → repo).
    /// Throws unless root/jarvis.py is a file and root/research is a directory, and throws
    /// .notInAppBundle unless bundle.bundleIdentifier == "com.jarvis.assistant" (tripwire:
    /// under `swift test` the main bundle is the test runner, so tests can never reach real state).
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                            bundle: Bundle = .main) throws -> StatePaths
    public var knowledge: URL { get }        // KB_FILE          knowledge.json
    public var history: URL { get }          // HIST_FILE        history.json
    public var corrections: URL { get }      // CORR_FILE        corrections.json
    public var changelog: URL { get }        // CHANGELOG_FILE   CHANGELOG.md
    public var profile: URL { get }          // PROFILE_FILE     profile.json
    public var personality: URL { get }      // PERSONALITY_FILE personality.json
    public var emotions: URL { get }         // EMOTIONS_FILE    emotions.json
    public var proactive: URL { get }        // PROACTIVE_FILE   proactive.json
    public var alarms: URL { get }           // ALARMS_FILE      alarms.json
    public var voiceprint: URL { get }       // VOICEPRINT_FILE  voiceprint.npy
    public var researchDir: URL { get }      // RESEARCH_DIR     research/
    public var researchMetrics: URL { get }  // RESEARCH_METRICS research/metrics.jsonl
    public var researchUsage: URL { get }    // RESEARCH_USAGE   research/usage.json
    public var notesFallback: URL { get }    // jarvis_notes.txt (jarvis.py:3976)
    public var auddKey: URL { get }          // audd_key.txt     (jarvis.py:4118)
    public var logFile: URL { get }          // LOG_FILE         logs/jarvis.log
    public var lockFile: URL { get }         // .jarvis.lock     (new)
    public var jarvisPy: URL { get }         // jarvis.py (research snapshot "code" block reads it)
}
public enum StatePathsError: Error, Sendable, Equatable {
    case notInAppBundle(bundleID: String?), notAJarvisRepo(URL)
}
```
The relative names are golden-tested against Python (`paths` suite) so a typo cannot slip in.

> **Integration D-1:** the normative type spec is M01 §3.1/§3.5 (JSONValue with Int64 + bigInt, loads(Data), ordered members). This section contributes the `ensureASCII:` option, DEL (0x7f) escaping, `AtomicFile.appendLine`, and the pyjson/pytime/pyround/paths golden suites.

**`PyJSON.swift`** — Swift's `JSONSerialization`/`JSONEncoder` cannot reproduce Python's key
order, float repr, or `\uXXXX` escaping, so state I/O goes through this:
```swift
public struct PyJSONObject: Sendable, Equatable, Sequence {   // insertion-ordered, like a Python dict
    public init(_ pairs: [(String, PyJSONValue)] = [])
    public subscript(key: String) -> PyJSONValue? { get set }  // set on an existing key keeps its position
    public var keys: [String] { get }
    public var count: Int { get }
    public mutating func removeValue(forKey: String) -> PyJSONValue?
}
public indirect enum PyJSONValue: Sendable, Equatable {
    case null, bool(Bool), int(Int), float(Double), string(String)
    case array([PyJSONValue]), object(PyJSONObject)
}
public enum PyJSONError: Error, Sendable, Equatable {
    case syntax(offset: Int, message: String), integerOverflow(String), loneSurrogate(offset: Int), bom
}
public enum PyJSON {
    /// json.loads: accepts NaN/Infinity/-Infinity, whitespace " \t\n\r"; duplicate keys keep the
    /// FIRST position and the LAST value (CPython dict semantics); "1.0" stays .float, "1" stays .int.
    public static func loads(_ text: String) throws(PyJSONError) -> PyJSONValue
    /// json.dumps with CPython defaults: indent nil → separators (", ", ": "); indent n → item
    /// separator "," + newline + n*depth spaces, key separator ": "; ensureASCII → \uXXXX
    /// lowercase hex, astral chars as surrogate pairs, DEL (0x7f) escaped; "/" never escaped;
    /// floats in repr() form (shortest round-trip digits; exponent form iff exp < -4 or >= 16,
    /// written e+16 / e-05; integral floats keep ".0"; NaN / Infinity / -Infinity).
    public static func dumps(_ value: PyJSONValue, indent: Int? = nil, ensureASCII: Bool = true,
                             sortKeys: Bool = false) -> String
}
```
`Int` overflow (Python ints are unbounded) throws `.integerOverflow` rather than silently
changing a value; lone-surrogate escapes (`"\ud800"`, legal in Python) throw `.loneSurrogate`
because a Swift `String` cannot hold them — both are logged and treated as "file unreadable,
do not overwrite" by callers (M1).

**`AtomicFile.swift`**
```swift
public enum AtomicFile {
    /// Temp file ".<name>.<pid>.<random>.tmp" in the SAME directory, fchmod to the existing
    /// file's mode (else 0o644), write all, fsync, rename(2) over the target. Never leaves a
    /// partial target; on error the temp file is unlinked and the old target is untouched.
    public static func write(_ data: Data, to url: URL) throws
    /// Python "a"-mode equivalent for metrics.jsonl / jarvis_notes.txt: open O_WRONLY|O_APPEND|
    /// O_CREAT|O_CLOEXEC, one write(2) of the whole line, close.
    public static func appendLine(_ line: String, to url: URL) throws
}
```
Consequence to note (not a bug): `rename` replaces the inode, so extended attributes on the
old file (several state files carry `@` xattrs) are dropped; Python's truncate-in-place kept them.

**`PyTime.swift`**
```swift
public protocol JarvisClock: Sendable { func now() -> Date; var timeZone: TimeZone { get } }
public struct SystemClock: JarvisClock { public init() }
public struct FixedClock: JarvisClock { public init(epoch: TimeInterval, timeZone: TimeZone) }
public enum PyTime {
    /// time.strftime / datetime.strftime for the directive set jarvis.py uses:
    /// %A %B %H %I %M %S %Y %d %m %p and %% (C/English names, zero-padded, %p = "AM"/"PM").
    /// Any other directive → precondition failure (so a new one cannot silently mis-render).
    public static func strftime(_ format: String, _ date: Date, timeZone: TimeZone) -> String
    /// Naive datetime.isoformat(): "YYYY-MM-DDTHH:MM:SS" plus ".ffffff" iff microseconds != 0.
    public static func isoformat(_ date: Date, timeZone: TimeZone) -> String
    public static func fromisoformat(_ s: String, timeZone: TimeZone) -> Date?
}
public enum PyMath {
    /// Python round(x, ndigits) for floats: correctly rounded from the exact binary value
    /// (round(2.675, 2) == 2.67, round(0.0125, 3) == 0.013), ties-to-even, keeps -0.0.
    public static func round(_ x: Double, _ ndigits: Int) -> Double
}
```

**`InstanceLock.swift`** (mechanism §3.5)
```swift
public enum LockHolder: Sendable, Equatable { case python(pid: Int32), native(pid: Int32), unknown(String) }
public final class InstanceLock: Sendable {       // immutable: holds the fd until process exit
    public let url: URL
    public enum Outcome: Sendable { case acquired(InstanceLock), held(by: LockHolder?), foreignProcess(pids: [Int32]) }
    public static func tryAcquire(at url: URL, repoRoot: URL, impl: String = "native") -> Outcome
    public static func acquireWaiting(at url: URL, repoRoot: URL, poll: Duration = .seconds(5),
                                      onFirstWait: @Sendable (LockHolder?) -> Void) async -> InstanceLock
    public static func readHolder(at url: URL) -> LockHolder?
    public static func foreignJarvisProcesses(repoRoot: URL) -> [Int32]
}
```

**`JarvisLog.swift`** (design §3.9)
```swift
public enum LogCategory: String, Sendable, CaseIterable { case app, lock, state, brain, tools, voice, research, security }
public enum JarvisLog {
    public static func configure(file: URL?, mirrorToStdout: Bool)   // once, before the lock
    public static func log(_ message: String, category: LogCategory = .app)   // file: "[JARVIS] <message>\n"
    public static func banner(clock: any JarvisClock)                 // "\n===== JARVIS (native) starting %Y-%m-%d %H:%M:%S ====="
}
```
Implementation: file sink is a `Mutex<Int32>` (Synchronization) around an
`O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC` fd, one `write(2)` per line (UTF-8, invalid scalars
replaced — Python's `errors="replace"`); `os.Logger(subsystem: "com.jarvis.assistant",
category: category.rawValue)` receives the same text with `privacy: .private` (transcripts and
tool output must not become public in the unified log; the gitignored file keeps full text,
as Python's does).

### 3.7 `native/tools/golden.py` — the oracle harness

Shebang `#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3`; refuses (exit 2,
message naming the right interpreter) if `sys.version_info[:2] != (3, 14)` or
`sys.executable` is not under `/Library/Frameworks/Python.framework/`. Repo root is
`Path(__file__).resolve().parents[2]`; no absolute home path appears in the script.

CLI:
```
golden.py list                         # suites and their fixture paths
golden.py <suite> [<suite> …] | all    # (re)generate fixtures
golden.py --check                      # exit 1 if any fixture's jarvis_py_sha256 != current jarvis.py
golden.py selftest                     # harness self-check (sandbox, clock, tripwire); writes nothing
golden.py readback <dir> <suite>       # load files that Swift tests wrote into <dir> with Python's own
                                       # loaders; exit 1 on any mismatch (reverse oracle, used from M1)
flags: --allow-dirty (see policy), --out <dir> (default native/Tests/Fixtures/golden)
```

Process model — every suite runs in a **fresh child interpreter** (`subprocess.run([sys.executable,
__file__, "--_child", suite, sandbox, epoch], env=clean_env)`) so import-time state
(`_history` at jarvis.py:4675, env-derived constants, `ANTHROPIC_API_KEY` pop) never leaks
between suites. `clean_env` = only `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`,
`LANG=en_US.UTF-8`, `LC_ALL=en_US.UTF-8`, `TZ=Europe/London`, plus the suite's own
`JARVIS_*` overrides when a suite is about env parsing. `time.tzset()` runs before import.

Sandbox, done in the child **immediately after `import jarvis`** and before any suite code:
```python
sb = Path(sandbox)                        # tempfile.mkdtemp(prefix="jarvis-golden-")
(sb / "research").mkdir(); (sb / "logs").mkdir()
shutil.copy2(REPO / "jarvis.py", sb / "jarvis.py")   # research_snapshot reads HERE/jarvis.py (2487)
J.HERE = str(sb)
for name, rel in {"LOG_FILE": "logs/jarvis.log", "KB_FILE": "knowledge.json",
                  "HIST_FILE": "history.json", "CORR_FILE": "corrections.json",
                  "CHANGELOG_FILE": "CHANGELOG.md", "PROFILE_FILE": "profile.json",
                  "PERSONALITY_FILE": "personality.json", "EMOTIONS_FILE": "emotions.json",
                  "PROACTIVE_FILE": "proactive.json", "ALARMS_FILE": "alarms.json",
                  "VOICEPRINT_FILE": "voiceprint.npy", "RESEARCH_DIR": "research",
                  "RESEARCH_METRICS": "research/metrics.jsonl",
                  "RESEARCH_USAGE": "research/usage.json"}.items():
    setattr(J, name, str(sb / rel))
J._history = []; J._corr_cache = None
```
The constant list is asserted against `sorted(n for n in dir(J) if n.endswith("_FILE") or
n.startswith("RESEARCH_"))` — verified today to be exactly `ALARMS_FILE, CHANGELOG_FILE,
CORR_FILE, EMOTIONS_FILE, HIST_FILE, KB_FILE, LOG_FILE, PERSONALITY_FILE, PROACTIVE_FILE,
PROFILE_FILE, RESEARCH_DIR, RESEARCH_METRICS, RESEARCH_USAGE, VOICEPRINT_FILE` — so a new
constant in jarvis.py fails the harness instead of writing real state.

Tripwire: before the first suite and after the last, the parent records `(size, mtime_ns,
sha256)` of every real state file, `research/*`, `logs/jarvis.log`, `.jarvis.lock`; any
difference → exit 3 `"REAL STATE TOUCHED: <relative path>"` (the fixtures are still discarded).

Deterministic clock (installed in the child before suite code):
```python
class ShimTime:                           # jarvis.time = ShimTime(epoch)
    def __init__(self, epoch): self.now = float(epoch)
    def time(self): return self.now
    def sleep(self, s): self.now += max(0.0, float(s))      # never really sleeps
    def localtime(self, t=None): return _time.localtime(self.now if t is None else t)
    def strftime(self, fmt, t=None): return _time.strftime(fmt, t if t is not None else _time.localtime(self.now))
    def monotonic(self): return self.now
    def __getattr__(self, n): return getattr(_time, n)     # everything else passes through
class FrozenDateTime(_dt.datetime):       # jarvis.datetime = FrozenDateTime
    @classmethod
    def now(cls, tz=None): return cls.fromtimestamp(SHIM.now, tz)
```
Default epoch `1790582400` (a fixed instant; its local rendering is recorded in the fixture's
`clock` block by golden.py itself, not hand-typed). Suites that care about day/DST boundaries
set their own epochs per case (§4). Suites must not call functions that start threads or
subprocesses (`threading.Timer`, `subprocess.run` with side effects); golden.py fails a suite
if `threading.active_count()` grew.

Path tokens: before a fixture is written, every string in it has the sandbox path, the real
repo root and `os.path.expanduser("~")` replaced (longest first) by `${JARVIS_HOME}`,
`${JARVIS_HOME}` and `${HOME}`. Swift tests apply the same substitution to their output
(sandbox root → `${JARVIS_HOME}`, `NSHomeDirectory()` → `${HOME}`) before comparing. This is
also what keeps `/Users/<name>/` out of committed fixtures (pre-commit hook). golden.py fails if
any fixture still matches `/Users/[A-Za-z0-9._-]+/`.

Fixture envelope (`native/Tests/Fixtures/golden/<suite>.golden.json`), written with
`json.dumps(obj, indent=1, ensure_ascii=False) + "\n"` so diffs are readable and runs are
byte-reproducible (no timestamps in the envelope):
```json
{
 "schema": 1,
 "suite": "pyjson",
 "generator": "native/tools/golden.py",
 "generated_from": {"jarvis_py_sha256": "<64 hex>", "git_head": "68cd112", "jarvis_py_dirty": false,
                    "python": "3.14.2"},
 "clock": {"epoch": 1790582400.0, "tz": "Europe/London", "local": "<strftime %Y-%m-%d %H:%M:%S>"},
 "cases": [
  {"name": "indent1-nested-unicode", "input": {...}, "expected": {...}}
 ]
}
```
`input`/`expected` are free-form JSON per suite. Anything byte- or order-sensitive is carried
as a string field ending `_text` (e.g. `"expected": {"dumps_text": "{\n \"a\": 1\n}"}`), because
the Swift loader parses the envelope with `JSONSerialization` (independent of `PyJSON`, so the
code under test never loads its own test vectors). Exceptions are `{"raises": "<ExcType>"}`.

Regeneration policy: fixtures are committed. They are regenerated only when `jarvis.py`
changes (or a suite's corpus changes), from a jarvis.py with no uncommitted changes —
golden.py refuses when `git diff --quiet -- jarvis.py` fails unless `--allow-dirty` (then
`jarvis_py_dirty: true` is recorded and the commit must not land until regenerated clean).
Every regeneration is a separate commit whose diff is reviewed; a changed `expected` is a
behaviour change in Python and must be named in the commit message. Swift tests do not call
Python; `golden.py --check` is the staleness gate (run it before `swift test` in CI-like checks).

Swift side (`native/Tests/JarvisTestSupport/`):
```swift
public enum GoldenJSON: Sendable, Equatable { case null, bool(Bool), number(Double), string(String),
                                              array([GoldenJSON]), object([String: GoldenJSON]) }
public struct GoldenCase: Sendable, CustomStringConvertible { public let name: String
    public let input: GoldenJSON; public let expected: GoldenJSON; public var description: String { name } }
public struct GoldenFixture: Sendable { public let suite: String; public let jarvisPySHA256: String
    public let clockEpoch: Double?; public let clockTZ: String?; public let cases: [GoldenCase] }
public enum Golden {
    /// Walks up from the calling test file (#filePath) to the "Tests" directory → Tests/Fixtures/golden.
    public static func fixturesDirectory(file: StaticString = #filePath) -> URL
    public static func load(_ suite: String, file: StaticString = #filePath) throws -> GoldenFixture
    /// Never throws: on a load failure returns one case named "LOAD FAILURE: <error>" whose
    /// expected is .null, so the parameterised test fails visibly instead of running zero cases.
    public static func cases(_ suite: String, file: StaticString = #filePath) -> [GoldenCase]
    public static func detokenize(_ s: String, sandbox: URL) -> String   // sandbox → ${JARVIS_HOME}, home → ${HOME}
}
public final class Sandbox: Sendable {   // FileManager.default.temporaryDirectory/jarvis-tests-<UUID>/
    public let root: URL; public let paths: StatePaths
    public init() throws                  // creates research/, logs/, and an empty jarvis.py marker
    public func write(_ relative: String, _ text: String) throws
    public func read(_ relative: String) throws -> String
    public func remove()                  // precondition: root is under temporaryDirectory
}
```
NSNumber → `GoldenJSON` distinguishes Bool via `CFGetTypeID(n) == CFBooleanGetTypeID()`.

Swift Testing conventions (all test targets): `import Testing` (never XCTest); one `@Suite` per
fixture suite; parameterised `@Test("<suite>: golden", arguments: Golden.cases("<suite>"))`
taking a `GoldenCase`; assertions with `#expect(actual == expected, "\(c.name)")`, `#require`
for preconditions; every test that needs files creates its own `Sandbox` and removes it in a
`defer`; no test reads `StatePaths.live()`; test names mirror the Python function
(`pyjsonDumpsMatchesPython`). Run with `swift test -j 2 --package-path ~/jarvis/native`.

### 3.8 `native/tools/parity_inventory.py`

Same interpreter rules as golden.py. Parses `jarvis.py` with `ast` + regex for: tool names in
`TOOLS`; `os.environ.get("…")` names; module-level `*_FILE`/`RESEARCH_*`; literal
`os.path.join(HERE, "<name>")` files; `# ───` banners with line numbers. Modes: `--emit`
prints the PARITY skeleton rows (used once in T0.4 to confirm the committed PARITY matches);
`--check` exits 1 listing every name present in jarvis.py but absent from `native/PARITY.md`
(and every PARITY name no longer in jarvis.py). Known non-rows (`PATH`, `APPDATA`,
`PROGRAMDATA`; verified to be the only env names outside PARITY's 29) are an explicit allowlist.

### 3.9 Logging and process layout

One process, `JARVIS` (menu-bar agent). Child processes only where a milestone needs them:
`claude` CLI per brain session (M3; env without `ANTHROPIC_API_KEY`), the MCP stdio relay as
the **same signed binary** re-exec'd with `--mcp-relay <socket>` (M3; no second executable to
sign), Piper only if the M8 plan chooses a subprocess. No `caffeinate` child (M14 uses
`IOPMAssertionCreateWithName`).

Entry and lifecycle (`native/Sources/JarvisApp/`):
- `Entry.swift`: `@main @MainActor enum Entry { static func main() }` — handles
  `--version` (prints `JARVIS <CFBundleShortVersionString> (<CFBundleVersion>)`, exit 0),
  `--selftest` (JSON report, exit 0/1), `--permissions` (JSON report, §7), `--mcp-relay` (M3);
  otherwise calls `JarvisSwiftUIApp.main()`.
- `JarvisSwiftUIApp.swift`: `struct JarvisSwiftUIApp: App` with
  `@NSApplicationDelegateAdaptor(AppDelegate.self)` and a `MenuBarExtra("JARVIS", systemImage:
  "circle.hexagongrid")` whose menu shows `State: ~/jarvis`, `Lock: native <pid>` and `Quit JARVIS`
  (M4 grows it; M0 only needs it to be observable).
- `AppDelegate.swift`: `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate`.
  `applicationWillFinishLaunching` → `NSApplication.shared.setActivationPolicy(.accessory)`;
  `applicationDidFinishLaunching` → re-assert `.accessory` (Python's lesson: a window library
  re-asserted Regular on first paint, jarvis.py:5431-5433), log
  `"activation policy: accessory"` only after reading back `NSApp.activationPolicy() ==
  .accessory`, then `StatePaths.live()` → `JarvisLog.configure` → banner → `InstanceLock`
  (§3.5) → start subsystems lazily. The compiler enforces the main thread: these AppKit calls
  are `@MainActor`-isolated in the SDK and Swift 6 strict concurrency rejects off-main calls.
  M4/M13 must call the same re-assert after showing any window/panel.

Logs: file sink = the shared `logs/jarvis.log`, line format identical to Python
(`[JARVIS] <msg>`, no timestamp) so `jarvisctl status` (`tail -1`) and `jarvisctl logs` keep
working; eras are separated by the native banner. `mirrorToStdout` only when `isatty(1)`, so
under the LaunchAgent `logs/jarvis.boot.log` receives only crash output (Python double-writes
everything there). Unified log: `log stream --level info --predicate 'subsystem ==
"com.jarvis.assistant"'`. No rotation (Python never rotates; 697 KB after months) — open
question §8. Crashes land in `~/Library/Logs/DiagnosticReports/JARVIS-*.ips`.

### 3.10 M15 RAM benchmark (`native/scripts/ram-bench.sh`)

- **Metric:** phys_footprint (primary; what Activity Monitor "Memory" shows, includes
  compressed pages — RSS on this machine is misleading because idle pages are compressed, e.g.
  `TGOnDeviceInferenceProviderService` showed 528 KB RSS) via `footprint -p <pid> --noCategories`
  (or `-j <file>`); RSS via `ps -o rss= -p <pid>` for continuity; `vmmap --summary <pid>` once
  per scenario for the breakdown.
- **Process sets, per implementation:** *own* = the JARVIS pid; *tree+helpers* = own + all
  descendants (recursive `pgrep -P`: `claude`/node, Piper, `caffeinate`, `ffmpeg`) + helpers
  attributed to it (Python: `com.apple.WebKit.WebContent`/`.Networking`/`.GPU` started after
  JARVIS and gone after it quits; Ollama server); *daemons* = named system services each
  footprinted individually: `TGOnDeviceInferenceProviderService`, `modelmanagerd`,
  `generativeexperiencesd`, `corespeechd`, `coreaudiod`, any `*speech*` process that appears
  (run `ps -axo pid,comm | grep -iE 'speech|inference|model'` before/after to discover names).
- **System delta:** `vm_stat` (active+wired+compressor pages × 16 KiB) and `sysctl vm.swapusage`
  before launch vs. during the scenario — the honest total, noisy; median of runs.
- **Protocol:** same boot, same state files, Python ↔ native alternated P,N,P,N,P,N (3 each);
  60 s settle; then `footprint --sample 2 --sample-duration 20` per process; record
  `memory_pressure -Q`-style free % at start (reject runs starting < 10 % free).
- **Scenarios:** PARITY §RAM rows. Mid-conversation = the same 5 scripted spoken requests by
  the user (speaker gate rejects `say`), sampled at 0.5 s, report peak and median. Offline =
  `JARVIS_USE_CLAUDE=0` for both. Text-chat-only has no Python counterpart unless a Python text
  channel exists by then → mark "Py n/a".
- **Output:** `native/benchmarks/ram-<date>.json` (numbers + tool versions, no paths) and the
  PARITY table. Never into `research/` (the dataset is not a benchmark log).
- **Requires the user's go-ahead** to start Python JARVIS and Ollama (§8).

### 3.11 M15 LaunchAgent swap and rollback (`native/scripts/switch-impl.sh python|native|status`)

- Backup once: `~/Library/LaunchAgents/com.jarvis.assistant.plist` →
  `~/jarvis/native/dist/com.jarvis.assistant.python.plist` (gitignored; never recreate the
  Python plist from install.sh's template — the live one carries the user's env edits).
- `native` writes the plist with **the same keys as the Python one** except: ProgramArguments =
  `[<abs>/native/dist/JARVIS.app/Contents/MacOS/JARVIS]` (direct exec, never `open -W -a`);
  env adds `JARVIS_HOME=<abs repo>`; keeps the user's `JARVIS_*` values, `LANG`/`LC_ALL`, and
  `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` (must contain
  `/usr/sbin:/sbin`); drops `PYTHONUNBUFFERED`; `RunAtLoad`/`KeepAlive` true, `ThrottleInterval`
  10, same StandardOut/Err paths. Absolute paths are expanded at run time from `$HOME` (script
  itself contains none).
- Sequence (both directions): `launchctl bootout gui/$(id -u)/com.jarvis.assistant` (ignore
  "not found") → wait until `.jarvis.lock` is free (`InstanceLock` probe via
  `JARVIS --selftest`, ≤ 30 s) → install plist → `plutil -lint` → `lsregister -f <chosen bundle>`
  → `launchctl bootstrap gui/$(id -u) <plist>` → verify.
- `status` prints: loaded?, `program` path from `launchctl print gui/$(id -u)/com.jarvis.assistant`,
  pid, lock holder line, last `logs/jarvis.log` line.
- Rollback is `native/scripts/switch-impl.sh python` — restores the backup plist byte-for-byte.
  Safe because state is byte-compatible and Python reads what native wrote (`golden.py readback`
  green is a precondition of cutover).

### 3.12 M15 parity audit (`native/tools/parity_audit.py`)

- Evidence grammar per PARITY row (Evidence column, `·`-separated, ≥ 1 required):
  `T:<TestTarget>/<Suite>/<test>` (must appear as passed in `swift test` output saved to
  `native/dist/audit/swift-test.log`) · `G:<suite>.golden.json` (exists, fresh per
  `golden.py --check`) · `M:<benchmarks file>#<key>` · `O:<date> <log line or screenshot sha256>`
  (screenshots stay out of git — they may show personal data) · `N/A:<reason> (user <date>)`.
- Script: runs `parity_inventory.py --check`, parses every table row and checklist line,
  fails on any `☐`/`[ ]`, empty Evidence, unknown test id, missing/stale fixture, or `N/A`
  without a user date. Prints `rows: N ok, M failing` and the failing rows.
- Procedure: executor fills evidence milestone by milestone (M1–M14 each tick their rows);
  M15 only re-runs everything from clean (`golden.py --check`, `swift test`, audit) and then a
  live-observation pass for rows that need `O:` evidence.

## 4. Golden vectors

M0 suites (fixtures in `native/Tests/Fixtures/golden/`; Swift consumer in `native/Tests/JarvisCoreTests/`):

| Suite / fixture | Python function(s) | Input corpus (each a case) | Case shape |
|---|---|---|---|
| `pyjson.golden.json` | `json.loads` then `json.dumps(v)`, `json.dumps(v, indent=1)`, `json.dumps(v, indent=0)`, `json.dumps(v, ensure_ascii=False)` (the four styles jarvis.py uses + two controls) | empty `{}`/`[]`; nested dict/list 4 deep; key order `{"b":1,"a":2}`; duplicate key `{"a":1,"b":2,"a":3}`; ints `0,-1,2**53+1,2**63-1`; floats `0.1, 0.1+0.2, 1e16, 1.5e-05, 0.0001, 1234567890123456.0, 9007199254740993.0, 123456789012345678.0, 1e22, 100.0, -0.0, 5e-324, 1.7976931348623157e308`, `NaN`, `Infinity`, `-Infinity`; strings `"é"`, `"😀"`, `"\u007f"`, `"/"`, `"\"\\\b\f\n\r\t"`, `"\u0000\u001f"`, `" "`, 10 KB string; `true/false/null`; whitespace-heavy input; adversarial: `"\ud800"` (lone surrogate), BOM-prefixed text, trailing comma, `2**64` → expected `raises`; plus **a copy-shaped sample of each real state file's structure with synthetic values** (never real content) | `input: {"json_text": "<text>"}`, `expected: {"dumps_text", "indent1_text", "indent0_text", "noascii_text"}` or `{"raises": "JSONDecodeError"}` |
| `pytime.golden.json` | `time.strftime(fmt, time.localtime(t))` for every format in §2.3; `datetime.fromtimestamp(t).isoformat()`; `datetime.fromisoformat(s)` | epochs: default 1790582400; 00:00:00 and 23:59:59 local; 12:00 / 00:30 (for `%I`/`%p`); 2026-03-29 00:59:59/01:00:00 UTC and 2026-10-25 00:59:59/01:00:00 UTC (BST transitions); 2028-02-29; a fractional epoch (microseconds); `.lstrip('0')` variant of `'%I:%M %p'` | `input: {"epoch": e, "format": f}`, `expected: {"text": s}`; iso cases `expected: {"iso": s, "roundtrip_epoch": e}` |
| `pyround.golden.json` | `round(x, n)` | `2.675,2`; `0.0125,3`; `-0.0005,3`; `-0.0001,3` (→ `-0.0`); `0.5,0`; `1.5,0`; `2.5,0`; `1e-10,3`; 200 pseudo-random emotion-like values in [-1,1] from `random.Random(1)` with `n=3` | `input: {"x_text": repr(x), "n": n}`, `expected: {"text": repr(round(x, n))}` |
| `paths.golden.json` | `os.path.relpath(getattr(jarvis, C), jarvis.HERE)` for each constant in §3.7 + the two literal files | the 14 constants + `jarvis_notes.txt`, `audd_key.txt` | `input: {"constant": C}`, `expected: {"relative": r}` |

`golden.py selftest` (not a fixture): asserts sandboxed constants, runs `research_bump("x")`
twice under the shim in the sandbox and checks `research/usage.json` in the *sandbox* has
`{day: {"x": 2}}`, confirms the tripwire saw no real change, and that the fixture writer is
byte-reproducible (generate `pyjson` twice into two temp dirs, `cmp`).

## 5. Acceptance checks

All commands from any cwd; `SP` = a scratch dir. "Proves" = the observable output required.

| # | Command | Proves |
|---|---|---|
| A1 | `cd ~/jarvis/native && swift build -j 2 2>&1 \| tail -3` | ends `Build complete!` |
| A2 | `cd ~/jarvis/native && swift test -j 2 2>&1 \| tail -5` | Swift Testing summary line `Test run with N tests … passed`, N ≥ number of golden cases in the 4 suites, 0 failures |
| A3 | `~/jarvis/native/tools/golden.py selftest && ~/jarvis/native/tools/golden.py --check` | prints `selftest: OK` and `fixtures fresh: 4/4`; exit 0 |
| A4 | `cd ~/jarvis && native/tools/golden.py all && git status --porcelain native/Tests/Fixtures` | empty output on a second run (byte-reproducible) |
| A5 | `grep -rEl '/Users/[A-Za-z0-9._-]+/' ~/jarvis/native --include='*.json' --include='*.swift' --include='*.py' --include='*.sh' --include='*.md'` | no output |
| A6 | `~/jarvis/native/scripts/build-app.sh 2>&1 \| tail -4` | contains `DR matches Python bundle: yes` and `Built: …/native/dist/JARVIS.app`; no line contains `Authority=`, `designated`, or a 40-hex string |
| A7 | `codesign --verify --strict ~/jarvis/native/dist/JARVIS.app && plutil -p ~/jarvis/native/dist/JARVIS.app/Contents/Info.plist \| grep -E 'CFBundleIdentifier\|LSUIElement'` | exit 0; `com.jarvis.assistant`, `LSUIElement => true` |
| A8 | `~/jarvis/native/dist/JARVIS.app/Contents/MacOS/JARVIS --selftest` | JSON with `"bundle_id": "com.jarvis.assistant"`, `"state_root_valid": true`, `"lock_free": true`, and per real state file `"reencode_byte_identical": true` (read-only PyJSON round-trip of the real files in their Python style) |
| A9 | `open -n ~/jarvis/native/dist/JARVIS.app; sleep 3; cat ~/jarvis/.jarvis.lock; tail -3 ~/jarvis/logs/jarvis.log` + screenshot of the menu bar | lock line `native <pid> <epoch>`; log shows `===== JARVIS (native) starting …` and `[JARVIS] activation policy: accessory`; menu-bar item visible, **no Dock icon** in the screenshot |
| A10 | with A9 running: `open -n ~/jarvis/native/dist/JARVIS.app; sleep 3; tail -1 ~/jarvis/logs/jarvis.log; pgrep -x JARVIS \| wc -l` | second instance logs `… holds .jarvis.lock — exiting.`; exactly 1 JARVIS process |
| A11 | with A9 running: `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3 -c "import fcntl,os; fd=os.open(os.path.expanduser('~/jarvis/.jarvis.lock'),os.O_RDWR); fcntl.flock(fd,fcntl.LOCK_EX\|fcntl.LOCK_NB)"` | fails with `BlockingIOError` (Python sees native's lock). Then quit JARVIS via its menu and re-run: exits 0 |
| A12 | Python patch, **without starting Python JARVIS**: hold the lock from Swift (A9), then `cd ~/jarvis && timeout 8 /Library/Frameworks/Python.framework/Versions/3.14/bin/python3 -c "import jarvis; jarvis.acquire_instance_lock()"; echo rc=$?` (`timeout` may be absent → use `perl -e 'alarm 8; exec @ARGV' …`) | prints `[JARVIS] Another JARVIS instance holds .jarvis.lock — waiting.` then is killed by the alarm (rc 142); lock line unchanged |
| A13 | `~/jarvis/native/tools/parity_inventory.py --check` | exit 0 after the P1/P2 PARITY edits |
| A14 (M15) | `~/jarvis/native/tools/parity_audit.py` | `rows: N ok, 0 failing` |
| A15 (M15) | `~/jarvis/native/scripts/switch-impl.sh native && ~/jarvis/native/scripts/switch-impl.sh status` | `program = …/native/dist/JARVIS.app/Contents/MacOS/JARVIS`, `state = running`, lock `native <pid>` |
| A16 (M15) | `~/jarvis/native/scripts/switch-impl.sh python && ~/jarvis/native/scripts/switch-impl.sh status; cmp ~/Library/LaunchAgents/com.jarvis.assistant.plist ~/jarvis/native/dist/com.jarvis.assistant.python.plist` | program = Python bundle, lock `python <pid>`, `cmp` silent — **only with user go-ahead** (starts Python) |
| A17 (M15) | `tail -2 ~/jarvis/research/metrics.jsonl \| /Library/Frameworks/Python.framework/Versions/3.14/bin/python3 -c "import sys,json; d=[json.loads(l)['date'] for l in sys.stdin]; print(d, len(set(d))==len(d))"` after a same-day switch | `True` (no duplicate day) |
| A18 (M15) | `~/jarvis/native/scripts/ram-bench.sh report` | fills every PARITY §RAM cell; writes `native/benchmarks/ram-<date>.json` |

## 6. Executor tasks

Each task ends with its verification and a worklog line; commit only when the user asks
(branch first — the repo is on its default branch).

| Task | Files touched | Spec | Verify | Deps |
|---|---|---|---|---|
| **T0.1** Apply review edits | `native/ROADMAP.md`, `native/PARITY.md`, `native/Package.swift` header, `~/jarvis/.gitignore` (append `native/.build/`, `native/.swiftpm/`, `native/Vendor/onnxruntime/lib/`, `.jarvis.lock`) | §3.1 R1–R9, P1–P6, S1 exactly. **Note:** the §3.1 ROADMAP/PARITY/Package.swift corrections were applied in b3667d2; the root `.gitignore` additions listed here remain for T0.1 | `grep -c` each new string = 1; `git check-ignore -v native/.build .jarvis.lock` both matched | — |
| **T0.2** Neutralise prototype bundle | none in repos | ask user (§8 Q1); if approved `lsregister -u ~/jarvis-swift/dist/JARVIS.app` | `mdfind` still lists it (file untouched) but `lsregister -dump \| grep -c jarvis-swift/dist` = 0 | — |
| **T0.3** Package scaffold | `native/Package.swift` (§3.2), `Sources/JarvisCore/Support/StatePaths.swift`, `Sources/JarvisApp/Entry.swift` (stub: `--version`), `Tests/JarvisTestSupport/Sandbox.swift`, `Tests/JarvisCoreTests/StatePathsTests.swift` | §3.2, §3.6 StatePaths | A1; `swift test` runs StatePathsTests (sandbox paths + `live()` throws `.notInAppBundle` under test) | T0.1 |
| **T0.4** golden.py + parity_inventory.py | `native/tools/golden.py`, `native/tools/parity_inventory.py`, fixtures `paths.golden.json` | §3.7, §3.8, §4 `paths` | A3 (selftest), A13, A5 | T0.1 |
| **T0.5** PyJSON | `Support/PyJSON.swift`, `Tests/JarvisTestSupport/Golden.swift`, `Tests/JarvisCoreTests/PyJSONGoldenTests.swift`, `pyjson.golden.json` | §3.6, §4 `pyjson` | A2 for the pyjson suite, A4 | T0.3, T0.4 |
| **T0.6** PyTime + PyMath + AtomicFile | `Support/PyTime.swift`, `Support/AtomicFile.swift`, tests + `pytime`/`pyround` fixtures | §3.6, §4 | A2; AtomicFile test: kill-mid-write simulation (write to a read-only dir → error, target unchanged), mode preserved, no temp left | T0.5 |
| **T0.7** InstanceLock + JarvisLog | `Support/InstanceLock.swift`, `Support/JarvisLog.swift`, `InstanceLockTests.swift` (two opens in-process conflict; holder parse; `O_CLOEXEC` checked via `fcntl(F_GETFD)`) | §3.5, §3.9 | A2 | T0.3 |
| **T0.8** jarvis.py lock patch | `~/jarvis/jarvis.py` (additive: new function above `def main():`, one call in `main()`) | §3.5 verbatim | A12; `git diff --stat jarvis.py` = 1 file, only insertions; then regenerate fixtures clean (`golden.py all`) since jarvis.py sha changed | T0.4, T0.7 |
| **T0.9** App shell | `Sources/JarvisApp/{Entry,JarvisSwiftUIApp,AppDelegate,SelfTest}.swift`, `native/Resources/Info.plist`, `native/Resources/JARVIS.entitlements` | §3.3 plist table, §3.9 | A8 (after T0.10), A9, A10 | T0.5–T0.7 |
| **T0.10** build-app.sh | `native/scripts/build-app.sh` | §3.3 | A6, A7 | T0.9 |
| **T0.11** `--permissions` probe (optional in M0, required by M15) | `Sources/JarvisApp/PermissionsProbe.swift` | §7 list; launched via `open -n -W --stdout $SP/perm.json ~/jarvis/native/dist/JARVIS.app --args --permissions` | JSON with one key per TCC service, values from the APIs in §7 | T0.10 |
| **T15.1** parity_audit.py | `native/tools/parity_audit.py` | §3.12 | run on current PARITY → lists every row failing (proves it detects) | M14 done |
| **T15.2** ram-bench.sh | `native/scripts/ram-bench.sh` | §3.10 | dry run against the running native build prints own/tree/daemon numbers | T15.1 |
| **T15.3** Benchmark runs | `native/benchmarks/ram-<date>.json`, PARITY §RAM | §3.10 protocol — **user go-ahead to run Python + Ollama** | A18 | T15.2 |
| **T15.4** switch-impl.sh | `native/scripts/switch-impl.sh` | §3.11 | `status` only (no switching) prints current state | T15.1 |
| **T15.5** Cutover | LaunchAgent plist (backup first) | §3.11 + TCC checklist §7 — **user present** | A15, `--permissions` all needed services granted, A17 next day | T15.1–T15.4, audit green |
| **T15.6** Rollback drill | — | `switch-impl.sh python` then `native` again | A16 then A15 | T15.5 |

## 7. RAM / permissions

**RAM (M0):** the M0 app is AppKit + SwiftUI + a menu bar item — expected own phys_footprint
~20–40 MB (estimate, not measured; T0.9 records the real number with `footprint -p JARVIS
--noCategories` into PARITY). `swift build`/`swift test` are the heavy part (swift-frontend
several hundred MB per job) → always `-j 2`, and don't run them while Python JARVIS is up.
golden.py child interpreters: ~36 MB max RSS each (measured: `import jarvis` 0.13 s, 35.8 MB).

**TCC — what native inherits vs must re-grant.** Native and Python share one TCC client
(bundle id + identical DR, §3.4). Expectation (NOT verified — `--permissions` observes it):

| Service | Python used | Native mechanism | Expectation at cutover | Probe API (`--permissions`) |
|---|---|---|---|---|
| Microphone | yes | AVAudioEngine | inherited | `AVCaptureDevice.authorizationStatus(for: .audio)` |
| Speech recognition | usage key present; Whisper did not need it | SpeechTranscriber (M9) | likely new prompt | `SFSpeechRecognizer.authorizationStatus()` |
| Calendars | EventKit | EventKit | inherited | `EKEventStore.authorizationStatus(for: .event)` |
| Reminders | AppleScript (Automation) | EventKit if M6 chooses | new if EventKit | `EKEventStore.authorizationStatus(for: .reminder)` |
| Contacts | AppleScript | Contacts.framework if M6 chooses | new if framework | `CNContactStore.authorizationStatus(for: .contacts)` |
| Automation (per target app) | via `osascript` children | NSAppleScript/`osascript` | inherited per (client,target) pair | `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: false)` for running targets |
| Screen Recording | `screencapture` child | ScreenCaptureKit | inherited (same client) | `CGPreflightScreenCaptureAccess()` |
| Accessibility / event posting | System Events keystroke | CGEvent if M5 chooses | new if CGEvent | `AXIsProcessTrusted()`, `CGPreflightPostEventAccess()` |
| Full Disk Access | chat.db | same | inherited | readable open of `~/Library/Messages/chat.db` |
| Notifications | osascript `display notification` | UNUserNotificationCenter | new | `UNUserNotificationCenter.current().notificationSettings()` |
| Keychain (ElevenLabs) | — | `SecItemCopyMatching` generic password | one "Always Allow" per item (DR-bound) | n/a |

Never `tccutil reset` for `com.jarvis.assistant`. Every prompt must be answered by the user
at the Mac; T15.5 schedules it with the user present.

**Info.plist keys:** §3.3 table. **Entitlements:** §3.3 (sandbox off, audio-input,
apple-events; no hardened runtime, no keychain/network entitlements).

## 8. Risks and open questions

1. **Prototype bundle with a different DR** (`~/jarvis-swift/dist/JARVIS.app`) can corrupt the
   shared TCC entry if ever launched. Q1: unregister only (T0.2), or may we delete/rename that
   build artefact? (Brief says don't modify jarvis-swift — needs the user.)
2. **Dataset meaning of `code.*` in snapshots** (jarvis.py:2487-2500): it measures `jarvis.py`.
   After cutover it will flat-line (native doesn't change jarvis.py). Proposal, additive only:
   keep `code` = jarvis.py exactly, add `"impl": "native"` and `"code_native": {"bytes","lines",
   "files","git_head"}`; absent `impl` = python. Needs the user's decision (dataset is sacred).
   M1 owns the implementation.
3. **M15 benchmark requires running Python JARVIS and Ollama** — conflicts with "Python
   intentionally stopped / no Ollama" unless the user approves at that time. Ollama's 2.5 GB
   model on ~1 GB free will swap and perturb both runs; report swap alongside.
4. **FoundationModels / Speech daemon memory may be shared with Siri/Apple Intelligence** and
   resident anyway; attributable delta ≠ absolute. Report both; don't claim a saving the
   daemon split hides.
5. **Concurrent Python writer beyond JARVIS itself:** a `jarvis-chat` session config was seen
   (`~/.claude/tools/tasks.d/jarvis-chat.json`, planning `chat.html`/`chat_app.py` in the repo,
   files not present yet). If it runs outside the JARVIS process and writes state, it must take
   `.jarvis.lock` too.
6. **Python writes are non-atomic** (truncate-in-place); a Python crash mid-write can still
   corrupt a file native then reads. Not fixed here (scope). PyJSON errors ⇒ M1 must not
   overwrite an unreadable file.
7. **Overlap with other plans:** PyJSON/AtomicFile/PyTime/PyMath are specified here as M0
   primitives; the M1 plan should consume, not re-specify, them. The minimal MenuBarExtra
   overlaps M4 by design.
8. **Log format:** identical `[JARVIS] msg` without timestamps (parity) vs adding timestamps;
   no rotation. Decision deferred to the user; os_log has timestamps meanwhile.
9. **ATS:** a user-set `http://` `JARVIS_NEWS_FEED` (or any M6 tool fetching arbitrary URLs)
   would be blocked by ATS; Python allowed it. Decide in M6 whether to add
   `NSAllowsArbitraryLoads` (security trade-off).
10. **`CFBundleShortVersionString`** `2.0.0` collides with the archived prototype's value; pick
    a version with the user (e.g. `3.0.0`).
11. **Unverified API assumptions:** SpeechTranscriber needing `NSSpeechRecognitionUsageDescription`;
    TCC inheritance between the two bundles (derived from matching DRs, not observed); SwiftUI
    re-asserting Regular policy (only known for pywebview). Each is observed by A9/T0.11.
12. **Fixture/`.gitignore` traps** (§3.1 R9) — audio fixtures in M10/M11 need negation rules.
13. **Pre-commit hook** blocks `/Users/<name>/` in any added line; the installed LaunchAgent
    plist backup must stay in gitignored `native/dist/`.
14. `swift build`/`swift test` were **not run** during planning (forbidden); S3 and A1/A2 are
    untested predictions.
