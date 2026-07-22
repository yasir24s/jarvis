# JARVIS Changelog — 2026-07-12 (deep system access)

JARVIS now reaches the whole machine: every file (by content, not just name), every
System Settings pane, and the hidden `defaults` options. All at the normal user level —
no sudo, and the injection-containment guard stays on (a malicious page still can't drive
these). Spotlight and Launch Services already index everything live, so JARVIS queries
them rather than crawling the disk itself.

### Files — Spotlight as a first-class client
- **Content search, not just filenames**: "find my tax PDF", "where's that video about X".
  New `find_files` tool + `_spotlight` with kind filters (pdf/image/video/audio/document/
  spreadsheet/presentation/code/archive/folder) and `recent=true`.
- **"What did I work on recently"** — this week's changed files, filtered to real documents
  (caches, logs, build junk, dotfiles stripped out).
- **Open / reveal**: "open file <name>" opens it in the default app; "reveal <name> in
  Finder" jumps to it. Both accept a literal path or a Spotlight query.

### System Settings — every pane by voice
- **"Open bluetooth settings"**, "open displays", "open sound", etc. — 40+ panes mapped to
  their `x-apple.systempreferences:` anchors, with fuzzy fallback.
- **Privacy sub-panes**: "open microphone privacy", "open screen recording settings",
  "open full disk access" — jumps straight to the exact permission list (handy for
  granting JARVIS its own permissions).

### Hidden macOS options
- **`system_control` tool + voice**: "turn on dark mode", "show hidden files", "enable dock
  autohide", "turn off wifi", "enable do not disturb", plus path bar, status bar, file
  extensions, desktop icons, natural scrolling, key-repeat, screenshot shadow. Curated,
  reversible `defaults`/AppleScript toggles — each known-safe, none arbitrary.
- Wi-Fi toggles via `networksetup`; Bluetooth via `blueutil` if installed; Do Not Disturb
  via a Shortcut hook.

### Note on "root"
Deliberately **not** wired to sudo. An always-listening mic + local LLM + untrusted web
content reaching uid 0 is the one combination that turns a prompt injection into a wiped
disk — and everything above is reachable without it. The destructive-command denylist and
post-untrusted-content executor lockout remain in force.

---

# JARVIS Changelog — 2026-07-22 (calendar, transcription, PATH)

### Calendar via EventKit
- Calendar reads, event creation, and meeting alerts now go through **EventKit** (PyObjC)
  instead of AppleScript. Calendar's `every event whose start date ≥ …` AppleScript query
  returns `-600` on modern macOS even when listing calendar names works; EventKit is the
  reliable, supported path. AppleScript remains an automatic fallback. Adds a one-time
  Calendars permission prompt (`NSCalendarsFullAccessUsageDescription` in the bundle;
  re-signed with the stable identity so existing TCC grants survive). New dep:
  `pyobjc-framework-EventKit`.

### Transcription (speech-to-text)
- **Local-first by default.** `JARVIS_STT` now defaults to `whisper` (fully on-device) and
  `JARVIS_WHISPER` to **`small.en`** (measured clearly better than `base.en` on-device,
  ~600 MB, fits 8 GB). The Google cloud path is now opt-in (`JARVIS_STT=auto`/`google`) and
  locale-aware (`JARVIS_STT_LANG`, default `en-GB`) — the old default silently sent audio
  to Google as `en-US`, hurting non-US accents and contradicting the local-first design.
- **Accuracy tuning:** `beam_size` 1 → 5 (weighs alternatives on short clips) and an
  `initial_prompt` seeded with "Jarvis" + command vocabulary (stops short clips snapping
  "jarvis" → "jobs"/"java's"). Configurable via `JARVIS_WHISPER_BEAM` / `JARVIS_WHISPER_PROMPT`.
  Residual errors on ultra-short phrases remain `small.en`'s floor; Claude's intent
  recovery masks most of them. (Bigger models / Apple Speech are for the 48 GB machine.)

### System tools PATH fix
- The LaunchAgent PATH was missing `/usr/sbin`, so `screencapture`, `networksetup`
  (Wi-Fi toggle), `ioreg` (Bluetooth battery), and `system_profiler` (diagnostics) all
  silently failed with "No such file or directory". Added `/usr/sbin:/sbin` to the PATH in
  `install.sh` and the pkg postinstall. This is what made "see my screen" fail earlier —
  a mis-heard command routed into a tool that was itself broken.

---

# JARVIS Changelog — 2026-07-12 (Claude Agent SDK backend)

JARVIS gains a Claude brain — used when reachable, with the local model as a always-on
safety net. This is an *addition*, not a swap: there was never any Claude integration
before (JARVIS was 100% local Ollama), so Ollama becomes the fallback rather than the
only path.

