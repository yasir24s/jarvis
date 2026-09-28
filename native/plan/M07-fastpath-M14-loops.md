# M7 + M14 — Offline fast-path router and background life

Source of truth: `~/jarvis/jarvis.py` (5,762 lines, sha256 is recorded in each
fixture header). All line numbers below were checked with `grep -n` / the AST on 2026-09-28.
Default policy: **native matches Python exactly**. Every deliberate fix is a row in the
deviations table (§8.1) with its own marked fixture; nothing diverges silently.

## 1. Goal and scope (in / explicitly out)

**M7 — fast-path router.** Port `fast_path()` (jarvis.py 4359-4654) and its in-section
helpers `_resolve_open` (4313-4344), `_app_exists` (4285-4292), `_launch_app` (4299-4311,
macOS branch only), `_nudge_volume` (4346-4357, macOS branch only) and the tables
`APP_ALIASES` (macOS variant, 4269-4276) and `WEBSITES` (4277-4283). Deliverables:
1. `FastPathRouter` in JarvisCore: a **pure, synchronous** function `text -> FastPathMatch`
   (branch name + route). It never acts; it names the helper/action to run.
2. `FastPathDispatcher` in JarvisApp: executes a route exactly like `handle_one`
   (5548-5589): tuple → start the action concurrently, speak the announcement, join the
   action ≤ 8 s; string → speak; `None` → brain (`process_command`); update last-reply
   unless it starts with `"Copied to your clipboard"`.
3. Golden suite `fastpath` in `native/tools/golden.py` and Swift test that replays it.

**M7 is not the helpers.** The 40 helpers `fast_path` calls inline (table §2.2) and the 13
action targets are owned by M1 (corrections), M5/M6 (tools). M7 tests only *that the
right helper/action is dispatched with the right arguments* and every literal reply.

**Explicitly out of M7:** helper bodies; `_consume_pending` (1212, M2) which runs before
`fast_path`; `_apply_corrections` (892, applied at transcription in `transcribe` 960-974
and 1135 — M9); `extract_command` (5113, M11/M12); `is_dismiss` (5591), `_is_enroll`,
`_is_shazam` (M12); every `IS_WIN` branch (native is macOS-only).

**M14 — background life.** Keep-awake (5448-5459), lock observer + unlock greeting
(530-572), `proactive_loop` (2527-2559: voiceprint-enrol nudge + weekly consolidation
trigger), `research_log_loop` scheduling (2561-2570; snapshot body is M1b),
`personality_distill_async` trigger (2573-2604; called at 5697), `research_loop`
(2606-2621), `daily_briefing_loop` (3754-3774), `low_battery_watch_loop` (3787-3808),
`meeting_alert_loop` (3846-3871), alarm scheduling/firing/rescheduling (`_next_repeat`
4001-4006, `_fire_alarm` 4008-4033, `_schedule_alarm` 4035-4042, `reschedule_alarms`
4096-4111), start order in `run_assistant` (5466-5473), and the **run-mode policy**
(full voice vs chat-only RAM-light mode, §3.3).

**Explicitly out of M14:** `_briefing` content (M6), `_upcoming_events`/`_ek_events`
(M6 calendar), battery reading (M5 `get_battery`), `set_alarm`/`_parse_when`/cancel/list
(M6), `personality_consolidate` and `personality_learn` bodies (M1), `research_snapshot`
body (M1b), `_web_search` (M6), `speak`/`chime` (M8), HUD (M13), `_startup_watchdog`
(M12), `automation_preflight` probes (M15 TCC; M14 only starts it), `_lock_heartbeat`
(574-581, dead code — never started), `_enrich_app_index` (M5).

## 2. Python reference

### 2.0 What happens before `fast_path` (caller chain, 5548-5589 and 5605-5697)

Voice path: STT → `_apply_corrections` (inside `transcribe`, so corrections are already
applied; teach/forget commands are never altered, 892-895) → `extract_command(text)` if
`contains_wake_word(text)` (lower-cases, strips wake word) → `_is_enroll` / speaker check
/ `_is_shazam` / `is_dismiss` → `handle_one(command)`: `command.strip()`, empty → return;
`_consume_pending(command)` (pending confirmation wins) → `fast_path(command)`.
Inside `fast_path` the only normalisation is line 4362:
`t = text.lower().strip().rstrip("?.")` — **no** whitespace collapsing, **no** `!`
stripping, **no** apostrophe folding (`_resolve_open` separately does
`name.lower().strip().rstrip("?.!")`, 4316). Native typed chat (M4) has no Python oracle:
it must call the router with the trimmed text and **no** correction/wake-word pass (§8 Q3).
Note `"go to sleep"` is caught by `is_dismiss` before `fast_path`; if it reaches
`fast_path` the launcher takes it (case in corpus).

### 2.1 Branch table (in evaluation order — order is load-bearing)

Generated from the AST and re-verified (§5 check V1). Cells are Python source with
newlines collapsed; in raw markdown `|` inside cells is escaped as `\|` (GFM renders it
as `|`; the verifier un-escapes). `t` = normalised text, `m` = the match object.
"inline" = the helper runs **during** the `fast_path` call (side effect at call time);
"lambda" = returned unexecuted.

