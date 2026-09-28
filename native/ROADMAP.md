# Native JARVIS — roadmap

Execution plan: see plan/README.md

A full rewrite of `jarvis.py` (Python, ~5,760 lines, 46 tools) as a native macOS app in
Swift. Decided 2026-09-28: **full parity before anything ships** — the Python JARVIS stays
the production assistant (currently parked for RAM) until the native one passes the parity
audit in M15. Deadline pressure is low (dissertation ~2028); correctness is not.

## Why native

On an 8 GB M2 the cost of Python JARVIS is not the interpreter (importing `jarvis.py` is
~26 MB) but what it has to carry in-process: faster-whisper, PyTorch (speaker ID),
onnxruntime + numpy (wake word), a WebKit HUD process, and Ollama's 2.5 GB model for the
fallback. On macOS 26+ the system provides most of these as shared, OS-managed services:

| Python JARVIS             | Native JARVIS                                          | Verified here |
|---------------------------|--------------------------------------------------------|---------------|
| faster-whisper small.en   | `SpeechAnalyzer` / `SpeechTranscriber` (en-GB on-device) | 2026-09-28 ✅ |
| Ollama qwen2.5:3b         | FoundationModels `SystemLanguageModel` (fallback only)  | 2026-09-28 ✅ 5.3 s cold, 21 MB client RSS (inference daemon not counted — must be measured, see M15; D-7) |
| claude-agent-sdk (Python) | `claude -p --output-format stream-json` driven directly | 2026-09-28 ✅ flags present |
| PyTorch Resemblyzer       | same LSTM exported to ONNX, run on ONNX Runtime         | M10 |
| onnxruntime (Python)      | ONNX Runtime C API (salvaged from `~/jarvis-swift`)     | prototype 2026-07-10 |
| pywebview HUD             | native `NSPanel` + SwiftUI                              | M13 |
| Piper (`piper-tts` 1.4.2, in-process; espeak-ng inside `piper/espeakbridge.so`; 356 MB peak RSS, 1.3 s load, 0.25 s/sentence — orchestrator-measured) | ElevenLabs streaming TTS over HTTPS (API key in the login Keychain) primary, Piper as the offline/failure fallback — mechanism per the M8 plan | M8 |
| ffmpeg pitch shift        | `AVAudioUnitTimePitch`                                  | M8 |
| `caffeinate`              | `IOPMAssertionCreateWithName`                           | M14 |

## Rules for every session

1. **Python is the oracle.** Any deterministic behaviour (regexes, prompt text, decay maths,
   intent routing, risk tiers, embeddings) is verified against golden vectors produced by
   running the real Python functions (`tools/golden.py`), never against values typed from
   memory. A test written from the same belief as the code proves nothing. Fixtures are named `<suite>.golden.json`; never name a fixture after a state file, and audio fixtures (M10/M11) need an explicit `.gitignore` negation.
2. **The dataset is sacred.** `research/metrics.jsonl` and `research/usage.json` keep their
   exact field names and meanings. New fields may be *added*; none may be renamed, removed
   or re-scaled. See `research/README.md`.
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
4. **Nothing resident that isn't needed.** Load models lazily, release them when idle, prefer
   system services. At every milestone that adds a subsystem, measure phys_footprint (primary) and RSS (continuity) of the JARVIS process tree AND of the system daemons it wakes (`PARITY.md` §RAM, method in `plan/M00-foundation-and-M15-cutover.md` §3.10).
