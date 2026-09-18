# JARVIS — a fully local voice assistant (macOS + Windows)

A self-hosted, always-listening voice assistant, inspired by the Iron Man companion.
Everything runs **on-device** — no cloud assistant, no third-party "brain." It hears
you, thinks locally, speaks back, controls your computer, and shows a reactive
arc-reactor HUD. Built first for Apple Silicon Macs; it also runs on Windows 10/11
(same `jarvis.py`, platform-specific glue is selected automatically).

> Built and tuned for an Apple M2 / 8 GB machine, so it favours small, efficient models
> and graceful fallbacks over raw size.

## What it does
- **Wake word** — an always-on [openWakeWord](https://github.com/dscripka/openWakeWord)
  model ("hey jarvis") scans raw mic frames continuously; full speech-to-text only kicks
  in after it fires, instead of transcribing everything you say just to check for the
  wake word. Stays in conversation until you say "thank you, Jarvis."
- **Ears** — local **Whisper** (faster-whisper `small.en`, `beam_size=5`, with a JARVIS
  vocabulary prompt) on-device by default — fully local, no cloud. Optional Google cloud
  STT (en-GB) via `JARVIS_STT=auto` or `google`.
- **Brain** — [Claude](https://claude.com) via the **Claude Agent SDK** (signed in with
  your Claude subscription, no API key) when it's reachable, with automatic fallback to
  the **local** [Ollama](https://ollama.com) `qwen2.5:3b` on the Metal GPU whenever a
  Claude request doesn't go through (not signed in, no credit, rate limit, offline, or
  the SDK/CLI absent). Both paths call the *same* tools. Ask "which model are you using?"
  to hear which handled the last request. Claude is opt-out via `JARVIS_USE_CLAUDE=0`;
  swap the local model via `JARVIS_MODEL` — see
  [Design decisions](#design-decisions) for why 3B is the measured default on 8 GB.
- **Voice** — [Piper](https://github.com/rhasspy/piper) neural TTS (British male),
  pitch-tuned; falls back to macOS `say`.
- **Streamed replies** — JARVIS starts speaking the first sentence of a reply while the
  rest is still being generated, instead of waiting for the whole answer.
- **Barge-in** — once your voice is enrolled, you can talk over JARVIS mid-sentence to
  interrupt him (opt-out via `JARVIS_BARGE_IN=0`).
- **Speaker recognition** — enrol your voice ("Jarvis, learn my voice") and it responds
  only to you, ignoring TV/music/other people. Also gates barge-in (above).
- **Reactive HUD** — a transparent, click-through arc-reactor overlay (pywebview),
  hidden until spoken to. Runs as a background agent (no Dock icon).

<details>
<summary><b>Full skill list</b> — memory, apps &amp; media, smart home, deep system access, browser awareness, vision</summary>

- **Memory** — durable facts about *you* (name, preferences, ongoing projects) picked up
  from things you say ("my name is...", "I'm working on...", "remember that...") and
  recalled in later conversations; separate from the background research cache below.
- **Screen saver** — a matching native arc-reactor (`screensaver/`) for the lock/idle screen.
- **Skills** — open any installed app, control music (library → YouTube fallback),
  volume, **brightness**, weather, location, timers, **alarms**, **reminders**, calendar
  (read **and create events**), messages (read **and send iMessages**), **send email**,
  **contact lookup**, **news headlines**, notes, **dictation** ("type…"), **screenshots**,
  **lock screen**, **empty trash**, **system diagnostics** (CPU/RAM/disk/battery/uptime),
  web + Wikipedia lookup, file search/read, screen-awareness (OCR), clipboard,
  song-ID from lyrics, and Shazam-style ambient music ID (via AudD, optional token).
- **Smart home & automations** — "turn off the lights" runs your matching Apple/HomeKit
  Shortcut; any shortcut is voice-callable by (fuzzy) name, e.g. "run the encode to MP3
  shortcut".
- **Everyday controls** — quit apps ("close Spotify", "close everything"), cancellable
  timers ("how long left?", "cancel the timer"), **recurring alarms** ("wake me up every
  day at 7"), "copy that" (last reply → clipboard), "Google X" / "search YouTube for X"
  in the browser, "what's my IP", AirPods battery, and "goodnight, Jarvis" to sleep the
  Mac.
- **Deep system access** — Spotlight-powered file search by *content* ("find my tax PDF",
  "recent files"), open/reveal files, jump to any **System Settings pane** ("open
  bluetooth settings", "open microphone privacy"), and flip **hidden macOS options**
  ("turn on dark mode", "show hidden files", "enable dock autohide", "turn off wifi").
  All at user level — no sudo; the prompt-injection guard stays active.
- **Browser awareness** — "summarize this page" reads the article open in Safari/Chrome
  and gives you the gist aloud.
- **Optional real vision** — set `JARVIS_VISION_MODEL` to a local Ollama vision model
  (e.g. `moondream`) and "what do you see" truly describes the screen, not just its text.
- **Proactive meeting alerts** — opt-in: "Sir, your meeting starts in about five minutes."
- **Welcome-back greeting** — greets you by time of day when you unlock the Mac after
  being away (opt-out `JARVIS_GREET_UNLOCK=0`).
- **Memory across restarts** — the recent conversation reloads on start (`history.json`,
  never committed).

</details>

## How it works

```
mic · always on
 │
 ▼  openWakeWord · 80 ms frames — the only model running continuously
wake word fires
 │
 ▼  wake clip vs enrolled voiceprint — rejects "Jarvis" from a TV or another person
Whisper STT · local, plus learned transcription corrections
 │
 ▼  voiceprint checked again, now on the command audio
dispatch
 │
 ├── matched ─────▶ fast_path() · deterministic handler, no model round-trip
 │
 └── open-ended ──▶ Claude Agent SDK · subscription auth, tools over MCP
                      │
                      └── any failure ──▶ local Ollama · same tools, bounded loop
 │
 ▼  (either route)
Piper TTS · speaks sentence N while N+1 is still being generated
 │
 ▼
arc-reactor HUD · state + captions
```

A few properties worth calling out, since they're the parts that took the design work:

- **The wake word is the cheap gate.** Continuous STT on an 8 GB machine is not viable
  alongside everything else, so only 80 ms frames (openWakeWord's expected hop) hit the
  wake-word model; Whisper is loaded but idle until it fires.
- **The voiceprint is checked twice.** Once on the wake clip, to reject "Jarvis" from a
  TV or another person before spending any Whisper time on it, and again on the
  transcribed command — so a wake word that squeaks through still can't issue actions.
- **Common commands never reach a model.** `fast_path()` matches things like "open
  Spotify", "set a timer", "run diagnostics" deterministically and acts immediately —
  the LLM is the fallback for open-ended language, not the default route. This is most
  of the perceived responsiveness.
- **Both brains are behind one tool interface.** Claude (via an MCP bridge) and local
  Ollama call the *same* tool implementations with the same effects, so a fallback
  mid-conversation changes latency and quality, not capability. The Ollama path runs a
  bounded tool loop (5 iterations) so a confused small model can't spin.
- **Safety is enforced at the choke point, not per tool.** Shell commands are classified
  into three tiers (`ok` / `confirm` / `block`); destructive actions stash themselves and
  require a spoken "confirm" *from the enrolled voice*; and once a request has ingested
  untrusted external content (a web page, the screen, the clipboard, a file), executors
  and outward-facing tools — messaging, email, synthetic keystrokes — are revoked for the
  rest of that request, so a malicious page can't steer it into running commands or
  exfiltrating. Both backends share that gate.
- **Background loops are opt-in.** Research, daily briefing, meeting alerts, and
  low-battery warnings each run on their own thread and stay silent unless configured —
  the assistant doesn't speak unprompted by default.

> **On the single file:** `jarvis.py` is deliberately one module. It ships as a py2app
> bundle driven by a LaunchAgent, so there's no packaging story to justify a tree, and
> keeping the tool implementations, their safety gates, and the dispatch table in one
> place is what makes the "both backends, one tool interface" guarantee checkable by
> reading rather than by trusting an import graph. It's a trade I'd revisit if this grew
> a second entry point.

## Design decisions

**Why `qwen2.5:3b` and not 7B.** Benchmarked both on the target machine (M2, 8 GB) under
*realistic concurrent load* — mic capture, Whisper, and Piper all live, not a quiet
single-process benchmark:

| | mean latency | p95 latency | swap |
|---|---|---|---|
| `qwen2.5:3b` | baseline | baseline | none |
| `qwen2.5:7b` | ~2.6× higher | ~4× higher | genuine swapping |

The p95 is the number that decided it: a voice assistant that is usually quick and
occasionally takes four times as long feels broken in a way that a uniformly slower one
does not. 7B also pushed the machine into real swap once the audio stack was resident,
which degrades everything else running. 3B is the default *for this hardware* — on a
bigger machine the trade flips, so the `.pkg` installer picks a larger model for you
based on installed RAM (see [Installer model selection](#installer-model-selection)), and
`JARVIS_MODEL` overrides it at any time.

**Why `small.en` for Whisper.** Same constraint. `medium.en` is noticeably better on long
dictation but the accuracy gain on 2–5 second spoken commands didn't justify the extra
resident memory next to the LLM; `base.en` started dropping proper nouns the vocabulary
prompt was meant to catch.

**Why Claude is primary but not required.** The subscription path gives much better
instruction-following for open-ended requests, but an assistant that stops working when
the network does isn't an assistant. Hence: same tools behind both, automatic fallback on
*any* failure class (not signed in, rate limited, offline, SDK absent), and a spoken
"which model are you using?" so the current backend is never a mystery.

**Why `low` effort by default.** Spoken replies are short by nature; higher effort mostly
buys reasoning depth the user never hears, at the cost of latency and subscription quota.

### Installer model selection

The 8 GB tuning above is the *floor*, not a ceiling. The macOS `.pkg` installer reads
`hw.memsize` and pre-selects the largest local model the machine can actually hold, so a
better Mac gets a better assistant without touching a config file:

| Installed RAM | Pre-selected model | Size |
|---|---|---|
| < 16 GB | `qwen2.5:3b` | bundled in the installer, no download |
| 16–31 GB | `qwen2.5:7b` | ~4.5 GB download |
| 32–63 GB | `qwen2.5:14b` | ~9 GB download |
| 64–127 GB | `qwen2.5:32b` | ~20 GB download |
| ≥ 128 GB | `qwen2.5:72b` | ~45 GB download |

Every tier is a visible, overridable checkbox in the installer — the RAM check sets the
*default*, so you can deliberately take a smaller model to save disk or a larger one if
you know your workload. Two guards keep that from producing a broken install:
`postinstall` re-checks actual RAM and quietly downgrades if the selection can't fit, and
falls back to the RAM-appropriate tier if no selection arrives at all. The 3B weights
ship inside the installer, so the low-memory path — and only that path — needs no network
at install time.

## Setup

### macOS
```bash
./install.sh          # installs deps, pulls the model + voice, builds the .app, starts the agent
```
This installs Ollama (cask), Python deps, the Piper voice, caches Whisper, builds the
`JARVIS.app` bundle (py2app), and installs the always-on LaunchAgent. It uses
`qwen2.5:3b` unless `JARVIS_MODEL` says otherwise.

There's also a graphical `.pkg` installer (`./build_pkg.sh`, optionally
`./build_dmg.sh`) for installing on a machine that isn't this one. Unlike `install.sh`,
it sizes the local model to the target Mac's RAM — see
[Installer model selection](#installer-model-selection).

### Windows
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install.ps1         # installs Ollama + deps, pulls the model + voice, adds a Startup shortcut
```
Then allow microphone access for desktop apps in **Settings → Privacy & security →
Microphone**. Optional extras: `winget install Gyan.FFmpeg` (deeper voice pitch) and
`winget install UB-Mannheim.TesseractOCR` (screen-reading OCR).

## Running it
```bash
./jarvisctl status|restart|stop|logs|test        # macOS
```
```powershell
.\jarvisctl.ps1 status|start|restart|stop|logs|test   # Windows
```

## Configuration (env vars, then `./jarvisctl restart`)
| Var | Default | Purpose |
|---|---|---|
| `JARVIS_MODEL` | `qwen2.5:3b` | Ollama model. 3B is the benchmarked default for 8 GB — see [Design decisions](#design-decisions); worth re-testing on a 16 GB+ machine. |
| `JARVIS_WAKE_THRESHOLD` | `0.5` | Wake-word detection confidence (0-1, lower = more sensitive/more false triggers) |
| `JARVIS_SPEED` | `0.62` | Piper speech *length scale* — lower = faster speech (despite the var name; it maps to Piper's `length_scale`) |
| `JARVIS_PITCH` | `0.92` | Voice pitch (lower = deeper) |
| `JARVIS_SPK_THRESH` | `0.70` | Speaker-match strictness (also gates barge-in) |
| `JARVIS_BARGE_IN` | `1` | Allow interrupting JARVIS mid-sentence; only active once a voice is enrolled. Set `0` to disable. |
| `JARVIS_BRIEFING_TIME` | — | Opt-in: speak the daily briefing once a day at this time, e.g. `08:00` (24h). Unset = never speaks unless asked. |
| `JARVIS_LOW_BATTERY` | — | Opt-in: speak a one-time (per-hour cooldown) warning when battery drops to/below this percent, e.g. `20`. Unset = never warns unasked. |
| `JARVIS_GREET_UNLOCK` | `1` | Greet you by time of day when you unlock the Mac after being away >2 min. Set `0` to disable. |
| `JARVIS_NEWS_FEED` | BBC RSS | RSS feed URL used for spoken news headlines. |
| `JARVIS_MEETING_ALERTS` | — | Opt-in: announce calendar events this many minutes before they start, e.g. `5`. Unset = off. |
| `JARVIS_VISION_MODEL` | — | Opt-in: local Ollama vision model (e.g. `moondream`) for true screen description; unset = OCR-only. Pull it first: `ollama pull moondream`. |
| `JARVIS_USE_CLAUDE` | `1` | Use Claude (Agent SDK, subscription auth) as the primary brain when reachable, falling back to local Ollama. Set `0` for local-only. Needs the Claude Code CLI + Node and a prior `claude login`; never uses an API key or pay-as-you-go billing. |
| `JARVIS_CLAUDE_MODEL` | — | Claude model for the Agent SDK (e.g. `sonnet`, `opus`); unset uses the CLI default. |
| `JARVIS_CLAUDE_EFFORT` | `low` | Agent SDK effort level (`low`–`max`); `low` keeps spoken replies fast and light on your subscription quota. |
| `JARVIS_CLAUDE_MAX_TURNS` | `6` | Max agentic tool-use turns per Claude request. |
| `JARVIS_CLAUDE_TIMEOUT_MS` | `45000` | Per-request Claude timeout; on a stall JARVIS falls back to the local model. |
| `JARVIS_STT` | `whisper` | Speech-to-text engine: `whisper` (local, on-device), `auto` (Google when online, Whisper fallback), or `google` (cloud only). |
| `JARVIS_WHISPER` | `small.en` | Local Whisper model size (`tiny.en`/`base.en`/`small.en`/`medium.en`…). `small.en` is the 8 GB sweet spot. |
| `JARVIS_WHISPER_BEAM` | `5` | Whisper beam width; higher = more accurate on short clips, slightly slower. |
| `JARVIS_STT_LANG` | `en-GB` | Locale for the optional Google path. |
| `JARVIS_KEEP_AWAKE` | `1` | Keep listening while locked/idle (uses battery) |
| `AUDD_API_KEY` | — | Free [AudD](https://audd.io) token for ambient song ID |

**macOS permissions the new skills need** (macOS prompts once, on first use — click Allow):
Messages/Mail/Contacts/Calendar **Automation** for sending texts/email and creating events;
**Accessibility** for dictation (`type_text`) and brightness (or `brew install brightness`);
**Screen Recording** for screenshots. Grant them in **System Settings → Privacy & Security**.

## Privacy & secret-guard
This repo intentionally **excludes** your voiceprint, spoken-command logs, learned
knowledge cache, personal profile memory, alarms, and any API tokens (see `.gitignore`). A tracked
**pre-commit hook** also refuses to commit those files or anything that looks like a
token / private key / hard-coded home path — enable it once per clone:

```bash
git config core.hooksPath .githooks
```

Since nothing personal lives in the code, the repo is fine to keep public; make it
private if you'd rather not publish your exact setup.

See **[SECURITY.md](SECURITY.md)** for the full threat model, the hardening controls
(prompt-injection containment, command denylist, least-privilege file reads, speaker
verification), residual risks, and how to report a vulnerability.

## Notes
- Apple reserves the lock screen and mic-while-locked for Siri; JARVIS can't override
  that, so it goes quiet once the Mac is truly password-locked (the screen saver still shows).
- Voice models, the LLM, and tools all run locally; only optional web lookups and
  ambient song ID use the network.

## Windows differences
- **AppleScript → PowerShell**: the LLM gets a `run_powershell` tool instead of
  `run_applescript` (same denylist guarding destructive commands, extended with
  Windows patterns like `format`, `vssadmin`, `Remove-Item -Recurse`, `iex`).
- **Music**: controlled via the system media keys (play/pause/next/previous work with
  Spotify, YouTube, etc.); "play <song>" uses YouTube. No now-playing readout yet.
- **Apple apps**: Messages and Calendar aren't available; Notes and untimed reminders
  go to a local `jarvis_notes.txt`, timed reminders use the built-in alarm scheduler
  plus a notification balloon.
- **Screen awareness** needs Tesseract OCR (`winget install UB-Mannheim.TesseractOCR`
  plus `pip install pytesseract pillow`) instead of Apple's Vision framework.
- **File search** walks Desktop/Documents/Downloads/Pictures/Music/Videos by filename
  (no Spotlight); app launching indexes every Start Menu shortcut.
- **Fallback voice** is Windows SAPI (Microsoft George/Hazel) instead of macOS `say`.

## License
[MIT](LICENSE) © 2026 yasir24s
