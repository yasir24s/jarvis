# Native JARVIS — deviations register

Every place where native JARVIS is planned to behave differently from Python JARVIS on
purpose. Policy (integration decision D-4, `plan/README.md`): native matches Python by
default, enforced by golden fixtures; each deliberate difference is listed here and has its
own marked fixture or test, where the deviating case carries `"deviation": "<ID>"`.

Line numbers refer to jarvis.py @ 68cd112.

- **IDs** are the plan authors' own (`X-n`, `Dn`, `DEV-…`, `Rn`), so the plan text still
  matches. They are only unique together with the **source** column. Where an integration
  decision covers the entry, it is shown as `→ D-n`.
- **Status.** `approved` = approved in the judging ledger (D-12, D-15, D-18, D-21, and X-1
  via D-11 "D-1 yes"). Everything else is `proposed — decide at milestone start`. Where the
  ledger already rules on a related point, the reason column says so under **Ledger:**.
- Consolidated 2026-09-28 by grepping each section for `DEV-`, `X-[0-9]`, `D1`–`D5`
  (M01b), "deviation" and "improvement". Nothing here is built yet.

| ID | Milestone | Python behaviour | Native behaviour | Reason | Fixture marker | Status | Source |
|---|---|---|---|---|---|---|---|
| R3 | M1 | Unparseable state file is silently overwritten with defaults | Same, but first copies the bytes once to `logs/state-backups/<name>.<epoch>.unreadable` | Recoverability; additive, changes no Python-visible bytes. **Ledger:** D-3 "APPROVED" (not in the status list above) | `StateStoreTests` (T3; tests only, no fixture) | `proposed — decide at milestone start` | M01-core-state-persona.md §3.5, §8 R3 |
| D1 | M1b | Unparseable non-empty `usage.json` → `{}` → all past days overwritten | Copies the original bytes to `research/usage.json.corrupt-<unix>` (never overwritten), logs, then writes the Python-identical result | Protects the dissertation series. **Ledger:** listed as a known deliberate fix in D-4 | `bump.json` | `proposed — decide at milestone start` | M01b-research-dataset.md §3.4 |
| D2 | M1b | Last date read from the last 8 KB only; a last line ≥ 8 KB gives hourly duplicate rows | Reads the complete last line (backwards scan in 8 KB chunks, no limit) | Verified bug (max row 4,110 B today). **Ledger:** listed in D-4 | `last_date.json` | `proposed — decide at milestone start` | M01b-research-dataset.md §3.4 |
| D3 | M1b | Truncate-and-write `usage.json` | Temp file in `research/` + `rename(2)`, mode 0644 | Atomicity | `ResearchLoggerTests` (A5) | `proposed — decide at milestone start` | M01b-research-dataset.md §3.4 |
| D4 | M1b | Appends after a dangling partial line (merges two rows) | If the file is non-empty and does not end in `\n`, writes `\n` first; the fragment stays a skippable malformed line | Row integrity | `ResearchLoggerTests` (A5) | `proposed — decide at milestone start` | M01b-research-dataset.md §3.4 |
| D5 | M1b | Missing/unreadable `jarvis.py` → exception → no row that day | Row written with `code.bytes`/`code.lines` = `null`, git fields as usual, plus a log line; README documents it | Series continuity after cutover (`jarvis.py` stays in the repo, §8 R4) | `snapshot.json` | `proposed — decide at milestone start` | M01b-research-dataset.md §3.4 |
| X-1 | M2 | `_SUDO_ALLOW.search` runs over the whole line, so only the first command is checked; `shell=True` then runs every chained command | Every shell segment is classified, sudo checked per segment, unparseable → block | Verified sudo-chaining gap. **Ledger:** D-11 "D-1 yes" | `deviations/shell_chain.json` | `approved` | M02-M04-security-brain-chat.md §2.3, §3.2, §8.1 |
| X-2 | M2 | `_SUDO_ALLOW` as written, including `^sudo\s+periodic` | Effective allowlist = `_SUDO_ALLOW` ∩ commands granted by `native/Resources/sudoers/jarvis`; `periodic` removed (binary absent) | The OS file will be tighter. **Ledger:** D-11 W4-D-2 = tightened sudoers (W8, user installs) | `deviations/sudo_effective.json` | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §3.2, §8.1 |
| X-3 | M2 | System-path check on the lexical abspath only | Also checks the `realpath(3)` of the nearest existing ancestor; either true → refuse | Symlinks and non-canonical spellings | `PathPolicyDeviationTests` | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §3.2, §8.1 |
| X-4 | M2 | No `security`-specific rule (the plan lists X-4 as stricter than Python) | Segments running `security find-generic-password` / `find-internet-password` / `dump-keychain` / `export` → block | Protects the Keychain-held ElevenLabs key | `deviations/shell_chain.json` | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §3.2, §8.1 |
| X-5 | M2 | `_sensitive_path` is defined (jarvis.py:1249) but never called | Enforced for read_file / write_file / delete_file / move_file with a fixed refusal line | Python dead code. **Ledger:** D-11 overrides W4-D-3 to **OFF** (user's July "full read access"; the taint guard is the control), so expect this to be dropped | W4 D-3 (decision) | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §3.2, §8.1; M05-M06-tools.md §8 R1 |
| X-6 | M3 | Claude bridge could run parallel tool calls before the taint was set | Calls for one turn run strictly one at a time, in arrival order (per-turn FIFO) | Taint race | A-4 | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §3.3, §8.1 |
| X-7 | M4 | Confirmation by voice, checked against the enrolled voiceprint | Typed confirm needs LocalAuthentication; a failed auth gives "Confirmation cancelled, sir." | Text has no voiceprint | A-13 | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §3.4, §8.1 |
| X-8 | M4 | No text channel | Pasted or dropped text starts the turn tainted | Paste is an injection route. **Ledger:** D-11 W4-D-8 ON | W4 D-8 (decision); paste test in T4.2 | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §3.5, §3.12, §8.1 |
| X-9 | M3 | claude-agent-sdk bridge; strips `ANTHROPIC_API_KEY` from the child env (jarvis.py:4835). The plan lists the rest as stricter than Python | Allowlisted child env; `--strict-mcp-config`, `--permission-prompts none`, `--no-session-persistence` | Orchestrator rule; stricter | A-8 | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §8.1 |
| X-10 | M3 | None of these checks (the plan lists them as stricter than Python) | Turn killed on API-key auth, unexpected tools, or overage (R1/R3/R8) | Subscription-only use. **Ledger:** D-11 W4-D-4 ON covers the overage kill only | unit tests | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §8.1 |
| X-11 | M3 | `result.is_error` could be spoken as the reply | Treated as a failure (fallback path) | Never speak an error string as an answer | unit test | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §8.1 |
| X-12 | M3 | Ollama `qwen2.5:3b` is the local fallback | `--include-partial-messages`; FoundationModels replaces Ollama; history folded into instructions; 10-call cap (behavioural, not security) | Latency; native has no Ollama | A-11 | `proposed — decide at milestone start` | M02-M04-security-brain-chat.md §8.1 |
| R2 → D-12 | M5 | `EXECUTOR_TOOLS` (jarvis.py:4843-4847) omits write_file / delete_file / move_file; in-home writes, moves and trash are instant, including existing `~/.zshrc` and `~/Library/LaunchAgents` (injection → persistence gap, verified 2026-09-28) | Executor set = Python's + {write_file, delete_file, move_file}; writes/moves into dotfiles (`~/.zsh*`, `~/.bash*`, `~/.profile`), `~/Library/LaunchAgents`, `~/.ssh`, `~/Library/Keychains`, `~/.claude` → confirm tier even in home | Security. Python fix task stopped by the user before any change, so Python keeps the gap and this stays a deviation (PARITY.md `X*`) | to add: marked cases in `taint_sets.json` (G16) and the G9 files suite — not yet in the M05 plan, which implements Python's sets | `approved` | M05-M06-tools.md §8 R2 |
| R3 → D-15 | M5 | `get_wifi_status` via `networksetup`, which reports "not associated" while en0 is up on macOS 27 (oracle broken) | CoreWLAN SSID (needs the Location grant), reply in networksetup format | Oracle broken on this OS | A-SYS-4 (manual) | `approved` | M05-M06-tools.md §3.5, §8 R3 |
| R4 → D-14 | M6 | summarize_page and find_song_by_lyrics call `_ask_model` (Ollama `qwen2.5:3b`) | Brain chain: Claude CLI → FoundationModels; lyrics tool still returns title + artist only, never lyrics | No Ollama in native. **Ledger:** D-14 decides this route (not in the status list above) | none: answers cannot be golden-tested | `proposed — decide at milestone start` | M05-M06-tools.md §3.5, §8 R4 |
| §3.6 (no ID) | M5 | No outer timeout on a tool call | Registry safety net at 120 s → `Tool error: timed out` | Only shows on a hang | not stated in the plan | `proposed — decide at milestone start` | M05-M06-tools.md §3.6 |
| R11 | M5 | `notify` breaks silently on `"` | Quotes escaped; reply always "Notification shown." | Intentional improvement | flagged in PARITY evidence | `proposed — decide at milestone start` | M05-M06-tools.md §3.5, §8 R11 |
| R12 | M5 | `pbpaste` returns RTF source for an RTF-only clipboard | `""` for an RTF-only clipboard | Intentional improvement | flagged in PARITY evidence | `proposed — decide at milestone start` | M05-M06-tools.md §3.5, §8 R12 |
| R13 | M5 | Trash via Finder Automation; a filename containing "error" reports a false failure | Trash via `FileManager`, no Automation(Finder); false failure fixed; whether Put Back works is not verified | Intentional improvement | A-FILE-3 (manual Put Back check) | `proposed — decide at milestone start` | M05-M06-tools.md §3.5, §8 R13 |
| R14 | M6 | Reminder due `(current date)+offset`, which runs 1 s early | EventKit exact due date | Intentional improvement | flagged in PARITY evidence | `proposed — decide at milestone start` | M05-M06-tools.md §3.5, §8 R5, R14 |
| DEV-M7-01 | M7 | `start a timer for 5 minutes` → open.app, "I couldn't find an app called a timer for 5 minutes, sir.", no action | timer.set → `_set_timer(300)` | Launcher branch always returns, so it swallows the phrase | `fastpath_deviations.json` | `approved` | M07-fastpath-M14-loops.md §4.2, §8.1 |
| DEV-M7-02 | M7 | `start music` / `start the music` → open.app, "Opening Music, sir." + launch Music | media.play, "Playing, sir." + `_media("play")` (the set entries are dead code today) | Same launcher bug | `fastpath_deviations.json` | `approved` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-03 | M7 | `run diagnostics please` → open.app, "I couldn't find an app called diagnostics please, sir." | Defer to the LLM, which calls run_diagnostics | Plan recommendation: optional | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-04 | M4 | `go to sleep` typed in chat (no `is_dismiss`) → open.app, "I couldn't find an app called sleep, sir." | M4 applies `is_dismiss` before the router; router unchanged | Plan recommendation: fix in M4, not M7 | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-05 | M7 | `notes` / `notebook` → note.make → `_make_note("s")` / `("book")`, creating a Notes note | Defer (require `\s` or `:` after bare `note`) | Regex bug | `fastpath_deviations.json` | `approved` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-06 | M7 | `that's right not wrong` → corr.teach, learns "wrong"→"right" | unchanged | Plan recommendation: keep parity (the teach grammar is intentional) | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-07 | M7 | `see screen time` → screen.fuzzy → `_screen_help("see screen time")` | unchanged | Plan recommendation: keep parity | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-08 | M7 | `what's my airpods battery status` → battery → Mac battery | Defer | Plan recommendation: optional | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-09 | M9 | `what’s playing` (U+2019) → defer | Router unchanged; M9 folds U+2019 → `'` in STT output (whether SpeechTranscriber emits curly quotes is unverified) | Plan recommendation: fix in M9 | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M7-10 | M7 | `open settings app` → open.app, "I couldn't find an app called settings app, sir." | unchanged | Plan recommendation: keep parity | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M14-01 | M14 | Lock observer installed twice (jarvis.py:5431 + 5433, no idempotence guard) ⇒ likely two unlock greetings (inferred, not verified) | Install once, one greeting | Double install is real; double greeting inferred | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M14-02 | M14 | `speak()` has no lock; background speech can overlap a reply | All speech through M8's serial queue | Overlapping audio | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M14-03 | M14 | `_alarm_timers` keyed by ISO time, so a second alarm at the same minute overwrites the first handle and cancel misses one | Key per entry (UUID) | Lost alarm handle | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M14-04 | M14 | Non-integer `JARVIS_LOW_BATTERY` / `JARVIS_MEETING_ALERTS`: `int()` at import raises, JARVIS fails to start | Treated as 0 (off) + log line | Robust start | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| DEV-M14-05 | M14 | `JARVIS_NO_HUD=1` ⇒ no lock observer ⇒ no unlock greeting | Observer independent of the HUD | Plan recommendation: decide (M07 §8.3 Q2) | `fastpath_deviations.json` | `proposed — decide at milestone start` | M07-fastpath-M14-loops.md §8.1 |
| R9 → D-18 | M12 | Claude-path `emit` (jarvis.py:4949-4954) keeps speaking queued sentences after a barge-in; only the Ollama consumer (jarvis.py:4789) drops them | `SpeechQueue.cancelAll` drops queued sentences for both backends | Verified Python bug | `SpeechQueue` tests (T8.5 / A8); marked case to add | `approved` | M08-M13-voice-hud.md §2.2, §8 R9 |

The M7 table gives one fixture for all 15 `DEV-M7-*` / `DEV-M14-*` rows (§8.1 heading:
"fixture §4.2"). For the `DEV-M14-*` rows that marker was carried over as written; the
loop behaviours may need their own tests at M14.

## Counts

42 entries: 7 `approved` (X-1, R2 → D-12, R3 → D-15, DEV-M7-01, DEV-M7-02, DEV-M7-05,
R9 → D-18) and 35 `proposed — decide at milestone start`.

## Not registered: differences mentioned only in the M05 §3.5 tool table

The M05 plan names these as implementation notes, not deviations. Decide at M5 start
whether each one belongs in the table above:

- `see_screen` writes no screen PNG to `$TMPDIR` (a privacy gain).
- `type_text` needs no System Events automation and types non-ASCII correctly.
- `set_alarm`: the M1 store is an actor, which removes Python's read-modify-write race.
- `set_reminder`, `find_contact`: no longer launch Reminders.app / Contacts.app and need no Automation grant.

## Kept on purpose (bug-for-bug parity, not deviations)

M05 §8 R5 lists Python bugs the native tools replicate, each marked in the fixtures:
"p.m." unrecognised; `within 5 days` matches; `cat 5` counts as "at 5"; `bool("false")` is
true; move clobbers an existing directory. Fixing any of them is a separate, user-approved
change after parity, and then gets a row here.
