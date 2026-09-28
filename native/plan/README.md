# Native JARVIS — execution plan

These files plan the native Swift rewrite of `jarvis.py` described in `../ROADMAP.md`,
milestone by milestone, in enough detail for an executor to build each one without
re-deriving the Python behaviour. `../PARITY.md` is the inventory every milestone ticks off,
and `DEVIATIONS.md` lists every place native deliberately differs from Python.

**Status:** plan complete 2026-09-28; nothing built yet.

Line numbers refer to jarvis.py @ 68cd112.

## Reading order

M00 → M01 → M01b → M02–M04 → M05–M06 → M07+M14 → M08–M13 → M15 (M15 lives in the M00 file).

## Sections

| File | Milestones covered | Lines | Verdict |
|---|---|---|---|
| `M00-foundation-and-M15-cutover.md` | M0 foundation (package, bundle build, signing, oracle, exclusion guard, logging) and M15 parity audit & cutover | 1140 | accepted (with D-1) |
| `M01-core-state-persona.md` | M1 core state & persona: JSON state store, personality, emotions, profile, KB, corrections, tone, app context, history, prompt builder | 1730 | accepted |
| `M01b-research-dataset.md` | M1b research dataset logger: snapshot writer, counters, additive schema v2, gap annotations | 790 | accepted |
| `M02-M04-security-brain-chat.md` | M2 security choke point, M3 Claude/FoundationModels brain, M4 text chat | 1249 | accepted (with D-9, D-10, D-11) |
| `M05-M06-tools.md` | M5 system & file tools, M6 apps & data tools | 475 | accepted (with D-12, D-13, D-14) |
| `M07-fastpath-M14-loops.md` | M7 offline fast-path router, M14 background life | 832 | accepted (with D-21, D-22) |
| `M08-M13-voice-hud.md` | M8 voice out, M9 voice in, M10 speaker verification, M11 wake word, M12 conversation loop & barge-in, M13 HUD | 726 | accepted (with D-17 to D-20) |

Also here: `DEVIATIONS.md` (the deviations register) and this index.

## Integration decisions

Made by the orchestrator while judging the sections. Where a section disagrees with a
decision below, the decision wins. The section plans have their own local `D-n` and `R-n`
lists (for example M02–M04 §8.2 "Decisions for the user"). Those are separate numbering
schemes: "W4 D-3" is not integration decision D-3.

- **D-1. PyJSON/AtomicFile ownership.** One module in JarvisCore, built in M0 (W1's
  placement). The normative types are M01 §3.1/§3.5: `JSONValue` with `int(Int64)` and
  `bigInt(String)`, `loads(Data)`, ordered `JSONObject.Member`, `setDefault`. M00 §3.6 adds
  the `dumps` `ensureASCII:` parameter, DEL (0x7f) escaping (matches CPython's
  `ESCAPE_ASCII` class `[^\ -~]`), `AtomicFile.appendLine`, and the pyjson/pytime/pyround/paths
  golden suites. M00 §3.6 carries a banner pointing here.
- **D-2. Personality consolidation and distill backend.** Claude CLI first, then
  FoundationModels, then skip on refusal or failure. Claude adds no new privacy exposure (the
  persona is already in every Claude prompt) and avoids on-device guardrail refusals of
  profanity notes. This is a hygiene job: it never fabricates.
- **D-3.** M01 R3, the `.unreadable` backup made before overwriting an unparseable state file:
  approved.
