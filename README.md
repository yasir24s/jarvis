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
- **Local brain** — [Ollama](https://ollama.com) running `qwen2.5:3b` on the Metal GPU
  (tool-calling). Swap to a bigger model via `JARVIS_MODEL` if you have the RAM — see
  `JARVIS_MODEL` below for why 3B is the measured default on 8GB.
- **Streamed replies** — JARVIS starts speaking the first sentence of a reply while the
  rest is still being generated, instead of waiting for the whole answer.
- **Barge-in** — once your voice is enrolled, you can talk over JARVIS mid-sentence to
  interrupt him (opt-out via `JARVIS_BARGE_IN=0`).
- **Memory** — durable facts about *you* (name, preferences, ongoing projects) picked up
  from things you say ("my name is...", "I'm working on...", "remember that...") and
  recalled in later conversations; separate from the background research cache below.
- **Ears** — Google STT when online, local **Whisper** (faster-whisper) when offline.
- **Voice** — [Piper](https://github.com/rhasspy/piper) neural TTS (British male),
  pitch-tuned; falls back to macOS `say`.
- **Speaker recognition** — enrol your voice ("Jarvis, learn my voice") and it responds
  only to you, ignoring TV/music/other people. Also gates barge-in (above).
- **Reactive HUD** — a transparent, click-through arc-reactor overlay (pywebview),
  hidden until spoken to. Runs as a background agent (no Dock icon).
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

## Setup

### macOS
```bash
./install.sh          # installs deps, pulls the model + voice, builds the .app, starts the agent
```
This installs Ollama (cask), Python deps, the Piper voice, caches Whisper, builds the
`JARVIS.app` bundle (py2app), and installs the always-on LaunchAgent.

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
| `JARVIS_MODEL` | `qwen2.5:3b` | Ollama model. Benchmarked `7b` vs `3b` on this exact 8GB M2 under real concurrent load (mic + Whisper + Piper all running): 7B's mean latency was ~2.6x higher, p95 ~4x higher, and it caused genuine swap (3B did not) — 3B stays the default here. Worth re-testing on a 16GB+ machine. |
| `JARVIS_WAKE_THRESHOLD` | `0.5` | Wake-word detection confidence (0-1, lower = more sensitive/more false triggers) |
| `JARVIS_SPEED` | `0.62` | Piper speech rate (lower = faster) |
| `JARVIS_PITCH` | `0.92` | Voice pitch (lower = deeper) |
| `JARVIS_SPK_THRESH` | `0.70` | Speaker-match strictness (also gates barge-in) |
| `JARVIS_BARGE_IN` | `1` | Allow interrupting JARVIS mid-sentence; only active once a voice is enrolled. Set `0` to disable. |
| `JARVIS_BRIEFING_TIME` | — | Opt-in: speak the daily briefing once a day at this time, e.g. `08:00` (24h). Unset = never speaks unless asked. |
| `JARVIS_LOW_BATTERY` | — | Opt-in: speak a one-time (per-hour cooldown) warning when battery drops to/below this percent, e.g. `20`. Unset = never warns unasked. |
| `JARVIS_GREET_UNLOCK` | `1` | Greet you by time of day when you unlock the Mac after being away >2 min. Set `0` to disable. |
| `JARVIS_NEWS_FEED` | BBC RSS | RSS feed URL used for spoken news headlines. |
| `JARVIS_MEETING_ALERTS` | — | Opt-in: announce calendar events this many minutes before they start, e.g. `5`. Unset = off. |
| `JARVIS_VISION_MODEL` | — | Opt-in: local Ollama vision model (e.g. `moondream`) for true screen description; unset = OCR-only. Pull it first: `ollama pull moondream`. |
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
