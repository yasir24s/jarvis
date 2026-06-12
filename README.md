# JARVIS — a fully local macOS voice assistant

A self-hosted, always-listening voice assistant for Apple Silicon Macs, inspired by the
Iron Man companion. Everything runs **on-device** — no cloud assistant, no third-party
"brain." It hears you, thinks locally, speaks back, controls your Mac, and shows a
reactive arc-reactor HUD.

> Built and tuned for an Apple M2 / 8 GB machine, so it favours small, efficient models
> and graceful fallbacks over raw size.

## What it does
- **Wake word** — say "Jarvis" / "Hey Jarvis"; stays in conversation until you say
  "thank you, Jarvis."
- **Local brain** — [Ollama](https://ollama.com) running `qwen2.5:3b` on the Metal GPU
  (tool-calling). Swap to a bigger model via `JARVIS_MODEL` if you have the RAM.
- **Ears** — Google STT when online, local **Whisper** (faster-whisper) when offline.
- **Voice** — [Piper](https://github.com/rhasspy/piper) neural TTS (British male),
  pitch-tuned; falls back to macOS `say`.
- **Speaker recognition** — enrol your voice ("Jarvis, learn my voice") and it responds
  only to you, ignoring TV/music/other people.
- **Reactive HUD** — a transparent, click-through arc-reactor overlay (pywebview),
  hidden until spoken to. Runs as a background agent (no Dock icon).
- **Screen saver** — a matching native arc-reactor (`screensaver/`) for the lock/idle screen.
- **Skills** — open any installed app, control music (library → YouTube fallback),
  volume, weather, location, timers, **alarms**, **reminders**, calendar, messages,
  notes, web + Wikipedia lookup, file search/read, screen-awareness (OCR), clipboard,
  song-ID from lyrics, and Shazam-style ambient music ID (via AudD, optional token).

## Setup
```bash
./install.sh          # installs deps, pulls the model + voice, builds the .app, starts the agent
```
This installs Ollama (cask), Python deps, the Piper voice, caches Whisper, builds the
`JARVIS.app` bundle (py2app), and installs the always-on LaunchAgent.

## Running it
```bash
./jarvisctl status|restart|stop|logs|test
```

## Configuration (env vars, then `./jarvisctl restart`)
| Var | Default | Purpose |
|---|---|---|
| `JARVIS_MODEL` | `qwen2.5:3b` | Ollama model (e.g. `qwen2.5:7b` if you have RAM) |
| `JARVIS_SPEED` | `0.62` | Piper speech rate (lower = faster) |
| `JARVIS_PITCH` | `0.92` | Voice pitch (lower = deeper) |
| `JARVIS_SPK_THRESH` | `0.70` | Speaker-match strictness |
| `JARVIS_KEEP_AWAKE` | `1` | Keep listening while locked/idle (uses battery) |
| `AUDD_API_KEY` | — | Free [AudD](https://audd.io) token for ambient song ID |

## Privacy
This repo intentionally **excludes** your voiceprint, spoken-command logs, learned
knowledge cache, alarms, and any API tokens (see `.gitignore`). Keep the repo
**private** — it controls your Mac and can read your data.

## Notes
- Apple reserves the lock screen and mic-while-locked for Siri; JARVIS can't override
  that, so it goes quiet once the Mac is truly password-locked (the screen saver still shows).
- Voice models, the LLM, and tools all run locally; only optional web lookups and
  ambient song ID use the network.
