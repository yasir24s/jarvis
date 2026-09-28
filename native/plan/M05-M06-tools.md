# M5, M6 — System & files tools, apps & data tools

Oracle: `jarvis.py` @ `68cd112` (verify with `git -C ~/jarvis log -1 --format=%h`). Every line
number below was re-checked with `grep -n` against that commit. If `jarvis.py` has moved on,
re-run the line check in §5.0 before trusting any range.

## 1. Goal and scope (in / explicitly out)

**Goal.** Port all 46 macOS tools in `jarvis.py`'s `TOOLS` list (lines 168-460) into
`native/Sources/JarvisTools/`, so that for the same arguments and the same machine state the
native tool returns the same result string Python's `execute_tool()` (lines 4180-4255)
returns, and has the same effect. Every tool call goes through the M2 guard choke point.

**In scope.**
- M5 (system and files): `run_command`, `run_applescript`, `get_battery`, `get_time`,
  `get_cpu_usage`, `get_wifi_status`, `set_volume`, `set_brightness`, `run_diagnostics`,
  `notify`, `read_clipboard`, `take_screenshot`, `see_screen`, `type_text`, `find_apps`
  (plus the app index and app intelligence), `open_settings`, `system_control`,
  `search_files`, `find_files`, `read_file`, `delete_file`, `move_file`, `write_file`.
  That is 23 tools.
- M6 (apps and data): `music_now_playing`, `music_search`, `music_play`, `music_control`,
  `get_calendar`, `create_event`, `set_reminder`, `get_messages`, `send_message`,
  `send_email`, `find_contact`, `make_note`, `run_shortcut`, `list_shortcuts`,
  `get_weather`, `get_location`, `web_search` (with its KB cache calls), `get_news`,
  `summarize_page`, `find_song_by_lyrics`, `set_alarm`, `personality_note`,
  `personality_rewrite`. That is 23 tools.
- The `Tool` protocol, the tool registry, and schema parity: each tool's JSON schema must
  equal Python's `TOOLS` entry exactly (§3.2).
- Golden vectors for every deterministic helper these tools use (§4). Acceptance checks for
  every tool (§5).

**Out of scope. These are owned elsewhere; this plan only uses their interfaces.**
- `run_powershell` and every `IS_WIN` branch. Native is macOS-only.
- The guard logic itself: `_shell_risk`, `_gate`/`_consume_pending`, `_in_home`,
  `_is_system_path`, `_sensitive_path`, `_dangerous_applescript`, and the taint sets
  (M2). M5/M6 *call* the M2 API (§3.4) and must not re-implement it.
- The MCP tool server and Claude driver (M3). The native tools are plain async functions
  that M3 registers.
- KB storage `kb_lookup`/`kb_remember` (M1). `web_search` calls M1's KB API.
- Personality state file and prompt integration (M1). `personality_note`/`_rewrite` in
  M6 are thin wrappers over M1's `Personality` store.
- Alarm *firing* (the background alarm loop, the sound, the alarms.json schema) belongs to
  M1 state / the M4+ app loop. M6 owns only the `set_alarm` tool: parse, persist, reply.
  Timers (`set_timer`) are not in `TOOLS`. They are fast-path only (M7).
- Background research, proactive nudges, AudD music recognition from the mic
  (`identify_song`, which is not in `TOOLS`), and the local vision model (JARVIS_VISION_MODEL).
  The ROADMAP puts "AudD" and "background research" under M6. They are not tools, so this
  plan lists them in §8 as unplanned rather than scoping them in quietly.
- The `emotion_event("task_fail")` side effect of `execute_tool`'s exception handler
  (line 4253). The registry exposes an `onToolError` hook. M1/M3 wire it to emotions.

## 2. Python reference

Guard column. **Taint** is membership in Python's sets at lines 4841-4847:
`X` = in `EXECUTOR_TOOLS`, which blocks the tool after untrusted input in the same turn;
`U` = in `UNTRUSTED_TOOLS`, which taints the turn; `-` = in neither. **Tier** is the tool's
own risk gate: `block` means refused outright, `confirm` means it goes through
`_gate()` (1207-1210), which stashes the action and replies "…, sir — say 'confirm' to
proceed.", and `instant` means it runs immediately. Every tool is also wrapped by
`execute_tool`'s `except Exception as e: return f"Tool error: {e}"` (4252-4254).

Shared helpers the rows refer to:
`_run_applescript` 1394-1407 (`osascript -` fed UTF-8 on stdin, 30 s timeout, returns
`(stdout or stderr or b"Done.")` decoded with `errors="replace"`, then `.strip()[:1000]`) ·
`_applescript_errored` 2985-2991 · `_ensure_app_running` 2993-2997 (`launch` then sleep 2 s) ·
`_as_escape` 1253-1255 · `_exec_shell` 1257-1264 · `_http_json` 1359-1361
(UA `JARVIS/1.0 (personal assistant)`, 8 s) · `_open_url` 600-604 (`open URL`, Popen).

### 2a. M5 — system and files (23 tools)