- **D-4. Bug-compat policy.** Native matches Python by default, enforced by golden fixtures.
  Every deliberate fix is listed in `DEVIATIONS.md` with its own marked fixture
  (`"deviation": "DEV-n"`). Known when decided: the chained-sudo guard (W4), the fast-path
  launcher swallowing "start a timer…" and "start music" (W6), the research 8 KB tail read
  (W3's D-list), and preserving an unreadable `usage.json` (W3 D1).
- **D-5.** Dataset rows written by Python carry `runtime.impl="python"` and `build="release"`,
  since Python JARVIS, whenever it runs, is the production assistant (per W3).
- **D-6. Commit hygiene.** Plan files must pass `.githooks/pre-commit`, so absolute
  `/Users/<name>/` paths become `~/`. Applied at integration: 7 home paths rewritten to `~/`
  (one Python one-liner uses `os.path.expanduser("~/jarvis")`, because `sys.path` does not
  expand `~`), and 2 synthetic test paths in M05 rewritten as `$HOME/w` and `$SHARED` so
  the hook's path regex does not fire.
- **D-7. FoundationModels RAM.** Measure the inference daemon too (W1 flag 6). ROADMAP's
  "21 MB" is the client process's RSS only; W1's §3.1 corrections are applied.
- **D-8.** The jarvis-chat Python chat app is superseded and will not be built (W1 flag 7 is moot).
- **D-9. Guard attack corpus.** Generated programmatically from the guard's own patterns plus
  systematic mutations (quoting, whitespace, case, chaining, substitution), with Python's
  verdicts as the expectations. No hand-written payloads: W4 §4 is thin because the
  classifier stopped the hand-writing.
- **D-10. M3 task.** Measure claude-opus-5-5's refusal rate on the real `SYSTEM_PROMPT` across
  about 30 typical JARVIS commands, recording which model answered. If the rate is material,
  decide between accepting the claude-opus-4-8 fallback and a Claude-only prompt deviation
  (in `DEVIATIONS.md`). Always record the answering model per turn.
- **D-11. W4's user-decision list (M02–M04 §8.2), resolved.** W4 D-1 yes (X-1). W4 D-2:
  tightened sudoers, `native/ops/jarvis.sudoers` (the user is installing it). W4 D-3
  overridden to OFF (the user's July "full read access"; the taint guard is the control).
  W4 D-4 ON (overage kill, so no pay-as-you-go). W4 D-5 yes (claude-opus-5-5 by default;
  the counter stays `backend_claude`).
  W4 D-6: reword for the CLI. W4 D-7: CORE-22 accepted pending the M3 context measurement.
  W4 D-8 ON. W4 D-9: `interactions` is bumped for text too, plus W3's additive
  `interactions_text`. W4 D-10: reject. W4 D-11 and D-12: defaults. W4 D-13: the user writes
  `shouldSpeakReply` (batched to the user).
- **D-12. Security, now parity.** The native executor set includes `write_file`,
  `delete_file` and `move_file`. Writes and moves into dotfiles (`~/.zsh*`, `~/.bash*`,
  `~/.profile`), `~/Library/LaunchAgents`, `~/.ssh`, `~/Library/Keychains` and `~/.claude`
  take the confirm tier even inside home. Python has done the same since fef66c1, so this is
  parity, not a deviation. `PARITY.md` keeps the three rows `X*` with a footnote;
  `DEVIATIONS.md` has the entry (M05 R2 → D-12), resolved.
- **D-13. Target split** (W5 R8): pure-logic targets are Foundation-only and golden-testable;
  platform targets may import AppKit, EventKit and so on. This corrects the rule in the
  `Package.swift` header comment, which now says so.
- **D-14.** `summarize_page` and `find_song_by_lyrics` use the brain chain (Claude CLI, then
  FoundationModels) and keep "title + artist only, never lyrics".
- **D-15.** Wi-Fi SSID comes from CoreWLAN with the Location grant, because the
  `networksetup` oracle is broken on macOS 27. Accepted deviation (W5 R3).
- **D-16. Parallel Python session (task_9ad883cb).** The user had started a separate session
  to fix the write_file/delete_file/move_file injection gap in `jarvis.py`. The user stopped
  it at 16:56 before it changed anything (verified: `jarvis.py` unmodified, no worktree, no
  stash). The gap was then fixed in Python by fef66c1, so the "becomes parity" branch applies:
  D-12 is parity and the Python gap is closed. Plan line citations are @68cd112, and the
  plan commit stages only `native/`.
- **D-17. `speakLocally` stub.** No `fatalError`. The default body is `return true` (speak
  locally with Piper, the privacy-safe choice) under a clearly marked USER DECISION comment;
  the user writes the real rule. M08 §3.2 is edited to match.
- **D-18. Barge-in.** Native drops queued sentences on both backends, where Python's Claude
  path keeps speaking. Approved deviation.
- **D-19. Echo cancellation.** Voice processing on, ducking at its minimum, AGC off.
  Re-measure the wake and speaker thresholds with AEC on. `JARVIS_AEC=0` is the escape hatch.
- **D-20.** The native speaker-ID and Piper routes (dlopen of Python's `_webrtcvad.so` and
  `espeakbridge.so` with dummy symbols) are spikes with a go/no-go. Fallbacks that download
  or brew-install (webrtc VAD source, espeak-ng) need the user's explicit approval at
  execution time.
- **D-21. Router fixes approved as deviations:** DEV-M7-01 (the launcher swallows "start a
  timer…"), DEV-M7-02 ("start music" and "start the music" → play), DEV-M7-05 (the note
  regex turns "notes" and "notebook" into notes "s" and "book"). The other W6 DEVs follow
  M07 §8.
- **D-22. Ownership.** Alarm store and the `set_alarm` tool: M6. Alarm firing and
  rescheduling: M14. `web_search` and the KB cache: M6; the background research loop: M14.
  Research logger logic: M1b, on the shared scheduler M14 provides. Chat-only mode runs the
  dataset snapshot, alarm and reminder firing, and meeting and low-battery alerts (as
  UNUserNotifications), never the voice-only loops. Personality distill runs after 10 minutes
  of chat idle or when the window closes.

## Judging notes

Each section was written by a separate agent (W1–W7; W8 prepared the sudoers file), then
judged against the live Python code.

- W1, M00 + M15: accepted with D-1. Verified: the prototype bundle's designated
  requirement differs from the Python bundle's (a TCC hazard); no absolute paths.
- W2, M01: accepted. Verified: 8 of 8 sections; `app_context` is at jarvis.py:3536 (the
  brief was wrong); re-serialisation is byte-identical on the real files (indent=1; history
  compact); the hook blocks `/Users/<name>/`; fixtures need an `m1_` prefix because of
  `.gitignore`.
- W3, M01b: accepted. Verified: the 8 KB tail-read bug is real (`_research_last_date`
  seeks to size − 8192; the longest row today is 4,110 bytes); the 4 undocumented counters are
  real. Writes under `research/` (README, `annotations.jsonl`) were done with the user's
  approval on 2026-09-29 (M1b T9); task T8 edits `jarvis.py`.
- W4, M02–M04: accepted with D-9, D-10, D-11. Verified: the probe transcript shows a
  `"category":"cyber"` refusal on claude-opus-5-5 and the CLI's fallback to
  claude-opus-4-8; `_sensitive_path` is defined at jarvis.py:1249 and never called.
  **Rule breach, self-disclosed:** an unsandboxed `emotion_context()` call rewrote
  `~/jarvis/emotions.json` at 12:46:17. The values are unchanged (equal to the baselines and
  to the 2026-08-20 dataset snapshot); only the `at` timestamp moved. No other state or
  dataset file was touched.
- W5, M05–M06: accepted with D-12, D-13, D-14. Verified: 46 of 46 tools covered;
  `write_file`, `delete_file` and `move_file` are not in Python's `EXECUTOR_TOOLS`, and
  in-home writes (including an existing `~/.zshrc` and LaunchAgents) are instant, which is a
  live injection → persistence chain in Python.
- W6, M07 + M14: accepted with D-21, D-22. Verified: the launcher branch always returns
  (the fixture shows "start a timer for 5 minutes" → "I couldn't find an app called a timer
  for 5 minutes, sir." and "start music" → launches Music); the 280-case fixture is present;
  `_apply_overlay_main` is scheduled twice (`callAfter` + `callLater 1.5`) and
  `_install_lock_observer` has no idempotence guard (the double install is real; the double
  greeting is inferred).
- W7, M08–M13: accepted with D-17 to D-20. Verified: torch 2.12.0, onnx not installed,
  onnxruntime 1.26.0, resemblyzer 0.1.4, webrtcvad 2.0.10; the Claude-path `emit()`
  (jarvis.py ~4949-4954) speaks queued sentences without a barge-in check. One detail was
  rejected: the `speakLocally` stub was a `fatalError`. It is replaced per D-17.
- W8, sudoers: accepted. Tightened, 17 entries, sha256 `ca2cfb44…`, kept in the repo as
  `native/ops/jarvis.sudoers`; `pmset` left unrestricted by the user's decision. The user
  installs it. **Rule breach, self-disclosed:** one `sudo -V` (version only).
- Integration: W1's review corrections from M00 §3.1 are applied to `ROADMAP.md`,
  `PARITY.md` and `Package.swift` (R1–R9, P1–P6, S1; S2 and S3 are T0.3 scaffold work),
  followed by the ledger edits above, the path hygiene of D-6, and `native/.gitignore`
  (`.build/`, `dist/`).

## Gaps found in today's Python JARVIS

Found while planning. None is fixed by this plan; native behaviour is in `DEVIATIONS.md`.

- `write_file` / `delete_file` / `move_file` injection gap: not executor tools, and in-home
  writes are instant. **Closed in fef66c1**: the three are executor tools, and writes and move
  destinations under startup and credential paths ask for confirmation.
- Chained-sudo guard gap: only the first command on a line is checked against the sudo
  allowlist, and the shell then runs all of them.
- The Claude-path barge-in keeps speaking the queued sentences.
- The fast-path launcher swallows "start a timer…" and "start music".
- The research 8 KB tail read can write duplicate daily rows.
- The lock observer is installed twice.
- `_sensitive_path` is dead code.
- `/etc/sudoers.d/jarvis` is missing. A tightened replacement is prepared (W8) at
  `native/ops/jarvis.sudoers`; the user installs it:
  `sudo visudo -cf ~/jarvis/native/ops/jarvis.sudoers && sudo install -m 0440 -o root -g wheel ~/jarvis/native/ops/jarvis.sudoers /etc/sudoers.d/jarvis && sudo visudo -c`.
  Rollback: `sudo rm /etc/sudoers.d/jarvis`.
- `periodic` is absent on macOS 27.2, but still in `_SUDO_ALLOW`.
- Opus 5.5 refused a probe as "cyber", and the CLI fell back to claude-opus-4-8.

## M0 build notes

Integration decisions (D-25, D-26) and findings from building M0 (T0.1–T0.10).

- **D-25. The implemented golden harness is canonical.** `native/tools/golden.py` as built
  in M0 supersedes the §3.7 sketch: every fixture has an envelope with
  `generated_from.jarvis_py_sha256`; paths are written as `${JARVIS_HOME}` tokens; time is
  frozen by `ShimTime`. M1 suites plug in as `native/tools/golden_<x>.py` (registered with
  `@suite`, discovered by the `golden_*.py` glob) and pin time with `ctx.at()`.
- **D-26. Clock type.** M01's `JarvisClock` (`func now() -> Double`, in
  `State/CoreProtocols.swift`) is canonical from M1 on. M0's
  `JarvisLog.banner(now: Date = Date(), timeZone: TimeZone = .current)` stands as built; the
  plan's `banner(clock:)` does not exist.
- **A2.** Swift Testing counts test functions, not fixture cases: `Test run with 53 tests in
  9 suites passed … with 34 known issues`. The per-case counts appear on each
  parameterised test (for example `matchesPython(_:) with 428 test cases passed`), so
  "N ≥ number of golden cases" is read against those lines.
- **A12** needs `PYTHONUNBUFFERED=1`: piped stdout is block-buffered, so without it the
  `… holds .jarvis.lock — waiting.` line is still in Python's buffer when the alarm kills it.
- **Test rule.** Tests and checks never launch a fake or unsigned `*.app` (Gatekeeper shows a
  "damaged" dialog on the user's screen). Launching the real signed `native/dist/JARVIS.app`
  for acceptance is intended; the notarized framework `Python.app` is fine. Stop JARVIS with
  `kill -TERM <pid>` (it logs `received SIGTERM — exiting.`, releases the lock, exits 0),
  never with Apple Events (`osascript … quit` triggers an Automation prompt).
- **T0.11** (`--permissions` probe) is deferred to M15. Until then `--permissions` exits 64
  rather than falling through to the GUI.
- **Flags.** `PyMath.round(x, n)` returns ±inf where Python raises `OverflowError`;
  `PyMath.round(x)` (to `Int`) is a precondition failure on non-finite or out-of-range input.
- **App order** (executor choice, differs from §3.9). `AppDelegate` configures the log sink and writes the banner before it
  logs `activation policy: accessory` (read back from `NSApp`), so the line reaches
  `logs/jarvis.log` (A9); §3.9 lists the log line before `JarvisLog.configure`.
- **M0 status: done.** Commits 2af6e32 (scaffold, StatePaths), b8e3da8 (golden.py, paths
  suite, parity inventory), 7a93659 (PyJSON, PyTime, PyMath, AtomicFile), 720d2bc
  (`jarvis.py` lock patch), ea7c85f (InstanceLock, JarvisLog), 7ad11f2 (executable-path
  test), and the commit adding this section (app shell, `build-app.sh`, A1–A13). Measured
  RAM of the idle M0 app (menu-bar shell only, 2026-09-28): `footprint` 16 MB, RSS 25,488 KB.

## M1 build notes

M1 (M01, core state and persona) and M1b (M01b, research dataset) are built by parallel
executors in git worktrees (`~/jarvis-wt/<name>`, branches `m1/<name>`), at most two at a
time. Decisions and plan changes below come from M1 judging (2026-09-28/29). Commit hashes
are the ones on `main` after the 2026-09-28 history rewrite (see Privacy below); hashes
quoted before the rewrite are not on `main`.

Integration decisions:

- **D-27 … D-30. X1 rulings**, recorded together in the ledger, in this order; each is
  registered in DEVIATIONS.md as `approved`:
  - D-27: DEV-M1-01 `unicode-version`: Swift/ICU Unicode 17 vs Python's 16.0.0; only scalars Python leaves unassigned.
  - D-28: DEV-M1-02 `R5-case-folding`: `İ`/`ı` do not fold to `i`; ICU folds `ß`/`ẞ` to `ss` and `ﬀ` to `ff`.
  - D-29: DEV-M1-03 `sub-literal-repl`: the `re.sub` replacement is literal; only a hand-edited `corrections.json` hits it.
  - D-30: DEV-M1-04 `unsupported-construct`: `\B`, `\A`, inline flags, `[\b]` and `\v` throw.

  The same ruling approved the exact `\w` translation (fenced with `(?-i:…)` under
  ignore-case, private-use scalars excluded).
- **D-31.** The root `.gitignore` rule `research/` is anchored as `/research/`: with
  `core.ignorecase` the unanchored rule also hid the `native/**/Research/` sources (`d049fec`).
- **D-32 (open).** X4's internal `PyStr` duplicates X1's `Py.*`. Unify them and adopt X4's
  Unicode-16 masking in `Py.*`, which removes DEV-M1-01.
- **D-33.** M01's `ToneAppFeedback.swift` is split into `Persona/Tone.swift` (X5) and
  `Persona/AppFeedback.swift` (X6), so two parallel executors never edit one file.
- **D-34.** Feedback logic exists once: a pure `FeedbackLogic` (in `Persona/AppFeedback.swift`),
  golden-tested against `track_feedback`; no second copy of its regex or its 0.65 threshold.
- **D-35.** `CoreState` owns the feedback last-command state and calls `FeedbackLogic` inline
  in `beginTurn` (the bump order within a turn fixes `usage.json`'s key order). M1b's
  `FeedbackTracker` is dropped; M1b builds only the `ResearchLogger` façade.
- **D-36 (M4 requirement).** `ResearchLogger` / `UsageStore` must hold the `InstanceLock`
  state lease before writing the real `research/` root, as `StateStore` does.

Plan changes:

- M01 T2 (PyJSON) and M1b T1 (JSON layer) are satisfied by M0 (D-1).
- M1b T8 was declined by the user. The `jarvis.py` dataset patch (M01b §3.7) is not applied;
  `jarvis.py` stays unpatched. Python rows stay schema 1 with no `schema` key, so a row
  without `schema` is a Python row. No Python row carries `runtime` (D-5's
  `runtime.impl = "python"` is never written), `starts_python` does not exist, and Python
  keeps its 8 KB tail read (native reads the whole last line, D2).
- M1b T9 was approved by the user: an additive section in `research/README.md` and a new
  `research/annotations.jsonl`. Both live in the gitignored `research/` folder, not in this repo.
- M1b's `FeedbackTracker` is dropped (D-35); M1b T6 is the `ResearchLogger` façade only.
- M1b T10 (`ResearchScheduler` in the app, Info.plist keys) moves to M4. Until then
  nothing native writes the real `research/` folder.
- File layout: the D-33 split above replaces M01 §3.0's single `ToneAppFeedback.swift`.

Open follow-ups:

- D-32: unify X4's `PyStr` with `Py.*` and adopt its Unicode-16 masking.
- `StateStore` recognises test sandboxes by a `jarvis-tests-*` path predicate; a test-only
  initializer would be cleaner (low priority: the current rule fails safe).
- `tools/research_schema_check.py` does not yet validate schema-2 key types or key order;
  add that once native writes schema-2 rows.
- D-36 is an M4 requirement.

Privacy:

- The GitHub repo is public, so test corpora must contain no personal data. On
  2026-09-28, unpushed M1 work was found to use personal details as sample regex inputs
  (one line in a golden plugin, and the fixture variants generated from it). Nothing had
  been pushed. The unpushed history was rewritten from the first affected commit, the
  fixture regenerated, the result rescanned, and `main` pushed at `541d9b0`. Since then,
  corpora and fixtures use neutral stand-ins only (Robin, Morgan, Sam, "the university"),
  and every executor scans its added lines for personal details before its final commit.

**M1 status: COMPLETE (2026-09-29).** Validated on `main` at `77668c0` (validation pass V1).
Merged on `main`:

- M1: `0731dd0` StateStore, core protocols, state lease on InstanceLock; `d144d12` Py string
  semantics; `f054385` PyRegex; `7c7c47e` PyDifflib; `000b46b` personality; `7b033a4`
  emotions and tone; `9227a3e` neutral style-corpus phrases; `dcd9265` shared
  `StateShapeError`; `54fedad`, `aa258e2` taught corrections; `52775cd` history, app
  context and feedback logic; `2e6a5e8` corrections and history throw `StateShapeError`;
  `2e965b8` profile and knowledge base; `97a91ac` system prompt builder and `CoreState` turn
  pipeline (M01 T11, X8; the system prompt is byte-identical to Python's); `9fea3e3` persona
  consolidation and distillation (M01 T12); `77668c0` cross-implementation proof: Python
  reads Swift-written state, opt-in real-state round-trip (M01 T13).
- M1b: `ccf01dd` research oracle, counter keys, line count, git probe, clock; `23049d6`
  UsageStore and MetricsLog (D1–D4); `d049fec` D-31; `3a94af0` read-only schema-compat
  check over the real dataset (judged: it round-trips byte-identically); `fdc65e5` snapshot
  builder; `d75fd2b` ResearchLogger façade.
- Docs: `7c80fe9` M1 deviations and build notes; `0a2f025` statuses and open decisions; the
  final deviation (R8-list-content) and this status in the commit that follows them.
- Tests: `swift test -j 2` runs 153 tests in 38 suites, 0 failures, 162 known issues
  (6,858 parameterised cases). A clean `swift build -j 2` has 0 warnings.
- Golden: 23 fixtures, 6,799 cases (5,716 of them in the 19 `m1_*` / `m1b_*` fixtures).
  `golden.py --check` 23/23 fresh; `golden.py all` is byte-reproducible;
  `parity_inventory.py --check` 0 missing, 0 stale.
- Divergences: 120 fixture cases carry a native divergence marker (107 in M1/M1b, 13 in
  M0), recorded as 162 known issues. Every label maps to an `approved` row in
  `DEVIATIONS.md` (58 entries, 31 approved). M1/M1b added 19 approved rows: DEV-M1-01…04,
  R3, D1–D5, D1a–D1c, D5a and the five `R8-*` rows.
- Acceptance: M01 §5 A1–A10 pass. A1/A2 ran the 12 `m1_*` suites by name (`golden.py` has
  no `--only`), A3's `check-ignore` needs the glob expanded from `native/`, and A9's pickup
  runs as `golden.py readback <dir> m1_pickup`. M01b §5 A1–A6 pass: A1 ran the 7 `m1b_*`
  suites; A3 prints `rows 15 dates 15 first 2026-07-23 last 2026-08-20 violations 0
  unchanged yes`; A4 prints `roundtrip rows=15/15 usage=identical unchanged=yes`. M01b A7
  moves to M4 with T10; A8 is N/A (T8 declined). M0 A1–A13, re-run on the M1 tree, pass
  (A5 with `--exclude-dir=.build`; A11 quits the app with SIGTERM). The real state files
  and `research/` stayed byte-identical (sha256, size, mtime) through the whole validation.
  The personal-data and secret scan of `origin/main..main` found 0 hits.
- Carried forward to M4: D-36 (`ResearchLogger` / `UsageStore` hold the `InstanceLock` state
  lease before writing the real `research/` root) and D-37 (the snapshot's corrections and
  history counts come from `CoreState.snapshotInputs()`, as Python counts its in-memory
  cache, not from the files).

## Open user decisions

- Write `shouldSpeakReply` (text chat, M02–M04 §3.12) and `speakLocally` (sensitive routing
  to Piper, M08 §3.2). The user writes both.
- Any download or brew install (webrtc VAD source, espeak-ng): only if the spikes fail, and
  only with approval.
- Deleting or renaming the `~/jarvis-swift` prototype (T0.2 only unregisters it).
- The M15 benchmark needs Python JARVIS and Ollama running.
- ElevenLabs: the user creates the account and plan, and stores the API key in the Keychain.

Resolved, no longer open: writes under `research/` were done in M1b T9 on 2026-09-29 with
the user's approval (an additive README section and `annotations.jsonl`); the `jarvis.py`
dataset patch (M1b T8) was declined by the user.