| # | name | lines | trigger (verbatim) | returns (verbatim) | dispatch | notes |
|---|---|---|---|---|---|---|
| 1 | corr.forget | 4365-4366 | `if _CORR_FORGET_RE.search(t)` | `forget_correction(t)` | forget_correction (inline) | inline WRITE corrections.json (M1). Checked first so nothing swallows it. |
| 2 | corr.teach | 4367-4368 | `if _parse_teach(t)` | `learn_correction(t)` | learn_correction (inline) | inline WRITE corrections.json. Quirk: "that's right not wrong" is a teach (DEV-M7-06). |
| 3 | diagnostics | 4371-4375 | `if t in ("run diagnostics", "run a diagnostic", "run a diagnostics", "run system diagnostics", "system report", "system status", "full diagnostics", "diagnostics", "how's my system", "hows my system", "system health", "status report", "run a systems check", "systems check", "run a system check")` | `_system_report()` | _system_report (inline) | inline read (shell). Exact set only: "run diagnostics please" → launcher (DEV-M7-03). |
| 4 | shortcut.run | 4377-4379 | `m = re.match(r"run (?:the )?shortcut (.+)\|run (?:the )?(.+?) shortcut$", t) ; if m` | `_run_shortcut((m.group(1) or m.group(2)).strip())` | _run_shortcut (inline) | inline ACT (runs a Shortcut). Before launcher. |
| 5 | lights | 4380-4384 | `m = re.match(r"(?:turn\|switch) (on\|off) (?:the \|my )?(.+)\|(?:the \|my )?(.+?) (on\|off)$", t) ; if m and (m.group(2) or m.group(3) or "").strip() in ( "lights", "light", "lamp", "lamps", "the lights")` | `_run_shortcut(f"turn {state} lights")` | _run_shortcut (inline) | inline ACT (Shortcut "turn on/off lights"). Regex matching but not lights falls through. |
| 6 | settings.root | 4387-4389 | `if t in ("open settings", "open system settings", "open preferences", "open system preferences", "settings", "system settings")` | `("Opening System Settings, sir.", lambda: _open_settings())` | _open_settings (lambda) | lambda. Before launcher. |
| 7 | settings.privacy | 4390-4393 | `m = re.match(r"open (?:the )?(.+?) (?:privacy\|permission)s?(?: settings)?$", t) ; if m` | `("Opening privacy settings, sir.", lambda p=m.group(1).strip(): _open_settings(p))` | _open_settings (lambda) | lambda, arg = group(1).strip() via default param p. |
| 8 | settings.pane | 4394-4396 | `m = re.match(r"(?:open\|show\|go to\|take me to) (?:the )?(.+?) (?:settings\|preferences)$", t) ; if m` | `("Opening settings, sir.", lambda p=m.group(1).strip(): _open_settings(p))` | _open_settings (lambda) | lambda. "open bluetooth settings" lands here, not the launcher. |
| 9 | open.file | 4398-4400 | `m = re.match(r"open (?:the )?file (.+)", t) ; if m` | `_open_path(m.group(1).strip())` | _open_path (inline) | inline ACT (open / mdfind). |
| 10 | open.app | 4401-4403 | `m = re.match(r"(?:open\|launch\|open up\|fire up\|bring up\|pull up\|run\|start\|go to)\s+(.+)", t) ; if m` | `_resolve_open(m.group(1).strip())` | _resolve_open (inline) | `_resolve_open` (pure given pins, §2.3). Swallows "start music", "start a timer for 5 minutes", "go to sleep", "run diagnostics please" (DEV-M7-01..04). |
| 11 | media.play | 4405-4408 | `if t in ("play", "resume", "play music", "resume music", "continue playing", "unpause", "play it", "play some music", "play a song", "play something", "play tunes", "play me music", "play me some music", "start music", "start the music")` | `("Playing, sir.", lambda: _media("play"))` | _media (lambda) | lambda. Unreachable for "start music"/"start the music" (launcher first). |
| 12 | media.pause | 4409-4410 | `if t in ("pause", "pause music", "pause it", "stop", "stop music", "stop the music")` | `("Paused, sir.", lambda: _media("pause"))` | _media (lambda) |  |
| 13 | media.next | 4411-4412 | `if t in ("next", "next song", "next track", "skip", "skip song", "skip this", "skip it")` | `("Next track, sir.", lambda: _media("next track"))` | _media (lambda) |  |
| 14 | media.previous | 4413-4414 | `if t in ("previous", "previous song", "previous track", "last song", "go back a song", "replay")` | `("Going back, sir.", lambda: _media("previous track"))` | _media (lambda) |  |
| 15 | media.now_playing | 4415-4416 | `if t in ("what's playing", "what is playing", "what song is this", "current song", "name this song")` | `_now_playing()` | _now_playing (inline) |  |
| 16 | media.play_query | 4417-4424 | `m = re.match(r"(?:play\|put on\|throw on\|listen to\|i want to listen to\|i wanna listen to\|" r"i want to hear\|can you play)\s+(?:some \|the song \|the track \|me )?(.+?)" r"(?: please)?$", t) ; if m` | `_play_query(q) ⟂ ("Playing, sir.", lambda: _media("play"))` | _media (lambda), _play_query (inline) | inline ACT: `_play_query` launches Music.app and PLAYS via AppleScript during the call. Generic q → `("Playing, sir.", _media("play"))`. |
| 17 | media.song_by | 4426-4428 | `if re.match(r"^[\w'&., ]+ by [\w'&., ]+$", t) and not t.split()[0] in ( "what", "who", "stand", "made", "written", "directed", "designed", "built")` | `_play_query(t)` | _play_query (inline) | inline ACT (`_play_query`). First-word exclusion is exact: "what's up by …" plays. |
| 18 | location | 4430-4432 | `if t in ("where am i", "where am i right now", "what's my location", "what is my location", "my location", "where are we", "what's my current location", "locate me")` | `_location()` | _location (inline) |  |
| 19 | weather | 4434-4439 | `if "weather" in t or "temperature" in t or "forecast" in t or t in ("is it raining", "is it cold", "is it hot", "do i need a jacket", "is it going to rain", "will it rain", "will it rain today", "is it nice out", "what's it like outside")` | `_weather(wm.group(1) if wm else "")` | _weather (inline) | inline network. Any text containing weather/temperature/forecast. |
| 20 | timer.set | 4441-4446 | `m = re.match(r"(?:set \|start )?(?:a \|an )?timer (?:for \|of )?(\d+)\s*" r"(second\|sec\|minute\|min\|hour\|hr)s?", t) ; if m` | `_set_timer(secs)` | _set_timer (inline) | inline: starts a threading.Timer. Digits only ("ten minutes" defers). |
| 21 | reminder | 4448-4454 | `m = re.match(r"(?:remind me to\|set a reminder to\|reminder to\|remind me)\s+(.+)", t) ; if m` | `_create_reminder(task or rest, when_text)` | _create_reminder (inline) | inline WRITE (Reminders.app AppleScript). |
| 22 | alarm.set | 4456-4458 | `m = re.match(r"(?:set (?:an? )?alarm\|wake me up\|set alarm)\s*(?:for\|at\|in)?\s*(.+)", t) ; if m` | `set_alarm(m.group(1).strip())` | set_alarm (inline) | inline WRITE alarms.json + schedules a Timer. |
| 23 | lyrics.find | 4460-4464 | `m = re.match(r"(?:what(?:'s\| is)? the song (?:that goes\|with the lyrics\|that says\|called)\|" r"find (?:the \|a )?song(?: that goes\| with the lyrics)?\|name the song that goes\|" r"what song (?:goes\|says)\|song that goes)\s+(.+)", t) ; if m` | `_find_song_by_lyrics(m.group(1))` | _find_song_by_lyrics (inline) |  |
| 24 | messages.read | 4466-4468 | `if t in ("read my messages", "read my texts", "any new messages", "any new texts", "latest messages", "check my messages", "read my latest texts", "read my latest messages")` | `_recent_messages()` | _recent_messages (inline) |  |
| 25 | calendar.today | 4469-4472 | `if t in ("what's on my calendar", "whats on my calendar", "my calendar", "my schedule", "what's my schedule", "whats my schedule", "what's on today", "whats on today", "what does my day look like", "my schedule today", "what's on my schedule")` | `_calendar_today()` | _calendar_today (inline) |  |
| 26 | briefing | 4473-4475 | `if t in ("brief me", "briefing", "daily briefing", "what's my briefing", "morning briefing", "good morning jarvis", "good morning", "good evening jarvis")` | `_briefing()` | _briefing (inline) |  |
| 27 | screen.exact | 4477-4482 | `_SCREEN = ("what's on my screen", "whats on my screen", "what am i looking at", "look at my screen", "read my screen", "analyze my screen", "help me with this", "what should i do", "what am i doing", "help with this", "what do you see", "check my screen", "scan my screen", "what's on screen", "give me ideas") ; if t in _SCREEN` | `_screen_help()` | _screen_help (inline) |  |
| 28 | screen.fuzzy | 4483-4484 | `if "screen" in t and any(w in t for w in ("what", "help", "read", "look", "see", "analy", "scan", "explain"))` | `_screen_help(t)` | _screen_help (inline) | inline screen capture. Quirk: "see screen time" (DEV-M7-07). |
| 29 | clipboard.help | 4486-4488 | `if t in ("what's on my clipboard", "whats on my clipboard", "read my clipboard", "what did i copy", "explain this", "what is this", "explain my clipboard", "check my clipboard")` | `_clipboard_help()` | _clipboard_help (inline) |  |
| 30 | note.make | 4490-4492 | `m = re.match(r"(?:take a note\|make a note\|note that\|new note\|jot down\|note)\s*[:,\-]?\s*(.+)", t) ; if m` | `_make_note(m.group(1).strip())` | _make_note (inline) | inline WRITE (Notes.app). Quirk: "notes"→note "s", "notebook"→"book" (DEV-M7-05). |
| 31 | time | 4493-4494 | `if t in ("what time is it", "what's the time", "time", "what is the time")` | `_get_system_info("time")` | _get_system_info (inline) |  |
| 32 | battery | 4495-4496 | `if "battery" in t and ("level" in t or "how much" in t or "status" in t or t == "battery")` | `_get_system_info("battery")` | _get_system_info (inline) | inline read. Quirk: "what's my airpods battery status" → Mac battery (DEV-M7-08). |
| 33 | backend | 4497-4501 | `if t in ("which model are you using", "what model are you using", "which backend", "what backend are you using", "are you using claude", "claude or local", "which brain are you using", "what model handled that", "backend status", "are you running on claude", "which model was that")` | `_backend_report()` | _backend_report (inline) |  |
| 34 | presence | 4502-4503 | `if t in ("are you there", "you there", "hello", "you online", "are you online", "status")` | `"At your service, sir."` | — | literal reply; `hello!` defers (rstrip does not strip `!`). |
| 35 | voice.forget | 4504-4506 | `if t in ("forget my voice", "reset voice recognition", "respond to everyone", "disable voice recognition", "clear my voice", "stop recognizing only me")` | `forget_voice()` | forget_voice (inline) | inline WRITE: deletes voiceprint.npy. |
| 36 | volume.set | 4507-4510 | `m = re.match(r"(?:set )?volume (?:to )?(\d{1,3})", t) ; if m` | `(f"Setting volume to {lvl}, sir.", lambda: _set_volume(lvl))` | _set_volume (lambda) | clamped 0..100. |
| 37 | volume.mute | 4511-4511 | `if t in ("mute", "volume off")` | `("Muting, sir.", lambda: _set_volume(0))` | _set_volume (lambda) |  |
| 38 | volume.up | 4512-4512 | `if t in ("volume up", "louder")` | `("Turning it up, sir.", lambda: _nudge_volume(15))` | _nudge_volume (lambda) |  |
| 39 | volume.down | 4513-4513 | `if t in ("volume down", "quieter")` | `("Turning it down, sir.", lambda: _nudge_volume(-15))` | _nudge_volume (lambda) |  |
| 40 | news | 4515-4519 | `if t in ("news", "the news", "any news", "what's in the news", "whats in the news", "give me the news", "news briefing", "top headlines", "headlines", "the headlines", "today's headlines", "todays headlines", "what's the news", "whats the news", "what's happening in the world", "whats happening in the world")` | `_get_news()` | _get_news (inline) |  |
| 41 | screenshot | 4521-4523 | `if t in ("take a screenshot", "screenshot", "capture the screen", "capture my screen", "grab a screenshot", "screenshot this", "take a screen shot")` | `_take_screenshot()` | _take_screenshot (inline) |  |
| 42 | lock | 4525-4528 | `if t in ("lock my screen", "lock the screen", "lock my mac", "lock the mac", "lock it", "lock my computer", "lock the computer", "lock up", "i'm stepping away", "im stepping away", "going away for a bit")` | `("Locking, sir.", lambda: _lock_screen())` | _lock_screen (lambda) |  |
| 43 | trash | 4530-4532 | `if t in ("empty the trash", "empty trash", "empty the bin", "empty my trash", "take out the trash", "empty the recycle bin")` | `("Taking out the trash, sir.", lambda: _empty_trash())` | _empty_trash (lambda) |  |
| 44 | brightness.set | 4534-4537 | `m = re.match(r"(?:set )?brightness (?:to )?(\d{1,3})(?: percent)?", t) ; if m` | `(f"Brightness to {lvl}, sir.", lambda: _set_brightness(lvl))` | _set_brightness (lambda) |  |
| 45 | brightness.up | 4538-4539 | `if t in ("brightness up", "brighter", "screen brighter", "make it brighter")` | `("Brighter, sir.", lambda: _nudge_brightness(4))` | _nudge_brightness (lambda) |  |
| 46 | brightness.down | 4540-4541 | `if t in ("brightness down", "dimmer", "screen dimmer", "make it dimmer", "dim the screen")` | `("Dimming, sir.", lambda: _nudge_brightness(-4))` | _nudge_brightness (lambda) |  |
| 47 | message.send | 4543-4546 | `m = re.match(r"(?:send (?:a \|an )?(?:message\|text\|imessage)\|text\|message\|imessage)\s+" r"(?:to\s+)?(.+?)\s+(?:saying\|that says\|say\|telling (?:them\|her\|him))\s+(.+)", t) ; if m` | `_send_message(m.group(1).strip(), m.group(2).strip())` | _send_message (inline) | inline ACT: SENDS an iMessage during the call. |
| 48 | type | 4548-4550 | `m = re.match(r"(?:type\|dictate\|take this down)\s*[:,\-]?\s+(.+)", t) ; if m` | `_type_text(m.group(1).strip())` | _type_text (inline) | inline ACT: keystrokes into the front app. |
| 49 | page.summarize | 4552-4556 | `if t in ("summarize this page", "summarise this page", "summarize this article", "summarise this article", "summarize this", "read this page", "read this article", "what's this page about", "whats this page about", "what's this article about", "whats this article about", "tldr", "give me the gist of this")` | `_summarize_page()` | _summarize_page (inline) |  |
| 50 | shortcut.list | 4558-4560 | `if t in ("what shortcuts do i have", "list my shortcuts", "my shortcuts", "what automations do i have", "list shortcuts")` | `_list_shortcuts()` | _list_shortcuts (inline) |  |
| 51 | timer.cancel | 4562-4563 | `if re.match(r"(?:cancel\|stop\|kill) (?:the \|my \|all )?timers?$", t)` | `_cancel_timers()` | _cancel_timers (inline) |  |
| 52 | timer.status | 4564-4567 | `if re.search(r"how (?:long\|much time).*timer", t) or t in ("timer status", "how's the timer", "hows the timer", "how long left", "check the timer", "check my timer")` | `_timer_status()` | _timer_status (inline) |  |
| 53 | alarm.cancel | 4569-4570 | `if re.match(r"(?:cancel\|stop\|kill\|delete\|turn off) (?:the \|my \|all )?alarms?$", t)` | `_cancel_alarms()` | _cancel_alarms (inline) |  |
| 54 | alarm.list | 4571-4573 | `if t in ("what alarms do i have", "list my alarms", "my alarms", "list alarms", "what alarms are set", "do i have any alarms")` | `_list_alarms()` | _list_alarms (inline) |  |
| 55 | quit.all | 4575-4577 | `if t in ("close everything", "quit everything", "close all apps", "quit all apps", "close all my apps", "quit all applications", "close every app")` | `_quit_all_apps()` | _quit_all_apps (inline) |  |
| 56 | quit.app | 4578-4582 | `m = re.match(r"(?:quit\|close\|exit)\s+(.+)", t) ; if m` | `r` | _quit_app (inline) | inline ACT (terminates apps). `None` → falls through to later branches. |
| 57 | sleep | 4584-4587 | `if t in ("goodnight jarvis", "good night jarvis", "goodnight", "good night", "put the mac to sleep", "put my mac to sleep", "sleep the mac", "put the computer to sleep")` | `("Goodnight, sir.", _sleep_mac)` | _sleep_mac (callable) | action is the function object `_sleep_mac`, not a lambda. |
| 58 | clipboard.copy_last | 4589-4592 | `if t in ("copy that", "copy this", "copy that to my clipboard", "copy this to my clipboard", "put that on my clipboard", "copy your last reply", "copy your answer", "copy the answer", "copy it")` | `_copy_last_reply()` | _copy_last_reply (inline) |  |
| 59 | browser.default.get | 4594-4599 | `if t in ("what's my default browser", "whats my default browser", "what is my default browser", "which browser is my default", "what browser am i using")` | `f"Your default browser is {db}, sir." if db else "I couldn't determine your default browser, sir."` | _default_browser_name (inline) | reply depends on `_default_browser_name()` (pinned). |
| 60 | browser.default.set | 4600-4603 | `m = (re.match(r"(?:set\|make\|change) (?:the \|my )?default browser to (.+)", t) or re.match(r"make (.+?) (?:my\|the) default browser", t)) ; if m` | `_set_default_browser(m.group(1).strip())` | _set_default_browser (inline) |  |
| 61 | apps.find | 4604-4606 | `m = re.match(r"(?:what\|which) (.+?)(?: apps?)? do i have(?: installed)?$", t) ; if m and (_kind_word(m.group(1).strip()) or m.group(1).strip() in _ALL_KINDS)` | `_find_apps(m.group(1).strip())` | _find_apps (inline) | test calls `_kind_word` (pure table). |
| 62 | toggle | 4608-4621 | `m = re.match(r"(?:turn \|switch )?(on\|off\|enable\|disable\|show\|hide) (.+)", t) ; if m` | `(f"Turning {verb} {thing}, sir." if verb in ("on", "off") else f"Done, sir.", lambda: _toggle_system(thing_key, on)) ⟂ (f"Done, sir.", lambda: _macos_tweak(thing, on))` | _macos_tweak (lambda), _toggle_system (lambda) | lambda; passes `thing` (with "the ") to `_macos_tweak` but `thing_key` to `_toggle_system`. Unknown things fall through. |
| 63 | files.recent | 4623-4625 | `if t in ("what did i work on recently", "recent files", "my recent files", "what have i been working on", "recently changed files")` | `_spotlight("", recent=True)` | _spotlight (inline) |  |
| 64 | files.reveal | 4626-4629 | `m = re.match(r"(?:reveal\|find the file\|where is) (?:the )?(?:file )?(.+?)" r"(?: in finder)?$", t) ; if m and ("file" in t or "in finder" in t)` | `_reveal_in_finder(m.group(1).strip())` | _reveal_in_finder (inline) | inline ACT (Finder). Needs "file" or "in finder" in t. |
| 65 | ip | 4631-4634 | `if t in ("what's my ip", "whats my ip", "what's my ip address", "whats my ip address", "what is my ip address", "my ip address", "ip address", "what's my public ip", "whats my public ip")` | `_ip_report()` | _ip_report (inline) |  |
| 66 | bt.battery | 4636-4640 | `if t in ("how are my airpods", "airpods battery", "airpod battery", "check my airpods", "how's my airpods battery", "hows my airpods battery", "whats my airpods battery", "what's my airpods battery", "headphones battery", "headphone battery", "how are my headphones")` | `_bt_battery()` | _bt_battery (inline) |  |
| 67 | web.google | 4642-4646 | `m = re.match(r"google\s+(.+)", t) ; if m` | `(f"Googling {q}, sir.", lambda: _open_url("https://www.google.com/search?q=" + urllib.parse.quote(q)))` | _open_url (lambda) |  |
| 68 | web.youtube | 4647-4653 | `m = (re.match(r"(?:search \|look up \|find )?youtube (?:for )?(.+)", t) or re.match(r"(?:search for \|look up \|find )(.+?) on youtube$", t)) ; if m` | `(f"Searching YouTube for {q}, sir.", lambda: _open_url("https://www.youtube.com/results?search_query=" + urllib.parse.quote(q)))` | _open_url (lambda) |  |
| 69 | defer | 4654-4654 | `(end of function)` | `None` | — | `None` → LLM (`process_command`). |