| Tool | Python impl + jarvis.py lines | What it actually does (mechanism) | Guard (taint / tier) | Notes and quirks |
|---|---|---|---|---|
| `run_command` | `_run_command` 1266-1275 → `_shell_risk` 1185-1193, `_gate` 1207-1210, `_exec_shell` 1257-1264 | `subprocess.run(cmd, shell=True)` (`/bin/sh -c`), 30 s timeout. Returns `(stdout or stderr or "Done.").strip()[:1500]` | X / block, confirm or instant per `_shell_risk` | stderr is returned only when stdout is empty, and the exit code is ignored. On timeout it returns `"Command timed out."`. The block message differs when the command contains `\bsudo\b` (1270-1272). The confirm text is `f"That will run: {(command or '').strip()[:100]}"`. |
| `run_applescript` | `execute_tool` 4185-4190 → `_dangerous_applescript` 1242-1243 (`_AS_DENY` 1240) → `_run_applescript` 1394-1407 | `osascript -` with the script on stdin | X / block when `_AS_DENY` matches, else instant | Block reply: `"I won't run that script, sir — it could shell out or automate unsafely."` `_AS_DENY` is case-insensitive `do\s+shell\s+script\|administrator\s+privileges\|system\s+events`. |
| `get_battery` | `_get_system_info("battery")` 1277-1325 (branch 1281-1298) | `pmset -g batt`, regex `(\d+)%;?\s*(\w+)`, state map `charging/discharging/charged` → `charging/on battery/fully charged` (otherwise the raw word) | - / instant | With no battery or no match, `parts` is empty and the reply is `"No information."` (1325). On this Mac pmset prints `70%; discharging; …`, which becomes `"Battery at 70 percent, on battery."` |
| `get_time` | `_get_system_info("time")` 1279-1280 | `datetime.now().strftime("It is %I:%M %p on %A, %B %d.")` | - / instant | Zero-padded hour and day, e.g. `"It is 03:05 PM on Monday, September 08."`. C-locale names, because jarvis.py never calls `setlocale` (checked with grep). |
| `get_cpu_usage` | `_get_system_info("cpu")` 1312-1324 | `top -l 1 -n 0`, regex `CPU usage: ([\d.]+)%`, which takes the **user** percentage only | - / instant | Output: `"CPU user load 18.97 percent."`. The string is copied verbatim from top, which prints 2 decimals. top's single sample takes about 1 s. |
| `get_wifi_status` | `_get_system_info("wifi")` 1299-1310 | `networksetup -getairportnetwork en0`, stdout stripped and returned verbatim | - / instant | **Broken on this Mac.** It returns `"You are not associated with an AirPort network."` while en0 is up (`ipconfig getsummary en0` shows `LinkStatusActive : TRUE`, `SSID : <redacted>`). See §8 R3. |
| `set_volume` | `_set_volume` 1327-1341 | `osascript -e "set volume output volume N"`. N is `max(0,min(100,int(level)))` | - / instant | Python `int()` semantics: `int(55.9)=55`, `int("55")=55`, `int("55.5")` raises and gives `Tool error: invalid literal for int() with base 10: '55.5'`. The reply is always `f"Volume set to {level}."` (level after clamping) with no ", sir". |
| `set_brightness` | `_set_brightness` 3371-3388, `_brightness_cli` 3365-3369 | If `/opt/homebrew/bin/brightness` or `/usr/local/bin/brightness` exists, it runs `brightness N/100`. Otherwise System Events `key code 145` ×16 then `key code 144` ×`round(N/6.25)` | - / instant | Neither CLI exists on this Mac, so the key-code path is the live one. Replies: `f"Brightness set to {level} percent, sir."` (CLI) or `f"Brightness set to about {level} percent, sir."` (keys). If `"error"` appears in the output, it returns the Accessibility message. |
| `run_diagnostics` | `_system_report` 3299-3363 | Joins: `"Diagnostics complete."` + cpu (as above) + memory (`sysctl -n hw.memsize`, `vm_stat` free+inactive pages) + disk (`shutil.disk_usage(~)`) + battery + `ioreg -rn AppleSmartBattery` CycleCount + uptime (`sysctl -n kern.boottime`) + heaviest process (`ps -Aro %cpu,comm` row 1) + wifi | - / instant | Each part is wrapped in its own try, so a failing part is silently dropped. `vm_stat` "Pages free" **excludes speculative pages**. Formats: `{used:.1f} of {total:.0f} gigabytes`, `{free:.0f} gigabytes free of {total:.0f}`, `Uptime {d} day(s) {h} hour(s).` or `Uptime {h} hour(s).`, `{float(cpu):.0f} percent`. |
| `notify` | `_notify` 1343-1357 | `osascript -e 'display notification "{message}" with title "{title}"'` | - / instant | **No escaping**: a `"` in message or title breaks the script, but it still returns `"Notification shown."`. Title defaults to `"JARVIS"` (4226). |
| `read_clipboard` | `_get_clipboard` 643-649; `execute_tool` 4222 slices `[:3500]` | `pbpaste`, `text=True` (universal newlines, so CRLF/CR become LF), 5 s timeout | U / instant | Returns `""` on any failure. Only plain text: an image-only clipboard gives `""`. The slice counts code points. |
| `take_screenshot` | `_take_screenshot` 3425-3441 | `screencapture -x "~/Desktop/JARVIS Screenshot %Y-%m-%d at %H.%M.%S.png"` | - / instant | Success means the file exists afterwards. screencapture with one path captures the **main display only**, without the cursor. On failure it returns the Screen Recording hint. |
| `see_screen` | `_screen_text` 3907-3930 → `_ocr_image` 3875-3905; `execute_tool` 4221 | `screencapture -x -t png $TMPDIR/jarvis_screen.png`, then Vision `VNRecognizeTextRequest` (level 0 = accurate, language correction on), top-1 candidate per observation joined by `"\n"`, then the temp file is unlinked | U / instant | `[:3500] or "Screen not accessible."`. Any exception gives `""`, which becomes "Screen not accessible.". The VISION_MODEL path (`_screen_help`) is *not* this tool. |
| `type_text` | `_type_text` 3402-3423 | Text is `rstrip()`ed and split on `"\n"`. Each non-empty line becomes System Events `keystroke "<_as_escape(line)>"`, with `key code 36` between lines, run via `_run_applescript` | X / instant | If `"error"` (case-insensitive) or `"1719"` appears in the output, it returns the Accessibility message. Empty input gives `"Nothing to type, sir."`. Note that `_AS_DENY` does not apply, because the script is JARVIS's own. |
| `find_apps` | `_find_apps` 1971-1989 → `build_app_index` 1607-1645, `_enrich_app_index` 1691-1732, `_name_kinds` 1682-1689, `_kind_word` 1748-1750, `_app_kinds` 1752-1754, `_apps_of_kind` 1756-1759, `_default_browser_name` 1761-1771, `_NAME_KINDS` 1666-1680, `_CAT_KINDS` 1655-1664, `_KIND_SYNONYMS` 1734-1746, `_ALL_KINDS` 1818 | Index: `mdfind "kMDItemContentType == 'com.apple.application-bundle'"`, first `.app` path wins per lowercase name. Enrichment: plistlib reads each `Contents/Info.plist` for URL schemes, document types and `LSApplicationCategoryType`. Default browser: `NSWorkspace.URLForApplicationToOpenURL(https://example.com)` | - / instant | Kind query returns `"Installed {kind} apps: " + ", ".join(names[:12]) + "."`. The default browser gets `" — the default"`. Name query returns the first 10 index hits in mdfind order as `Name (kinds)`, where **kinds is a Python `set` joined, so its order is hash-random** (see §4 G6). `\b` is Python Unicode `re`. |
| `open_settings` | `_open_settings` 1875-1894, `_SETTINGS_PANES` 1825-1864, `_PRIVACY_ANCHORS` 1867-1873 | Normalises with `re.sub(r"^(the\|my)\s+\|\s+(settings?\|preferences?\|pane\|panel\|page)$", "", …)`. Privacy anchors are checked first, then an exact pane, then a **dict-order** fuzzy loop (`p in k or k in p`). Finally `Popen(["open", "x-apple.systempreferences:…"])` | - / instant | `"accessibility"` is in both tables and privacy wins. An unknown pane opens the root with `"I couldn't find a {pane} pane, sir, so I've opened System Settings."`, which uses the **raw** `pane`. |
| `system_control` | `_toggle_system` 1943-1969 → `_macos_tweak` 1915-1941, `_TWEAKS` 1898-1913; DND → `_run_shortcut` 3498-3514 | wifi: `networksetup -listallhardwareports` (regex `Wi-Fi\n.*?Device:\s*(\w+)`, default en0), then `-setairportpower IF on/off`. bluetooth: `blueutil -p 1/0` if it is on PATH (it is **not installed** here). DND: runs the Shortcut `"toggle do not disturb"`. dark mode: System Events `appearance preferences`. Other tweaks: `defaults write DOM KEY -bool V` then `killall RESTART` | - / instant | `bool(args.get("enable", True))`. `"light mode"` inverts `on`. `_TWEAKS` fuzzy matching is dict-order. The reply uses `key.capitalize()` (Python lowercases the rest). wifi/bt replies do not depend on success. |
| `search_files` | `_search_files` 2623-2649 → `_spotlight(query)` 2671-2709 | `mdfind "(kMDItemDisplayName == '*Q*'cd \|\| kMDItemTextContent == '*Q*'cd)"`, 15 s timeout | - / instant | Identical to `find_files` with no kind and `recent=False`. |
| `find_files` | `_spotlight` 2671-2709, `_KIND_MDFIND` 2654-2669 | Same query, plus `&& <kind clause>`, plus `recent` (`-onlyin ~`, `kMDItemFSContentChangeDate >= $time.this_week`, a junk filter, sorted newest-first by mtime). Limit 12 | - / instant | Escaping: `\` → `\\` and `'` → `\'`. An unknown kind is silently ignored. With an empty query and no clauses the expression is `"*"`. Reply: `"Found {n}: a, b, … , and {n-6} more.\n" + paths`. Result order is mdfind's. |
| `read_file` | `_read_file` 2810-2820 | `open(expanduser(path.strip()), "r", errors="ignore").read(4000)` | U / instant | Reads **4000 code points** after universal-newline translation. It **keeps a UTF-8 BOM** as U+FEFF. Empty file gives `"(file is empty)"`. Errors give `f"Could not read {path}: {e}"` with the Python `[Errno N] strerror: 'path'` text. **No `_sensitive_path` check.** `_sensitive_path` (1245-1251) is dead code in Python (see §8 R1). |
| `delete_file` | `_delete_file` 2747-2765, `_to_trash` 2741-2743 | In home and not `permanent`: Finder AppleScript `delete (POSIX file "…")`, which moves it to the Trash. Otherwise it gates `shutil.rmtree`/`os.remove` | taint - (PARITY.md says X, see §8 R2) / block for system paths, confirm when permanent or outside home, instant for trash-in-home | `_is_system_path` (1236-1238) uses `os.path.abspath` with **no symlink resolution**: `/tmp/x` is not a system path but `/private/tmp/x` is, and `~` itself is. `_to_trash` reports failure if the output contains `"error"`, which includes a file *named* error. `permanent` is `bool(args.get("permanent"))`. |
| `move_file` | `_move_file` 2767-2785 | `shutil.move(s, d)` | taint - (PARITY says X) / block for system src or dst, confirm on clobber or outside home, else instant | `clobber = os.path.exists(d)`, which is **true for an existing directory** even though shutil moves *into* it. `basename` is taken from the expanded but **not abspath'd** string, so a trailing `/` gives `""`. |
| `write_file` | `_write_file` 2787-2808, `_written_this_session` 2745 | `os.makedirs(dirname, exist_ok=True)` then `open(a,"w").write(content)` (UTF-8, no newline translation on macOS) | taint - (PARITY says X) / block for system paths, confirm when overwriting outside home unless written earlier this session, else instant | `_written_this_session` lives in memory per process. An empty path gives `"Which file, sir?"`. |

### 2b. M6 — apps and data (23 tools)