- **Primary backend: Claude via the Claude Agent SDK**, signed in with your Claude
  subscription (the SDK inherits the `claude` CLI's OAuth login). **No API key, no
  pay-as-you-go** — any inherited `ANTHROPIC_API_KEY` is stripped at startup so only the
  subscription login can be used.
- **Automatic fallback to local Ollama** (`qwen2.5:3b`) on *any* Claude failure — not
  signed in, no Agent SDK credit, rate limit, network, timeout, or the SDK/CLI being
  absent — with a one-line log note naming the reason. JARVIS never crashes or hangs
  waiting on Claude; a stalled call (default 45s) yields to the local model.
- **Same tools in both modes.** Every existing JARVIS tool is bridged to an in-process
  MCP tool that calls the *same* `execute_tool()` — one implementation, two front-ends.
  Claude's own built-in Bash/file tools are left off (`tools=[]`), and the prompt-
  injection guard (untrusted-content → block executor/outbound tools) is enforced on the
  bridge exactly as on the local path (trust classes now defined once, module-level).
- **Backend indicator (step 7).** A `Backend: …` log line each turn, plus a voice query —
  "which model are you using?" / "are you using Claude?" — reports which handled the last
  request.
- **8GB-aware.** When Claude is the active backend, the ~3GB local model is *not*
  pre-warmed — it loads lazily only on the first fallback. The Agent SDK spawns the
  `claude` CLI per request (RAM-friendly) rather than holding a resident process.
- **Config:** `JARVIS_USE_CLAUDE` (default on; `0` = local-only), `JARVIS_CLAUDE_MODEL`,
  `JARVIS_CLAUDE_EFFORT` (default `low`), `JARVIS_CLAUDE_MAX_TURNS`, `JARVIS_CLAUDE_TIMEOUT_MS`.
- **Deps:** `claude-agent-sdk` added to `install.sh` and `bundle_resources.sh`. Runtime
  also needs the Claude Code CLI + Node (both already present here) and a prior
  `claude login`; `setup.py` is alias-mode so it needs no change.

---

# JARVIS Changelog — 2026-07-12 (app intelligence)

JARVIS now knows what every installed app IS, not just its name. Each app's Info.plist
is parsed once in the background (plistlib, no subprocesses): declared URL schemes,
document types, and App Store category. An app claiming http+https handlers AND HTML
documents is a web browser — which is how ChatGPT Atlas is recognised as one (and as
the current system default). Substring pitfalls fixed with word-boundary matching
("arc" no longer tags ARChive Utility as a browser); downloaders that claim http but
not HTML documents (VLC, Downie) are excluded — verified against the real /Applications.

- **"Open my browser"** launches the actual system default (Atlas today, whatever
  tomorrow), resolved live via NSWorkspace. "Open my music app / mail app / editor"
  resolve by type too.
- **"What's my default browser"** / **"make Atlas my default browser"** (macOS shows
  its one-time confirmation prompt).
- **"Close all my browsers"** quits by app type, not name.
- **"What browsers / email apps / AI apps do I have"** — instant, offline.
- New `find_apps` LLM tool so the model can reason about app types mid-conversation
  ("is anything installed that can edit video?").

---

# JARVIS Changelog — 2026-07-12 (reliability release)

Every fix below was diagnosed from the real session log, reproduced, fixed, and covered
by tests. This is the "he must never silently ignore you" release.

### Wake & hearing
- **Fixed the wake-word swallow bug**: "can you hear me, Jarvis?" transcribed fine, then
  `extract_command` took only the text *after* "jarvis" — empty string — and the request
  vanished without a sound. Wake word mid/end phrase now yields the surrounding text.
- **Soft wake tier** (`JARVIS_WAKE_SOFT`, default 0.15): the hey_jarvis acoustic model is
  trained on "HEY jarvis" — a bare "Jarvis…" or soft-spoken wake often scores 0.15–0.5 and
  was dropped by the hard 0.5 threshold. Borderline scores now trigger a rate-limited local
  Whisper pass over the surrounding ~3.5s; if the transcript contains the wake word, JARVIS
  wakes — and since the command is usually already in that clip ("Jarvis, close Safari"),
  he acts on it immediately with no "Yes, sir?" round-trip.
- **Deaf-stream recovery**: a mic stream can go silently dead when CoreAudio rebinds
  devices (Bluetooth churn, virtual drivers — the device index moved 2→4 between boots).
  20s of pure digital zeros now triggers an in-place stream reopen instead of scanning a
  dead stream forever.
- **Startup watchdog**: on a fresh macOS boot, CoreAudio calls can block forever — JARVIS
  hung 13 hours between "Microphone ready" and "Calibrated" with launchd's KeepAlive
  powerless (the process never died). If not listening within 240s of launch, JARVIS now
  exits hard and launchd relaunches it with a fresh CoreAudio connection.
- **Fragmentation fix**: `pause_threshold` 0.8 → 1.15 — natural thinking pauses were
  chopping one sentence into several fragment commands ("no, change it to…" / "set a
  different…" from the real log).

### Brain resilience
- Empty-model-response retries 1 → 2 (the 3B model returned empty three times in one real
  conversation).
- System prompt: never ask for permission/confirmation — the request is the confirmation;
  pick the most likely interpretation of an ambiguous ask and act (the model was caught
  asking "Would you like me to proceed?" three times in a row).

---

# JARVIS Changelog — 2026-07-11 (round 3)

Everyday-usability round. Deliberately **zero new LLM tools** — every feature is a
deterministic fast-path, because the 3B model's tool-calling reliability drops as the
schema grows. Instant, offline, no model round-trip.

### Timers & alarms grew up
- Timers are now a registry: **"cancel the timer"**, **"how long left?"**, multiple named
  timers tracked and listed. (Previously fire-and-forget threads — uncancellable.)
- **Recurring alarms**: "wake me up every day at 7" / "every weekday at 8:30". Persisted
  with a `repeat` field; a missed recurring alarm rolls forward on restart instead of
  being silently dropped. Plus **"cancel my alarm"** and **"what alarms do I have"**.

### App & system control
- **Quit apps by voice**: "quit Safari", "close Spotify" (graceful terminate via
  NSWorkspace; unknown names fall through to the LLM, so "close the deal" isn't hijacked).
- **"Close everything"** — quits all regular apps except Finder and JARVIS itself.
- **"Goodnight, Jarvis"** puts the Mac to sleep ("go to sleep" remains a dismissal and
  does NOT sleep the machine).

### Little big things
- **"Copy that"** — puts JARVIS's last spoken reply on the clipboard.
- **"Google X" / "search YouTube for X"** — opens the browser with results (distinct from
  the spoken web_search answers).
- **"What's my IP"** — local + public. **"How are my AirPods?"** — Bluetooth battery
  levels (left/right/case) via ioreg.

---

# JARVIS Changelog — 2026-07-11 (round 2)

### Smart home & automations
- **Apple Shortcuts integration** (`run_shortcut`, `list_shortcuts`): "turn off the lights"
  now runs the matching HomeKit shortcut — and any custom automation you've built is voice-
  callable. Fuzzy name matching (exact > substring > token overlap) so "lights off" finds
  "turn off lights". Treated as an executor by the injection guard.

### Browser & vision
- **"Summarize this page"** (`summarize_page`): reads the URL from the frontmost browser tab
  (Safari or Chrome, whichever is up), fetches and strips the page, and summarizes it aloud.
  Page text is untrusted → taints the request for the injection guard.
- **Optional real vision** (`JARVIS_VISION_MODEL`, e.g. `moondream`): "what do you see"
  sends a screenshot to a local Ollama vision model for a true description, falling back to
  the existing OCR path automatically. Unset = pure OCR as before (right call on 8 GB).

### Proactive
- **Meeting alerts** (`JARVIS_MEETING_ALERTS=<minutes>`, opt-in): "Sir, your meeting starts
  in about five minutes." Polls Calendar every 2 min; each event announced once; seconds
  computed inside AppleScript so no locale-dependent date parsing.

### Brains
- **Conversation memory survives restarts**: the last 12 turns persist to `history.json`
  (gitignored) and reload on start.
- **Weekday parsing**: "on Friday at 2pm" / "next Monday" now work everywhere `_parse_when`
  is used — events, reminders, alarms. (Previously the bare "at 2pm" matcher swallowed the
  time and dropped the day.)
- Frontmost-app detection via NSWorkspace (no Accessibility permission needed).

---

# JARVIS Changelog — 2026-07-11

### Iron-Man-tier capabilities
New tools that let JARVIS act on the world, not just observe it — closing the gap to the
films' assistant:
- **Send iMessages by voice** (`send_message`): "text Mum saying I'll be late." Resolves the
  name against Contacts (exact > begins-with > contains, so "Mum" no longer mis-hits
  "someone's mum"), strips phone formatting for iMessage matching.
- **Send email** (`send_email`) via Mail, and **look up contacts** (`find_contact`).
- **Create calendar events** (`create_event`): "schedule a meeting tomorrow at 3pm."
  (Reading the calendar already existed.)
- **News briefing** (`get_news`): top headlines from an RSS feed (BBC by default,
  `JARVIS_NEWS_FEED` to change). Folded into the daily briefing, which now also reads out
  the day's calendar.
- **System diagnostics** (`run_diagnostics`): a spoken sweep of CPU, memory, disk, battery
  health + cycle count, uptime, heaviest process, and network — "run diagnostics."
- **Display brightness** (`set_brightness`, plus "brighter"/"dimmer"), **dictation**
  (`type_text`: "type ..." / "take this down ..."), **screenshots**, **lock screen**, and
  **empty trash** — all wired into the instant offline fast-path, no LLM round-trip.
- **Welcome-back greeting**: JARVIS greets you by time of day when you unlock the Mac after
  being away >2 min (opt-out `JARVIS_GREET_UNLOCK=0`).

### Security
- Extended the prompt-injection guard: outward-facing actions (`send_message`, `send_email`,
  `type_text`) join shell/AppleScript in being blocked for the rest of any request that has
  ingested untrusted content (web, screen, clipboard, files, **now also news**) — so a
  malicious page can't make JARVIS text or email on its behalf. New system-prompt rule that
  outbound sends may only ever come from the user's own spoken request.
- `type_text` is a fixed, argument-escaped System Events call we own — distinct from
  `run_applescript`, which still refuses LLM-authored System Events scripts outright.

---

# JARVIS Changelog — 2026-07-10

All from one session in `jarvis.py`; the Swift rewrite at the end is separate.

### Personality
- Loosened the rigid "one short sentence" reply constraint: occasional two-sentence replies
  with dry wit are allowed. Still spoken-aloud-friendly — no markdown, lists, emoji.

### Memory
- Added persistent user memory in `profile.json`: durable facts about the user (name,
  preferences, ongoing projects), extracted via deterministic regex triggers ("my name is...",
  "remember that...", "I'm working on...") and injected into every conversation's context.
  Distinct from the `knowledge.json` research cache (facts about the world, not the user).

### Wake word and microphone
- Replaced full speech-to-text on every phrase just to check for "jarvis" with an always-on
  openWakeWord model (`hey_jarvis`) scoring raw audio frames directly; full STT runs only after
  the wake word fires. ~1.5 ms CPU per 80 ms frame, vs a full Whisper/Google STT pass on every
  utterance before.
- Fixed a real pre-existing mic-selection bug: a numeric mic device index was cached at startup
  and reused for the process lifetime; Bluetooth (AirPods) connect/disconnect churn reorders
  macOS's audio device list and could silently rebind the mic stream to the wrong device. The
  mic is now re-resolved by name every time the stream opens.

### Speech output
- Streamed replies: JARVIS starts speaking the first sentence while the rest is still being
  generated, instead of waiting for the full reply — noticeably less pause on multi-sentence
  replies.
- Barge-in interruption (opt-in, `JARVIS_BARGE_IN`; default on, active once a voice is
  enrolled): talk over JARVIS mid-sentence to interrupt him. Gated by the speaker-verification
  voiceprint, fail-closed on ambiguous/short audio so his own voice leaking into the mic can't
  trigger it.

### Model and tool reliability
- Benchmarked `qwen2.5:7b` vs the default `qwen2.5:3b` under real concurrent load (mic +
  Whisper + Piper all running, not Ollama in isolation) on this machine's 8 GB RAM: 7B was
  ~2.6x slower on average and caused actual swapping. 3B stays default, now measured not
  assumed.
- Fixed a real bug where the 3B model sometimes fabricated answers (e.g. inventing a battery
  percentage) instead of calling the live-data tool. Root cause: `get_system_info` required
  choosing a parameter (battery/time/cpu/wifi); small models are measurably less reliable at
  tool calls that also require choosing a parameter. Split into four no-argument tools —
  `get_battery`, `get_time`, `get_cpu_usage`, `get_wifi_status` — from failing every test case
  to 15/15 passing.
- Fixed a silent-failure bug: an empty model response (rare small-model glitch) left JARVIS
  silent. It now retries once, then says "Sorry, sir — could you say that again?"

### Proactive nudges (opt-in, off unless configured)
- Daily spoken briefing at the time set in `JARVIS_BRIEFING_TIME` (e.g. "08:00").
- Low-battery warning via `JARVIS_LOW_BATTERY` (e.g. "20" = 20%), one-hour cooldown.

### Logging and platform
- Fixed two encoding bugs: AppleScript output with "smart" quotes/dashes (common in macOS's own
  error messages) could crash the AppleScript tool, and could separately vanish from the log —
  both because the LaunchAgent had no UTF-8 locale. Both now use UTF-8 explicitly.
- Calendar, Notes, and Reminders permissions now warm up at startup (previously only Music
  did), so they work immediately instead of prompting on first use.

### New Swift rewrite (separate project)
- From-scratch native Swift implementation of the same assistant at `~/jarvis-swift/`: same
  wake-word model (ported, numerically verified against the Python original), same tool-calling
  against the same local Ollama model, native Apple frameworks throughout (Speech framework for
  listening, AVSpeechSynthesizer for talking, native AppleScript/shell). Still experimental,
  not yet the always-on agent; this Python version runs daily.