### 2.1b Branch bodies with extra logic (verbatim source, jarvis.py lines in the header comment)

The table above gives each trigger; these bodies add sub-rules the router must reproduce.

```python
# --- lights: jarvis.py 4380-4384
    m = re.match(r"(?:turn|switch) (on|off) (?:the |my )?(.+)|(?:the |my )?(.+?) (on|off)$", t)
    if m and (m.group(2) or m.group(3) or "").strip() in (
            "lights", "light", "lamp", "lamps", "the lights"):
        state = m.group(1) or m.group(4)
        return _run_shortcut(f"turn {state} lights")
# --- media.play_query + media.song_by: jarvis.py 4417-4428
    m = re.match(r"(?:play|put on|throw on|listen to|i want to listen to|i wanna listen to|"
                 r"i want to hear|can you play)\s+(?:some |the song |the track |me )?(.+?)"
                 r"(?: please)?$", t)
    if m:
        q = m.group(1).strip()
        if q in ("music", "it", "that", "something", "a song", "some music", "tunes", "songs"):
            return ("Playing, sir.", lambda: _media("play"))
        return _play_query(q)
    # bare song request, e.g. "passion fruit by drake"
    if re.match(r"^[\w'&., ]+ by [\w'&., ]+$", t) and not t.split()[0] in (
            "what", "who", "stand", "made", "written", "directed", "designed", "built"):
        return _play_query(t)
# --- weather: jarvis.py 4434-4439
    if ("weather" in t or "temperature" in t or "forecast" in t
            or t in ("is it raining", "is it cold", "is it hot", "do i need a jacket",
                     "is it going to rain", "will it rain", "will it rain today",
                     "is it nice out", "what's it like outside")):
        wm = re.search(r"(?:weather|temperature|forecast)\s*(?:like\s*)?in (.+)", t)
        return _weather(wm.group(1) if wm else "")
# --- timer.set, reminder, alarm.set: jarvis.py 4441-4458
    m = re.match(r"(?:set |start )?(?:a |an )?timer (?:for |of )?(\d+)\s*"
                 r"(second|sec|minute|min|hour|hr)s?", t)
    if m:
        n, u = int(m.group(1)), m.group(2)
        secs = n if u.startswith("sec") else n * 60 if u.startswith("min") else n * 3600
        return _set_timer(secs)
    # reminder
    m = re.match(r"(?:remind me to|set a reminder to|reminder to|remind me)\s+(.+)", t)
    if m:
        rest = m.group(1).strip()
        wm = re.search(r"\b(in \d+\s*\w+.*|at \d.*|tomorrow.*)$", rest)
        when_text = wm.group(1) if wm else ""
        task = (rest[:wm.start()].strip() if wm else rest).strip(" ,")
        return _create_reminder(task or rest, when_text)
    # alarms
    m = re.match(r"(?:set (?:an? )?alarm|wake me up|set alarm)\s*(?:for|at|in)?\s*(.+)", t)
    if m:
        return set_alarm(m.group(1).strip())
# --- quit.app: jarvis.py 4578-4582
    m = re.match(r"(?:quit|close|exit)\s+(.+)", t)
    if m:
        r = _quit_app(m.group(1).strip())
        if r:
            return r    # not a running app → fall through to the LLM
# --- browser.default.get: jarvis.py 4594-4599
    if t in ("what's my default browser", "whats my default browser",
             "what is my default browser", "which browser is my default",
             "what browser am i using"):
        db = _default_browser_name()
        return f"Your default browser is {db}, sir." if db else \
            "I couldn't determine your default browser, sir."
# --- toggle: jarvis.py 4608-4621
    m = re.match(r"(?:turn |switch )?(on|off|enable|disable|show|hide) (.+)", t)
    if m:
        verb, thing = m.group(1), m.group(2).strip()
        on = verb in ("on", "enable", "show")
        thing_key = re.sub(r"^(the )?", "", thing)
        known_sys = thing_key in ("wifi", "wi-fi", "wireless", "bluetooth", "bt",
                                  "do not disturb", "dnd", "focus", "dark mode", "dark",
                                  "light mode")
        known_tweak = any(thing_key in k or k in thing_key for k in _TWEAKS)
        if known_sys:
            return (f"Turning {verb} {thing}, sir." if verb in ("on", "off")
                    else f"Done, sir.", lambda: _toggle_system(thing_key, on))
        if known_tweak:
            return (f"Done, sir.", lambda: _macos_tweak(thing, on))
```

### 2.1c `_resolve_open` (M7-owned; jarvis.py 4313-4344, verbatim)

```python
def _resolve_open(name: str):
    """Return (announcement, action_callable) for an 'open X' request.
    Resolves against EVERY app installed on the drive (APP_INDEX)."""
    key = name.lower().strip().rstrip("?.!")
    if key in WEBSITES:
        url = WEBSITES[key]
        return (f"Opening {name}, sir.", lambda: _open_url(url))
    # category requests: "open my browser" launches the DEFAULT browser, "open my
    # music app" the installed music player — resolved by what apps ARE, not their names
    kind = _kind_word(key)
    if kind:
        app = _default_browser_name() if kind == "browser" else ""
        if not app:
            of_kind = _apps_of_kind(kind)
            app = of_kind[0] if of_kind else ""
        if app:
            return (f"Opening {app}, sir.", lambda: _launch_app(app))
        return (f"I don't see a {kind} app installed, sir.", None)
    app = APP_ALIASES.get(key)
    if not app and key in APP_INDEX:          # exact installed-app match
        app = APP_INDEX[key]
    if not app:                               # fuzzy match against installed apps
        for low, real in APP_INDEX.items():
            if key == low or key in low or low in key:
                app = real; break
    if app or _app_exists(name):
        target = app or name
        return (f"Opening {target}, sir.", lambda: _launch_app(target))
    if "." in key or key.startswith("http"):
        url = key if key.startswith("http") else "https://" + key.replace(" ", "")
        return (f"Opening {name}, sir.", lambda: _open_url(url))
    return (f"I couldn't find an app called {name}, sir.", None)
```

### 2.2 Feasibility probe result: `fast_path(text)` is NOT side-effect free

Read of every callee (AST call list over 4359-4654 → 57 distinct functions) shows 40 helpers
run **inside** the `fast_path` call and do their work before it returns; only the tuple
branches return an unexecuted lambda. Calling it unstubbed on the wrong phrase sends an
iMessage (`_send_message` 3201), plays music (`_play_query` 1564 → AppleScript `play`),
types keystrokes (`_type_text` 3402), quits apps (`_quit_app` 3623 → `terminate()`),
writes `alarms.json` (`set_alarm` 4044), deletes `voiceprint.npy` (`forget_voice` 5241),
takes a screenshot (`_take_screenshot` 3425), runs a Shortcut (`_run_shortcut` 3498).

| class | functions (def line) | golden-harness treatment |
|---|---|---|
| inline, WRITES/ACTS | `forget_correction` 880, `learn_correction` 867, `_run_shortcut` 3498, `_open_path` 2711, `_play_query` 1564, `_set_timer` 2866, `_create_reminder` 2941, `set_alarm` 4044, `_make_note` 3969, `forget_voice` 5241, `_take_screenshot` 3425, `_send_message` 3201, `_type_text` 3402, `_cancel_timers` 2881, `_cancel_alarms` 4069, `_quit_all_apps` 3649, `_quit_app` 3623, `_set_default_browser` 1773, `_reveal_in_finder` 2726, `_copy_last_reply` 3687 | recorder (returns a `str` sentinel); `_quit_app` recorder returns sentinel only for names in `pins.QUIT_RUNNING`, else `None` |
| inline, READS live state | `_system_report` 3299, `_now_playing` 1466, `_location` 2843, `_weather` 2824, `_find_song_by_lyrics` 4162, `_recent_messages` 2964, `_calendar_today` 3087, `_briefing` 3124, `_screen_help` 3942, `_clipboard_help` 3960, `_get_system_info` 1277, `_backend_report` 4857, `_get_news` 3281, `_summarize_page` 3571, `_list_shortcuts` 3516, `_timer_status` 2890, `_list_alarms` 4079, `_find_apps` 1971, `_spotlight` 2671, `_ip_report` 3695, `_bt_battery` 3719 | recorder (sentinel) — their replies are M5/M6 goldens |
| action targets (only via returned lambda/callable) | `_open_url` 600, `_launch_app` 4299, `_open_settings` 1875, `_media` 1424, `_set_volume` 1327, `_nudge_volume` 4346, `_lock_screen` 3443, `_empty_trash` 3452, `_set_brightness` 3371, `_nudge_brightness` 3390, `_toggle_system` 1943, `_macos_tweak` 1915, `_sleep_mac` 3671 | recorder returning `None`; harness **calls** the returned lambda (safe: only recorders are reachable) and records `{fn,args}` |
| pure, kept REAL | `_parse_teach` 853, `_CORR_FORGET_RE` 851, `_resolve_open` 4313, `_kind_word` 1748 | run as-is |
| data providers, PINNED | `APP_INDEX` (1605; empty at import — `build_app_index` never runs), `APP_META` 1653, `_apps_of_kind` 1756, `_app_exists` 4285 (NSWorkspace), `_default_browser_name` 1761 (NSWorkspace) | fixture `pins` block (§4.1) |

