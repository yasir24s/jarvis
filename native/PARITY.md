# Native JARVIS — parity checklist

Generated from `jarvis.py` @ `68cd112` by `tools/parity_inventory.py` (reads `TOOLS`, `os.environ.get`, `*_FILE`, `os.path.join(HERE, "…")` literals and the `# ───` section banners); `tools/parity_inventory.py --check` fails if jarvis.py has grown anything this file lacks. A row is ticked only with
evidence (test name, golden fixture, screenshot or measurement) in the Evidence column.
`Guard`: **X** = executor (blocked after untrusted input), **U** = untrusted source (taints the turn).

Line numbers refer to jarvis.py @ 68cd112.

## Tools (46 + `run_powershell` Windows-only, not ported)

| ✓ | Tool | MS | Guard | Behaviour (from the Python tool schema) | Evidence |
|---|---|---|---|---|---|
| ☐ | `run_command` | M5 | X | Run ANY shell command on macOS to do tasks. 'open -a AppName' launches an app, 'open URL' opens a site. You have full access; use this freely. | |
| ☐ | `run_applescript` | M5 | X | Run AppleScript to control macOS apps — play/pause/skip music in Music or Spotify, control windows, send Messages, automate anything. | |
| ☐ | `get_battery` | M5 |  | Get the exact current battery percentage and charging status. ALWAYS call this for any battery question — never guess the percentage. | |
| ☐ | `get_time` | M5 |  | Get the exact current date and time. ALWAYS call this for any time/date question — never guess or state a placeholder. | |
| ☐ | `get_cpu_usage` | M5 |  | Get the exact current CPU load percentage. ALWAYS call this for any CPU/performance question — never guess. | |
| ☐ | `get_wifi_status` | M5 |  | Get the exact current Wi-Fi network name. ALWAYS call this for any Wi-Fi/network question — never guess. — _native: CoreWLAN + Location grant (D-15)_ | |
| ☐ | `set_volume` | M5 |  | Set system output volume from 0 to 100. | |
| ☐ | `music_now_playing` | M6 |  | Get the currently playing track in Music (or Spotify): name, artist, and album. Use for 'what's playing', 'what album is this', etc. | |
| ☐ | `music_search` | M6 |  | Search the user's Music library and list matching tracks (does NOT play them). Optional 'by' narrows to song, artist, or album. | |
| ☐ | `music_play` | M6 |  | Play a song, artist, or album — from the Music library if present, otherwise the top result online. 'query' e.g. 'Redbone by Childish Gambino' or 'som… | |
| ☐ | `music_control` | M6 |  | Control playback and the Music player's own volume. 'action' is one of play, pause, next, previous. Optional 'volume' 0-100 sets Music's volume (syste… | |
| ☐ | `web_search` | M6 | U | Search the web for current information (requires internet). | |
| ☐ | `search_files` | M5 |  | Find files on this Mac by name or content using Spotlight. | |
| ☐ | `read_file` | M5 | U | Read the contents of a file on this Mac (full disk access). | |
| ☐ | `delete_file` | M5 | X* | Delete a file or folder. Home files go to the Trash instantly (recoverable); permanent deletes and deletes outside home ask for confirmation; system l… | |
| ☐ | `move_file` | M5 | X* | Move or rename a file/folder from src to dst. Instant within the home folder; confirms if it would overwrite the destination or move outside home. | |
| ☐ | `write_file` | M5 | X* | Write text to a file, creating or overwriting it. Instant for new files and files in the home folder; confirms when overwriting outside home; system p… | |
| ☐ | `get_weather` | M6 |  | Get the current weather. Optional location, else uses current location. | |
| ☐ | `get_location` | M6 |  | Get the user's approximate current location (city/region) via IP. | |
| ☐ | `set_reminder` | M6 |  | Create a reminder. 'when' is natural language like 'at 5pm' or 'in 10 minutes'. | |
| ☐ | `get_messages` | M6 | U | Read the user's most recent received iMessages/texts. | |
| ☐ | `get_calendar` | M6 |  | Get today's calendar events. | |
| ☐ | `see_screen` | M5 | U | Read the text currently visible on the user's screen (OCR). Use this to help with what they're doing, explain errors, or summarize what's shown. | |
| ☐ | `read_clipboard` | M5 | U | Read the user's current clipboard contents. | |
| ☐ | `make_note` | M6 |  | Save a note to Apple Notes. | |
| ☐ | `set_alarm` | M6 |  | Set an alarm. 'when' is natural language like 'at 7 a.m.' or 'in 30 minutes'. | |
| ☐ | `find_song_by_lyrics` | M6 |  | Identify a song from a snippet of its lyrics; returns the title and artist. | |
| ☐ | `notify` | M5 |  | Show a macOS notification banner. | |
| ☐ | `send_message` | M6 | X | Send an iMessage/text. recipient is a contact name, phone number, or email address. ONLY use when the user explicitly asked to message someone. | |
| ☐ | `send_email` | M6 | X | Send an email via Mail. 'to' is a contact name or email address. ONLY use when the user explicitly asked to email someone. | |
| ☐ | `find_contact` | M6 |  | Look up a person's phone number and email address in Contacts by name. | |
| ☐ | `create_event` | M6 |  | Create a calendar event. 'when' is natural language like 'tomorrow at 3pm' or 'in 2 hours'. Optional duration_minutes, default 60. | |
| ☐ | `get_news` | M6 | U | Get the current top news headlines. ALWAYS call this for any news question — never invent headlines. | |
| ☐ | `run_diagnostics` | M5 |  | Run a full system diagnostic sweep: CPU, memory, disk space, battery health, uptime, network, heaviest process. Call this for 'run diagnostics' or any… | |
| ☐ | `set_brightness` | M5 |  | Set display brightness from 0 to 100. | |
| ☐ | `type_text` | M5 | X | Type text directly into whatever app the user is focused on (dictation). Use when the user says 'type ...' or 'take this down'. | |
| ☐ | `take_screenshot` | M5 |  | Capture the screen to an image file on the Desktop. | |
| ☐ | `run_shortcut` | M6 | X | Run one of the user's Apple Shortcuts by name — this is how you control smart-home devices (lights, plugs, scenes) and any custom automation they've b… | |
| ☐ | `list_shortcuts` | M6 |  | List the names of the user's Apple Shortcuts (automations). | |
| ☐ | `summarize_page` | M6 | U | Read the web page currently open in the user's browser and answer about it or summarize it. Use for 'summarize this page/article'. | |
| ☐ | `find_apps` | M5 |  | List installed apps by TYPE (browser, email, music, video, chat, editor, terminal, game, office, ai, ...) or by name. Knows what each app IS — e.g. th… | |
| ☐ | `find_files` | M5 |  | Search all files on this Mac via Spotlight — by name AND by content. Optional kind (pdf, image, video, audio, document, spreadsheet, presentation, fol… | |
| ☐ | `open_settings` | M5 |  | Open a specific macOS System Settings pane by name (wifi, bluetooth, displays, sound, privacy, keyboard, battery, etc.) or a privacy sub-pane (microph… | |
| ☐ | `system_control` | M5 |  | Toggle a system feature or hidden macOS option on/off: wifi, bluetooth, do not disturb, dark mode, hidden files, file extensions, dock autohide, path … | |
| ☐ | `personality_note` | M6 | X | Add ONE durable note to your own personality file about how you should speak or behave (tone, humour, address, verbosity). Use when the user asks you … | |
| ☐ | `personality_rewrite` | M6 | X | Rewrite the CORE of your own personality file wholesale — a full self-authored revision of who you are. Use only when the user asks for a personality … | |

X* — parity: Python has matched this since fef66c1. Its EXECUTOR_TOOLS now includes these three, and writes and move destinations under startup and credential paths ask for confirmation even inside home (this closed the injection → persistence gap verified 2026-09-28). See plan/DEVIATIONS.md (D-12).

## Settings (29 environment variables)

Native JARVIS reads the same names (LaunchAgent env or `defaults`). Obsolete ones are marked, never silently dropped.

| ✓ | Variable | Notes | Evidence |
|---|---|---|---|
| ☐ | `AUDD_API_KEY` |  | |
| ☐ | `JARVIS_BARGE_IN` |  | |
| ☐ | `JARVIS_BRIEFING_TIME` |  | |
| ☐ | `JARVIS_CLAUDE_EFFORT` |  | |
| ☐ | `JARVIS_CLAUDE_MAX_TURNS` |  | |
| ☐ | `JARVIS_CLAUDE_MODEL` |  | |
| ☐ | `JARVIS_CLAUDE_TIMEOUT_MS` |  | |
| ☐ | `JARVIS_GREET_UNLOCK` |  | |
| ☐ | `JARVIS_KEEP_ALIVE` | Ollama-only | |
| ☐ | `JARVIS_KEEP_AWAKE` |  | |
| ☐ | `JARVIS_LOW_BATTERY` |  | |
| ☐ | `JARVIS_MEETING_ALERTS` |  | |
| ☐ | `JARVIS_MODEL` | Ollama model → FoundationModels (keep as opt-in Ollama override?) | |
| ☐ | `JARVIS_NEWS_FEED` |  | |
| ☐ | `JARVIS_NO_HUD` |  | |
| ☐ | `JARVIS_PAUSE` |  | |
| ☐ | `JARVIS_PITCH` |  | |
| ☐ | `JARVIS_SPEED` |  | |
| ☐ | `JARVIS_SPK_THRESH` |  | |
| ☐ | `JARVIS_STT` |  | |
| ☐ | `JARVIS_STT_LANG` |  | |
| ☐ | `JARVIS_USE_CLAUDE` |  | |
| ☐ | `JARVIS_VISION_MODEL` | Ollama vision; revisit with FoundationModels image input | |
| ☐ | `JARVIS_WAKE_SOFT` |  | |
| ☐ | `JARVIS_WAKE_SPK_THRESH` |  | |
| ☐ | `JARVIS_WAKE_THRESHOLD` |  | |
| ☐ | `JARVIS_WHISPER` | obsolete → SpeechTranscriber | |
| ☐ | `JARVIS_WHISPER_BEAM` | obsolete → SpeechTranscriber | |
| ☐ | `JARVIS_WHISPER_PROMPT` | becomes SpeechTranscriber contextual strings | |
| ☐ | `JARVIS_HOME` | native-only, additive: state-root override (LaunchAgent sets it) | |

## Secrets & auth (never in env files, never logged)

| ✓ | Secret | Where | Evidence |
|---|---|---|---|
| ☐ | Claude subscription OAuth | `claude` CLI's own store; `ANTHROPIC_API_KEY` stripped from the child env (jarvis.py:4835) | |
| ☐ | AudD token | `audd_key.txt` or `AUDD_API_KEY` | |
| ☐ | ElevenLabs API key | login Keychain generic password (M8 plan) | |
| ☐ | Signing identity | `~/jarvis/.signing/config` (`KEYCHAIN`, `KEYCHAIN_PASSWORD`, `IDENTITY`) — build only | |

## State files (shared with Python, byte-compatible, atomic writes)

| ✓ | File | Constant | Evidence |
|---|---|---|---|
| ✓ | `knowledge.json` | `KB_FILE` | `M1ProfileKnowledgeTests` / `m1_profile_kb.golden.json`; `M1PromptGoldenTests` / `m1_prompt.golden.json`; Python reads native's file: `M1PythonPickupTests` / `m1_pickup.golden.json` (A9); atomic write + style: `StateStoreTests`, `StateStoreGoldenTests` / `m1_state_styles.golden.json`; real-file load→dump identical: `RealStateRoundTripTests` (A8, 2026-09-29) |
| ✓ | `history.json` | `HIST_FILE` | `M1HistoryAppFeedbackTests` / `m1_history_app.golden.json`; `M1PromptGoldenTests` / `m1_prompt.golden.json`; Python reads native's file: `M1PythonPickupTests` / `m1_pickup.golden.json` (A9); atomic write + style: `StateStoreTests`, `StateStoreGoldenTests` / `m1_state_styles.golden.json`; real-file load→dump identical: `RealStateRoundTripTests` (A8, 2026-09-29) |
| ✓ | `corrections.json` | `CORR_FILE` | `M1CorrectionsTests` / `m1_corrections.golden.json`; atomic write + style: `StateStoreTests`, `StateStoreGoldenTests` / `m1_state_styles.golden.json`; real-file load→dump identical: `RealStateRoundTripTests` (A8, 2026-09-29) |
| ☐ | `CHANGELOG.md` | `CHANGELOG_FILE` | |
| ✓ | `profile.json` | `PROFILE_FILE` | `M1ProfileKnowledgeTests` / `m1_profile_kb.golden.json`; `M1PromptGoldenTests` / `m1_prompt.golden.json`; Python reads native's file: `M1PythonPickupTests` / `m1_pickup.golden.json` (A9); atomic write + style: `StateStoreTests`, `StateStoreGoldenTests` / `m1_state_styles.golden.json`; A8 not run (no real profile.json present) |
| ✓ | `personality.json` | `PERSONALITY_FILE` | `M1PersonalityTests` / `m1_personality.golden.json`; `M1PersonaLLMTests` / `m1_persona_llm.golden.json`; `M1PromptGoldenTests` / `m1_prompt.golden.json`; Python reads native's file: `M1PythonPickupTests` / `m1_pickup.golden.json` (A9); atomic write + style: `StateStoreTests`, `StateStoreGoldenTests` / `m1_state_styles.golden.json`; real-file load→dump identical: `RealStateRoundTripTests` (A8, 2026-09-29) |
| ✓ | `emotions.json` | `EMOTIONS_FILE` | `M1EmotionsToneTests` / `m1_emotions_tone.golden.json`; `M1PromptGoldenTests` / `m1_prompt.golden.json`; Python reads native's file: `M1PythonPickupTests` / `m1_pickup.golden.json` (A9); atomic write + style: `StateStoreTests`, `StateStoreGoldenTests` / `m1_state_styles.golden.json`; real-file load→dump identical: `RealStateRoundTripTests` (A8, 2026-09-29) |
| ☐ | `proactive.json` | `PROACTIVE_FILE` | |
| ☐ | `alarms.json` | `ALARMS_FILE` | |
| ☐ | `voiceprint.npy` | `VOICEPRINT_FILE` | |
| ✓ | `research/metrics.jsonl` | dataset — append-only daily snapshot | `SnapshotGoldenTests` / `m1b_snapshot.golden.json`; `ResearchLastDateGoldenTests` / `m1b_last_date.golden.json`; `MetricsLogTests` |
| ✓ | `research/usage.json` | dataset — per-day counters | `ResearchBumpGoldenTests` / `m1b_bump.golden.json`; `UsageStoreTests`; real-file load→dump identical: `RealStateRoundTripTests` (A8, 2026-09-29) |
| ☐ | `jarvis_notes.txt` | fallback notes file, jarvis.py:3976 (append, UTF-8) | |
| ☐ | `audd_key.txt` | AudD token (secret; `AUDD_API_KEY` alternative), jarvis.py:4118 | |
| ☐ | `logs/jarvis.log` | `LOG_FILE` — shared human log, same `[JARVIS] …` line format | |
| ☐ | `.jarvis.lock` | single-instance lock (new, both implementations) | |
| ☐ | `voices/en_GB-alan-medium.onnx` (+`.json`) | `PIPER_MODEL`/`PIPER_CONFIG` — Piper fallback asset | |

## Subsystems (every `# ───` section of jarvis.py)

| ✓ | Line | Section | Evidence |
|---|---|---|---|
| ☐ | 66 | Configuration | |
| ☐ | 491 | Logging | |
| ☐ | 519 | Network | |
| ☐ | 583 | Windows platform helpers | N/A — Windows not ported (needs user sign-off) |
| ☐ | 651 | Text-to-Speech (Piper, local) | |
| ☐ | 666 | Barge-in (opt-in interruption while JARVIS is talking) | |
| ☐ | 804 | Speech-to-Text (online Google / offline Whisper) | |
| ☐ | 815 | Self-correcting transcription (explicit, user-taught) | |
| ☐ | 976 | Sentence-aware listening + vocal tone | |
| ☐ | 1068 | Wake-word detector (openWakeWord, always-on, cheap) | |
| ☐ | 1144 | Tools | |
| ☐ | 1146 | Security guards | |
| ☐ | 1422 | Media control (AppleScript on macOS / media keys on Windows) | |
| ☐ | 1603 | Application index (every app on the drive) | |
| ☐ | 1647 | App intelligence: know WHAT each app is, not just its name | |
| ☐ | 1820 | System Settings deep-linking + hidden macOS options | |
| ☐ | 1991 | Knowledge base (background learning & offline recall) | |
| ☐ | 2046 | Persistent user profile (durable facts ABOUT the user, not the world) | |
| ☐ | 2126 | Personality (J.A.R.V.I.S. persona + style notes learned from conversations) | |
| ☐ | 2285 | Virtual emotions (persistent mood that colours JARVIS's delivery) | |
| ☐ | 2431 | Dissertation research log (local-only longitudinal dataset) | |
| ☐ | 2822 | Assistant skills: weather, timers, reminders, messages, calendar | |
| ☐ | 2999 | Calendar via EventKit (reliable) with AppleScript fallback | |
| ☐ | 3137 | Outbound comms, calendar write, news, diagnostics, dictation | |
| ☐ | 3461 | Apple Shortcuts (smart home + user automations) | |
| ☐ | 3524 | Browser awareness ("summarize this page") | |
| ☐ | 3593 | Local vision (optional, JARVIS_VISION_MODEL) | |
| ☐ | 3621 | Everyday controls: quit apps, sleep, clipboard, IP, Bluetooth battery | |
| ☐ | 3741 | Proactive nudges (opt-in; JARVIS is otherwise purely reactive) | |
| ☐ | 3873 | Screen awareness, clipboard & notes | |
| ☐ | 3985 | Alarms (persistent across restarts) | |
| ☐ | 4113 | Music identification (Shazam-style via AudD) & lyric search | |
| ☐ | 4257 | Offline fast-path (instant common commands, no LLM needed) | |
| ☐ | 4656 | Ollama brain → FoundationModels fallback (M3) | |
| ☐ | 4815 | Claude Agent SDK backend (subscription auth) + local Ollama fallback | |
| ☐ | 5107 | Wake word | |
| ☐ | 5132 | Speaker verification (recognise the user's voice, ignore TV/music/others) | |
| ☐ | 5323 | HUD wrapper → native NSPanel (M13) | |
| ☐ | 5439 | Assistant loop | |
| ☐ | 5709 | Main | |

## Behaviours not visible in the tool list

- [ ] Fast-path router: every intent in `fast_path()` (golden corpus, M7)
- [ ] Wake word: hard + soft tier, speaker-gated wake (wake audio checked before chime/HUD)
- [ ] Conversation mode: follow-ups without wake word until dismissed or 30 s silence
- [ ] Dismiss phrases (`is_dismiss`), enrolment / forget voice by voice
- [ ] Spoken + typed confirmation gate for risk-tier `confirm` actions (25 s, enrolled voice)
- [ ] Prompt-injection taint guard on BOTH backends
- [ ] Claude → local fallback on any failure; partial-answer salvage; "which model are you using"
- [ ] History: last 12 turns persisted; reloads on start
- [ ] Streaming speech: first sentence spoken while the rest generates
- [ ] Barge-in by enrolled voice only
- [ ] STT hallucination guard (drop low-confidence segments; counted in dataset)
- [ ] Taught corrections applied at the transcription choke point, never to teach commands
- [ ] Personality: regex style triggers, toggle eviction, end-of-conversation distillation, weekly consolidation
- [ ] Emotions: decay half-lives, event classes, bands; `emotion_*` dataset counters
- [ ] Daily research snapshot + counters (same schema) — also while only the chat window runs
- [ ] Single-instance guard: native and Python never run together (`.jarvis.lock` + process check)
- [ ] Daily research snapshot never duplicated across an implementation switch (`_research_last_date` rule, jarvis.py:2516)
- [ ] Activation policy is Accessory (no Dock icon) from launch, re-asserted after the first window

## RAM (measured, not estimated)

Method: `plan/M00-foundation-and-M15-cutover.md` §3.10. Footprint = phys_footprint (MB), median of samples.

| Configuration | Py own | Py tree+helpers | Py daemons | Native own | Native tree+helpers | Native daemons | Py RSS | Native RSS | Sys delta Py / Native | Date |
|---|---|---|---|---|---|---|---|---|---|---|
| Idle, listening for wake word | | | | | | | | | | |
| Mid-conversation (Claude backend) | | | | | | | | | | |
| Offline fallback answering | | | | | | | | | | |
| Text chat only, window open | | | | | | | | | | |