| Tool | Python impl + jarvis.py lines | What it actually does (mechanism) | Guard (taint / tier) | Notes and quirks |
|---|---|---|---|---|
| `music_now_playing` | `_now_playing` 1466-1490 | AppleScript: `if application "Music" is running … if player state is playing then return name & " \| " & artist & " \| " & album`, else `"nothing"` | - / instant | Music only. Spotify was dropped deliberately (the comment at 1470-1472 explains the compile failure). `"nothing"`, empty output or an error gives `"Nothing is playing, sir."`. Output: `Now playing N[ by A][, from B], sir.` |
| `music_search` | `_music_search` 1492-1534 | AppleScript `every track whose <cond>` (with `launch`), first 8 as `name \| artist \| album` lines. On error: `_ensure_app_running("Music")`, then a retry without `launch` | - / instant | `by` maps `artist/album/song/track/title` → field. Anything else searches name, artist *or* album. The reply says `(first 8)` only when the count is exactly 8. `_as_escape` is applied to the query. |
| `music_play` | `_play_query` 1564-1601; `execute_tool` 4199-4206 runs the returned action | (1) Music library: `name contains S and artist contains A` when the query matches `^(.*\S)\s+by\s+(\S.*)$`, else name-or-artist contains Q, then `play (item 1 of theTracks)`. (2) If online: GET `youtube.com/results?search_query=` (UA `Mozilla/5.0`), first `"videoId":"([\w-]{11})"`, then `open https://www.youtube.com/watch?v=ID`. (3) Otherwise `open https://music.apple.com/us/search?term=Q` | - / instant | Returns `(announcement, action)`. `execute_tool` runs `action()` **before** returning the announcement. `urllib.parse.quote(q)` uses safe=`/`. |
| `music_control` | `_music_control` 1536-1562 → `_media` 1424-1447 | `_media` AppleScript: `if application "Spotify" is running then tell Spotify to CMD else tell Music (launch if needed) CMD`. Volume: `tell application "Music" to set sound volume to N` | - / instant | Aliases at 1540-1544. An unknown action with no volume gives ``f"I don't know the music action {action!r}, sir."``, which uses **Python `repr`** quoting. A bad volume gives `"What volume should I set, sir?"`. With no action and no volume the reply is `"Nothing to do, sir."`. `_media` references Spotify's terminology (see §8 R9). |
| `web_search` | `_web_search` 1363-1392 → `is_online` 521-528, `kb_lookup` 2016-2029, `kb_remember` 2003-2013 | Offline: KB lookup. Online: DuckDuckGo IA JSON (`AbstractText`, then `Answer`, then the first `RelatedTopics[].Text`). Then Wikipedia opensearch followed by the REST summary `extract`. Every hit is `kb_remember`ed (writes `knowledge.json`) and returned `[:800]` | U / instant | `is_online` = TCP connect to 1.1.1.1:53, then 8.8.8.8:53, with a 1.2 s timeout each. `str(data["Answer"])` can be a non-string. The final fallback is the KB, then `"I found nothing definitive, sir."`. |
| `get_weather` | `_weather` 2824-2841 | GET `https://wttr.in/<quote(loc)>?format=j1`, UA `curl/8`. Fields: `current_condition[0].weatherDesc[0].value.lower()`, `temp_C`, `FeelsLikeC`, `nearest_area[0].areaName[0].value` | - / instant | `f"It's {desc} and {temp} degrees{where}, feeling like {feels}, sir."` (`where = f" in {city}"` if city). Any exception gives `"I couldn't reach the weather service, sir."`. Offline has its own message. |
| `get_location` | `_location` 2843-2854 | GET `https://ipwho.is/` via `_http_json`. Joins non-empty `city, region, country` | - / instant | IP geolocation, **not** CoreLocation. `success` false or an exception gives `"I couldn't determine your location, sir."`. |
| `set_reminder` | `_create_reminder` 2941-2962 → `_parse_when` 2900-2939 | AppleScript `tell application "Reminders" to make new reminder with properties {name:"…", remind me date:((current date) + OFFSET)}`. With no parsable time, no date is set | - / instant | It parses `when_text or text`, so a time inside the reminder text counts. OFFSET is `int((dt - datetime.now()).total_seconds())` using a **second** `now()`, so live Python sets reminders about 1 s early. Reply: `Reminder set for {%I:%M %p lstrip 0}, sir.`, or `Reminder added, sir.`. |
| `get_messages` | `_recent_messages` 2964-2983 | sqlite3 `file:~/Library/Messages/chat.db?mode=ro`: `SELECT h.id, m.text FROM message m LEFT JOIN handle h … WHERE m.is_from_me=0 AND m.text IS NOT NULL AND length(m.text)>0 ORDER BY m.date DESC LIMIT 5` | U / instant | Needs **Full Disk Access**. Any exception gives the FDA message. Rows with only `attributedBody` (text NULL) are skipped, which is most modern messages. Joined as `From H: T ... From H: T`. |
| `get_calendar` | `_calendar_today` 3087-3122 → `_ek_authorized` 3013-3038, `_ek_events` 3040-3062 | EventKit (PyObjC): events from local midnight to +1 day, all calendars, sorted by start. Timed events print as `%I:%M %p` with the leading 0 stripped. All-day events print `, all day`. Fallback when EventKit is unavailable or denied: Calendar AppleScript, with a cold-start retry | - / instant | `requestFullAccessToEventsWithCompletionHandler_` with a 12 s wait. The window includes events that *overlap* today. The fallback prints `summary at time string. `. |
| `create_event` | `_create_event` 3246-3277 → `_ek_create` 3064-3085 | `_parse_when(when)`. `dur = max(5, int(duration_minutes))*60`, or 3600 if `int()` fails. EventKit `defaultCalendarForNewEvents`, `EKSpanThisEvent`. AppleScript fallback uses `first calendar whose writable is true` with a `(current date)+offset` start | - / instant | Reply date format: `dt.strftime('%A at %I:%M %p').replace(' 0', ' ')`. An unparsable `when` gives `"When should I schedule that for, sir?"`. `duration_minutes` defaults to 60 (4234-4236). |
| `send_message` | `_send_message` 3201-3224 → `_contact_handle` 3142-3171 | Resolves the recipient first: an `@` passes through; a phone regex `[+\d][\d\s().-]{6,}` (fullmatch) is stripped of `[\s().-]`; otherwise Contacts AppleScript with exact, then begins-with, then contains, preferring phones. Then Messages AppleScript `send "…" to participant "…" of (1st account whose service type = iMessage)`, falling back to the legacy `buddy` form | X / instant | No confirmation gate: the taint guard and the schema's "ONLY use when…" are the only protection. The reply echoes the **raw** `recipient`. Failure is detected by `"error"` in the output. |
| `send_email` | `_send_email` 3226-3244 → `_contact_handle(prefer="email")` | Mail AppleScript: `make new outgoing message {subject, content, visible:false}`, add a to-recipient, `send m` | X / instant | `"@" not in addr` gives `"I couldn't find an email address for {to}, sir."`. |
| `find_contact` | `_find_contact` 3173-3199 | Contacts AppleScript (exact, then begins-with, then contains). Returns `name, phone V…, email V…` for `item 1` | - / instant | AppleScript string comparison **ignores case** by default. Launches Contacts.app. `""`, `"Done."` or `AppleScript error…` gives the not-found message. |
| `make_note` | `_make_note` 3969-3983 | Notes AppleScript `make new note with properties {body:"…"}` | - / instant | Text is stripped. An empty note gives `"What should the note say, sir?"`. `"error"` in the output gives the failure message. |
| `run_shortcut` | `_run_shortcut` 3498-3514 → `_match_shortcut` 3476-3496, `_shortcuts_all` 3466-3474 | `shortcuts list` (10 s), then match: exact (case-insensitive), then substring (`min(subs, key=len)`, first shortest), then token Jaccard ≥ 0.5 (strictly greater, so first best wins). Then `shortcuts run NAME` (60 s) | X / instant | rc 0 gives `"Done, sir."`. A timeout gives `"…is taking a while…"`. `system_control` DND calls this too, bypassing the taint check because the call is internal (§8 R10). |
| `list_shortcuts` | `_list_shortcuts` 3516-3522 | `shortcuts list` | - / instant | First 15, then `, and N more`. |
| `get_news` | `_get_news` 3281-3297, `NEWS_FEED` 3279 | GET `JARVIS_NEWS_FEED` (default `https://feeds.bbci.co.uk/news/rss.xml`, UA `JARVIS/1.0`, 8 s), decoded as UTF-8 with replacement. Titles come from ``re.findall(r"<item>\s*<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>", xml, re.DOTALL)``, then `html.unescape(t.strip())`, keeping the first 4 | U / instant | `"Top headlines. " + " ... ".join(titles) + "."`. Offline, no titles, and exceptions each have their own message. `n=4` from the tool. `_briefing` uses 3, but that is not a tool. |
| `summarize_page` | `_summarize_page` 3571-3591 → `_active_tab_url` 3545-3561, `_front_app` 3526-3534, `_fetch_page_text` 3563-3569, `_ask_model` 3932-3940 | Front tab URL via Safari or Chrome AppleScript (Chrome first if frontmost, only if running). Fetch (UA `Mozilla/5.0 (JARVIS)`, 400 000 bytes max, 10 s), strip `script/style/nav/header/footer/aside`, strip tags, `html.unescape`, collapse `\s+`, `[:6000]`. Then **Ollama** `_ask_model` (`JARVIS_MODEL`, default `qwen2.5:3b`) | U / instant | The model's output is non-deterministic. If the model is empty the reply is `"I read the page, sir, but couldn't distil it."`. Native has no Ollama (see §8 R4). |
| `find_song_by_lyrics` | `_find_song_by_lyrics` 4162-4178 → `_ask_model` | Prompt to **Ollama** for "Title by Artist" or `unknown`. Post-processing: first line, strip quotes and whitespace, `[:120]` | - / instant | The snippet is `.strip(" ,:'\".")`. `unknown`, `i don't know` or `i do not know` give `"I couldn't place that song, sir."`. |
| `set_alarm` | `set_alarm` 4044-4067 → `_parse_when`, `_alarms_load` 3989-3992, `_alarms_save` 3994-3997, `_schedule_alarm` 4035-4042 | Detects a repeat (`weekdays`/`daily` regexes), strips it, prefixes `"at "` unless `\b(at\|in\|tomorrow)\b` is present, then `_parse_when`. Appends `{"time": iso, "label": L[, "repeat": R]}` to `~/jarvis/alarms.json` (`ALARMS_FILE` 3987) and schedules a `threading.Timer` | - / instant | **"p.m." is not recognised** (`(am\|pm)?`), so `"at 7 p.m."` gives 07:00. The file is written with `json.dump` defaults (`", "`/`": "`, ASCII-escaped) and is not atomic. `isoformat()` omits microseconds only when they are 0. |
| `personality_note` | `personality_note_tool` 2208-2213 → `personality_learn` 2184-2201 (M1) | Fewer than 8 stripped characters gives `"Note too short to keep."`. Otherwise M1 learn, which dedups and evicts toggles, keeps the last 14, stores `note[:200]`, and writes the personality file | X / instant | The reply is fixed: `"Noted, and remembered — my personality file is updated."`. |
| `personality_rewrite` | `personality_rewrite_tool` 2215-2227 | Lines are `l.strip().lstrip("-• ").rstrip(".") + "."` over non-blank `splitlines()`. The line count must be 3-12 or it gives `"Rewrite rejected — give me 3 to 12 trait lines, one per line."`. Then `p["core"] = [l[:300] …]` and the file is saved | X / instant | Learned notes survive. Taken under M1's `_personality_lock`. |

Not in `TOOLS` but dispatched: `get_system_info` (4191) is unreachable, because
`_claude_allowed` (4926) and the Ollama tool list are both built from `TOOLS`. Do not port it.

## 3. Swift design

### 3.1 Targets and layout
`Package.swift` says that every target except JarvisApp stays free of AppKit. The tools need
AppKit (`NSWorkspace`, `NSPasteboard`), so the work splits in two:
- **`JarvisToolsCore`** (Foundation only, headless, where all golden tests run). It holds everything pure.
- **`JarvisTools`** (depends on JarvisToolsCore, JarvisCore; links AppKit, EventKit, Contacts, Vision,
  ScreenCaptureKit, CoreWLAN, IOKit, CoreAudio, UserNotifications, sqlite3). This is the second AppKit target (§8 R8).