Probe actually run (scratch `fp_probe.py`, sandboxed import, every `*_FILE`/`RESEARCH_*`
reassigned to a temp dir, action targets + `_play_query` replaced by recorders), output:
```
{"text": "what time is it", "kind": "say", "reply": "It is 02:05 PM on Monday, September 28."}   # datetime pinned 2026-09-28 14:05
{"text": "open bluetooth settings", "kind": "act", "reply": "Opening settings, sir.", "action": {"static": {"co_names": ["_open_settings"], "closure": {}, "defaults": ["bluetooth"], "qualname": "fast_path.<locals>.<lambda>"}, "dynamic": [{"fn": "_open_settings", "args": ["bluetooth"]}]}}
{"text": "passion fruit by drake", "kind": "helper", "helper": {"fn": "_play_query", "args": ["passion fruit by drake"]}}
{"text": "hello", "kind": "say", "reply": "At your service, sir."}
{"text": "open youtube", "kind": "act", "reply": "Opening youtube, sir.", "action": {"static": {"co_names": ["_open_url"], "closure": {"url": "https://youtube.com"}, "defaults": [], "qualname": "_resolve_open.<locals>.<lambda>"}, "dynamic": [{"fn": "_open_url", "args": ["https://youtube.com"]}]}}
{"text": "volume up", "kind": "act", "reply": "Turning it up, sir.", "action": {"static": {"co_names": ["_nudge_volume"], "closure": {}, "defaults": [], ...}, "dynamic": [{"fn": "_nudge_volume", "args": [15]}]}}
{"text": "tell me a joke", "kind": "defer"}
sandbox files written: []
```
**Action identity method:** static `__code__.co_names` + `__closure__` + `__defaults__`
is incomplete (the `15` in `lambda: _nudge_volume(15)` lives in `co_consts`; `_sleep_mac`
is not a lambda). Use the **dynamic** method: patch every action target in `jarvis`'s
globals with a recorder, assert `set(act.__code__.co_names) ⊆ recorders` (refuse otherwise),
call `act()`, record exactly one `{fn, args}`. Lambdas resolve globals at call time, so
the recorder is what runs.

### 2.3 Replies that depend on live machine state and how the harness pins them

Inside `fast_path`/`_resolve_open` itself (helpers are sentinels, so their live state is
irrelevant here): `open.app` depends on `APP_INDEX` **iteration order** (fuzzy loop
4334-4336 takes the first `key in low or low in key` hit), `_kind_word`, `_apps_of_kind`,
`_default_browser_name`, `_app_exists`; `browser.default.get` on `_default_browser_name`;
`quit.app` on running apps. Nothing in `fast_path` reads the clock, battery or network
directly; `datetime` is still pinned (`FixedDT.now() = 2026-09-28 14:05:00`) defensively.
`TZ=UTC` is exported for the scenario suite (§4.3).

### 2.4 M14 reference (background life)

