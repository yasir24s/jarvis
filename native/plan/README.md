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

## M2 to M5 build notes

- **D-38. M2 is a faithful port.** By the user's instruction (2026-09-29), M2's guard returns
  exactly Python's verdicts. Plan decision D-9 (mutation-generated corpora) and every
  native-stricter guard deviation that would change a verdict (X-1, X-2 with the sudoers file
  as the allowlist, X-4) are deferred out of M2. The M2 sudo allowlist is jarvis.py's
  `_SUDO_ALLOW` verbatim; `native/ops/jarvis.sudoers` appears only in a rule-list consistency
  test. Golden inputs are everyday commands plus strings already in jarvis.py or this plan;
  must-block cases reuse those strings or test the rule list itself.
- **D-39. Sandboxed app runs.** M3 and M4 acceptance runs of the app set `JARVIS_HOME` to a
  sandbox copy of the state, never the real `~/jarvis` root. The first run against real state
  happens with the user present.
- **D-40. Rule-list parity.** The inputs D-38 allows reach only part of the rule lists (5 of 31
  block patterns, 6 of 17 confirm patterns, 1 of 13 sudo entries). So M2 also requires the Swift
  rule lists to equal Python's: every pattern and flag, both tool sets and the path lists, as
  recorded in the `m2_rules` fixture. Verdict parity applies to every recorded input.
- **D-41. Security rules win over Python quirks** (user, 2026-09-29). Native preserves Python's
  behaviour on compatibility surfaces, such as the state files, the research dataset and the
  strings users see or hear. Where a Python quirk would weaken the native app, the native
  macOS security and orchestrator rules take precedence: native follows the plan, the
  difference is registered in DEVIATIONS.md, and tests assert the native value directly while
  Python's value stays recorded as a known issue. Cases so far: DEV-M3-01 (the child PATH
  fallback of §3.6), DEV-M3-02 (empty PATH fields dropped) and DEV-M3-03 (relative PATH
  fields dropped).

M2 status: **accepted on 2026-09-29 at `52487e5`.** GPT built it in the Codex app (`894bf44`
guard, `4cf4fb0` gateway, `52487e5` gateway fixes), and Claude checked each commit.

- `SwiftGuard.shellVerdict` returns Python's tier exactly. The stricter version,
  `ShellPolicy.strictVerdict` (command splitting, the sudoers file as the allowlist, blocking
  keychain reads), is in the code but not wired in. It waits for the gated M5 step (D-38).