```
Sources/JarvisToolsCore/
  Py/        PyStr.swift (isspace set, strip/lstrip/rstrip(chars), split(), splitlines, lower, capitalize, repr)
             PyInt.swift (int() coercion + exact error text)  PyTruthy.swift (bool(x))
             PyPath.swift (expanduser, abspath/normpath w/o symlink resolution, basename, dirname)
             PyURL.swift (quote safe="/", urlencode=quote_plus)  PyTime.swift (C-locale strftime subset
             %Y %m %d %H %I %M %S %p %A %B, isoformat)  PyHTML.swift (html.unescape) + Generated/HTML5Entities.swift
             PyRegex.swift (NSRegularExpression factory; rewrites `\s`→Python isspace class, `\w`/`\b` notes)
             PyErrors.swift (OSError "[Errno N] strerror: 'path'")
  Parse/     ParseWhen.swift  SettingsMap.swift  TweakMap.swift  AppKinds.swift  SpotlightQuery.swift
             ShortcutMatch.swift  ContactHandle.swift  PageText.swift  NewsParse.swift  WeatherParse.swift
             SearchParse.swift (DDG/Wiki pick)  MusicParse.swift  Replies.swift  PersonalityLines.swift
             AlarmEntry.swift  Diagnostics.swift (formatters, vm_stat/pmset parsers for tests)
  Generated/ ToolSchemas.swift  (from tools/gen_tool_schemas.py — never hand-edited)
Sources/JarvisTools/
  Registry.swift (ToolRegistry, ToolContext, dispatch = execute_tool)   Tool.swift
  Run/       ShellRunner.swift  AppleScriptRunner.swift  Net.swift (URLSession + isOnline)
  System/    Battery Time CPU WiFi Volume Brightness Diagnostics Notify Clipboard .swift
  Screen/    ScreenCapture.swift (SCK) OCR.swift (Vision) Screenshot.swift SeeScreen.swift TypeText.swift
  Apps/      AppIndex.swift (actor) FindApps.swift OpenSettings.swift SystemControl.swift
  Files/     Spotlight.swift ReadFile.swift DeleteFile.swift MoveFile.swift (PyShutil.move) WriteFile.swift
  Media/     Music.swift (4 tools) Lyrics.swift
  Data/      Calendar.swift (EventKit + AS fallback) Reminders.swift Messages.swift (sqlite3) Contacts.swift
             Notes.swift Shortcuts.swift Alarm.swift Personality.swift
  Web/       WebSearch.swift Weather.swift Location.swift News.swift SummarizePage.swift
tools/gen_tool_schemas.py  tools/gen_html5_entities.py
```

### 3.2 Tool protocol and schemas (byte-identical)
```swift
public protocol JarvisTool: Sendable {
    static var name: String { get }                       // == TOOLS[i]["function"]["name"]
    func run(_ args: ToolArgs, _ ctx: ToolContext) async throws -> String
}
public struct ToolSchema: Sendable { let name: String; let description: String
    let parametersJSON: String  /* json.dumps(fn["parameters"], ensure_ascii=False) — Python key order */ }
```
- `tools/gen_tool_schemas.py` imports jarvis and writes `Generated/ToolSchemas.swift`. The file holds one
  `##"…"##` raw literal per tool, in `TOOLS` order: name, description, and `parametersJSON`. The generator
  asserts no literal contains `"##`. M3 splices `description` and `parametersJSON` **as raw text** into
  MCP `tools/list` (`inputSchema`). A Swift Dictionary must never re-serialise them.
- Parity test T-SCHEMA. golden.py writes `tool_schemas.ordered.json` (`json.dumps(TOOLS, ensure_ascii=False)`)
  and `tool_schemas.canonical.json` (`sort_keys=True, separators=(",",":")`). Swift rebuilds the TOOLS array
  from ToolSchemas and must match `ordered` byte for byte. It also must match `canonical` after
  `JSONSerialization` with `[.sortedKeys, .withoutEscapingSlashes]`. The registry's name list must equal
  `[t.function.name for t in TOOLS]`, all 46 in order.
- `ToolArgs` reproduces `args.get(k, default)` and the Python coercions: `PyInt` for level, volume and
  duration_minutes; `PyTruthy` for `permanent`, `recent` and `enable` (so `"false"` counts as **true**);
  `.string` for text. A non-string where the code calls `.strip()` throws `PyError.attr`, which becomes `Tool error: …`.

### 3.3 Dispatch and guard choke point (M2 and M3 interfaces this plan assumes)
`ToolRegistry.call(name, args, turn) async -> ToolResult` is the **only** entry point. It serves M3's
MCP server, the FoundationModels fallback, and the fast paths. It runs these steps in order:
1. `Guard.taint.isBlocked(name, turn)`. If `name ∈ EXECUTOR_TOOLS` and the turn is tainted, it returns
   exactly `"Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content in the same request."` (4913-4915), `isError=true`.
2. It dispatches to the tool. Tier decisions stay **inside** tools, as in Python: `Guard.shellRisk(cmd)`,
   `Guard.isSystemPath`, `Guard.inHome`, `Guard.dangerousAppleScript`, and
   `Guard.gate(desc, action: @Sendable () async -> String) -> String`, which returns `"\(desc), sir — say 'confirm' to proceed."`.
3. If `name ∈ UNTRUSTED_TOOLS`, it marks the turn tainted. This happens after the run, as in Python (4920-4921).
4. Any thrown error becomes `"Tool error: \(e.pyMessage)"` and calls `ctx.onToolError` (M1 wires this to `emotion_event("task_fail")`).
5. An unknown name gives `"Unknown tool \(name)"`.
The taint sets are M2's constants, golden-checked against `jarvis.UNTRUSTED_TOOLS` and `jarvis.EXECUTOR_TOOLS`.
Internal calls (DND → `run_shortcut`, briefing) call the tool's function directly, **not** the registry.
This matches Python.