5. **Installs need the user.** Package managers governed by the org's JFrog routing (npm,
   PyPI/pip, Maven, Gradle, Go, Docker, Helm, NuGet) are blocked until that routing is
   configured. Any other install (Homebrew, remote SwiftPM dependencies, downloaded
   binaries — e.g. `brew install espeak-ng`) needs the user's explicit approval in the
   session; never assume it. The plan itself uses only the Apple SDK, the salvaged ONNX
   Runtime dylib, and the installed Python — specifically
   `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3` (Homebrew's `python3`
   lacks JARVIS's deps) — for the oracle and one-off model export only.
6. **Security parity is a blocker, not a nice-to-have.** The shell denylist, risk tiers,
   confirmation gate and prompt-injection taint guard must be at least as strict as Python's
   before any tool that can act on the machine is enabled.

## Layout (`native/`)

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

## Milestones

Each is done only when its acceptance checks pass **by observation** (tests green, a
screenshot, a measured number) and it is committed.

- **M0 — Foundation.** Roadmap, parity checklist (+ generator), package scaffold, signed
  bundle build (stable identity from `~/jarvis/.signing/config`, never jarvis-swift's),
  single-instance guard in both implementations (additive `jarvis.py` patch), Python-compat
  primitives (PyJSON, AtomicFile, PyTime, PyMath.round), logging, accessory activation
  policy, Python oracle harness + first golden fixtures, `swift build` + `swift test` green.
- **M1 — Core state & persona.** Atomic JSON store for all state files; personality
  (seed, learn patterns, toggle eviction, forget, self-write tools, consolidation), emotions
  (decay, events, bands, context), profile, KB, corrections, tone, history. Prompt builder
  reproduces Python's system prompt byte-for-byte from the same state. Research logger
  (usage counters + daily snapshot) schema-identical; golden-tested.
- **M2 — Security.** Shell risk tiers (block/confirm/instant), denylist, AppleScript guard,
  sudo allowlist, sensitive-path rules, taint guard, spoken/typed confirmation gate.
  Golden vectors from `_shell_risk` & friends, including known-attack corpora.
- **M3 — Brain.** Claude CLI driver (stream-json in/out, Opus 5.5 selectable, effort,
  timeouts, partial-answer salvage); MCP server exposing JARVIS tools over a 0600 Unix
  socket + stdio relay; FoundationModels fallback with the same tool set; backend reporting;
  shared history. Taint guard enforced in the tool server.
- **M4 — Text chat.** SwiftUI chat window + menu bar extra; streamed replies; confirmation
  gate in text; optional spoken replies. (Internal dev use only until M15.)
- **M5 — Tools I: system.** run_command, run_applescript, battery, time, cpu, wifi, volume,
  brightness, diagnostics, notify, clipboard, screenshot, see_screen (ScreenCaptureKit +
  Vision), type_text, find_apps + app index + app intelligence, open_settings,
  system_control, files (search/read/find/delete/move/write).
- **M6 — Tools II: apps & data.** music ×4, calendar read/create (EventKit), reminders,
  messages read (chat.db) / send, email, contacts, notes, shortcuts, weather, location,
  web_search (+ KB cache, background research), news, summarize_page, lyrics ID, AudD,
  alarms, timers, personality_note/rewrite.
- **M7 — Fast paths.** The offline router, golden-tested against Python `fast_path()` over a
  phrase corpus (reply text + dispatched action).
- **M8 — Voice out.** ElevenLabs streaming TTS (key in Keychain) primary; Piper fallback when offline or on ElevenLabs failure; native pitch/tempo where it applies; sentence streaming; `say` last resort.
- **M9 — Voice in.** AVAudioEngine capture with voice processing (echo cancellation),
  SpeechTranscriber with contextual vocabulary, corrections, confidence gating,
  sentence-aware listening, vocal tone.
- **M10 — Speaker verification.** Resemblyzer → ONNX; native mel front-end; embeddings
  match Python (cosine ≥ 0.999) on golden audio; existing `voiceprint.npy` stays valid.
- **M11 — Wake word.** Salvaged openWakeWord ONNX pipeline (golden scores vs Python on the
  same audio), soft tier, speaker-gated wake.
- **M12 — Conversation loop & barge-in.** Wake → command → conversation mode → dismiss;
  barge-in (simplified by AEC); enrolment by voice.
- **M13 — HUD.** Native arc-reactor panel: states, captions, click-through, bottom-left.
- **M14 — Background life.** Proactive nudges, daily briefing, meeting alerts, low battery,
  unlock greeting, background research, keep-awake, alarms rescheduling.
- **M15 — Parity audit & cutover.** Every `PARITY.md` row ticked with evidence
  (`tools/parity_audit.py` green); RAM benchmark vs Python — phys_footprint of each whole
  process tree plus the system daemons each leans on (a dissertation data point; running
  Python and Ollama for it needs the user's go-ahead); LaunchAgent swap; TCC re-grant of
  only the genuinely new services; one-command rollback (`scripts/switch-impl.sh python`).