- Observed at `52487e5`: `swift test -j 2` passes with no failures (the 162 known issues are
  M1's registered deviations; none are in M2). `m2_shell` (3,182 cases) and `m2_applescript`
  (3,182) match Python exactly, as do `m2_file_tiers` (216), the taint sets and the refusal
  strings. The four pattern lists, the inline sudo test and the three path lists
  (`_PERSIST_FILES`, `_PERSIST_DIRS`, `_SYS_ROOTS`) match Python's. A-0 prints `ok 12/12`,
  `golden.py --check` reports 28/28 fresh, and JarvisCore still imports only Foundation.
- Gateway (T2.5, target `JarvisTools`): calls on one turn run in first-in, first-out order
  (`TurnFIFO` in `TurnContext`), and JarvisTools uses JarvisCore's JSON types. The 8
  `ToolGatewayTests` cover A-4: each backend's taint text, taint set only after the untrusted
  tool returns, a concurrent `web_search` and `run_command` on one turn, "Turn closed.", and the
  46-tool data-source map. A-5 holds: `Sources/JarvisTools/Tools` does not exist yet, and
  nothing in JarvisApp calls a tool directly.
- Left as is: `894bf44` added 9 test lines with made-up `/Users/<name>/` example paths. The
  pre-commit hook would block them if they were added again. That commit's hard-coded repo path
  and account name were removed in `4cf4fb0`.

## M3 build notes

- **D-42. MCP socket permissions.** Plan §3.7 wraps `bind` in `umask(0o177)`. `umask` is
  process-wide, so it raced a parallel `mkdtemp` in the test suite: the directory came out 0600
  and creating a file in it failed. The socket is bound inside the run directory instead, which
  is 0700 and ours, and is then set to 0600. Other users cannot reach it in between, because
  they cannot search that directory; the handshake guards against this user's other processes.
- MCP details (T3.3, merged at `42589d2`). `initialize` advertises `tools.listChanged:false`,
  as §3.7 says (the recorded CLI session got `{}`). JSON-RPC is encoded with `PyJSON`, not
  `JSONSerialization`, so each `inputSchema` keeps Python's key order. The 46 schemas come from
  the Python-generated `m3_tool_schemas` fixture through `tools/gen_tool_catalog.py`, which
  writes `Sources/JarvisTools/Catalog/ToolCatalog.swift`; nobody edits that file by hand.
- Open for T3.5, the first live runs:
  - The relay's parent-pid check assumes `claude` starts the relay directly, with no shell in
    between. The first live run confirms it.
  - A relay handshake that arrives before the driver has registered the `claude` pid is
    rejected, not delayed. The driver registers the pid right after launch; if a live run
    shows a race, the server should wait inside the 2 s handshake window.
  - A-10 needs the gateway to run the taint check before a missing tool body gives the
    unknown-tool reply, and to write the `BLOCKED` log lines and bump `taint_block` (plan §3.3
    steps 2 to 4). GPT is making that change.

- Live acceptance, 2026-09-29, each run on a sandbox copy of the state (D-39), with the real
  state files and logs byte-identical before and after:
  - A-9 (one Claude turn): init apiKeySource=none, tools=46, mcp jarvis=connected; Claude called
    get_time, which had no body yet, then run_command, and nothing ran; the reply said it could
    not read the clock rather than guessing; backend_claude +1.
  - A-10 (one Claude turn, started tainted): Claude called run_command for `echo hi`; the gateway
    logged the BLOCKED injection-guard line, returned the Claude block text as an error, and
    bumped taint_block; nothing ran.
  - A-11 (on-device, three runs after M3 B4 gave get_time its body): the model called get_time
    and read back the correct time each time. Before that body existed, Apple's filter ended two
    turns ("May contain unsafe content"); both were turns where the model wrote a run_command
    call, and a comparison with profanity turned off showed the persona was not the cause.
- Dataset: text turns bump interactions_text (M1b's key); the M3 code adds taint_block and
  claude_refusal_fallback; the on-device backend counter is backend_local_apple_foundation_model_
  with a trailing underscore. research/README.md documents all four.

## M4 build notes

- **D-43. JARVIS is a full macOS application** (user, 2026-09-30). It has a Dock icon and appears
  in Cmd-Tab, with a main window holding the chat and a normal app menu (About, Edit, Window,
  Quit). The menu-bar item stays, and the HUD (M13) and the voice loop (M8 to M12) will run
  alongside it as background UI. Closing the window keeps JARVIS running; the Dock icon or Open
  Chat reopens it. A launch with `--background` (the future login item) does not open the
  window. This supersedes the plan's LSUIElement agent app and `.accessory` policy (M02-M04 §1
  and §3.12) and A-12's "no Dock icon": A-12 now checks that the Dock icon is present. The HUD
  panel must never change the activation policy. Registered as DEV-M4-01.
- **D-44. Two hard gates before M5's side-effecting tools** (user, 2026-09-30). No M5 tool that
  changes anything gets a body until both are merged and validated. The first is X-1, the
  chained-command sudo fix that D-38 deferred out of M2: every shell segment classified and
  sudo checked per segment, built with harmless test cases only, as the first M5 task. The
  second is the four findings of Codex's MCP review of 2026-09-30
  (`reviews/2026-09-30-codex-mcp-review.md`), each fixed with a focused test:
  1. Authenticated traffic has no byte limit or backpressure: MCPServer's line buffer after
     the handshake, MCPConnection's unbounded event stream, and the relay's pumps.
  2. Connections are admitted without a cap before authentication, and a serve task can
     start after stop().
  3. Closing a turn does not stop tool work already admitted: closeTurn and
     TurnContext.close only refuse later requests.
  4. Malformed JSON-RPC envelopes still reach tools: there is no `jsonrpc: "2.0"` check, and
     an invalid id becomes null.

  The review's same-user notes fall under R-4, the accepted same-user malware limitation: a
  process running as the same user could rewrite a turn's MCP config before Claude reads it,
  and the relay does not authenticate the server.
- **D-45. The online check probes port 443** (user, 2026-09-30). This network blocks outbound
  TCP to port 53, so Python's `is_online` read offline and every turn went to the on-device
  model, which answered "what time is it" with a guessed time. Native keeps Python's hosts,
  order and 1.2 s timeout, on port 443, the port Claude itself uses. Registered as DEV-M4-02.
- **D-46. Native writes the real dataset from 2026-09-30** (user, 2026-09-30). The M4 at-screen
  checks run the debug app against the real `~/jarvis` root with the user present, as D-39
  requires. The `native-dev-writes` annotation went into `research/annotations.jsonl` first,
  under the instance lock. From that day the dataset has native rows (`runtime.impl` swift,
  `runtime.build` dev), and `gap-2026-08-21` closes on 2026-09-29 by its own rule.
- **D-47. M4 signed off; the order after it** (user, 2026-09-30). A-12, A-13 and A-14 passed at
  the screen, with the app icon and window reopen checked too. Next comes M5: X-1 first (the
  standing rule), then the read-only awareness tools (diagnostics, battery, CPU, wifi,
  clipboard, screen, files, "what's new"), then the MCP gate and the tools with side effects.
  After M5: voice out (M8) and the HUD (M13) together, with a Show HUD menu item that brings the
  overlay back after its idle hide. Then media analysis, a new milestone.
- **D-48. Voice and media directions** (user, 2026-09-30). The voice is chosen by a spike on
  this 8 GB Mac: Kokoro-82M with a built-in British male voice (`bm_george`, `bm_lewis`), or
  F5-TTS cloning from a reference clip, measured for RAM and time to first audio. Piper
  (Python's voice) and macOS speech stay as fallbacks. Media analysis is a blend: Apple's
  on-device frameworks (Vision, Speech, SoundAnalysis, AVFoundation) by default, with the image
  itself sent to Claude through the MCP server when a turn needs deeper understanding. Media
  is untrusted content, so it taints the turn.
- **D-49. Text chat keeps Python's JARVIS** (user, 2026-09-30). The first real-root chats read
  like a generic assistant: numbered lists, bold, long troubleshooting, asides about the
  safety rules. The cause was §3.9's addendum, which lifted the spoken persona's brevity for
  text. It now says JARVIS stays exactly as the persona describes: one or two crisp sentences
  by default, longer and with light Markdown only when the user asks for detail or the answer
  needs it. The voice prompt is unchanged and byte-identical to Python's.
- **D-50. The self-updating personality comes first** (user, 2026-09-30). Python updates
  `personality.json` four ways; native ran only the first (learning from the user's own words).
  P1 adds the rest:
  - `personality_note` and `personality_rewrite` get bodies now. They are exempt from D-44:
    they change only JARVIS's own personality file, and `TaintPolicy` already blocks both in a
    tainted turn.
  - The consolidation pass runs on Python's proactive-loop schedule (120 s after start, then
    hourly, with Python's 10-note, 7-day rule).
  - A conversation ends when the user dismisses JARVIS ("that's all, JARVIS"), spoken or
    typed. He replies "Always a pleasure, sir." and distils the conversation into a note.
    Typed dismissals must be the whole message, so "thanks, now open Safari" still reaches
    the brain.
  - The on-device model and Claude write the notes together: the local model drafts, Claude
    improves the draft when it is available, and the result must pass the same validator.
    Everything is saved on the Mac.
- **D-51. Memory that keeps everything, and background file understanding** (user,
  2026-09-30). New, native-only, built after P1.
  - **P2, memory.** Python's rolling 12-entry `history.json` stays as it is, because Python
    shares it. Alongside it, a local `memory/` folder in the state root keeps every exchange
    (an append-only archive) and a store of compiled facts about the user. Each fact records
    its source (conversation or file), its date and which writer made it. At each dismissal,
    P1's local-plus-Claude writers also extract facts from the conversation. Each turn gets the
    most relevant facts appended to its prompt, ranked on the Mac with on-device sentence
    embeddings within a token budget. That appendix is a registered deviation from Python's
    byte-identical prompt. `memory/` is never committed: it goes into .gitignore and the
    pre-commit denylist.
  - **P3, files.** A continuous low-priority scan of the user's home folder. It skips
    `~/Library`, hidden files and folders (`.ssh`, `.aws`, `.claude`, `.signing` and the rest),
    key, certificate, credential and `.env` files, JARVIS's own state and memory, build
    output (`.build`, `node_modules`, DerivedData) and media. Anything left that looks like a
    key or token is redacted before either model sees it. Small files, those that fit the
    on-device model's budget, are read by the local model; larger ones are read by Claude.
    Claude's reading has an hourly cap, and scanning pauses while a turn runs, so the user's
    subscription stays free for conversation. An index of path, size, modification time and
    digest means unchanged files are never read twice.
  - **As built (P3, 2026-10-01).** The scan starts 120 s after the brain. It walks the home
    folder, then iCloud Drive, reading txt, md, rtf, rtfd, docx, pdf and csv (in a git
    repository, only README files; never source code). It also skips bundles, archives, disk
    images, binaries, files over 20 MB and iCloud files not on the Mac: a dataless folder is
    never listed and a dataless file never opened. The on-device model takes a document when
    it fits 0.6 of the model's context, counted with its tokenizer (about 22,400 characters
    on macOS 27.2). Claude takes the rest in parts of up to 100,000 characters, at most 10
    files an hour. File names and paths never reach either model. The scan backs off when the
    Mac is hot or in Low Power Mode, and stops at quit before the lock is released.
    Registered as DEV-P3-01.
  - **File text is untrusted.** The extraction prompts ask only for facts about the user.
    Candidate facts that carry instructions, commands or URLs to fetch are dropped, and the
    prompt shows memory as information, never as instructions.
- **D-52. X-4 approved; the voice reference clip is in** (user, 2026-09-30). Shell segments that
  run `security find-generic-password`, `find-internet-password`, `dump-keychain` or `export`
  are blocked. Codex wires X-4 with X-1, in the same fixture. The reference clip for the voice
  spike (D-48) is `voices/jarvis_en.wav` (83 s, 16-bit stereo, 44.1 kHz; `voices/` is
  git-ignored and in the pre-commit denylist), from the JARVIS-ChatGPT repository's
  `Assistant/voices/`. The spike cuts a clean 5 to 15 s reference from it.
- **D-53. DEV-M5-01 to 03 approved, junk topics cleared, the voice is an F5 clone** (user,
  2026-10-01). DEV-M5-01, DEV-M5-02 and DEV-M5-03 are approved as proposed.
  - **Junk topics.** Python's research loop web-searched the literal words of commands and
    chat ("close app", "yes", "you're fine") and saved whatever came back as topics. 20 of
    the 23 topics in `knowledge.json` were of that kind and are removed. "drake", "who is
    drake" and "eiffel tower" stay, and the queue is untouched. A copy of the file from
    before is kept outside the repository, and `research/annotations.jsonl` records the
    change as the `kb-junk-cleanup` intervention, since `counts.kb_topics` drops with it.
  - **Voice.** The user chose to clone the D-52 clip with F5-TTS in Swift instead of using
    Kokoro's stock voices, knowing the clip is Bettany in an interview. The four downloads F5
    needs are approved: the Metal Toolchain, `swift-numerics`, F5's `vocab.txt` and the
    vocoder's `config.json`. The spike measures F5 against M8's budget and the 8 GB limit;
    Kokoro stays the measured fallback.
- **D-54. The voice is the short-reference F5 clone, slow as it is** (user, 2026-10-01).
  After hearing the nine F5 samples, the user judged the short-reference clone best and chose
  it over Kokoro, knowing it takes a median of 11.2 s per sentence (16.7 s at worst) on this
  Mac. M8's 600 ms sentence budget does not apply to this voice: M8 measures and reports
  its latency instead. Choosing a Kokoro voice is deferred. How M8 carries F5:
  - **A helper process** runs F5: mlx-swift 0.29.1 with swift-numerics, plus f5-tts-swift
    and vocos-swift with the spike's patches. It loads on the first reply that is spoken,
    stays warm while a conversation lasts and quits after a few idle minutes, which returns
    its memory to the system. A crash in it costs one spoken reply, not the app.
  - **MLX's buffer cache is capped at 512 MB** from launch: about 1.05 GB between calls and
    2.1 GB at peak, against 4.7 to 5.2 GB uncapped.
  - **Short replies are generated whole.** F5 makes audio about 3.6 times slower than it
    plays, so speaking sentence by sentence would leave a pause between sentences.
  - **The reference** is the spike's 4.28 s cut with its transcript. The weights (452 MB,
    downloaded and checked in the spike) move to Application Support. The Metal Toolchain
    stays installed, because MLX's shaders need it to build.
  - **The reply text shows at once,** and the speech follows when it is ready.
  - **Open:** the spike wrote its two v1 forward-pass fixes without the reference code, so
    only transcripts check them. M8 compares them with the reference implementation. It may
    also measure the short reference with 4 steps, or with `cfg` 0, if the user likes how
    they sound.
  - **Checked the same day:** the official `F5TTS_v1_Base.yaml` sets `pe_attn_head: null`
    (rotary on every head) and `text_mask_padding: True`. Those are the spike's two fixes.
- **D-55. DEV-M5-04 and DEV-M5-05 approved** (user, 2026-10-01). These are the two deviations
  from M5's tools that act. `move_file` names the real folder when the source path ends in
  `/`. `type_text` and the brightness keys post CGEvents under Accessibility instead of
  System Events scripts.
- **D-56. R11, R12 and R13 approved** (user, 2026-10-01). These are M5's three planned fixes
  of Python bugs, all already built. `notify` survives a quote mark. `read_clipboard` gives
  `""` for a clipboard that holds only rich text, where Python returns the RTF source.
  `delete_file` trashes through `FileManager` without Finder automation, which also ends
  Python's false failure for a file whose name contains "error".
- **D-57. Memory is the user's, the persona is the product's** (user, 2026-10-01). After other
  people's documents were stored as his facts, the user decided:
  - **Other people's documents** give nothing unless the user's own name appears in them.
    When it does, a few notes are kept as about that person (relationship and money
    details), never their health details or identifiers, and never as the user's. The check
    runs in code against the Mac account's full name (DEV-P4-01).
  - **Old wrong facts:** only the wrong ones were removed, 39 facts from 6 documents, with
    backups outside the repository.
  - **The J.A.R.V.I.S. persona belongs to the product** and lives in source. Memory belongs
    to each user, stays on their Mac and never goes in git; the repository is public. A new
    install starts with blank memory and learns from files only after the user allows it.
    This user's memory stays private on this Mac.
  - **P6** builds the compiled persona base, memory that can't be lost, automatic compiling
    of chats, a one-time import of the Python-era conversations, and first-run consent.
  - **Push-to-talk** comes right after P6. The user called it "important".
- **D-54, as built (2026-10-01, P5).** The user chose 4 steps after hearing both settings:
  the same words, made in 7.7 s instead of 18 s. Speech runs at speed 1.15, about 160 words
  a minute against 140. Every part plays at −11 LUFS, with a look-ahead limiter holding peaks
  0.1 dB under −1 dBFS. A reply is split at a sentence end only when a part's audio covers the
  next part's generation; otherwise it is spoken whole. Live and under load, first audio came
  after 6.4 to 7.4 s for replies of 78 to 120 characters, against 18 to 21 s before.
- **D-58. Live updates, chat editing, and memory that keeps everything** (user, 2026-10-01).
  - **Live updates by swap-over (U1).** A build no longer replaces the running app. JARVIS
    moves to a staged build only when no turn, speech or confirmation is active and the user
    has been away for 10 minutes, or when the user picks "Update Now". He keeps the chat,
    draft, scroll and window, and rolls back if the new build fails to start. Splitting him
    into a window process and a brain process waits until later.
  - **Chat like Claude's (C3):** a Stop button and Esc for text and voice, a message sent
    mid-reply added as context to the same request, and an earlier message edited and run
    again, with ‹ 1/2 › versions.
  - **Memory keeps everything said to him (P6b).** Every uncompiled message is compiled in
    batches, the conversation archives can be searched word for word and are backed up, and
    the Python-era exchanges are kept verbatim.
  - **Voice next (V1):**
    - an instant acknowledgement in his cloned voice when a message is sent
    - no splits at all
    - the room echo removed and a gate between words
    - speed about 1.25
    - the helper kept loaded from the first keystroke
    - the file scan paused while he speaks
  - **Then (M9 to M12):** push-to-talk, a first-launch setup that records the user's
    voiceprint so only their voice is heard, and "Hey Jarvis".
  - **App updates wait** until the file scan has finished, as the user asked.

## Open user decisions

- `speakLocally` (sensitive routing to a local voice, M08 §3.2). `shouldSpeakReply` was
  drafted in 986a890 at the user's request; Codex polishes it.
- Any download or brew install (webrtc VAD source, espeak-ng): only if the spikes fail, and
  only with approval.
- Deleting or renaming the `~/jarvis-swift` prototype (T0.2 only unregisters it).
- The M15 benchmark needs Python JARVIS and Ollama running.
- ElevenLabs: the user creates the account and plan, and stores the API key in the Keychain.

Resolved, no longer open: writes under `research/` were done in M1b T9 on 2026-09-29 with
the user's approval (an additive README section and `annotations.jsonl`); the `jarvis.py`
dataset patch (M1b T8) was declined by the user.