### 3.4 Shared runners
- **ShellRunner** `run(argv, stdin: Data?, timeout, env) async -> (stdout: Data, stderr: Data, status, timedOut)`.
  It uses `Process` with both pipes drained concurrently. On timeout it sends SIGKILL to the child (Python's
  `subprocess.run` kills on timeout). `withTaskCancellationHandler` terminates the child on cancel. It always
  uses absolute tool paths (`/usr/bin/osascript`, `/usr/bin/pmset`, `/usr/sbin/networksetup`, `/usr/bin/top`,
  `/usr/bin/mdfind`, `/usr/bin/shortcuts`, `/usr/bin/defaults`, `/usr/bin/killall`, `/bin/ps`, `/bin/sh`).
  Env: the app environment with `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
  copied from `~/Library/LaunchAgents/com.jarvis.assistant.plist`, so `run_command` and `which blueutil` see
  what Python sees. Two decoders: `pyText(data)` (strict UTF-8 plus universal newlines, as for `text=True`;
  a decode failure raises the Python `UnicodeDecodeError` text) and `pyReplace(data)` (U+FFFD for maximal
  subparts, with no newline translation, as `_run_applescript` does).
- **AppleScriptRunner** `run(script) async -> String` is `/usr/bin/osascript -` with the script on stdin
  and a 30 s timeout, returning `pyReplace(stdout or stderr or "Done.").pyStrip()[:1000]`. It uses osascript,
  not `NSAppleScript`, for three reasons: (a) Python parses osascript's text coercion of results and its
  stderr `execution error … (-600)` format, while NSAppleScript returns descriptors or error dicts;
  (b) NSAppleScript cannot be cancelled or timed out and wants the main thread; (c) TCC attributes the
  child to the responsible process, JARVIS.app, so Automation prompts name JARVIS. `ASFragments.swift`
  copies every fixed script from Python verbatim, and golden G10 checks them.
- **Net**: `isOnline()` is a TCP connect to 1.1.1.1:53 and then 8.8.8.8:53, each with a 1.2 s timeout
  (`NWConnection`). `get(url, ua, timeout)` treats non-2xx as an error, because urllib raises
  `HTTPError` and URLSession does not. It caps the body at N bytes (400 000 for pages).
- **AppIndex** (actor): `mdfind "kMDItemContentType == 'com.apple.application-bundle'"`. The first path per
  lowercase name wins, and mdfind order is preserved (`OrderedDictionary` built by hand, no package). It is
  enriched in a background Task via `PropertyListSerialization` of `Contents/Info.plist`. Until enrichment
  finishes, the `_name_kinds` fallback is used, as in Python. It is built when the registry initialises.

### 3.5 Per-tool native mechanism (the decision and why)
| Tool(s) | Native mechanism | Why not the Python mechanism / why keep it |
|---|---|---|
| run_command | `/bin/sh -c` via ShellRunner, 30 s, `[:1500]` | The shell is the point. Same tiers via M2 |
| run_applescript, music×4 scripts, make_note, send_message, send_email, dark mode, AS fallbacks for calendar/reminders, `_active_tab_url` | AppleScriptRunner (osascript) | No public API for Music, Notes, Messages, Mail or Safari/Chrome tab URLs. Scripts copied byte for byte |
| get_battery | IOKit `IOPSCopyPowerSourcesInfo`/`IOPSCopyPowerSourcesList`/`IOPSGetPowerSourceDescription`: `kIOPSCurrentCapacityKey`, `kIOPSIsChargingKey`, `kIOPSIsChargedKey`, `kIOPSIsFinishingChargeKey`, `kIOPSPowerSourceStateKey` | Structured data, no process. Map to pmset's word so the Python map applies: charged→`fully charged`, charging→`charging`, battery→`on battery`, AC not charging→raw `AC` (pmset `AC attached` → regex `\w+` = `AC`), finishing→`finishing`. Parity is proven live against pmset (A-SYS-1) |
| get_time | `PyTime.strftime("It is %I:%M %p on %A, %B %d.")` with fixed C-locale tables | Deterministic. `DateFormatter` locale drift is avoided |
| get_cpu_usage | `host_statistics(HOST_CPU_LOAD_INFO)` sampled twice 1.0 s apart, user share `%.2f` | No `top`. Same about 1 s latency. Falls back to top if the host call fails. Values are live, so parity is format plus a tolerance band (A-SYS-3) |
| get_wifi_status | CoreWLAN `CWWiFiClient.shared().interface()?.ssid()` (needs Location auth), reply in networksetup format `Current Wi-Fi Network: X` / `You are not associated with an AirPort network.` | The Python oracle is broken on macOS 27 (§8 R3) |
| set_volume | CoreAudio `AudioObjectSetPropertyData`, `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` on `kAudioHardwarePropertyDefaultOutputDevice`, scalar N/100 | No osascript spawn. The reply is identical and independent of success, as in Python |
| set_brightness | If a brightness CLI exists at Python's paths, use it. Otherwise `CGEventCreateKeyboardEvent` key 145 ×16 then 144 ×`pyRound(N/6.25)` (banker's), posted after a `CGPreflightPostEventAccess` check | Drops the Automation(System Events) prompt. The permission failure maps to Python's message. Whether keys 144/145 move brightness on this Mac is **not verified** (manual M-5) |
| run_diagnostics | `sysctlbyname("hw.memsize")`; `host_statistics64(HOST_VM_INFO64)` with free = `free_count - speculative_count + inactive_count` (vm_stat's "Pages free" excludes speculative); `vm_kernel_page_size`; `statvfs(home)` (free = `f_bavail*f_frsize`, total = `f_blocks*f_frsize`, as `shutil.disk_usage`); IOKit `IOServiceGetMatchingService(IOServiceMatching("AppleSmartBattery"))` + `IORegistryEntryCreateCFProperty("CycleCount")`; `sysctl kern.boottime`; heaviest process **keeps `/bin/ps -Aro %cpu,comm`** (the kernel's decayed %cpu is not exposed by libproc); wifi as above | Five process spawns become one |
| notify | `UNUserNotificationCenter` (the banner is attributed to JARVIS). If not authorised, fall back to osascript `display notification` with `_as_escape` applied | Python breaks silently on `"`. Reply always `"Notification shown."` (§8 R11) |
| read_clipboard | `NSPasteboard.general.string(forType: .string)` on MainActor, then universal-newline translation, then `[:3500]` code points | No process. An RTF-only clipboard gives `""` natively, where pbpaste returns RTF source (§8 R12) |
| take_screenshot, see_screen | ScreenCaptureKit `SCShareableContent` → display == `CGMainDisplayID()` → `SCContentFilter(display:excludingWindows:[])`, `SCStreamConfiguration` sized from `CGDisplayCopyDisplayMode`/`CGDisplayModeGetPixelWidth`/`Height`, `showsCursor=false` → `SCScreenshotManager.captureImage`. Screenshot is written as PNG via `CGImageDestinationCreateWithURL`/`Finalize` to `~/Desktop/JARVIS Screenshot <%Y-%m-%d at %H.%M.%S>.png`. see_screen passes the CGImage straight to Vision `VNImageRequestHandler(cgImage:)` + `VNRecognizeTextRequest` (`.accurate`, `usesLanguageCorrection=true`), top-1 candidate per observation, joined with `"\n"` | In-process with typed errors, and see_screen **writes no screen PNG to $TMPDIR** (a privacy gain). Same TCC (Screen Recording). `CGPreflightScreenCaptureAccess` failure gives Python's failure strings |
| type_text | CGEvent: per line `CGEventKeyboardSetUnicodeString` in chunks of ≤20 UTF-16 units that never split a surrogate pair, key 36 down/up between lines | No System Events automation. Types non-ASCII correctly. No Accessibility gives Python's message. **Manual only** |
| find_apps | AppIndex + `NSWorkspace.shared.urlForApplication(toOpen:)` for `https://example.com` | Same data sources as Python |
| open_settings | Pure `SettingsMap.resolve(pane) -> (url, reply)`, then `NSWorkspace.shared.open(url)` | No `open` process |
| system_control | wifi: **keep** `networksetup -listallhardwareports` / `-setairportpower` (known to work unprivileged; `CWInterface.setPower` is not verified). bt: `blueutil` looked up on the launch PATH (not installed here; no public BT power API). DND: internal `run_shortcut("toggle do not disturb")`. dark mode: System Events AS (no public system-appearance setter). tweaks: **keep** `/usr/bin/defaults write` + `/usr/bin/killall` | Exact parity of the `-bool` writes. CFPreferences would give no real gain |
| search_files, find_files | **Keep `/usr/bin/mdfind`** with the Python query string, 15 s. `recent` adds `-onlyin ~`, the junk filter, and a **stable** sort by `stat` mtime, newest first (ties keep mdfind order, as Python's `sort(reverse=True)` does) | Result order is part of the reply ("Found 12: a, b…"). `MDQueryCreate` would reorder, and NSMetadataQuery needs a run loop |
| read_file | POSIX `open`/`fstat` (a directory gives EISDIR at open time, like Python) → stream-decode UTF-8 **dropping** invalid bytes (a custom decoder, because Swift's decoders substitute U+FFFD) → universal newlines across chunk boundaries → stop at 4000 code points | Python text-mode semantics |
| delete_file | Trash: `FileManager.trashItem(at:resultingItemURL:)`. Hard delete: `removeItem`, but a symlink to a directory raises Python's rmtree error text | No Automation(Finder). This also fixes the `"error"`-in-filename false failure (§8 R13) |
| move_file | `PyShutil.move`: dst is a dir → `dst/basename(src)`, then "Destination path … already exists"; `rename(2)` (overwrites files like os.rename); on EXDEV → copy (dirs: `copyItem`) + remove | Python semantics. `FileManager.moveItem` refuses to overwrite |
| write_file | `mkdir -p` (mode 0777&~umask), then POSIX `open(O_WRONLY\|O_CREAT\|O_TRUNC, 0666)` + write UTF-8 | Truncating in place, as Python does, keeps the inode and permissions. `Data.write(.atomic)` would not |
| get_calendar, create_event | EventKit (`EKEventStore`, one per process, in an actor): `requestFullAccessToEvents` (12 s), `predicateForEvents(withStart:end:calendars:nil)`, stable sort by start; `EKEvent`, `defaultCalendarForNewEvents`, `save(_:span:.thisEvent)`. AS fallback kept verbatim | Python already uses EventKit via PyObjC |
| set_reminder | EventKit: `requestFullAccessToReminders`, `EKReminder`, `defaultCalendarForNewReminders`, `dueDateComponents` + `EKAlarm(absoluteDate:)`. AS fallback verbatim if not authorised | Does not launch Reminders.app, needs no Automation, and uses an exact date instead of a `(current date)+offset` that runs 1 s early (§8 R14) |
| get_messages | SQLite3 C API `sqlite3_open_v2("file:…chat.db?mode=ro", SQLITE_OPEN_READONLY\|SQLITE_OPEN_URI)`, identical SQL | Native, same semantics. Needs FDA |
| find_contact, `_contact_handle` | Contacts `CNContactStore.enumerateContacts(with: CNContactFetchRequest)` with keys `CNContactFormatter.descriptorForRequiredKeys(for:.fullName)`, `CNContactPhoneNumbersKey`, `CNContactEmailAddressesKey`. Name = `CNContactFormatter.string(from:style:.fullName)`. Match exact, then prefix, then contains, **case-insensitive, diacritic-sensitive** (AppleScript defaults), first in enumeration order | Does not launch Contacts.app (about 100 MB with about 1 GB free) and needs no Automation. Parity is proven over the real address book (A-DATA-3). **If the order diverges, fall back to the AS script** |
| run_shortcut, list_shortcuts | `/usr/bin/shortcuts list` / `run` (10 s / 60 s) | No public API lists or runs user shortcuts |
| web_search, get_weather, get_location, get_news, music_play (YouTube) | URLSession through Net with the exact UA strings, `PyURL.urlencode`/`quote` | Standard |
| summarize_page, find_song_by_lyrics | `ctx.localModel.complete(prompt) async -> String` (M3 supplies it, default FoundationModels `LanguageModelSession`). The prompt strings are verbatim from Python | Native has no Ollama (§8 R4) |
| set_alarm | `AlarmEntry.build(when,label,now)` (pure) → `ctx.alarms.append(entry)` (M1 store; writes `alarms.json` exactly like `json.dump`) → `ctx.alarmScheduler.schedule` (app loop) | The M1 store is an actor, which fixes Python's read-modify-write race |
| personality_note/rewrite | `PersonalityLines` (pure) → M1 `Personality.learn(note)` / `.setCore(lines)` | M1 owns the file |

### 3.6 Async and timeout model
- Tools are `Sendable` structs. Shared state (AppIndex, `writtenThisSession`, EKEventStore, CNContactStore)
  lives in actors. Blocking work (Vision `perform`, sqlite, EventKit fetch, `Process.waitUntilExit`) runs
  on a detached task off MainActor. Only NSPasteboard and UN authorisation touch MainActor.
- Timeouts per call are Python's: shell 30 s, AppleScript 30 s, mdfind 15 s, `shortcuts run` 60 s, HTTP 8 s
  (page 10 s), EventKit auth 12 s, isOnline 1.2 s ×2. The registry adds an outer safety net at 120 s, which
  returns `Tool error: timed out`. Python has no outer net, so this is a deviation that only appears on a hang.
- Tools may run concurrently, as in Python, where the MCP bridge uses `asyncio.to_thread`. Turn cancellation
  propagates to child processes.

## 4. Golden vectors

**Harness.** `native/tools/golden_m5m6.py` is a module that M0's `tools/golden.py` runs (§8 R7 covers the
interface). It imports `jarvis` from `~/jarvis` (measured at 36 MB RSS and 0.19 s) and **never** runs a
side effect. Every effectful call is monkeypatched to a recorder:
`jarvis._run_applescript`, `jarvis.subprocess.run`/`Popen`, `jarvis._open_url`, `jarvis.is_online`,
`jarvis._http_json`, `jarvis.urllib.request.urlopen`, `jarvis._to_trash`, `jarvis._schedule_alarm`,
`jarvis._ask_model`, `jarvis._shortcuts_all`, `jarvis.kb_lookup`/`kb_remember`,
`jarvis.personality_load`/`_save`/`personality_learn`, and `jarvis.ALARMS_FILE` (pointed at a temp path).
**Pinned clock:** `class FrozenDT(datetime)` with `now()` returning the pin, installed as `jarvis.datetime = FrozenDT`.
jarvis.py uses `from datetime import datetime` (line 26), so this one assignment covers
`_parse_when`, `strftime` and `fromtimestamp`. `time.time` is patched to the pin's epoch where it is used.
Pins: **P1** Mon 2026-09-28 14:30:15.123456, **P2** Fri 2026-10-02 23:59:59.999999,
**P3** Sun 2026-10-04 00:00:00.000000, **P4** Sat 2026-12-31 11:59:00.5 (year rollover). All are local naive time. Swift injects
`ctx.clock`, and tests run with `TZ=Europe/London` set in both harnesses.

**Fixture shape** (`native/Tests/Fixtures/golden/m5m6/<set>.json`):
```json
{"set":"parse_when","python":"jarvis._parse_when","jarvis_commit":"68cd112","pin":"2026-09-28T14:30:15.123456",
 "cases":[{"in":{"text":"in 10 minutes"},"out":"2026-09-28T14:40:15.123456"},
          {"in":{"text":"at 25"},"raises":{"type":"ValueError","msg":"hour must be in 0..23"}},
          {"in":{…},"out":"…","calls":[["osascript-script","tell application \"Music\"…"],["argv",["open","x-apple…"]]],
           "files":{"rel/path":"<utf8 or base64>"}}]}
```
`calls` is the ordered list of recorded effects. The Swift test injects fake runners that return the same
canned outputs, then asserts equality on `out`/`raises` and on `calls`. The effects are the script text and argv.

| Set | Python function(s) | Corpus (concrete) | Fixture |
|---|---|---|---|
| G1 py-compat | `str.isspace/strip/split/splitlines/lower/capitalize`, `repr`, `int()`, `bool()`, `urllib.parse.quote/urlencode`, `os.path.expanduser/abspath/basename/dirname` (HOME=`/Users/t`, cwd=`$HOME/w`), `strftime`, `isoformat`, `round`, `html.unescape`, `html.entities.html5` | Every code point with `chr(c).isspace()` (full scan). Strings: `" \x0b\x1c\x85  x​ "`, `"ΟΔΟΣ"`, `"İ"`, `"ß"`, `"it's"`, `'say "hi"'`, `"a'b\"c"`. int: `55, 55.9, -0.5, true, "55", " 7 ", "1_0", "55.5", "", null, "abc"`. bool: `"false", "", 0, 0.0, [], {}, null, "0"`. quote: `"New York"`, `"AC/DC"`, `"é&=+?#"`. urlencode of the DDG and Wiki param dicts. paths: `"~"`, `"~/a/../b/"`, `"/tmp/x"`, `"//x"`, `"a/./b"`, `"/private/tmp/x"`, `""`. strftime: each P× with `%I:%M %p`, `%A at %I:%M %p`, `%Y-%m-%d at %H.%M.%S`. unescape: `&amp;`, `&amp`, `&ampx`, `&#0;`, `&#128;`, `&#x110000;`, `&notit;`, `&NotANamedEntity;`. round: `0.5, 1.5, 2.5, 8.0, 12.48` | `pycompat.json`, `html5_entities.json` |
| G2 parse_when | `_parse_when` | P1-P4 × `in 10 minutes`, `in 1 sec`, `in 2 hrs`, `in 3 days`, `in 5min`, `within 5 days`, `at 5pm`, `at 5`, `at 12am`, `at 12pm`, `at 0`, `at 11:59 pm`, `at 17:45`, `at 7 a.m.`, `at 7 p.m.`, `at 25`, `at 9:75`, `tomorrow`, `tomorrow at 3pm`, `at 3pm tomorrow`, `on friday`, `friday` (on P2), `next monday at 2:30pm`, `Sunday at 10am`, `cat 5`, `noon`, `""` | `parse_when.json` |
| G3 set_alarm | `set_alarm` (ALARMS_FILE→temp, starting with `[]` and with one existing entry) | `("7 a.m.","")`, `("at 7 p.m.","wake")`, `("every weekday at 6:30am","gym")`, `("daily 8","")`, `("every night at 11pm","")`, `("in 30 minutes","tea")`, `("tomorrow","")`, `("banana","")` | `set_alarm.json` (reply + exact file bytes + schedule calls) |
| G4 reminders/events/calendar | `_create_reminder`, `_create_event` (both `_ek_create` return values True/False/None), `_calendar_today` (patched `_ek_events` → canned lists incl. all-day, `12:05 AM`, same-start ties; and None → AS fallback with canned outputs incl. `-600`) | text/when pairs from G2. `duration_minutes`: `60, 2, "abc", null, 90.7` | `reminder.json`, `event.json`, `calendar.json` |
| G5 open_settings | `_open_settings` | every key of `_SETTINGS_PANES` and `_PRIVACY_ANCHORS`, plus `"the sound settings"`, `"my displays pane"`, `"Bluetooth preferences"`, `"blue"`, `"privacy & security"`, `"xyz"`, `""`, `"accessibility"` | `open_settings.json` |
| G6 system_control | `_toggle_system`, `_macos_tweak` | every `_TWEAKS` key × on/off, `wifi` (canned `-listallhardwareports`, with and without Wi-Fi), `bt` (which→None / path), `dnd` (stubbed `_run_shortcut` found / not found), `dark`, `light mode`, `the dock autohide`, `hidden`, `nonsense`. Dark-mode canned outputs `""` and `"execution error"` | `system_control.json` |
| G7 apps | `_name_kinds`, `_enrich_app_index` (temp `.app` dirs with fixture Info.plists: Safari-like, VLC-like with http but no html doc types, "Downie", mailto app, a games category, "Archive Utility", "The Unarchiver", "Arc"), `_kind_word`, `_find_apps` (fixed APP_INDEX order, `_default_browser_name` stubbed) | queries: `browsers`, `my web browser`, `email client`, `game`, `ai apps`, `arc`, `zzz`, `""` | `apps.json`. **Kinds in `Name (k1, k2)` are compared as a set**, because Python joins a hash-ordered `set` |
| G8 spotlight | `_spotlight`, `_search_files` (canned mdfind stdout, argv recorded; recent uses temp files with `os.utime`-set mtimes and junk paths) | `("report",)`, `("it's",)`, `("a\\b",)`, `("", "pdf")`, `("x","nosuchkind")`, `("", "", True)`, `("notes","document",True)`, 0 / 6 / 7 / 20 hits | `spotlight.json` |
| G9 files | `_read_file`, `_delete_file`, `_move_file`, `_write_file` against a temp tree under `~/Library/Caches/jarvis-golden/<uuid>` (in-home) and `$SHARED/jarvis-golden/<uuid>` (outside home; SHARED=/Users/Shared). `_to_trash` is stubbed True/False. Gated actions are recorded from `jarvis._pending_action["desc"]` and then **executed** via `_pending_action["fn"]()` on the temp tree | read: missing, dir, chmod-000, empty, BOM, CRLF+CR, invalid UTF-8, 5000 ASCII, 4000 emoji + more, flag emoji, path containing `'`, `~` path. delete: in-home, permanent, outside-home, `/etc/hosts`, `~`, `/private/tmp/x`, symlink→dir permanent. move: rename, into existing dir, clobber file, outside home, trailing `/`, system src. write: new nested, overwrite in-home, overwrite outside home (second write in same session is instant), `""`, dir path | `files.json` (reply + tree listing + file bytes after) |
| G10 AppleScript text | `_now_playing`, `_music_search`, `_play_query`, `_music_control`, `_media`, `_make_note`, `_find_contact`, `_contact_handle`, `_send_message`, `_send_email`, `_type_text`, `_set_brightness` (CLI absent/present), `_notify`, `_set_volume`, `_active_tab_url`, `_run_applescript`-blocking via `execute_tool("run_applescript")` | canned outputs: `"Redbone \| Childish Gambino \| Awaken, My Love!"`, `"nothing"`, `"x \|  \| "`, 0/3/8 search lines, `"execution error: … (-600)"`, `"playing"`, contact outputs, `"+44 (7700) 900-123"`, `"mum"`, `"a@b.c"`. Text with `"`, `\`, newlines, emoji, and `do shell script`/`System Events` for the block path | `applescript.json` (script bytes + reply) |
| G11 web parse | `_web_search` (fixture DDG JSON: AbstractText / Answer number / RelatedTopics only / empty; Wiki opensearch + summary; offline→kb stub), `_weather` (fixture j1 JSON; missing nearest_area; malformed), `_location` (success / fail / empty bits), `_get_news` (fixture RSS: CDATA, `&amp;`, `&#8217;`, empty title, 10 items), `_play_query` (fixture YouTube HTML with/without videoId, offline) | as listed | `web.json` (URL requested + UA + reply) |
| G12 page text | `_fetch_page_text` (patched urlopen) | fixture HTML: nested `<script>`, `<STYLE>`, `<nav class=x>`, entities, `\x0b`/` ` whitespace, >6000 chars, >400 000 bytes, invalid UTF-8 | `page_text.json` |
| G13 shortcuts | `_match_shortcut`, `_list_shortcuts`, `_run_shortcut` (canned rc 0/1/timeout) | name lists incl. ties on length, Jaccard exactly 0.5, `"Toggle Do Not Disturb"`, 0/15/16 shortcuts | `shortcuts.json` |
| G14 lyrics + personality | `_find_song_by_lyrics` (canned `_ask_model`: `"Redbone by Childish Gambino"`, `'"Hello" by Adele\nextra'`, `"unknown"`, `""`, `"  'x'  "`, a 200-char line), `personality_rewrite_tool` (2/3/12/13 lines, `- trait.`, `• trait`, blank lines), `personality_note_tool` (7/8 chars) | as listed | `lyrics.json`, `personality.json` |
| G15 sysinfo/diagnostics | `_get_system_info` each type, `_system_report` (canned outputs for pmset: `70%; discharging`, `100%; charged`, `80%; AC attached`, `95%; finishing charge`, no battery; top; networksetup; sysctl; vm_stat; ioreg; ps; patched `shutil.disk_usage`, `time.time`) | as listed | `sysinfo.json`. Swift feeds the same numbers to `Diagnostics.format` |
| G16 schemas + taint | `jarvis.TOOLS`, `UNTRUSTED_TOOLS`, `EXECUTOR_TOOLS` | the whole list | `tool_schemas.ordered.json`, `tool_schemas.canonical.json`, `taint_sets.json` |
| G17 OCR | `_ocr_image` | 4 PNGs rendered once by a Swift CoreText script (`Tests/Fixtures/golden/m5m6/ocr/*.png`, committed): plain paragraph, code with symbols, two columns, dark mode | `ocr.json` (exact string. Same OS and Vision on both sides) |
| G18 messages | `_recent_messages` with `HOME` set to a temp home holding a fixture `Library/Messages/chat.db` (the golden script creates `message(ROWID,text,handle_id,is_from_me,date)` and `handle(ROWID,id)`) | 0 rows, NULL text, NULL handle, 7 rows (limit 5), emoji text | `messages.json` |
## 5. Acceptance checks

**5.0 Preconditions (automated).** Python is `PY=/Library/Frameworks/Python.framework/Versions/3.14/bin/python3`.
The oracle commit must still match: `git -C ~/jarvis log -1 --format=%h` is `68cd112`. If it is not,
regenerate the fixtures and re-check the §2 lines with `grep -n "^def <fn>(" jarvis.py`.
`swift build && swift test` must be green. All §4 sets must pass, along with T-SCHEMA and T-GUARD.
**Never start Python JARVIS.** The oracle is `import jarvis` plus a single function call.
**Harness.** `swift run jarvis-tools-cli <tool> '<json>' [--dry-run]` is a dev-only executable. It goes
through ToolRegistry with the real guard, and `--dry-run` swaps in recorder runners that print the
script, argv or URL instead of executing. Anything that needs a TCC grant runs from the signed bundle
instead: `JARVIS.app/Contents/MacOS/JARVIS --tool <tool> '<json>'`, a hidden dev flag in JarvisApp.
TCC attributes a grant to the responsible app, so a CLI run from Terminal would test Terminal's grants.
**Live parity** means running Python's function and the native tool back to back on the same machine
state. Private output (messages, contacts, clipboard) is compared by SHA-256 and never printed.

| ID | Tool group | Automated check → observable proof | Manual (needs user / TCC) |
|---|---|---|---|
| T-SCHEMA | all 46 | Swift test vs G16: ordered and canonical bytes equal. Names equal to TOOLS order | — |
| T-GUARD | all | For each of the 8 EXECUTOR names (the set has 9; run_powershell is not ported): a tainted turn gives the exact block string and the fake runner's call count stays 0. For each of the 7 UNTRUSTED: the turn is tainted after the call. Errors give `Tool error: `. `get_system_info` gives `Unknown tool get_system_info` | — |
| A-SYS-1 | get_battery | `$PY -c 'import sys,os;sys.path.insert(0,os.path.expanduser("~/jarvis"));import jarvis;print(jarvis._get_system_info("battery"))'` vs the CLI's `get_battery`: equal strings (retry once if the % ticks) | Plugged in / charged states: the user plugs in and both are re-run |
| A-SYS-2 | get_time | Python `_get_system_info("time")` vs native within the same minute: equal | — |
| A-SYS-3 | get_cpu_usage | Matches `^CPU user load \d+\.\d{2} percent\.$`. Over 3 paired samples, \|native − `top -l 1 -n 0` user\| ≤ 15 points | — |
| A-SYS-4 | get_wifi_status | Format matches either networksetup form. With Location granted, the SSID is non-empty | The user confirms the SSID. This is the intended deviation from Python (R3) |
| A-SYS-5 | run_diagnostics | Live vs Python: memory ±0.3 GB, disk free ±1 GB, cycle count exact, uptime exact (off an hour boundary), battery exact. The heaviest process only has to match the format | — |
| A-SYS-6 | set_volume | Read `osascript -e 'output volume of (get volume settings)'` = V, run native `set_volume {"level":V}`, read again = V. The reply is `Volume set to V.` | An audible change, with consent |
| A-SYS-7 | set_brightness, type_text, notify | `--dry-run` event and script lists equal G10 | M-5: brightness 30→ back, with consent. Typing into a TextEdit scratch doc. A notification banner seen with a screenshot |
| A-SYS-8 | read_clipboard | SHA-256 of native == SHA-256 of `jarvis._get_clipboard()[:3500]` | — |
| A-SCR-1 | take_screenshot, see_screen | After the Screen Recording grant: the file exists, its PNG pixel size equals the main display mode size, and the test moves it to the Trash. For see_screen, the native OCR of the G17 fixture PNGs is exact | Grant Screen Recording. see_screen on a TextEdit window containing a known sentence, which must appear in the output |
| A-APP-1 | find_apps | Live: Python `build_app_index()`, then `_enrich_app_index()` on the calling thread, then `_find_apps(q)` vs native for G7's queries. Equal, with kinds compared as a set | — |
| A-APP-2 | open_settings, system_control | `--dry-run` URL and argv equal G5 and G6 | Open wifi, privacy→microphone and "xyz" (screenshots). Toggle `hidden files` on and then off, with consent |
| A-FILE-1 | search_files, find_files | Live parity for `jarvis`, `README`, kind `pdf`, `recent`: equal strings (retry once) | — |
| A-FILE-2 | read_file | Live parity on `~/jarvis/README.md`, `~/jarvis/jarvis.py`, `/bin/ls`, a missing path, `~` | — |
| A-FILE-3 | delete/move/write | G9 replayed natively on fresh temp trees (in home and in `/Users/Shared`), with the trasher faked. Gate text equal; the confirmed action's effect equal | One real trash of a test file, then check it in Finder's Trash (and Put Back, R13) |
| A-MUS-1 | music_now_playing | Live parity. Safe: the script does not launch Music | While a track plays, the user confirms |
| A-MUS-2 | music_search/play/control | `--dry-run` equals G10 | Search (this launches Music), play one track, pause, set volume to 40 |
| A-WEB-1 | web_search, get_weather, get_location, get_news | Live back-to-back parity with KB writes redirected to a temp KB on both sides. Equal strings, retrying once for drift | — |
| A-WEB-2 | summarize_page, find_song_by_lyrics | `_fetch_page_text(url)` vs native PageText on the same live URL: equal. Post-processing is covered by G14 | The model answer is judged by the user (non-deterministic) |
| A-DATA-1 | get_calendar | Live parity if both the Python process and JARVIS.app hold Calendar full access. Otherwise manual | Grant Calendars; compare with Calendar.app |
| A-DATA-2 | create_event, set_reminder | `--dry-run` EK payload (title, start, end, calendar id) equals the G4 expectation | Create one event and one reminder in a user-approved "JARVIS Test" calendar/list, then delete them by hand |
| A-DATA-3 | find_contact, contact handle | Up to 50 names from CN plus 3 prefixes and 3 lowercased: Python `_find_contact` / `_contact_handle` vs native gives **0 mismatches**. Only the mismatch count and names are printed. This launches Contacts.app once | Grant Contacts and Automation(Contacts) |
| A-DATA-4 | get_messages | SHA-256 parity if FDA is granted to both the terminal and JARVIS.app. G18 always runs | Grant FDA |
| A-DATA-5 | send_message, send_email, make_note | `--dry-run` scripts byte-equal G10 | With consent: one iMessage and one email **to the user's own address**, and one note, which is then deleted by hand |
| A-DATA-6 | list_shortcuts, run_shortcut | list: live parity (read-only). run: `--dry-run` argv | Run a harmless shortcut the user picks |
| A-DATA-7 | set_alarm, personality_* | G3 and G14 replayed against a temp AlarmStore and a temp Personality store: bytes equal | One real alarm 2 minutes out, which fires (app loop, M4+) |

## 6. Executor tasks
Each task: write code and tests first, then run `swift test --filter <Suite>` and paste the result. Append to the task worklog.
Never execute a real side effect: use `--dry-run` or temp targets. RAM: no Python JARVIS, one oracle call at a time.

| # | Task (≤2 h) | Files | Spec → verification | Depends on |
|---|---|---|---|---|
| T5.1 | Py-compat layer | `JarvisToolsCore/Py/*`, `tools/gen_html5_entities.py`, `golden_m5m6.py` G1 | §3.1 helpers → G1 green | M0 golden.py |
| T5.2 | Schemas, Tool protocol, registry, dispatch rules | `Generated/ToolSchemas.swift`, `tools/gen_tool_schemas.py`, `Registry.swift`, `Tool.swift` | §3.2-3.3 → T-SCHEMA, T-GUARD (M2 stub allowed; replace when M2 lands) | T5.1, M2 API |
| T5.3 | Runners, fakes, CLI, app `--tool` flag | `Run/*`, `JarvisToolsCLI/main.swift`, JarvisApp flag, Package.swift targets | §3.4 → unit tests for timeout-kill (`sleep 5` with a 1 s limit), pipe drain (1 MB output), decoders | T5.2 |
| T5.4 | run_command, run_applescript | `System/Shell.swift` | Table rows → G10 block cases, M2 tier vectors via registry | T5.3, M2 |
| T5.5 | battery, time, cpu, wifi, volume, diagnostics | `System/*` | §3.5 → G15, A-SYS-1..6 | T5.3 |
| T5.6 | brightness, notify, clipboard, type_text | `System/*`, `Screen/TypeText.swift` | → G10 subset, A-SYS-7/8 | T5.3 |
| T5.7 | ScreenCapture, OCR, take_screenshot, see_screen | `Screen/*`, the OCR fixture render script | → G17, A-SCR-1 | T5.3 |
| T5.8 | AppIndex, find_apps | `Apps/AppIndex.swift`, `Apps/FindApps.swift`, `Parse/AppKinds.swift` | → G7, A-APP-1 | T5.3 |
| T5.9 | open_settings, system_control | `Apps/*`, `Parse/SettingsMap.swift`, `Parse/TweakMap.swift` | → G5, G6, A-APP-2 dry-run | T5.3, T6.7 (DND) |
| T5.10 | search_files, find_files | `Files/Spotlight.swift`, `Parse/SpotlightQuery.swift` | → G8, A-FILE-1 | T5.3 |
| T5.11 | read/delete/move/write | `Files/*` | → G9, A-FILE-2/3 | T5.3, M2 path guards + gate |
| T6.1 | ParseWhen, AlarmEntry, set_alarm | `Parse/ParseWhen.swift`, `Parse/AlarmEntry.swift`, `Data/Alarm.swift` | → G2, G3 | T5.1, M1 alarms store |
| T6.2 | Music ×4 | `Media/Music.swift`, `Parse/MusicParse.swift` | → G10 music, A-MUS-1/2 dry-run | T5.3 |
| T6.3 | Calendar, create_event, set_reminder | `Data/Calendar.swift`, `Data/Reminders.swift` | → G4, A-DATA-1/2 | T6.1 |
| T6.4 | Contacts matcher + AS fallback | `Data/Contacts.swift`, `Parse/ContactHandle.swift` | → G10 contact cases, A-DATA-3 | T5.3 |
| T6.5 | send_message, send_email, make_note | `Data/Comms.swift`, `Data/Notes.swift` | → G10, A-DATA-5 dry-run | T6.4 |
| T6.6 | get_messages | `Data/Messages.swift` | → G18, A-DATA-4 | T5.3 |
| T6.7 | Shortcuts | `Data/Shortcuts.swift`, `Parse/ShortcutMatch.swift` | → G13, A-DATA-6 | T5.3 |
| T6.8 | web_search, weather, location, news | `Web/*`, `Parse/{SearchParse,WeatherParse,NewsParse}.swift` | → G11, A-WEB-1 | T5.1, M1 KB API |
| T6.9 | summarize_page, find_song_by_lyrics | `Web/SummarizePage.swift`, `Media/Lyrics.swift`, `Parse/PageText.swift` | → G12, G14, A-WEB-2 | T6.8, M3 localModel |
| T6.10 | personality_note/rewrite | `Data/Personality.swift`, `Parse/PersonalityLines.swift` | → G14, A-DATA-7 | M1 Personality |
| T6.11 | Acceptance sweep, PARITY evidence, RSS | `PARITY.md` evidence column | Every A-* row pasted with its output. RSS measured idle, after see_screen, and after find_apps | all |

## 7. RAM / permissions

**Signing.** TCC grants are keyed to the code signature's designated requirement. With the stable
self-signed identity from M0, grants survive rebuilds. With ad-hoc signing (`-`), **every build
loses its grants** (R6). No hardened runtime is planned for dev builds, so no entitlements are required.
If M0 enables hardened runtime, add `com.apple.security.automation.apple-events`,
`com.apple.security.personal-information.calendars`, `…addressbook` and `…location`. Not sandboxed.
A self-signed, non-notarised app **can** obtain every grant below, because each is a user decision in
System Settings or a prompt. None needs Apple approval.

| Permission (TCC) | Info.plist key | Tools | How granted |
|---|---|---|---|
| Automation → Music, Spotify(*), Notes, Messages, Mail, Calendar/Reminders (AS fallback only), System Events, Safari, Google Chrome, Contacts (fallback), Finder (none now) | `NSAppleEventsUsageDescription` (without it, Apple Events fail with -1743 and no prompt appears) | music×4, make_note, send_message, send_email, get_calendar/create_event/set_reminder fallbacks, system_control dark mode, summarize_page, run_applescript (any target) | A prompt per target app |
| Accessibility (post events) | — | type_text, set_brightness (key path) | `CGRequestPostEventAccess()`, then the user toggles it in Settings |
| Screen Recording | — | take_screenshot, see_screen | `CGRequestScreenCaptureAccess()`. macOS re-confirms periodically |
| Full Disk Access | — | get_messages, read_file for protected paths, search_files content in protected dirs | Manual only (Settings → FDA → add JARVIS.app) |
| Calendars (full) | `NSCalendarsFullAccessUsageDescription` | get_calendar, create_event | `requestFullAccessToEvents` |
| Reminders (full) | `NSRemindersFullAccessUsageDescription` | set_reminder | `requestFullAccessToReminders` |
| Contacts | `NSContactsUsageDescription` | find_contact, send_message/send_email resolution | CNContactStore request |
| Location | `NSLocationWhenInUseUsageDescription` (+ `NSLocationUsageDescription`) | get_wifi_status, run_diagnostics wifi line (SSID only) | CLLocationManager request |
| Notifications | — (UN authorisation) | notify | `requestAuthorization(options:[.alert,.sound])` |
| Files & Folders (Desktop) | — | take_screenshot writes `~/Desktop`, read/write/move under Desktop/Documents/Downloads | A prompt on first access, or implied by FDA |
| none | — | get_battery, get_time, get_cpu_usage, set_volume, run_diagnostics, read_clipboard, find_apps, open_settings, system_control (except dark mode), find/search_files, get_weather/location/news, web_search, shortcuts, set_alarm, personality_* | — |
(*) Spotify is referenced by the `_media` script. Automation is prompted only if Spotify is installed.

**RAM (about 1 GB free).** Transient costs: Vision accurate OCR, about 100-200 MB peak for see_screen, released
after (**measure**). A Retina main-display CGImage is about 24 MB. EventKit and Contacts stores are about 10-30 MB
each (**measure**). AppleScript targets that get *launched* are separate apps of about 50-150 MB each:
Music (search/play), Notes, Mail, Messages, Calendar/Reminders (fallbacks only). Native CN and EK avoid launching
Contacts.app and Reminders.app. Short-lived processes: mdfind, shortcuts, osascript (about 10-20 MB). Rules: at
most one OCR at a time (an actor gate), release the CGImage before OCR returns, and no persistent SCStream.
The numbers above are estimates. T6.11 records the measured RSS.

## 8. Risks and open questions
- **R1 `_sensitive_path` is dead code.** It is defined at 1245-1251 and never called. Python `read_file`
  reads `~/.ssh/id_rsa` and `voiceprint.npy` freely, and `run_command` can `cat` them. Parity means native
  also does not check. "Security at least as strict" belongs to M2. **Decision for the planner/M2:** wire it
  into read_file, or keep parity.
- **R2 PARITY.md vs Python taint sets.** PARITY marks `delete_file`, `move_file` and `write_file` as **X**, but
  Python's `EXECUTOR_TOOLS` (4843-4847) omits them. Their only protection is the tier gate. This plan
  implements Python's sets. Adding them to X is stricter and harmless, but it is a deviation that needs
  the planner or user to decide.
- **R3 get_wifi_status oracle is broken on macOS 27.** networksetup prints "not associated" while en0 is
  up (observed). Native uses CoreWLAN, which needs the Location grant. This is a deliberate deviation.
  If full parity must hold literally, the user decides.
- **R4 No Ollama in native.** `summarize_page` and `find_song_by_lyrics` call `_ask_model` (Ollama,
  `qwen2.5:3b`). Native needs M3 to supply `ctx.localModel` (FoundationModels proposed). The answers
  cannot be golden-tested. An alternative is to return page text to Claude, which changes behaviour.
- **R5 Parity-bug replication.** Python bugs kept on purpose: "p.m." unrecognised; `within 5 days`
  matches; `cat 5` counts as "at 5"; notify unescaped (the native version *does* escape, R11); a reminder
  1 s early (native uses an exact date, R14); `bool("false")` is true; move clobber on an existing dir.
  Each is marked in the fixtures. Fixing any of them is a separate, user-approved change *after* parity.
- **R6 TCC with the self-signed identity.** If M0's signing identity or bundle id changes, every grant
  resets. Dev builds share `com.jarvis.assistant` with Python's py2app bundle. **Open question:** does the
  Python app's existing grant transfer? No: a different signature means a different designated requirement,
  so it will re-prompt.
- **R7 M0, M1, M2 and M3 interfaces are assumed.** Those plan files were empty skeletons when this was
  written. This plan assumes: golden.py loads per-milestone modules; M2 exposes `Guard.shellRisk`,
  `isSystemPath`, `inHome`, `dangerousAppleScript`, `gate`, the taint sets and the turn state; M1 exposes
  KB `lookup`/`remember`, `Personality.learn`/`setCore`, and `AlarmStore.append`; M3 provides `localModel`
  and consumes `ToolSchema` raw text. Reconcile names at integration. There is one call site each.
- **R8 AppKit in a non-App target** conflicts with the Package.swift comment. The mitigation is the
  JarvisToolsCore/JarvisTools split. Planner sign-off is needed.
- **R9 `_media` references Spotify terminology.** On a Mac without Spotify, `tell application "Spotify"`
  inside `if … is running` may fail to compile, which is exactly the failure `_now_playing`'s comment
  describes. Python's `music_control` may therefore be broken here too. G10 records the script. A-MUS-2
  manual will show whether it works. **Not verified.**
- **R10 Internal tool calls bypass the taint guard.** DND calls `_run_shortcut`, an executor-class
  action, even in a tainted turn (via `system_control`, class `-`). This is parity, and it is a small hole to report to M2.
- **R11-R14 Small intentional native improvements.** Each is flagged in PARITY evidence. R11: notify escapes
  quotes (Python silently fails). R12: an RTF-only clipboard gives `""` (pbpaste gives RTF source). R13: Trash
  via FileManager; whether **Put Back** works is not verified, so A-FILE-3 manual checks it. R14: reminders are
  exact to the second.
- **R15 Unverified mechanics.** Whether CGEvent keys 144/145 change brightness on this Mac, whether
  `CWInterface.setPower` works without admin (so networksetup is kept), whether UN notifications work
  from a self-signed app, and whether AppleScript `every person whose…` order equals `CNContactStore`
  enumeration order (A-DATA-3 decides, and the AS fallback is ready).
- **R16 Out-of-TOOLS features that the ROADMAP lists under M6** are not planned here: AudD
  `identify_ambient`, background `research_loop`, timers (fast-path, M7), and alarm firing (app loop).
  Someone must own them.
- **R17 Unicode semantics.** Python `\s`, `\w`, `\b`, `strip`, `split`, `splitlines`, `lower` and code-point
  `len` differ from Swift and ICU defaults. G1 pins them. Any regex copied from Python goes through `PyRegex`.
  Swift `Regex` `\b` defaults to Unicode word boundaries: use NSRegularExpression, or `.wordBoundaryKind(.simple)`.