| feature | jarvis.py | gate (env, verbatim parse) | schedule | says / does (verbatim) | notes |
|---|---|---|---|---|---|
| keep-awake | 5448-5459 | `os.environ.get("JARVIS_KEEP_AWAKE", "1") == "1"` | once at `run_assistant` start | `subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())])`; log `Holding wake assertion (always-listening, even when locked).` | `-i` = prevent idle *system* sleep; display may sleep. Ends with the process. |
| lock observer | 557-569 | none | installed from `_apply_overlay_main` (5399), i.e. **only when the HUD runs**, and that function is scheduled twice (5431 `callAfter`, 5433 `callLater(1.5, …)`) | observes `"com.apple.screenIsLocked"` / `"com.apple.screenIsUnlocked"` on `NSDistributedNotificationCenter` | two observer pairs ⇒ probable double greeting (inferred from code, **not verified**) → DEV-M14-01; `JARVIS_NO_HUD=1` ⇒ no observer ⇒ no greeting → Q2 |
| unlock greeting | 535-555 | `os.environ.get("JARVIS_GREET_UNLOCK", "1") != "0"`; `GREET_MIN_AWAY = 120` | on unlock if `_locked_at[0] and time.time() - _locked_at[0] > GREET_MIN_AWAY` | `f"Welcome back, sir. Good {tod}."`, tod = `"morning" if h < 12 else "afternoon" if h < 18 else "evening"` | spoken on a new thread; no chime, no HUD state |
| voiceprint-enrol nudge | 2527-2555 | none (fires only while `VOICEPRINT_FILE` absent) | `time.sleep(120)` then hourly (`time.sleep(3600)`) | if no voiceprint and `st.get("enroll_reminded") != day and 10 <= hour <= 21`: write `proactive.json` `{"enroll_reminded": day}`, `chime("Tink")`, HUD speaking, speak `"A housekeeping note, sir — I still don't have your voiceprint, so I can't yet tell your voice from the television. Say 'learn my voice' whenever convenient."`, HUD idle + caption "" | at most once per day |
| weekly consolidation trigger | 2556 → 2394-2429 | none | same hourly tick as above, after the nudge | calls `personality_consolidate()`; it returns early unless `len(notes) >= 10` and 7 × 86400 s since `consolidated_at` | body is M1 |
| research snapshot | 2561-2570 | none | `time.sleep(90)` then hourly | if `_research_last_date() != time.strftime("%Y-%m-%d")`: `research_snapshot()` | body is M1b; PARITY: must also run in chat-only mode |
| end-of-conversation distill | 2573-2604, call 5697 | none | after each voice conversation ends (inner loop exit: dismiss, 30 s silence, enrol) | returns unless `time.time() - _last_distill >= 900` and `len(_history) >= 4`; thread posts last 10 turns (each content `[:200]`) to the local model with the verbatim system prompt at 2591-2596, `temperature 0`, timeout 60; if reply `.lower().startswith("the user") and len < 200` → `personality_learn(note)` | model call is Ollama in Python → FoundationModels natively (M3) |
| background research | 2606-2621 | none | `time.sleep(45)` then every 300 s | if `is_online()`: first `q` in `kb["queue"]` whose `kb["topics"][q]` is missing or `updated` older than 3600 s → `_web_search(q)` (caches via `kb_remember`), log `Background research · {q} → {res[:50]}`; one topic per tick | |
| daily briefing | 3743, 3746-3774 | `os.environ.get("JARVIS_BRIEFING_TIME", "").strip()`; empty = off; invalid → log `Invalid JARVIS_BRIEFING_TIME={BRIEFING_TIME!r} (want "HH:MM") — briefing disabled.` and return | sleep until next `HH:MM` (`max(1.0, …)`), repeat daily | `chime("Tink")`, HUD speaking, speak `"Good day, sir. " + _briefing()`, HUD idle | `_next_daily_occurrence`: `h, m = map(int, hhmm.split(":"))` |
| low battery | 3744, 3776-3808 | `int(os.environ.get("JARVIS_LOW_BATTERY", "0"))`; `<= 0` = off | `time.sleep(300)` first, every 300 s | skip if `pct is None or state in ("charging", "charged", "ac")`; if `pct <= threshold` and 3600 s since last warning: `chime("Funk")`, speak `f"Battery at {pct} percent, sir — you may want to plug in."` | state = lower-cased word after `NN%;` in `pmset -g batt`; a non-integer env value raises at import (crash) → DEV-M14-04 |
| meeting alerts | 3810, 3812-3871 | `int(os.environ.get("JARVIS_MEETING_ALERTS", "0") or "0")` minutes; `<= 0` = off | `time.sleep(120)` first, every 120 s | for each event from `_upcoming_events(lead*60)`: key `f"{summ}@{start.isoformat()}"` with `start = (now + secs).replace(second=0, microsecond=0)`; skip if seen or empty; `mins = max(1, round(secs / 60))` (**banker's rounding**); `chime("Tink")`, speak `f"Sir, {summ} starts in about {mins} minute{'s' if mins != 1 else ''}."`; prune keys older than 7200 s | |
| alarm reschedule | 4096-4111, call 5473 | none | once at startup (before mic init) | drop unparsable and past one-shot entries; roll `repeat` entries forward with `_next_repeat` until `> now`; `_schedule_alarm` each; **always** rewrite `alarms.json`; log `Rescheduled {n} pending alarm(s).` | |
| alarm fire | 4008-4042 | none | `threading.Timer(delay)`; `delay <= 0` → not scheduled | `afplay /System/Library/Sounds/Funk.aiff` ×4 (sequential), speak `f"Alarm, sir. {label}."` or `"Alarm, sir. It's time."`; remove entries with that `time`; `repeat` → next occurrence re-added + scheduled | timers keyed by ISO time: two alarms at the same minute overwrite each other's handle (cancel misses one) → DEV-M14-03 |
| `_next_repeat` | 4001-4006 | — | — | `dt + 1 day`; `"weekdays"` skips Sat/Sun | pure |
| automation preflight | 1449-1464, start 5469 | none (`IS_MAC`) | once at startup | 4 read-only AppleScript probes (Music, Calendar, Notes, Reminders) | M14 only starts it (M15 TCC) |

Start order in `run_assistant` (5466-5473): `research_loop`, `research_log_loop`,
`proactive_loop`, `automation_preflight`, `daily_briefing_loop`, `low_battery_watch_loop`,
`meeting_alert_loop` (daemon threads), then `reschedule_alarms()` synchronously. Keep-awake
precedes all of them (5448). Python `speak()` (723) has **no lock**: a background
announcement can overlap a foreground reply → DEV-M14-02.

## 3. Swift design

Swift 6 language mode, deployment macOS 26 (`Package.swift` already declares
`.macOS("26.0")`, tools 6.2). JarvisCore stays Foundation-only (no AppKit/IOKit).

### 3.1 M7 files

| file | contents |
|---|---|
| `native/Sources/JarvisCore/FastPath/FastPathTypes.swift` | route/helper/action enums below + `goldenIdentity` |
| `native/Sources/JarvisCore/FastPath/FastPathPatterns.swift` | every regex from §2.1/§2.1b as a `static let` `NSRegularExpression` (pattern strings copied byte-for-byte), plus the exact phrase sets as `Set<String>` |
| `native/Sources/JarvisCore/FastPath/PyCompat.swift` | `pyNormalise(_:)` = Python `text.lower().strip().rstrip("?.")`; `pyStrip`; `reMatch(_:_:)` (anchored at start, like `re.match`); `reSearch`; `group(_:)` returning `String?` (Python `None` for unmatched groups) |
| `native/Sources/JarvisCore/FastPath/AppTables.swift` | `APP_ALIASES` (macOS variant), `WEBSITES`, `_KIND_SYNONYMS`, `_ALL_KINDS`, `_TWEAKS` keys — if M5 already defines kind tables, import them instead; the fixture's `tables` block is asserted equal either way |
| `native/Sources/JarvisCore/FastPath/OpenResolver.swift` | port of `_resolve_open` (§2.1c) |
| `native/Sources/JarvisCore/FastPath/FastPathRouter.swift` | the router |
| `native/Sources/JarvisApp/FastPath/FastPathDispatcher.swift` | executes a match (the `handle_one` part) |
| `native/Sources/JarvisApp/FastPath/FastPathActions.swift` | the 13 action targets: `launchApp` = `Process("/usr/bin/open", ["-a", target])` (parity with `open -a`), `openURL` = `/usr/bin/open url`, `nudgeVolume` = `/usr/bin/osascript -e` with the exact script of 4355-4356; the rest delegate to M5 |
| `native/Tests/JarvisCoreTests/FastPathGoldenTests.swift` | replays `fastpath_router.json` |

```swift
public enum FastPathAction: Equatable, Sendable {
    case openURL(String), launchApp(String), openSettings(String?)   // nil == `_open_settings()`
    case media(String), setVolume(Int), nudgeVolume(Int), lockScreen, emptyTrash
    case setBrightness(Int), nudgeBrightness(Int), toggleSystem(String, Bool)
    case macosTweak(String, Bool), sleepMac
}
public enum FastPathHelper: Equatable, Sendable {
    case forgetCorrection(String), learnCorrection(String), systemReport, runShortcut(String)
    case openPath(String), nowPlaying, playQuery(String), location, weather(String)
    case setTimer(Int), createReminder(task: String, when: String), setAlarm(String)
    case findSongByLyrics(String), recentMessages, calendarToday, briefing
    case screenHelp(String?)                       // nil == `_screen_help()`
    case clipboardHelp, makeNote(String), systemInfo(String), backendReport, forgetVoice
    case news, takeScreenshot, sendMessage(to: String, text: String), typeText(String)
    case summarizePage, listShortcuts, cancelTimers, timerStatus, cancelAlarms, listAlarms
    case quitAllApps, quitApp(String), copyLastReply, setDefaultBrowser(String)
    case findApps(String), spotlightRecent         // `_spotlight("", recent=True)`
    case revealInFinder(String), ipReport, btBattery
}
public enum FastPathRoute: Equatable, Sendable {
    case say(String)                               // Python returned a literal str
    case act(announcement: String, action: FastPathAction?)   // Python returned a tuple
    case helper(FastPathHelper)                    // Python returned helper(...)'s value
    case deferToBrain                              // Python returned None
}
public struct FastPathMatch: Equatable, Sendable { public let branch: String; public let route: FastPathRoute }

/// Read-only facts the router needs; production = M5 app index, tests = fixture pins.
public protocol FastPathEnvironment: Sendable {
    var appIndex: [(lower: String, display: String)] { get }   // ORDERED (fuzzy loop order)
    func appsOfKind(_ kind: String) -> [String]
    func appExists(_ name: String) -> Bool                        // NSWorkspace lookup in prod
    func defaultBrowserName() -> String                           // "" if unknown
    func quitWouldHandle(_ name: String) -> Bool                  // mirrors `_quit_app` != None
}
public struct FastPathRouter: Sendable {
    public init(env: any FastPathEnvironment)
    public func route(_ text: String) -> FastPathMatch            // pure, synchronous, no I/O
}
```
Rules for the port:
- Evaluate branches in exactly the §2.1 order; each returns a `FastPathMatch` whose
  `branch` is the §2.1 `name`. `quit.app` returns `.helper(.quitApp(name))` only when
  `env.quitWouldHandle(name)`; otherwise it continues to branch 57 (Python fall-through).
- Regex engine: `NSRegularExpression` (ICU), not Swift `Regex` — Swift `Regex` defaults to
  grapheme semantics and Unicode word boundaries, which differ from Python `\b`/`\w`.
  `re.match` ⇒ `.anchored`; `re.search` ⇒ unanchored; operate on the `String` via
  `NSRange(t.startIndex..., in: t)`. Any ICU/Python divergence is caught by the corpus's
  Unicode cases (`déjà vu by olivia rodrigo`, NBSP, `\n`).
- `pyNormalise`: Python `str.lower()` ≈ `lowercased()`; `strip()` must trim exactly
  Python's `str.isspace()` set (incl. U+001C–U+001F, U+0085, U+00A0) — implement with an
  explicit scalar set, not `.whitespacesAndNewlines`; `rstrip("?.")` removes only trailing
  `?` and `.` scalars.
- Clamp and arithmetic exactly as Python: `max(0, min(100, int(...)))`; timer seconds
  `n if u.startswith("sec") else n * 60 if u.startswith("min") else n * 3600`.
- Replies are `String` literals copied from source; f-strings interpolate the *original*
  captured text (e.g. `"Opening youtube, sir."` keeps the user's casing after `lower()`).

`FastPathDispatcher` (JarvisApp, `@MainActor final class`):
`func perform(_ m: FastPathMatch, turn: TurnContext) async -> String?` returns the
`reply_text` (nil for `.deferToBrain`, which the caller sends to the M3 brain).
`.act`: start the action in a child `Task`, speak the announcement via M8, then await the
action with an 8 s timeout (`withTaskGroup` race against `Task.sleep(for: .seconds(8))`;
on timeout, leave it running — Python's `join(timeout=8)` does not kill the thread).
`.helper`: `await tools.run(helper)` (M5/M6 registry) → its reply is `String` or a
`(String, FastPathAction?)` pair (e.g. `_play_query`), handled as `.say` / `.act`.
`TurnContext.lastReply` is updated unless the reply starts with `"Copied to your clipboard"`.

### 3.2 M14 files

| file | contents |
|---|---|
| `native/Sources/JarvisCore/Background/WallClock.swift` | `public protocol WallClock: Sendable { func now() -> Date; func sleep(seconds: Double) async throws }`; `SystemWallClock` (`Date()` + `ContinuousClock().sleep(for:)` — continues across system sleep like wall time); tests use a virtual clock |
| `native/Sources/JarvisCore/Background/BackgroundConfig.swift` | env parsing with Python semantics (table §2.4 col 3): `keepAwake`, `greetUnlock`, `briefingTime: String` (stripped), `lowBatteryThreshold: Int`, `meetingAlertLead: Int` |
| `native/Sources/JarvisCore/Background/BackgroundRules.swift` | pure, golden-tested: `nextDailyOccurrence(_ hhmm: String, now: Date) throws -> Date` (Python `int()` semantics: accepts `" 8"`, `"+8"`, `"8_0"`; rejects `"8.30"`, `"07:30:00"`, hour ≥ 24); `unlockGreeting(hour:)`; `shouldGreet(lockedAt:now:enabled:)`; `lowBatteryShouldWarn(pct:state:threshold:lastWarned:now:)`; `meetingKey(summary:secs:now:)` + `meetingMinutes(secs:)` using `.toNearestOrEven`; `enrolNudgeDue(state:day:hour:voiceprintExists:)`; `distillDue(lastDistill:now:historyCount:)`; `nextResearchTopic(kb:now:)`; `nextRepeat(_:repeat:)`; `reschedule(entries:now:) -> (keep: [AlarmEntry], schedule: [(Date, String)])` |
| `native/Sources/JarvisCore/Background/AlarmScheduler.swift` | `public actor AlarmScheduler` — `schedule(at:label:)`, `cancelAll()`, `rescheduleFromDisk()`; one `Task` per alarm keyed by ISO string (parity) ; `onFire: @Sendable (String) async -> Void` injected (sound ×4 + speech live in JarvisApp). Reads/writes `alarms.json` through the M1 atomic JSON store with Python's `json.dump` default separators |
| `native/Sources/JarvisApp/Background/KeepAwake.swift` | `IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "JARVIS always-listening" as CFString, &id)` / `IOPMAssertionRelease(id)`. `kIOPMAssertionTypePreventUserIdleSystemSleep` is a `CFSTR` macro (IOPMLib.h:292/1004) and Swift does not import `CFSTR` macros — pass the literal; this exact call typechecked with `swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0` (§7) |
| `native/Sources/JarvisApp/Background/LockObserver.swift` | `DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"/"com.apple.screenIsUnlocked"), object: nil, queue: .main)`; installed once per process (DEV-M14-01) |
| `native/Sources/JarvisApp/Background/BackgroundLife.swift` | `@MainActor final class BackgroundLife { init(config:clock:announcer:services:); func start(mode: RunMode); func switchMode(to: RunMode); func stop() }` — each loop is a stored `Task` with the Python initial delay and period; `stop()` cancels all and releases the assertion |
| `native/Sources/JarvisApp/Background/Announcer.swift` | `protocol Announcer { func announce(_ text: String, chime: String?) async }` — voice mode: M8 speech queue (serialised) + M13 HUD speaking/idle; chat-only: §3.3 |
| `native/Tests/JarvisCoreTests/BackgroundGoldenTests.swift` | replays `background_rules.json` and `background_scenarios.json` against `BackgroundRules` + loops driven by a virtual `WallClock` |

Loop periods (seconds, first delay → period), from §2.4: research 45 → 300; research
snapshot 90 → 3600; proactive 120 → 3600; briefing → next HH:MM (min 1) daily; battery
300 → 300; meetings 120 → 120; alarms reschedule at start; preflight at start.
Loops call `clock.sleep` and check `Task.isCancelled`; exceptions are logged with the same
prefixes as Python (`Proactive loop: `, `Research loop: `, `Daily briefing error: `,
`Low-battery warning error: `, `Meeting alert error: `, `Personality distill: `).

### 3.3 Run-mode policy (native only — Python has no chat-only mode, so no oracle)

`enum RunMode { case voice, chatOnly }`. RAM-light chat-only mode must not start
voice-only loops. "Voice-only" = exists to support always-listening.

| loop | voice | chatOnly | why |
|---|---|---|---|
| keep-awake assertion | on if gate | **off** (released on switch) | comment 5445-5447: its purpose is listening while locked |
| lock observer + unlock greeting | on if gate | **off** | spoken greeting for an always-on assistant |
| voiceprint-enrol nudge | on | **off** | speaker ID is voice-only |
| weekly consolidation trigger | on | on | state hygiene; model call on demand |
| research snapshot | on | on | PARITY.md: "also while only the chat window runs" |
| background research | on | on | network only, no model |
| distill trigger | end of voice conversation | chat idle 30 s (`CONV_TIMEOUT`) after last reply, or window close (Q3) | same 900 s / ≥ 4 turn gates |
| alarms reschedule + fire | on | on | user-set; sound always plays |
| briefing / battery / meetings | on if gate | on if gate, delivered as a chat message; spoken only if chat "spoken replies" is on (Q4) | opt-in user requests |
| automation preflight | start | start | TCC prompts |

## 4. Golden vectors

All suites run under `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3`,
import `jarvis` once, then **before anything else** reassign every module attribute whose
name ends in `_FILE` or starts with `RESEARCH_` to a fresh `tempfile.mkdtemp()` (14 today:
ALARMS, CHANGELOG, CORR, EMOTIONS, HIST, KB, LOG, PERSONALITY, PROACTIVE, PROFILE,
RESEARCH_DIR/METRICS/USAGE, VOICEPRINT). If M0's `golden.py` provides a shared sandbox
helper, use it; otherwise each suite does this itself (the prototype did; §5 V3).
Suite modules: `native/tools/golden_suites/fastpath.py` and
`native/tools/golden_suites/background.py`, invoked as `golden.py fastpath` /
`golden.py background` (if M0 chose another registration mechanism, follow M0 — §8 Q1).

### 4.1 Suite `fastpath` → `native/Tests/Fixtures/golden/fastpath_router.json`

Harness rules (all proven in the scratch prototype, §5 V3):
1. **Tripwires after import:** `subprocess.run`, `subprocess.Popen`,
   `subprocess.check_output`, `urllib.request.urlopen`, `socket.create_connection`,
   `threading.Timer`, `threading.Thread.start` raise `Tripwire`; `builtins.open` in any
   write mode outside the sandbox raises; `sys.modules["AppKit"] = None` and
   `sys.modules["Foundation"] = None` so any `from AppKit import …` fails. A case that trips
   is recorded as `{"text", "error"}` and the suite exits non-zero.
2. **Recorders:** every §2.2 "inline" helper → returns `class Sent(str)` sentinel and appends
   `{"fn", "args"[, "kwargs"]}`; every action target → returns `None` and appends.
3. **Pins** (written verbatim into the fixture):
```json
{"APP_INDEX": [["safari","Safari"],["music","Music"],["notes","Notes"],["mail","Mail"],
  ["messages","Messages"],["calendar","Calendar"],["maps","Maps"],["tv","TV"],["xcode","Xcode"],
  ["visual studio code","Visual Studio Code"],["google chrome","Google Chrome"],
  ["calculator","Calculator"],["system settings","System Settings"],["terminal","Terminal"],
  ["weather","Weather"],["shortcuts","Shortcuts"],["vlc","VLC"],["zoom.us","zoom.us"]],
 "APPS_OF_KIND": {"browser":["Google Chrome","Safari"],"music":["Music"],"email":["Mail"],
  "video":["VLC"],"terminal":["Terminal"],"editor":["Visual Studio Code","Xcode"],
  "notes":["Notes"],"chat":["Messages","zoom.us"]},
 "APP_EXISTS": ["finder"], "DEFAULT_BROWSER": "Safari",
 "QUIT_RUNNING": ["safari","music","xcode","all my browsers"]}
```
   Applied as `J.APP_INDEX = dict(pairs)` (order preserved), `J.APP_PATHS = {}`,
   `J.APP_META = {}`, `J._apps_of_kind = lambda k: list(APPS_OF_KIND.get(k, []))`,
   `J._app_exists = lambda a: a in APP_EXISTS`, `J._default_browser_name = lambda: "Safari"`,
   `J._quit_app` = recorder returning the sentinel iff `name in QUIT_RUNNING` else `None`,
   `J.datetime` = subclass with `now()` → `2026-09-28 14:05:00`.
4. **Branch identity:** `sys.settrace` on `fast_path`'s code object records the line of the
   `return` event; map it to the enclosing top-level `if`/`return` statement of the
   function body (AST, computed from the live file), then to the §2.1 `name` list (69
   names, in order). If the AST branch count ≠ 69 the suite fails ("branch count changed").
5. **Action identity:** dynamic method of §2.2 (call the returned callable; exactly one
   recorder hit, else fail).

Fixture shape:
```json
{"schema": "jarvis.golden.fastpath/1",
 "source": {"file": "jarvis.py", "sha256": "<hex>", "fast_path_lines": [4359, 4654]},
 "pins": { …as above… },
 "tables": {"KIND_SYNONYMS": {…}, "ALL_KINDS": [sorted], "TWEAKS_KEYS": [ordered],
            "WEBSITES": {…}, "APP_ALIASES": {…}},
 "branches": [{"name": "corr.forget", "lines": [4365, 4366]}, …69],
 "cases": [
  {"text": "open bluetooth settings", "t": "open bluetooth settings", "branch": "settings.pane",
   "kind": "act", "reply": "Opening settings, sir.", "action": {"fn": "_open_settings", "args": ["bluetooth"]}},
  {"text": "passion fruit by drake", "t": "passion fruit by drake", "branch": "media.song_by",
   "kind": "helper", "helper": {"fn": "_play_query", "args": ["passion fruit by drake"]}},
  {"text": "hello", "t": "hello", "branch": "presence", "kind": "say", "reply": "At your service, sir."},
  {"text": "open flurbo", "t": "open flurbo", "branch": "open.app", "kind": "act",
   "reply": "I couldn't find an app called flurbo, sir.", "action": null},
  {"text": "close the deal", "t": "close the deal", "branch": "defer", "kind": "defer",
   "probes": [{"fn": "_quit_app", "args": ["the deal"]}]}]}
```
`kind`: `say` (literal str) · `act` (tuple; `action` null when Python's action is `None`)
· `helper` (sentinel returned; `helper` = last recorder hit) · `defer` (`None`).
`probes` lists `_quit_app` consultations that returned `None` and fell through.
Swift maps `FastPathHelper`/`FastPathAction` to `{fn, args}` via `goldenIdentity`
(e.g. `.createReminder(task:when:)` → `["_create_reminder", [task, when]]`,
`.spotlightRecent` → `["_spotlight", [""], {"recent": true}]`, `.screenHelp(nil)` →
`["_screen_help", []]`, `.openSettings(nil)` → `["_open_settings", []]`).

**Corpus (280 phrases, ASCII-escaped JSON, verbatim input to the suite).** ≥ 1 positive
per branch (prototype: 69/69 branches hit), plus near-misses and ordering conflicts:
```json
[
 "forget the correction for passion", "please forget the corrections", "forget corrections",
 "forget all corrections", "i said passion not fashion", "correct fashion to passion",
 "when i say lamps i mean lights", "it's drake not dray", "that's right not wrong",
 "i said hello", "run diagnostics", "Run Diagnostics.", "system status", "how's my system",
 "run a systems check", "diagnostics?", "run diagnostics please",
 "run shortcut morning routine", "run the good night shortcut", "run the shortcuts app",
 "turn on the lights", "switch off my lamp", "lights off", "the lights on",
 "turn on the light switch", "turn off the tv", "open settings", "system settings", "settings",
 "open system preferences", "open settings app", "open microphone privacy settings",
 "open the camera permissions", "open screen recording privacy", "open bluetooth settings",
 "show display settings", "take me to the sound preferences", "go to wifi settings",
 "open screen time settings", "open file budget.xlsx", "open the file notes.txt", "open safari",
 "Open Safari!", "open youtube?", "launch music", "open my browser", "open my music app",
 "open my game app", "open mail", "fire up xcode", "open vs code", "bring up calculator",
 "pull up maps", "open the tv", "open github.com", "open http://example.com", "open flurbo",
 "open finder", "go to google", "open weather", "open notes", "start music", "start the music",
 "start a timer for 5 minutes", "go to sleep", "play", "resume music", "unpause",
 "play some music", "play it", "pause", "stop", "stop music", "next", "skip it", "previous",
 "replay", "what's playing", "name this song", "play bohemian rhapsody", "put on some jazz",
 "listen to the song yellow", "can you play hotel california please", "play songs",
 "i want to hear music", "play cats on youtube", "passion fruit by drake", "hello by adele",
 "what's up by 4 non blondes", "who sang yesterday by the beatles", "stand by me by ben e king",
 "written by shakespeare", "down by the river?", "ac/dc by angus", "where am i", "locate me",
 "what's the weather", "weather in london", "what's the temperature in paris",
 "what's the weather like in new york", "is it raining", "forecast for tomorrow",
 "will it rain today", "whether or not", "set a timer for 5 minutes", "timer for 30 seconds",
 "timer 2 hours", "set a timer for ten minutes", "remind me to call mum in 10 minutes",
 "remind me to buy milk tomorrow", "set a reminder to pay rent at 5 pm", "remind me",
 "set an alarm for 7 am", "wake me up at 6:30", "set alarm in 20 minutes",
 "set an alarm for 7 every weekday", "what's the song that goes never gonna give you up",
 "find the song with the lyrics hello from the other side", "song that goes we will rock you",
 "read my messages", "any new texts", "what's on my calendar", "my schedule today", "brief me",
 "good morning", "good morning jarvis", "what's on my screen", "what's on my screen?",
 "help me with this", "give me ideas", "what's on the screen", "explain my screen",
 "can you see my screen", "see screen time", "lock my screen", "take a screenshot",
 "screen brighter", "what's on my clipboard", "explain this", "what is this",
 "explain this page", "take a note buy eggs", "note: call the bank",
 "note that the meeting moved", "jot down meeting at noon", "notes", "notebook", "note",
 "what time is it", "What Time Is It?", "time", "what's the time", "what time is it in tokyo",
 "what  time is it", "battery level", "battery", "how much battery do i have",
 "what's my airpods battery status", "my battery", "which model are you using",
 "backend status", "hello", "  hello  ", "hello!", "hello jarvis", "are you there", "status",
 "forget my voice", "respond to everyone", "volume 50", "set volume to 30", "volume to 150",
 "set volume to 0", "volume fifty", "mute", "volume up", "louder", "quieter", "news",
 "top headlines", "what's the news", "screenshot", "i'm stepping away", "lock it",
 "empty the trash", "brightness 70", "set brightness to 40 percent", "brightness to 200",
 "brighter", "dim the screen", "text mum saying i'll be late",
 "send a message to dad that says happy birthday", "message sarah telling her i'm outside",
 "text mum", "type hello world", "dictate: dear sir", "take this down the meeting is at noon",
 "summarize this page", "tldr", "list my shortcuts", "what shortcuts do i have",
 "cancel the timer", "stop my timers", "kill all timers", "how long is left on the timer",
 "timer status", "how long left", "cancel my alarm", "turn off the alarm", "delete all alarms",
 "list my alarms", "do i have any alarms", "quit everything", "close all apps", "quit safari",
 "close the deal", "close all my browsers", "exit", "goodnight", "goodnight jarvis",
 "put the mac to sleep", "copy that", "copy it", "what's my default browser",
 "set my default browser to chrome", "make firefox my default browser",
 "what browsers do i have", "which music apps do i have installed", "what games do i have",
 "what friends do i have", "turn on dark mode", "turn off wifi", "enable bluetooth",
 "show hidden files", "hide the dock", "disable do not disturb", "switch on focus",
 "turn on the kettle", "show me the money", "recent files", "what have i been working on",
 "reveal the file budget.pdf", "where is the file thesis.docx",
 "find the file resume in finder", "where is my phone", "what's my ip", "ip address",
 "airpods battery", "how are my headphones", "google swift concurrency",
 "google how tall is everest", "youtube lofi beats", "search youtube for cats",
 "find cooking videos on youtube", "look up youtube for guitar lessons", "tell me a joke",
 "what's the capital of france", "who are you", "how are you doing today", "thank you", "",
 "open my games", "open a game", "stop the timer", "stop the music", "turn the lights off",
 "open the pod bay doors", "hide", "play music by drake", "WHAT'S PLAYING?",
 "what\u2019s playing", "open system settings", "turn off the lights",
 "what's the weather in london?", "launch spotify", "d\u00e9j\u00e0 vu by olivia rodrigo",
 "play d\u00e9j\u00e0 vu", "turn on the lights\u00a0", "open safari\n?", "hello."
]
```

Ordering conflicts and quirks inside the corpus (verdicts copied from the prototype
fixture, not typed):

| phrase | rule exercised | Python verdict (oracle, prototype run) | dev |
|---|---|---|---|
| `run diagnostics` | diagnostics precedes launcher | `diagnostics: helper _system_report()` |  |
| `run diagnostics please` | exact set only → launcher | `open.app: act "I couldn't find an app called diagnostics please, sir." + None` | DEV-M7-03 |
| `run the good night shortcut` | shortcut precedes launcher (`run`) | `shortcut.run: helper _run_shortcut('good night')` |  |
| `run the shortcuts app` | not a shortcut phrase → launcher fuzzy | `open.app: act 'Opening Shortcuts, sir.' + _launch_app('Shortcuts')` |  |
| `open settings` | settings.root precedes settings.pane | `settings.root: act 'Opening System Settings, sir.' + _open_settings()` |  |
| `open bluetooth settings` | settings.pane precedes launcher | `settings.pane: act 'Opening settings, sir.' + _open_settings('bluetooth')` |  |
| `go to wifi settings` | settings.pane precedes launcher (`go to`) | `settings.pane: act 'Opening settings, sir.' + _open_settings('wifi')` |  |
| `open screen time settings` | settings.pane, not screen.fuzzy | `settings.pane: act 'Opening settings, sir.' + _open_settings('screen time')` |  |
| `open settings app` | no settings rule → launcher miss | `open.app: act "I couldn't find an app called settings app, sir." + None` | DEV-M7-10 |
| `open file budget.xlsx` | open.file precedes launcher | `open.file: helper _open_path('budget.xlsx')` |  |
| `open weather` | launcher precedes weather substring | `open.app: act 'Opening Weather, sir.' + _launch_app('Weather')` |  |
| `open notes` | launcher precedes note.make | `open.app: act 'Opening Notes, sir.' + _launch_app('Notes')` |  |
| `start music` | launcher precedes media.play (set entry dead) | `open.app: act 'Opening Music, sir.' + _launch_app('Music')` | DEV-M7-02 |
| `start the music` | same | `open.app: act 'Opening Music, sir.' + _launch_app('Music')` | DEV-M7-02 |
| `start a timer for 5 minutes` | launcher precedes timer.set | `open.app: act "I couldn't find an app called a timer for 5 minutes, sir." + None` | DEV-M7-01 |
| `set a timer for 5 minutes` | timer.set | `timer.set: helper _set_timer(300)` |  |
| `go to sleep` | launcher (is_dismiss normally catches it first) | `open.app: act "I couldn't find an app called sleep, sir." + None` | DEV-M7-04 |
| `play it` | media.play exact precedes play_query | `media.play: act 'Playing, sir.' + _media('play')` |  |
| `play songs` | play_query generic word | `media.play_query: act 'Playing, sir.' + _media('play')` |  |
| `play cats on youtube` | play_query precedes web.youtube | `media.play_query: helper _play_query('cats on youtube')` |  |
| `what's up by 4 non blondes` | song_by: first word is "what's", not "what" | `media.song_by: helper _play_query("what's up by 4 non blondes")` |  |
| `who sang yesterday by the beatles` | song_by excluded first word | `defer: defer` |  |
| `turn on the lights` | lights precedes toggle | `lights: helper _run_shortcut('turn on lights')` |  |
| `turn the lights off` | neither lights alternative matches | `defer: defer` |  |
| `turn on dark mode` | lights regex matches, not lights → toggle | `toggle: act 'Turning on dark mode, sir.' + _toggle_system('dark mode', True)` |  |
| `turn off the alarm` | alarm.cancel precedes toggle | `alarm.cancel: helper _cancel_alarms()` |  |
| `stop` | media.pause exact | `media.pause: act 'Paused, sir.' + _media('pause')` |  |
| `stop the timer` | timer.cancel | `timer.cancel: helper _cancel_timers()` |  |
| `lock my screen` | "screen" but no fuzzy verb → lock | `lock: act 'Locking, sir.' + _lock_screen()` |  |
| `see screen time` | screen.fuzzy swallows | `screen.fuzzy: helper _screen_help('see screen time')` | DEV-M7-07 |
| `screen brighter` | brightness.up | `brightness.up: act 'Brighter, sir.' + _nudge_brightness(4)` |  |
| `notes` | note.make regex `note` + `s` | `note.make: helper _make_note('s')` | DEV-M7-05 |
| `notebook` | same | `note.make: helper _make_note('book')` | DEV-M7-05 |
| `that's right not wrong` | teach regex `that'?s X not Y` | `corr.teach: helper learn_correction("that's right not wrong")` | DEV-M7-06 |
| `what's my airpods battery status` | battery precedes bt.battery | `battery: helper _get_system_info('battery')` | DEV-M7-08 |
| `airpods battery` | bt.battery | `bt.battery: helper _bt_battery()` |  |
| `hello!` | `!` not stripped | `defer: defer` |  |
| `what\u2019s playing` | curly apostrophe not folded | `defer: defer` | DEV-M7-09 |
| `close the deal` | quit probe None → falls through | `defer: defer` |  |
| `hide the dock` | toggle passes "the dock" to _macos_tweak | `toggle: act 'Done, sir.' + _macos_tweak('the dock', False)` |  |

### 4.2 Deviations fixture → `native/Tests/Fixtures/golden/fastpath_deviations.json`

One entry per §8.1 row. `python` is copied by the suite from the parity run (oracle);
`native` is the **hand-specified** intended verdict — the only non-oracle expectation in
M7, marked as such. Shape:
```json
{"schema": "jarvis.golden.deviations/1", "source": {"sha256": "<same as router fixture>"},
 "deviations": [{"id": "DEV-M7-01", "status": "proposed", "text": "start a timer for 5 minutes",
   "python": {"branch": "open.app", "kind": "act", "reply": "I couldn't find an app called a timer for 5 minutes, sir.", "action": null},
   "native": {"branch": "timer.set", "kind": "helper", "helper": {"fn": "_set_timer", "args": [300]}},
   "hand_specified": true}]}
```
Swift test rule: for `status == "approved"` the parity case with the same `text` is skipped
and `native` asserted; otherwise the parity case is asserted and `native` ignored. The
router reads approvals from one `static let approvedDeviations: Set<String>` in
`FastPathRouter.swift` (empty at M7 start). Approving a deviation = add its id there +
flip `status` in the suite's source list; the suite regenerates the file.

### 4.3 Suite `background` → `background_rules.json` and `background_scenarios.json`

Same sandbox + tripwires as §4.1; additionally `os.environ["TZ"] = "UTC"; time.tzset()`
**before** `import jarvis`. A virtual clock replaces `J.time` (object exposing `time()`,
`sleep(s)` — advances the clock, appends `{"at","sleep"}`, raises `StopScenario` when a
tick budget is exhausted — and `strftime(fmt)`) and `J.datetime` (subclass whose `now()`
reads the clock). `J.speak`, `J.chime`, `J.log`, HUD are recorders; `J.threading` is
replaced by a shim whose `Thread(...).start()` runs the target synchronously (only for
the unlock and distill scenarios).

`background_rules.json` — direct calls of the real Python functions:
| vector set | Python call | inputs |
|---|---|---|
| `next_daily` | `J._next_daily_occurrence(s)` with clock at each `now` | `s` ∈ `"08:30" "8:30" " 8:30" "07:05" "7:5" "23:59" "00:00" "24:00" "8.30" "07:30:00" "+8:30" "8_0:30" "ab:cd" ""`; `now` ∈ `2026-09-28T07:00:00`, `T08:30:00` (equal ⇒ next day), `T23:59:30`; record ISO result or `{"error": type(e).__name__}` |
| `unlock_greeting` | `J._unlock_greeting()` | clock hour 0…23 |
| `next_repeat` | `J._next_repeat(dt, rep)` | `dt` = each day 2026-09-25 … 2026-10-02 at 07:00, `rep` ∈ `"daily" "weekdays"` |
| `reschedule` | `J.reschedule_alarms()` with `_schedule_alarm` recorded | the 6-entry `alarms.json` of §5 V4 + variants: empty file, missing file, all past one-shots |

`background_scenarios.json` — the real loop functions driven by the clock; each entry
`{"scenario", "setup", "end": "returned"|"budget", "events": [...]}`:
| scenario | function | setup |
|---|---|---|
| `low_battery.threshold20` | `low_battery_watch_loop(hud)` | `LOW_BATTERY_THRESHOLD=20`; `_battery_raw` script `(35,discharging) (20,discharging) (18,…)…` then ≥ 13 more ticks below 20 so the 3600 s cooldown expires once; include `charging`, `charged`, `ac`, `(None, None)` |
| `low_battery.disabled` | same | threshold 0 ⇒ returns immediately |
| `meeting.lead5` | `meeting_alert_loop(hud)` | `MEETING_ALERT_LEAD=5`; `_upcoming_events` script per poll: repeated event across polls (dedupe), new event, empty summary |
| `meeting.rounding` | same | one poll with distinct events at `secs` ∈ 30, 89, 90, 150, 210, 270, 299 (observed from the real loop: 30→"1 minute", 89→1, 90→2, 150→"2 minutes", 210→4, 270→4, 299→5 — banker's rounding) |
| `meeting.prune` | same | same event reappearing after > 7200 s ⇒ announced again |
| `briefing.0830` | `daily_briefing_loop(hud)` | `BRIEFING_TIME="08:30"`, clock 07:00, `_briefing` → fixed string, 3 ticks |
| `briefing.invalid` | same | `"8.30"` ⇒ one log line, returns |
| `unlock.*` | `_on_lock(None)`; advance; `_on_unlock(None)` | away 60 / 120 / 121 / 3600 s at hours 10, 13, 18; `GREET_UNLOCK` False; unlock without prior lock |
| `proactive.*` | `proactive_loop(hud)` | no voiceprint; clock hours 9, 10, 21, 22; `proactive.json` absent / already reminded today; `personality_consolidate` recorded |
| `distill.*` | `personality_distill_async()` | `_history` of 3 / 4 / 12 turns; `_last_distill` now-100 / now-901; `ollama_post` recorder returning `"The user prefers brevity."`, `"NONE"`, a 250-char "The user …"; record the full payload and `personality_learn` calls |
| `research.*` | `research_loop()` | `is_online` True/False; `kb_load` → queue of 3 with fresh/stale/missing topics; `_web_search` recorded |
| `research_log.*` | `research_log_loop()` | `_research_last_date` = today / yesterday; `research_snapshot` recorded |
| `alarm.fire.*` | `_fire_alarm(label, iso)` | `subprocess.run` temporarily a recorder (afplay ×4), `_schedule_alarm` recorded; one-shot, daily, weekdays-on-Friday, label "" |

## 5. Acceptance checks

Run from `~/jarvis/native`. `PY=/Library/Frameworks/Python.framework/Versions/3.14/bin/python3`.

| # | command | observable proof |
|---|---|---|
| A1 | `$PY tools/golden.py fastpath` | prints `cases=280 errors=0 branches_hit=69/69`; `git status --porcelain ..` shows no change outside `native/Tests/Fixtures/golden/`; sandbox dir listing printed empty of anything but expected files |
| A2 | `$PY tools/golden.py fastpath --negative-control` | restores the real `_take_screenshot` and `_open_path` for one case each and prints two `Tripwire` messages (`subprocess.run(['screencapture', …` and `['mdfind', …`) — proves stubs, not luck, keep the run side-effect free |
| A3 | `swift test --filter FastPathGoldenTests` | all 280 parity cases pass (branch, kind, reply, helper/action identity); table-equality tests for `KIND_SYNONYMS`, `ALL_KINDS`, `TWEAKS_KEYS`, `WEBSITES`, `APP_ALIASES` pass; fixture `sha256` equals `shasum -a 256 ../jarvis.py` (else test fails with "regenerate fixture") |
| A4 | `swift test --filter FastPathDeviationTests` | with `approvedDeviations` empty every deviation's `python` verdict equals the router; after an approval its `native` verdict does |
| A5 | `$PY tools/golden.py background` then `swift test --filter BackgroundGoldenTests` | every rules vector and scenario event list equal (text, chime name, virtual timestamps) |
| A6 | `swift build` then run the app in voice mode 10 s, `pmset -g assertions \| grep -i "JARVIS always-listening"` | one `PreventUserIdleSystemSleep` line owned by the JARVIS pid; after quit the same grep prints nothing. In chat-only mode: nothing |
| A7 | **manual, user present:** lock screen (⌃⌘Q) ≥ 121 s, unlock, with the app in voice mode | log shows `screen LOCKED` / `screen UNLOCKED` exactly once each and one spoken `Welcome back, sir. Good …` (screen recording or log line from the Announcer); at < 120 s no greeting; in chat-only mode no observer log line |
| A8 | `grep -c "addObserver(forName: .init(\"com.apple.screenIs" Sources/JarvisApp/Background/LockObserver.swift` | `2`, and a unit test asserts `LockObserver.install()` is idempotent (second call returns without adding) |
| A9 | chat-only mode, `ps -o rss= -p <pid>` after 60 s | no mic / wake / speaker-ID object alive (debug `BackgroundLife.activeLoops` prints only the chat-only rows of §3.3); RSS recorded in `PARITY.md` §RAM "Text chat only" row |

Never done in acceptance: executing any action/helper for real from the corpus, starting
Python JARVIS, `launchctl`, or posting fake `com.apple.screenIs*` distributed notifications
(they reach other processes).

## 6. Executor tasks

Each task: start writing immediately, read `jarvis.py` on demand with `sed -n 'A,Bp'`
(never the whole file), append one line per step to your worklog. Commit per task on the
native branch named by the M0 plan, never on `main` without the user.

| id | task (≤ ~2 h) | files | spec | verification | deps |
|---|---|---|---|---|---|
| T1 | Fast-path golden suite | `native/tools/golden_suites/fastpath.py`, fixture `fastpath_router.json` | §4.1 exactly: sandbox, tripwires, recorders (lists in §2.2), pins, settrace branch map, dynamic action identity, corpus of §4.1 verbatim, `--negative-control` | A1, A2; fixture has 280 cases, 69/69 branches, 0 errors | M0 `golden.py` |
| T2 | Deviations fixture | `fastpath.py` (+ `DEVIATIONS` list), `fastpath_deviations.json` | §4.2, one entry per §8.1 M7 row, `python` copied from the parity run | file has 12 entries (one per phrase in §8.1 M7 rows), each `python` equals the router fixture case with the same text | T1 |
| T3 | Router types + PyCompat + tables | `FastPathTypes.swift`, `PyCompat.swift`, `AppTables.swift`, `FastPathPatterns.swift` | §3.1; patterns/phrases pasted from §2.1/§2.1b (not retyped: copy from `jarvis.py` lines) | unit tests: `pyNormalise` on the corpus equals fixture `t` for all 280; table-equality tests vs fixture `tables` | T1 |
| T4 | Router branches 1-34 | `FastPathRouter.swift`, `OpenResolver.swift` | §2.1 rows 1-34 + §2.1b/§2.1c in order; unimplemented tail returns `.deferToBrain` with branch `"defer"` | `FastPathGoldenTests` filtered to cases whose fixture branch is in rows 1-34 pass | T3 |
| T5 | Router branches 35-69 | `FastPathRouter.swift` | rows 35-69 incl. `quit.app` fall-through and `toggle` sub-rules | A3 (all 280), A4 | T4 |
| T6 | Dispatcher + actions | `FastPathDispatcher.swift`, `FastPathActions.swift` | §3.1 dispatcher semantics (concurrent action, 8 s join, last-reply rule); actions call M5 where they exist, else `Process` parity commands | unit test with a fake tool registry + fake speaker: order of events `action-start, speak, join` and 8 s timeout path; **no real action executed in tests** | T5, M5/M6 registry |
| T7 | Background golden suite | `native/tools/golden_suites/background.py`, `background_rules.json`, `background_scenarios.json` | §4.3 | A5 (Python half): both files written, 0 tripwires, events non-empty for every enabled scenario | M0 |
| T8 | BackgroundRules + WallClock + config | `WallClock.swift`, `BackgroundConfig.swift`, `BackgroundRules.swift` | §3.2 pure functions, Python `int()`/`round()` semantics | `BackgroundGoldenTests` rules half green | T7 |
| T9 | AlarmScheduler | `AlarmScheduler.swift` | actor, reschedule at start, fire → injected callback, roll-forward, file via M1 store | scenario half for `alarm.*` and `reschedule` green; test uses a temp copy of `alarms.json`, never the real one | T8, M1 store |
| T10 | Loops on virtual clock | `BackgroundLife.swift`, `Announcer.swift` | §3.2 periods, §2.4 texts, §3.3 mode table | remaining scenarios green with a virtual `WallClock`; `activeLoops` per mode equals §3.3 | T8, T9 |
| T11 | KeepAwake + LockObserver | `KeepAwake.swift`, `LockObserver.swift` | §3.2; install once; mode switch releases the assertion | A6, A8; A7 by the user | T10 |
| T12 | Wire-up + RAM | `JarvisApp` entry (M4/M12 owners' files — touch only the start call) | start `BackgroundLife` in both modes; `reschedule` before mic init | A9; RSS numbers written to `PARITY.md` §RAM with date | T6, T11 |

## 7. RAM / permissions

- **Golden runs:** `fastpath` suite measured at 68 MB max RSS, 0.27 s wall (`/usr/bin/time -l`,
  prototype, 261-case run); `background` prototype similar (single import). Safe with ~1 GB free.
- **Swift typecheck** of the IOKit/DistributedNotificationCenter snippet: 369 MB peak for
  ~5 s — run `swift build`/`swift test` alone, never alongside Xcode or a second build.
- **Router:** pure value types, regexes compiled once (static lets); nothing resident beyond
  a few KB. **Background life:** ~10 suspended `Task`s; no model loaded until distill /
  consolidation fires (FoundationModels on demand, released after — M3's policy).
- **Chat-only mode** starts no audio objects, holds no power assertion (§3.3).
- **Permissions:** IOPM assertions need no entitlement. Distributed lock notifications need
  none. Calendar (meeting alerts) = EventKit full access (M6). Automation prompts for
  Music/Calendar/Notes/Reminders come from `automation_preflight` (M15 re-grant). The
  router itself needs nothing; actions inherit M5/M6 permissions.
- **Never during development:** start Python JARVIS or `launchctl`; run any corpus phrase
  through real helpers; post fake `com.apple.screenIs*` notifications; touch the real
  `alarms.json`/`proactive.json`/`personality.json` from tests (temp copies only — dev
  builds share real state via `com.jarvis.assistant`).

## 8. Risks and open questions

### 8.1 Deviations (default = Python parity; each needs explicit approval; fixture §4.2)

| id | phrase(s) | Python verdict (oracle) | proposed native verdict | recommendation |
|---|---|---|---|---|
| DEV-M7-01 | `start a timer for 5 minutes` | open.app, "I couldn't find an app called a timer for 5 minutes, sir.", no action | timer.set → `_set_timer(300)` | fix (launcher does not claim `start …` when the remainder matches the timer regex) |
| DEV-M7-02 | `start music`, `start the music` | open.app, "Opening Music, sir." + launch Music | media.play, "Playing, sir." + `_media("play")` (the set entries are dead code today) | fix |
| DEV-M7-03 | `run diagnostics please` | open.app, "I couldn't find an app called diagnostics please, sir." | defer (LLM calls run_diagnostics) | optional |
| DEV-M7-04 | `go to sleep` (typed chat has no `is_dismiss`) | open.app, "I couldn't find an app called sleep, sir." | M4 applies `is_dismiss` before the router (router unchanged) | fix in M4, not M7 |
| DEV-M7-05 | `notes`, `notebook` | note.make → `_make_note("s")` / `("book")` — creates a Notes note | defer | fix (require `\s` or `:` after bare `note`) |
| DEV-M7-06 | `that's right not wrong` | corr.teach → learns "wrong"→"right" | — | keep parity (teach grammar is intentional) |
| DEV-M7-07 | `see screen time` | screen.fuzzy → `_screen_help("see screen time")` | — | keep parity |
| DEV-M7-08 | `what's my airpods battery status` | battery → Mac battery | defer | optional |
| DEV-M7-09 | `what’s playing` (U+2019) | defer | router unchanged; M9 folds U+2019→`'` in STT output (SpeechTranscriber may emit curly quotes; Whisper did not — unverified) | fix in M9 |
| DEV-M7-10 | `open settings app` | open.app, "I couldn't find an app called settings app, sir." | — | keep parity |
| DEV-M14-01 | unlock greeting | observer installed twice (5431 + 5433) ⇒ likely two greetings (inferred, **not verified**) | install once, one greeting | fix |
| DEV-M14-02 | overlapping speech | `speak()` has no lock; background speech can overlap a reply | all speech through M8's serial queue | fix |
| DEV-M14-03 | two alarms at the same minute | `_alarm_timers` keyed by ISO ⇒ second overwrites the first handle; cancel misses one | key per entry (UUID) | fix |
| DEV-M14-04 | non-integer `JARVIS_LOW_BATTERY` / `JARVIS_MEETING_ALERTS` | `int()` at import raises ⇒ JARVIS fails to start | treat as 0 (off) + log | fix |
| DEV-M14-05 | `JARVIS_NO_HUD=1` | no lock observer ⇒ no unlock greeting | observer independent of HUD | decide (Q2) |

### 8.2 Risks

- **Side effects in the oracle.** `fast_path` acts inline (§2.2). The suite's safety rests
  on the recorder lists; the tripwires + A2 negative control are mandatory, not optional.
  If `jarvis.py` gains a helper, the AST call list changes — T1 must fail if any Name-call
  inside `fast_path` is neither a recorder, a kept-real function, nor a builtin.
- **Regex engine mismatch** (ICU vs Python `re`): `\w`, `\s`, `\b`, `$`-before-newline.
  Mitigated by NSRegularExpression + Unicode corpus cases; any new STT character classes
  (curly quotes, NBSP) must be added to the corpus.
- **App-index ordering.** Fuzzy `_resolve_open` returns the first dict-order hit; the M5
  native index must expose a deterministic order and document it; the golden pins only
  prove the algorithm, not the production order (production uses `mdfind` order in Python).
- **Fixture staleness:** fixtures carry the `jarvis.py` sha256; any Python edit ⇒
  regenerate and re-review diffs.
- **Ownership overlaps:** alarms (M6 vs M14 — `AlarmScheduler` is in M14 but M6's
  `set_alarm` needs it: build T9 before M6's alarm tool or move T9 into M6), background
  research (ROADMAP lists it under M6 and M14 — here M14 owns the loop, M6 `_web_search`),
  research snapshot scheduling (M1b may also plan a scheduler — one must own it),
  consolidation/distill bodies (M1) vs triggers (M14).
- **`ContinuousClock` vs Python `time.sleep`** across system sleep: not verified which
  Python behaviour macOS gives; keep-awake prevents idle sleep in voice mode, so impact is
  limited to lid-close.

### 8.3 Open questions

- **Q1** M0's `golden.py` suite-registration interface is not written yet (sibling plan
  was a skeleton on 2026-09-28). This plan assumes `golden.py <suite>` + modules in
  `tools/golden_suites/`; adapt to M0.
- **Q2** DEV-M14-05: greet on unlock when the HUD is disabled?
- **Q3** Typed chat input path: confirm "trim → pending-confirmation → is_dismiss → router",
  with **no** corrections and no wake-word extraction (Python applies corrections only to
  STT output). Also the chat-only distill trigger (idle 30 s or window close).
- **Q4** Chat-only delivery of briefing / battery / meeting alerts (chat message, spoken
  only if spoken replies are on) — no Python oracle; needs the user's call.
- **Q5** Assertion name `"JARVIS always-listening"` is new (caffeinate used its own); fine
  unless something greps for `caffeinate`.
