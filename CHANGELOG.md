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
