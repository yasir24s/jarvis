# M1b — Research dataset logger (native snapshot writer, counters, additive schema v2, gap annotations)
## 1. Goal and scope (in / explicitly out)

**Goal.** Native JARVIS writes the dissertation dataset (`research/metrics.jsonl`,
`research/usage.json`) with **exactly** the schema Python JARVIS writes (golden-tested
against the Python oracle, byte-identical where the inputs are identical), plus a small,
justified **schema-2 additive extension** that both implementations emit, so an analyst
can always tell which implementation, which build channel and which instrumentation level
produced every row and every day of counters. The 2026-08-21 → (first new row) gap is
documented honestly, never backfilled.

Dates in this plan: the dataset started 2026-07-23; the last existing snapshot is
2026-08-20; today (plan written) is 2026-09-28.

**In scope**

1. `ResearchLogger` in `JarvisCore` (Foundation + Darwin only): `bump(_:by:)`, daily
   snapshot builder, last-date check, feedback tracking (`user_correction`,
   `rephrase_suspected`), the counter-name catalogue as typed constructors (§2.3), the
   schema-2 blocks (`schema`, `runtime`, `code_native`) and the new counters
   (`starts_*`, `alive_hours`, `fast_path_handled`, `interactions_text`, and the
   native-only TTS counters `tts_*`).
2. `ResearchScheduler` in `JarvisApp`: first check ~90 s after launch, then hourly, for the
   whole process lifetime, independent of which windows or pipelines are running (text
   chat only, voice off, HUD off — still logs).
3. The matching **additive** Python patch to `jarvis.py` (snapshot writer + three
   one-line counter bumps) so Python rows carry the same schema-2 blocks
   (`runtime.impl == "python"`).
4. `research/annotations.jsonl` (new, curated, append-only) + an additive README section
   documenting new fields, the python/swift and dev/release split, previously
   undocumented existing counters, and the gap.
5. Golden fixtures from the Python oracle, plus a read-only schema-compat check over the
   REAL `metrics.jsonl` / `usage.json`.

**Explicitly out of scope**

- The subsystems that *emit* counters (STT, tone, emotions, speaker ID, wake, backends,
  TTS, fast path). M1b ships the typed counter API and its golden tests; each emitting
  milestone calls it (catalogue §2.3 names the milestone per counter).
- Emotion maths, personality/profile/KB/corrections/history loading: owned by M1
  (`plan/M01-core-state-persona.md`). M1b consumes them through a protocol (§3.2).
- The Python ↔ native "never concurrent" guard and single-instance guard: owned by M0
  (`plan/M00-foundation-and-M15-cutover.md`). M1b depends on it (§8 R3).
- Any rewrite, reformat, re-scale, backfill or de-duplication of existing rows/days.
- Response-latency metrics (rejected for now, §3.6 table).
- Starting Python JARVIS. Nothing here runs `jarvis.py` as an app; the oracle only imports it.
## 2. Python reference

All line numbers are `jarvis.py` at the time of writing (5,762 lines). Re-grep before use.

### 2.1 Functions and constants

| function/constant | jarvis.py lines | behaviour | notes |
|---|---|---|---|
| `RESEARCH_DIR` / `RESEARCH_METRICS` / `RESEARCH_USAGE` | 2438–2440 | `HERE/research`, `…/metrics.jsonl`, `…/usage.json` | Reassignable after import (oracle sandbox). |
| `_research_lock` | 2441 | in-process `threading.Lock` around both files' read-modify-write | No cross-process lock. |
| `research_bump(key, n=1)` | 2443–2456 | `day = time.strftime("%Y-%m-%d")` (local); `makedirs`; `json.load(usage)` or `{}` on ANY exception; `u.setdefault(day, {})[key] = u.get(day, {}).get(key, 0) + n`; rewrite whole file with `json.dump(u, f, indent=1)` (truncate-in-place, not atomic); any exception → `log("Research bump: …")` and no write. | **Hazard:** unreadable/partial `usage.json` → `u = {}` → next write replaces ALL past days with just today. Non-dict root, non-dict day value, or non-numeric counter → exception → silently no write. Float counters stay float; `True` counts as 1. |
| `_FEEDBACK_NEG_RE` | 2460–2463 | `re.I`: `\bno,? (?:i said\|i meant\|that's not)\b`, `\bnot what i (?:said\|meant\|asked)\b`, `\bthat'?s (?:wrong\|not right)\b`, `\bwrong answer\b`, `\bcancel that\b`, `\bundo that\b`, `\bnever ?mind\b` | Copy the pattern from source, not from this table. |
| `_LAST_CMD` | 2464 | `{"text": "", "at": 0.0}` process-global | Not persisted; resets on restart. |
| `track_feedback(text)` | 2466–2474 | if NEG regex `search` → `research_bump("user_correction")` + `emotion_event("corrected")` (which also bumps `emotion_corrected`); elif last text non-empty, `now - at < 30`, `text != last`, and `difflib.SequenceMatcher(None, text, last).ratio() > 0.65` → `research_bump("rephrase_suspected")`; then always store `(text, now)`. | Exact repeat is NOT a rephrase. Ratio compares (new, old) in that argument order (matters for autojunk ≥200 chars). |
| `research_snapshot()` | 2476–2514 | builds `snap` in this key order: `ts` (`time.time()` float), `date`, `code{bytes, lines, git_head, git_commits}`, `personality`, `emotions`, `counts{profile_facts, corrections, kb_topics, history_turns}`, `voiceprint_enrolled`, `usage_today`; appends `json.dumps(snap) + "\n"` under the lock; logs `Research snapshot appended for {day}.`; any exception → `log("Research snapshot: …")`, no row. | Details in 2.2. |
| `_research_last_date()` | 2516–2523 | reads last ≤8192 bytes of metrics, `decode(errors="ignore")`, `strip().splitlines()`, `json.loads(lines[-1]).get("date", "")`; any failure → `""` | **Latent bug:** a last line longer than 8192 bytes parses as a fragment → `""` → a duplicate snapshot every hour. Real lines are already 1,521–4,110 bytes and grow with `personality.learned`. |
| `research_log_loop()` | 2561–2570 | `time.sleep(90)`; loop: if `_research_last_date() != today` → `research_snapshot()`; `time.sleep(3600)` | Started as a daemon thread in `run_assistant` at 5467. **Not** `research_loop` (2606), which is background web research for the KB — name collision, different subsystem (M14). |
| `personality_load()` | 2166–2175 | file dict with truthy `core` → `setdefault("learned", [])` (appends key at END if missing); else deep copy of `_PERSONALITY_SEED` (2136) | Snapshot copies this verbatim (M1 owns). |
| `_emotions_load()` | 2303–2313 | file must contain all `_EMO_DIMS` keys (`mood`, `energy`, `warmth`, `patience`; 2296) else baselines + `at` | Snapshot uses the RAW loaded values — **no decay** — `{k: round(v, 3) for k, v in … if k != "at"}` in file key order. README says "at snapshot time"; code says "last persisted". Native mirrors code. Non-numeric extra key → `round` raises → no row. Int values stay int (`round(1, 3) == 1`). |
| `profile_load()` | 2051–2055 | `json.load(PROFILE_FILE)` or `{"facts": {}}` | `counts.profile_facts = len(p.get("facts", {}))`. |
| `_corrections_load()` | 822–832 | process-cached list of dicts with truthy `heard` and `meant` from `CORR_FILE` (101) | `counts.corrections = len(...)`. |
| `kb_load()` | 1994–1998 | `json.load(KB_FILE)` (99) or `{"topics": {}, "queue": []}` | `counts.kb_topics = len(kb.get("topics", {}))`. |
| `_history` / `_history_load()` | 4675 / 4660–4666 | in-memory turns; loaded as role∈{user,assistant} dicts, last 12 | `counts.history_turns = len(_history)` — in-memory, can briefly be 13 mid-turn (5026–5027 then assistant append). |
| `VOICEPRINT_FILE` | 5134 | `HERE/voiceprint.npy` | `voiceprint_enrolled = os.path.exists(...)` — file existence, not "gate active". |
| `HERE` | 68 | directory of `jarvis.py` | `code` measures `HERE/jarvis.py` and `git -C HERE`. |
| `MODEL` | 77 | `JARVIS_MODEL` env, default `qwen2.5:3b` | Feeds `backend_local_…` counter names. |
| `CLAUDE_ENABLED` / `CLAUDE_MODEL` | 4825 / 4826 | env `JARVIS_USE_CLAUDE` (default on) / `JARVIS_CLAUDE_MODEL` or `None` | Feeds `backend_claude…` names; used by the Python `runtime.backends` patch. |
| `handle_one(command, online)` | 5548 (fast path at 5567) | fast path and confirmation-resolve replies do NOT reach `process_command`, so they are not in `interactions` | Python patch adds `fast_path_handled` here (§3.6). |
| `process_command(text, …)` | 5018; bumps at 5024–5025 | `emotion_react` → `research_bump("interactions")` → `track_feedback` | Only the LLM path counts as an interaction. |

### 2.2 Exact on-disk formats (from the code, confirmed on the real files read-only)

- `metrics.jsonl`: `json.dumps(snap)` defaults → separators `", "` and `": "`,
  `ensure_ascii=True` (non-ASCII → lowercase `\uXXXX`, non-BMP as surrogate pairs),
  insertion key order, Python `repr` floats, one line + `"\n"`, opened `"a"`.
- `usage.json`: `json.dump(u, f, indent=1)` → item separator `","`, key separator `": "`,
  newline + 1 space per level, `ensure_ascii=True`, no trailing newline; existing day order
  is preserved (dict insertion order), new day appended at end, new key appended at end of
  its day.
- `code.bytes` = `os.path.getsize`; `code.lines` = number of lines when iterating the file
  in text mode (universal newlines: `\n`, `\r\n`, lone `\r` each end a line; a final
  unterminated line counts). `code.git_head` = stdout of `git -C HERE rev-parse --short
  HEAD`, stripped; `code.git_commits` = stdout of `git -C HERE rev-list --count HEAD`,
  stripped — a **string**, not an int (real data: all 15 rows are `str`). Any exception
  in either call (timeout 5 s, git missing) → both `""`.
- Real data, structure only (2026-09-28): 15 rows, 15 distinct dates 2026-07-23 →
  2026-08-20, no duplicate dates, sorted; top-level keys exactly the 8 listed above in
  every row; `personality` keys `core`, `learned` (15) and `consolidated_at` (14).
  `usage.json`: 10 days, 2026-07-23 → 2026-08-18, all counter values `int`.

### 2.3 Complete counter catalogue

Every `research_bump(` call site (grep: 952, 1056, 2351, 2426, 2469, 2473, 4855, 5024,
5194, 5197, 5625; definition at 2443). "Real" = seen in the real `usage.json` (key names
only). "README" = documented in the current README.

**Existing counters (names byte-identical to Python — never change)**

| counter | kind | jarvis.py site (function) | fires when | native emitter | README | Real |
|---|---|---|---|---|---|---|
| `interactions` | static | 5024 (`process_command`) | every command that reaches the LLM path (voice **and** native text chat) | M3 (process-command equivalent), used by M4 | yes | yes |
| `backend_` + `re.sub(r"\W+", "_", name.lower())` | dynamic | 4855 (`_set_backend`) | a backend served a reply. Python names: `"claude (partial)"` (4998) → `backend_claude_partial_`; `"claude"` or `"claude (<CLAUDE_MODEL>)"` (5003) → `backend_claude` / `backend_claude_<model>_`; `f"local ({MODEL})"` (5045) → e.g. `backend_local_qwen2_5_3b_` (**trailing underscore**, real) | M3. Native local fallback is FoundationModels: its name string is an M3 decision, but it MUST go through the same sanitiser, so it will be a *new* `backend_local_…` name (additive, documented) | as `backend_*` | `backend_claude`, `backend_local_qwen2_5_3b_` |
| `emotion_` + `name` | dynamic | 2351 (`emotion_event`) — only if `name in _EMO_DELTAS`, else early return | emitted names (call sites): `barge_in` (718, `_barge_in_watch`), `user_urgent` (1058, `set_tone`), `insult`/`praise`/`gratitude` (2367/2369/2371, `emotion_react`), `corrected` (2470, `track_feedback`), `task_fail` (4253, `execute_tool` exception). `task_ok` is in `_EMO_DELTAS` but **never emitted** — native must not emit it either. | the bump lives in M1's `emotionEvent`; callers: M12 (barge_in), M9 (user_urgent), M1/M3 (insult/praise/gratitude), M1b (corrected), M5/M6 (task_fail) | 5 of 7 (`emotion_user_urgent`, `emotion_corrected` undocumented) | `emotion_user_urgent` |
| `tone_` + `re.sub(r"\W+", "_", desc.split(",")[0].strip())` | dynamic (no lowercasing) | 1056 (`set_tone`); skipped when `desc == ""` | the five fixed `analyze_tone` outputs (1037–1045) give exactly: `tone_hurried_and_tense`, `tone_clipped`, `tone_animated_and_upbeat`, `tone_quiet_and_subdued`, `tone_calm_and_even` | M9 (vocal tone) — native must return the same five description strings | as `tone_*` (short words only; real names are longer) | 3 of 5 |
| `stt_segments_dropped` | static | 952 (`whisper_transcribe`) | a Whisper segment with `no_speech_prob > 0.6` or `avg_logprob < -1.2` | M9 — **instrument change**: SpeechTranscriber has different confidence signals (§8 R6) | yes | yes |
| `personality_consolidations` | static | 2426 (`personality_consolidate`) | a successful weekly merge | M1 (consolidation), scheduled by M14 | yes | yes |
| `user_correction` | static | 2469 (`track_feedback`) | NEG regex matched | **M1b** | yes | no |
| `rephrase_suspected` | static | 2473 (`track_feedback`) | similar (ratio > 0.65) different command within 30 s | **M1b** | yes | no |
| `speaker_reject` | static | 5194 (`speaker_ok`) | voiceprint loaded, gate on, embedding ok, similarity < threshold | M10 (called from M11 wake gate and M12 command/follow-up gates, sites 5623/5657/5681) | **no** | yes |
| `speaker_pass` | static | 5197 (`speaker_ok`) | same, similarity ≥ threshold | M10 (same callers) | **no** | yes |
| `wake_rejected_foreign_voice` | static | 5625 (`run_assistant`) | wake word fired but `speaker_ok(…, WAKE_SPK_THRESHOLD)` false. **The same event also bumps `speaker_reject`** (inside `speaker_ok`) — native must bump both. | M11 | yes | yes |

**New counters (schema 2, additive; justification in §3.6)**

| counter | emitted by | fires when | python? |
|---|---|---|---|
| `starts_python` | Python patch (`research_log_loop`, before its first sleep) | once per process start | python only |
| `starts_swift_dev` / `starts_swift_release` | M1b `ResearchScheduler.start()` | once per app launch, suffix = `runtime.build` | swift only |
| `alive_hours` | both: every iteration of the hourly check (first at ~90 s) | one per check ⇒ ≈ awake hours JARVIS ran that day | both |
| `fast_path_handled` | Python patch at 5567 (`handle_one`); native M7 router | a command answered by the offline fast path (never reaches `interactions`) | both |
| `interactions_text` | native M4 | a typed chat command reached the LLM path (it ALSO bumps `interactions`) | swift only (Python has no text input ⇒ true zero) |
| `tts_elevenlabs` | native M8 | one synthesis request whose audio was produced by ElevenLabs | **swift only** |
| `tts_piper` | native M8 | one synthesis request whose audio was produced by Piper (primary-by-config, fallback, or sensitive routing) | **swift only** (Python used Piper for everything, uncounted) |
| `tts_fallback_offline` / `tts_fallback_quota` / `tts_fallback_timeout` / `tts_fallback_error` / `tts_fallback_sensitive` | native M8 | a request that would have gone to ElevenLabs was sent to Piper, by reason. `sensitive` = policy routing (personal content never leaves the Mac), not a failure | **swift only** |
| `tts_chars_elevenlabs` | native M8 | `+= text.unicodeScalars.count` of every request body transmitted to ElevenLabs (attempted, including ones that later timed out/failed) | **swift only** |

Invariants (asserted by M8 tests, documented in README): each synthesis request bumps
exactly one of `tts_elevenlabs` / `tts_piper` (the engine whose audio finished the
request) and at most one `tts_fallback_*`; hence `tts_piper ≥ Σ tts_fallback_*` per day.
## 3. Swift design

### 3.1 Files

```
native/Sources/JarvisCore/Research/            (Foundation + Darwin only, no AppKit)
  ResearchPaths.swift        struct ResearchPaths
  ResearchClock.swift        protocol ResearchClock, SystemResearchClock, FixedResearchClock
  ResearchKey.swift          typed counter catalogue + PyWord sanitiser
  PyLineCount.swift          Python universal-newline line counting + code_native walker
  GitProbe.swift             git rev-parse / rev-list with 5 s timeout
  UsageStore.swift           usage.json read-modify-write (Python-identical bytes, atomic)
  SnapshotSources.swift      protocol SnapshotSources + FileSnapshotSources
  SnapshotBuilder.swift      builds the ordered snapshot JSONValue (v1 keys + schema 2)
  RuntimeInfo.swift          struct RuntimeInfo, MemoryFootprint (proc_pid_rusage)
  MetricsLog.swift           last-date read (full last line), append
  FeedbackTracker.swift      _FEEDBACK_NEG_RE + _LAST_CMD + SequenceMatcher ratio
  ResearchLogger.swift       façade: final class ResearchLogger: Sendable
native/Sources/JarvisApp/Research/
  ResearchScheduler.swift    launch bump, 90 s + hourly loop, lifecycle, build channel
native/Tests/JarvisCoreTests/Research/
  ResearchGoldenTests.swift  RealDatasetCompatTests.swift  ResearchLoggerTests.swift
  MemoryFootprintTests.swift
native/tools/golden_research.py      oracle generator (invoked by tools/golden.py research)
native/tools/research_schema_check.py  read-only check of the REAL dataset (aggregates only)
```

**Cross-plan dependency (JSON).** M1 owns the ordered JSON value and the
Python-compatible encoder. M1b needs exactly this interface; if M1 has not landed it when
M1b starts, task T1 builds it at `native/Sources/JarvisCore/Store/JSONValue.swift` and
`…/Store/PyJSON.swift` and M1 adopts it (§8 R1):

```swift
public indirect enum JSONValue: Sendable, Equatable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([JSONValue])
    case object(JSONObject)          // ordered; Python dict semantics (dup key: first position, last value)
}
public struct JSONObject: Sendable, Equatable { public var pairs: [(String, JSONValue)] … subscript, append }
public enum PyJSON {
    public static func loads(_ data: Data) throws -> JSONValue          // == json.loads: 1 → .int, 1.0 → .double
    public static func dumps(_ v: JSONValue, indent: Int? = nil) -> String
        // indent nil == json.dumps(v); indent n == json.dumps(v, indent=n)
        // ensure_ascii (lowercase \uXXXX, surrogate pairs), Python float repr, NaN/Infinity as Python
}
```

### 3.2 Types and signatures (JarvisCore)

```swift
public struct ResearchPaths: Sendable {
    public let here: URL                       // repo root (== Python HERE, ~/jarvis)
    public init(here: URL)
    public var dir: URL          { here/"research" }
    public var metrics: URL      { dir/"metrics.jsonl" }
    public var usage: URL        { dir/"usage.json" }
    public var jarvisPy: URL     { here/"jarvis.py" }
    public var nativeSources: URL { here/"native/Sources" }
    public var voiceprint: URL   { here/"voiceprint.npy" }
}

public protocol ResearchClock: Sendable {
    func now() -> Double                       // unix seconds (== time.time())
    var timeZone: TimeZone { get }
}
extension ResearchClock {
    func localDate(_ ts: Double) -> String     // == time.strftime("%Y-%m-%d", localtime(ts)); Gregorian, POSIX locale
    func utcOffset(_ ts: Double) -> String     // == time.strftime("%z") → "+0100" / "-0230"
}

public enum ResearchKey {                       // every counter name the app may emit — no free strings at call sites
    public static let interactions = "interactions", interactionsText = "interactions_text",
        sttSegmentsDropped = "stt_segments_dropped", personalityConsolidations = "personality_consolidations",
        userCorrection = "user_correction", rephraseSuspected = "rephrase_suspected",
        speakerReject = "speaker_reject", speakerPass = "speaker_pass",
        wakeRejectedForeignVoice = "wake_rejected_foreign_voice",
        aliveHours = "alive_hours", fastPathHandled = "fast_path_handled",
        ttsElevenLabs = "tts_elevenlabs", ttsPiper = "tts_piper", ttsCharsElevenLabs = "tts_chars_elevenlabs"
    public static func backend(_ name: String) -> String   // "backend_" + PyWord.sub(name.lowercased()) — Python str.lower()
    public static func emotion(_ event: String) -> String   // "emotion_" + event (caller guarantees event ∈ emitted set)
    public static func tone(_ desc: String) -> String?      // nil when desc == "" ; "tone_" + PyWord.sub(first-comma-field.pyStrip())
    public static func tool(_ name: String, known: Set<String>) -> String   // "tool_" + (known.contains(name) ? name : "unknown")
    public static func starts(build: BuildChannel) -> String // "starts_swift_dev" | "starts_swift_release"
    public static func ttsFallback(_ r: TTSFallbackReason) -> String // "tts_fallback_" + r.rawValue
}
public enum BuildChannel: String, Sendable { case dev, release }
public enum TTSFallbackReason: String, Sendable, CaseIterable { case offline, quota, timeout, error, sensitive }
public enum PyWord { public static func sub(_ s: String) -> String }  // == re.sub(r"\W+", "_", s), Python-3 str \w

public enum PyLineCount {
    public static func lines(_ data: Data) -> Int           // "\n", "\r\n", lone "\r" end lines; final unterminated line counts
    public static func codeNative(_ sources: URL) -> (bytes: Int, lines: Int, files: Int)
        // recursive, regular files whose name ends ".swift", no symlink-following descent, sorted walk
}

public enum GitProbe {
    public static func headAndCommits(repo: URL, timeout: Double = 5) -> (head: String, commits: String)
        // /usr/bin/env git -C repo rev-parse --short HEAD ; … rev-list --count HEAD ; stdout trimmed
        // (Python .strip()); either call failing to launch or timing out → ("", "")
}

public final class UsageStore: Sendable {
    public init(url: URL)
    public func bump(_ key: String, by n: Int, day: String) throws(UsageError)
    public func day(_ day: String) -> JSONObject              // usage_today; {} on any failure
}

public protocol SnapshotSources: Sendable {
    func personality() -> JSONValue                   // == personality_load()
    func emotions() throws -> JSONObject              // == _emotions_load() RAW (no decay), key order kept, INCLUDING "at";
                                                      //    builder: emotions = all keys but "at" (py-round 3), emotions_at = raw "at" or null
    func profileFactsCount() throws -> Int
    func correctionsCount() -> Int
    func kbTopicsCount() throws -> Int
    func historyTurns() -> Int                        // in-memory history count of the running process
}
public struct FileSnapshotSources: SnapshotSources {
    public init(here: URL, personalitySeed: JSONValue, emotionBaselines: [(String, Double)],
                historyTurns: @escaping @Sendable () -> Int)
    // file semantics exactly as §2.1; seed + baselines are INJECTED (app: from M1; tests: from golden fixtures)
}

public struct RuntimeInfo: Sendable {
    public var impl = "swift"
    public var build: BuildChannel
    public var version: String?                       // CFBundleShortVersionString, nil without a bundle
    public var sourceCommit: String                   // Info.plist JARVISGitCommit, "" without a bundle
    public var sourceDirty: Bool?                     // Info.plist JARVISGitDirty, nil without a bundle
    public var processStarted: Double
    public var voice: Bool                            // voice pipeline running at snapshot time (false until M9/M12)
    public var claudeEnabled: Bool                    // M3 config (JARVIS_USE_CLAUDE equivalent), not a reachability probe
    public var localModel: String?                    // M3's local-backend id, same string used in backend_local_…
}
public enum MemoryFootprint {
    public static func current() -> (footprint: UInt64, peak: UInt64)?
        // proc_pid_rusage(getpid(), RUSAGE_INFO_V4) → ri_phys_footprint, ri_lifetime_max_phys_footprint
}
public enum HostInfo {
    public static func osVersion() -> (product: String, build: String)  // SystemVersion.plist ProductVersion / ProductBuildVersion
    public static func hwModel() -> String                              // sysctlbyname("hw.model")
    public static func ramBytes() -> UInt64                             // sysctlbyname("hw.memsize")
}

public struct MetricsLog: Sendable {
    public init(url: URL)
    public func lastDate() -> String                  // date of the COMPLETE last line; "" on any failure (§3.4 D2)
    public func append(_ line: String) throws         // single O_APPEND write of line + "\n" (§3.4 D4)
}

public final class FeedbackTracker: Sendable {
    public init(logger: ResearchLogger, clock: any ResearchClock, emotionEvent: @escaping @Sendable (String) -> Void)
    public func track(_ text: String)                 // == track_feedback; state in a Mutex<(text: String, at: Double)>
}

public enum SnapshotOutcome: Sendable, Equatable { case written(date: String), skippedAlreadyToday, failed(String) }

public final class ResearchLogger: Sendable {
    public init(paths: ResearchPaths, clock: any ResearchClock, sources: any SnapshotSources,
                runtime: @escaping @Sendable () -> RuntimeInfo)
    public func bump(_ key: String, by n: Int = 1)      // non-blocking; FIFO on the private serial queue
    public func hourlyCheck() -> SnapshotOutcome        // bump alive_hours, then snapshot if lastDate != today
    public func snapshot() -> SnapshotOutcome           // == research_snapshot() + schema-2 blocks
    public func flush()                                 // queue.sync {} — tests and applicationWillTerminate
}
```

Concurrency: `ResearchLogger` owns one private serial `DispatchQueue(label:
"com.jarvis.assistant.research", qos: .utility)`; every read-modify-write of either file
runs on it (the analogue of `_research_lock`). `bump` is `queue.async` so call order from
one thread is preserved (keys are inserted in first-bump order, like Python) and callers on
the audio/main threads never block on disk. `snapshot`/`hourlyCheck` are `queue.sync` and
are only called from the scheduler's background task. The class is `Sendable` because it
holds only `let` Sendable members. `FeedbackTracker`'s last-command state is a
`Mutex` (Synchronization, macOS 15+). Cross-process exclusion (Python vs native; two
native instances) is M0's guard; M1b adds none (§8 R3).

### 3.3 Snapshot content (native == Python after the §3.7 patch)

Key order: the 8 schema-1 keys exactly as §2.1, then the schema-2 keys appended in this
order: `emotions_at`, `schema`, `runtime`, `code_native`.

```jsonc
{"ts": 1790000000.123, "date": "2026-10-01",
 "code": {"bytes": 0, "lines": 0, "git_head": "abc1234", "git_commits": "212"},  // UNCHANGED meaning: HERE/jarvis.py + repo HEAD
 "personality": {…}, "emotions": {…}, "counts": {…}, "voiceprint_enrolled": false, "usage_today": {…},
 "emotions_at": 1789999000.5,            // the persisted "at" of emotions.json (float) — lets analysts apply decay
 "schema": 2,
 "runtime": {"impl": "swift", "build": "dev", "version": "0.1.0",
             "source_commit": "abc1234", "source_dirty": true, "process_started": 1789990000.0,
             "os": "27.2", "os_build": "26B5091g", "hw_model": "Mac14,7", "ram_bytes": 8589934592,
             "mem_footprint_bytes": 41000000, "mem_footprint_peak_bytes": 52000000,
             "voice": false, "backends": {"claude": true, "local": "<M3 id>"}, "utc_offset": "+0100"},
 "code_native": {"bytes": 0, "lines": 0, "files": 0}}
```

- `runtime.build`: **dev by default.** `release` only when `Info.plist` has
  `JARVISBuildChannel = release`, which only the release path of `scripts/build-app.sh`
  writes (flag `--channel release`, used at M15 cutover). `swift test` / `swift run` / any
  build without the key → `dev`. Bundle id stays `com.jarvis.assistant` for both (user decision).
- `runtime.source_commit` / `source_dirty`: written into Info.plist by `build-app.sh`
  (`git rev-parse --short HEAD`; dirty = `git status --porcelain -- native` non-empty).
- `code.*` stays exactly Python's: native measures `HERE/jarvis.py` and runs the same two
  git commands. After cutover `code.bytes`/`code.lines` freeze by design; `code.git_*`
  keep rising because they were always repo-wide (README states this).
- `code_native`: `native/Sources/**/*.swift`, same line-count rule as `code.lines`.

### 3.4 Deliberate deviations from Python (safer, schema-neutral; each golden-tested)

| id | Python | native |
|---|---|---|
| D1 | unparseable non-empty `usage.json` → `{}` → all past days overwritten | first copies the original bytes to `research/usage.json.corrupt-<unix>` (never overwritten), logs, then writes the Python-identical result |
| D2 | last date from last 8 KB only → ≥8 KB last line ⇒ hourly duplicate rows | reads the complete last line (backwards scan in 8 KB chunks, no limit) |
| D3 | truncate-and-write `usage.json` | temp file in `research/` + `rename(2)`, mode 0644 |
| D4 | appends after a dangling partial line (merges two rows) | if the file is non-empty and its last byte is not `\n`, writes `\n` first; the fragment stays as a skippable malformed line |
| D5 | missing/unreadable `jarvis.py` → exception → no row that day | row written with `code.bytes` and `code.lines` = `null` (git fields as usual) and a log line; README documents it. `jarvis.py` is retained forever (§8 R4) |

Everything else — including "no row" on a corrupt `emotions.json` extra key or a non-dict
`profile.json` — mirrors Python.

### 3.5 Scheduling, lifecycle, text-chat-only operation (`ResearchScheduler`, JarvisApp)

```swift
@MainActor final class ResearchScheduler {
    init(logger: ResearchLogger, build: BuildChannel)
    func start()      // 1) logger.bump(ResearchKey.starts(build:)) at once
                      // 2) Task.detached(priority: .utility) {
                      //      try await Task.sleep(for: .seconds(90), clock: .suspending)
                      //      while !Task.isCancelled { _ = logger.hourlyCheck()
                      //          try await Task.sleep(for: .seconds(3600), clock: .suspending) } }
    func stop()       // cancel; logger.flush()   (called from applicationWillTerminate)
}
```

- Timing == Python: first check ~90 s after launch, then every 3600 s; a check = bump
  `alive_hours`, then snapshot iff the last row's date ≠ today. No extra triggers on wake
  or midnight (rejected: they would move *when* in the day native snapshots are taken
  relative to Python rows, a needless confound). `SuspendingClock` so system sleep does not
  count toward the hour (Python's `time.sleep` behaviour across system sleep: not verified, §8 R8).
- Ownership: the scheduler is created in the app delegate's
  `applicationDidFinishLaunching`, **before and independent of** the voice pipeline, HUD
  and windows. The app is a menu-bar agent that does not quit when its last window closes
  (`applicationShouldTerminateAfterLastWindowClosed` → `false`, M4). Therefore with only
  the text-chat window open — or no window, voice off — the logger still bumps and
  snapshots; `runtime.voice` records `false`, and text commands bump `interactions` +
  `interactions_text`.
- App Nap may coalesce the hourly timer. Acceptance A7 measures tick drift; if a tick is
  late by > 10 min the scheduler takes a `ProcessInfo.beginActivity` token (option chosen
  and verified in that task, §8 R9).

### 3.6 Schema-2 additions — what was accepted, what was rejected, and why

The dissertation question is how a personal assistant evolves; the cutover from Python to
Swift is itself an **intervention** in that time series. The additions below are chosen
so that (a) every row and every day says which implementation/build produced it,
(b) rates have honest denominators, (c) confounds you can't see in the data today
(OS, hardware, memory, configuration) get recorded, and (d) capability growth stays
measurable once `jarvis.py` stops changing.

| addition | where | verdict | justification |
|---|---|---|---|
| `schema: 2` | row | **accept** | Tells you which fields and counters to expect. Without it, an absent counter could mean "zero" or "not measured". |
| `runtime.impl` (`python`/`swift`) | row | **accept** | Needed to separate the two implementations; cutover analysis depends on it. |
| `runtime.build` (`dev`/`release`) | row | **accept** | Dev builds write real data (user decision); this lets analysts exclude or stratify them. Defaults to `dev` so a mislabel can only hide release data, never pass dev data off as release. |
| `runtime.version`, `source_commit`, `source_dirty` | row | **accept** | Ties each row to the code that actually ran. `code.git_head` is repo HEAD when the snapshot is taken, which is not necessarily the running code. |
| `runtime.process_started` | row | **accept** | Uptime at snapshot time, and it tells snapshots taken just after a restart apart from ones in a long session. |
| `runtime.os`, `os_build`, `hw_model`, `ram_bytes` | row | **accept** | Native relies on OS services (SpeechAnalyzer, FoundationModels), so OS updates are real confounds. It also covers a future move to a new Mac. Cheap to read. |
| `runtime.mem_footprint_bytes`, `…_peak_bytes` | row | **accept** | Memory is the stated reason for the rewrite (8 GB). Both implementations read the same kernel ledger through the same API, so the numbers compare directly. Limitation (README): it covers the JARVIS process only, not out-of-process services. |
| `runtime.voice` | row | **accept** | Dev builds may run text-only. Without this flag, zero STT/tone/speaker counters would look like behaviour when they are really absence of the pipeline. |
| `runtime.backends` | row | **accept** | Denominator for "autonomy": a day with no Claude replies because Claude was disabled is different from one where it wasn't chosen. Records configuration only (no probes, no RAM cost). |
| `runtime.utc_offset` | row | **accept** | `date` is local. BST↔GMT (and any travel) moves the day boundary. With this, `ts`↔`date` can be reconstructed. |
| `emotions_at` | row | **accept** | `emotions` holds the last *persisted* values, and today their timestamp is discarded, so the state at `ts` cannot be derived. One float fixes that without building the decay model into the data. |
| `code_native{bytes,lines,files}` | row | **accept** | Capability-growth proxy for the implementation that is actually changing after cutover. `code` itself stays byte-for-byte the same. |
| `starts_<impl>[_<build>]` | counter | **accept** | `usage.json` days have no `runtime` block. This is the only way to know which implementation or build produced a day's counters. Restart frequency also measures stability. |
| `alive_hours` | counter | **accept** | Exposure: interactions per running-hour rather than per calendar day. Removes the biggest confound, which is whether JARVIS was running at all. |
| `fast_path_handled` | counter | **accept** | `interactions` counts only LLM-handled commands. Total command volume and "offline autonomy" need the router's share. |
| `tool_<name>` / `tool_unknown` | counter | **accept** | Shows which of the 46 capabilities are actually used and how that changes. It is also the proper denominator for `emotion_task_fail` (fired only on tool exceptions). Names are the fixed tool set, so the key count is bounded. |
| `interactions_text` | counter | **accept** | Native adds a text modality. Voice vs text use of the same assistant is a first-order dissertation variable. |
| `tts_*` (orchestrator decision) | counter | **accept** | Cloud-voice reliance, failure reasons and privacy routing (`sensitive`). Native-only. |
| `tts_chars_elevenlabs` in **usage.json**, not `runtime` | counter | **decided: usage.json** | It is a per-day accumulating event quantity. Counters sum across restarts and processes; a `runtime` field would be a point-in-time value that resets with the process and is sampled once a day (~90 s after launch), so it would miss nearly all of the day. Quota: the app may *estimate* the month's usage by summing days, but ElevenLabs' own account figure is authoritative (billing cycle ≠ local calendar days; failed requests' billing not verified). |
| gap-marker rows in `metrics.jsonl` | — | **reject** | Breaks the invariant that every line is a snapshot and the last-line-per-date rule, which would give fake dates to existing analysis code. |
| auto-generated gap annotations / `prev_date` field | — | **reject** | Derivable from the dates. The only non-derivable fact is the *reason*, which only a human knows, so annotations are curated (§3.8). |
| response-latency sums | counter | **reject (defer)** | Very valuable, but Python needs streaming-path instrumentation (not a small patch). Native-only numbers would not compare across the cutover, which is the comparison that matters. Revisit in M3/M12 with a design for both. |
| test-suite size | row | **reject** | Measures engineering effort, not assistant capability. |
| git fields inside `code_native` | row | **reject** | Duplicates `code.git_*`, which are already repo-wide. |
| a decayed `emotions_now` | row | **reject** | Builds the decay model into the data. `emotions_at` + documented half-lives is more fundamental. |
| system-wide memory / swap / Ollama RSS | row | **reject** | Implementation-specific and noisy, and it cannot be calibrated between rows. The M15 RAM benchmark measures whole-system cost properly. |
| wake / midnight snapshot triggers | timing | **reject** | Would move native snapshots to a different time of day from Python rows, a needless confound. |

### 3.7 The matching additive Python patch (`jarvis.py`)

Five hunks, **+75 / −1 lines** (the −1 only hoists `_emotions_load()` into a variable;
the values are identical). Verified in this planning session on a scratch copy: it
imports, and a sandboxed `research_snapshot()` produced the 8 schema-1 keys with values
equal to the unpatched function, followed by `emotions_at`, `schema`, `runtime` and
`code_native`, all populated. Every new call is wrapped so it cannot fail the row. Apply
with exact-string edits; each `old` must match exactly once.

H1 — after `_research_lock = threading.Lock()` (2441), insert:

```python
_RESEARCH_START = {}      # schema 2: what is running, captured once when the daily logger starts

def _research_runtime_start():
    try:
        head = subprocess.run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
        dirty = bool(subprocess.run(["git", "-C", HERE, "status", "--porcelain", "--", "jarvis.py"],
                                    capture_output=True, text=True, timeout=5).stdout.strip())
    except Exception:
        head, dirty = "", None
    _RESEARCH_START.update(ts=time.time(), head=head, dirty=dirty)

def _research_runtime() -> dict:
    """Schema 2 `runtime` block: which implementation wrote this row, on what, using how much."""
    rt = {"impl": "python", "build": "release", "version": None,
          "source_commit": _RESEARCH_START.get("head", ""),
          "source_dirty": _RESEARCH_START.get("dirty"),
          "process_started": _RESEARCH_START.get("ts"),
          "os": "", "os_build": "", "hw_model": "", "ram_bytes": None,
          "mem_footprint_bytes": None, "mem_footprint_peak_bytes": None,
          "voice": True, "backends": {"claude": CLAUDE_ENABLED, "local": MODEL},
          "utc_offset": time.strftime("%z")}
    try:
        import plistlib
        with open("/System/Library/CoreServices/SystemVersion.plist", "rb") as f:
            sv = plistlib.load(f)
        rt["os"], rt["os_build"] = sv.get("ProductVersion", ""), sv.get("ProductBuildVersion", "")
    except Exception:
        pass
    try:
        hw = subprocess.run(["sysctl", "-n", "hw.model", "hw.memsize"],
                            capture_output=True, text=True, timeout=5).stdout.split()
        rt["hw_model"], rt["ram_bytes"] = hw[0], int(hw[1])
    except Exception:
        pass
    try:   # same kernel ledger the native build reads: proc_pid_rusage(RUSAGE_INFO_V4)
        import ctypes, struct
        buf = ctypes.create_string_buffer(512)
        if ctypes.CDLL(None).proc_pid_rusage(os.getpid(), 4, buf) == 0:
            rt["mem_footprint_bytes"] = struct.unpack_from("<Q", buf, 72)[0]        # ri_phys_footprint
            rt["mem_footprint_peak_bytes"] = struct.unpack_from("<Q", buf, 240)[0]  # ri_lifetime_max_phys_footprint
    except Exception:
        pass
    return rt

def _research_code_native() -> dict:
    """Schema 2 `code_native`: size of the Swift rewrite (native/Sources/**/*.swift)."""
    b = l = n = 0
    try:
        for dp, dn, fn in os.walk(os.path.join(HERE, "native", "Sources")):
            dn.sort()
            for name in sorted(fn):
                p = os.path.join(dp, name)
                if name.endswith(".swift") and os.path.isfile(p) and not os.path.islink(p):
                    with open(p, encoding="utf-8", errors="replace") as f:
                        l += sum(1 for _ in f)
                    b += os.path.getsize(p); n += 1
    except Exception:
        pass
    return {"bytes": b, "lines": l, "files": n}
```

(Offsets 72/240 come from `struct rusage_info_v4` in the SDK's `sys/resource.h`: a
16-byte uuid, then `uint64_t` fields; `ri_phys_footprint` is field 7 and
`ri_lifetime_max_phys_footprint` is field 28. `RUSAGE_INFO_V4` is `4`.)

H2 — in `research_snapshot` (2476–2514): after `p = personality_load()` insert
`emo = _emotions_load()`; replace `_emotions_load().items()` with `emo.items()`; replace

```python
            "usage_today": usage_today,
        }
```
with
```python
            "usage_today": usage_today,
            # schema 2 (additive, 2026): see research/README.md
            "emotions_at": emo.get("at"),
            "schema": 2,
            "runtime": _research_runtime(),
            "code_native": _research_code_native(),
        }
```

H3 — `research_log_loop` (2561–2570): before `time.sleep(90)` insert
`_research_runtime_start()` and `research_bump("starts_python")`. As the first statement
inside the loop's `try:` insert `research_bump("alive_hours")`.

H4 — `handle_one` (5548), immediately after `fp = fast_path(command)` (5567):
```python
        if fp is not None:
            research_bump("fast_path_handled")   # schema 2: answered offline, never an interaction
```

H5 — immediately before `def execute_tool(name: str, args: dict) -> str:` (4180) insert
`_TOOL_NAMES = {t["function"]["name"] for t in TOOLS}`; as the first statement of
`execute_tool` (before `try:`) insert
`research_bump("tool_" + (name if name in _TOOL_NAMES else "unknown"))   # schema 2`.

`runtime.build` for Python is the constant `"release"`, because Python is the
production assistant until cutover. After cutover `jarvis.py` is frozen and M0's guard
keeps it from running beside native (§8 R5).

### 3.8 Gap documentation — `research/annotations.jsonl` (new, curated)

One JSON object per line, append-only; for a given `id` the **last line wins** (the same
rule as `metrics.jsonl`). Keys: `id` (stable), `kind` (`gap` | `intervention` |
`incident` | `note`), `from`/`to` (YYYY-MM-DD, inclusive, `to: null` = open until the day
before the next `metrics.jsonl` row) or `date`, `text`, `recorded` (YYYY-MM-DD), `by`.
Written by hand or by a task with the user's approval. Code never auto-writes it, except
D1 incidents, which the app may append as `kind: "incident"`.

Initial lines (task T9, needs the user's go-ahead to touch `research/`):

```json
{"id": "gap-2026-08-21", "kind": "gap", "from": "2026-08-21", "to": null, "text": "Python JARVIS deliberately stopped (8 GB RAM) while the native Swift rewrite is built. No snapshots and no counters were recorded. Nothing has been backfilled. Closes on the day before the next metrics row.", "recorded": "<T9 date>", "by": "user"}
{"id": "pre-gap-absent-days", "kind": "note", "from": "2026-07-23", "to": "2026-08-20", "text": "15 rows over 29 days. The 14 days without a row are days JARVIS was not running (rows are written only while running). Reasons were not recorded.", "recorded": "<T9 date>", "by": "user"}
{"id": "schema-2", "kind": "intervention", "date": "<date the §3.7 patch lands>", "text": "Schema 2 additive fields (emotions_at, schema, runtime, code_native) and counters (starts_*, alive_hours, fast_path_handled, tool_*) added to jarvis.py; native emits the same.", "recorded": "<T9 date>", "by": "user"}
```

Later interventions, same format: `native-dev-writes` (the first day a dev build writes
real data, T10) and `cutover` (M15, `impl` switches to swift/release).

### 3.9 README.md — additive text (append verbatim after "Suggested analyses"; nothing above it changes)

```markdown
## Schema 2 (additive; from 2026-09, native JARVIS)

Nothing above has changed meaning. Schema 2 only **adds** keys and counters. Every
schema-1 field is still written by both implementations, with the same name, type and
meaning.

### Which implementation wrote a row
- A row **without** `schema` is schema 1 and was written by Python JARVIS (all rows
  2026-07-23 → 2026-08-20).
- A row with `"schema": 2` has a `runtime` block:
  - `impl`: `"python"` (jarvis.py) or `"swift"` (the native macOS app).
  - `build`: `"release"` (the installed production assistant) or `"dev"` (a development
    build of the native app). Python rows are always `"release"`. Dev builds share the
    real state and write this dataset on purpose, so development use counts as real use,
    but they may be incomplete. Exclude `build == "dev"` for production-only analyses, or
    treat it as a transition phase.
  - `version`, `source_commit`, `source_dirty`: the code that was running (native: set at
    build time; python: git HEAD and whether jarvis.py had uncommitted changes when the
    process started).
  - `process_started`: unix time the logger started (≈ process start).
  - `os`, `os_build`, `hw_model`, `ram_bytes`: platform confounds (OS updates change the
    system speech and language-model services the native app uses).
  - `mem_footprint_bytes`, `mem_footprint_peak_bytes`: this JARVIS process's physical
    footprint now and its lifetime peak (kernel `phys_footprint` ledger, read with the same
    API in both). Out-of-process services are excluded (Ollama for python; system
    speech/FoundationModels daemons for swift). Use the cutover RAM benchmark for
    whole-system cost.
  - `voice`: whether the voice pipeline was running at snapshot time. Native dev builds
    can run text-chat only; then STT/tone/speaker counters are absent because nothing was
    listening.
  - `backends`: `claude` = Claude enabled in configuration; `local` = the configured
    local fallback model. Configuration, not reachability.
  - `utc_offset`: the local offset behind `date` (e.g. `+0100` in BST).
- `emotions_at`: the timestamp of the persisted `emotions` values. `emotions` is the last
  *persisted* state, not decayed to `ts`. To get the state at `ts`, decay it with the
  half-lives in jarvis.py `_EMO_DIMS`.
- `code_native`: `bytes`, `lines`, `files` of `native/Sources/**/*.swift`, the
  capability-growth proxy for the native implementation. `code` keeps its exact meaning
  (jarvis.py plus repo-wide git). After cutover jarvis.py is frozen, so `code.bytes` and
  `code.lines` stop moving, while `code.git_head` and `code.git_commits` keep counting
  repo commits (they always did). If jarvis.py is ever missing, native rows carry
  `code.bytes` / `code.lines` = `null`.

### Counters that already existed but were not listed above
- `speaker_pass` / `speaker_reject`: speaker-verification decisions on every gated clip
  (wake, command, follow-up). A foreign-voice wake bumps **both** `speaker_reject` and
  `wake_rejected_foreign_voice`.
- `emotion_user_urgent` (hurried tone) and `emotion_corrected` (always bumped together with
  `user_correction`).
- Exact `tone_*` names: `tone_hurried_and_tense`, `tone_clipped`,
  `tone_animated_and_upbeat`, `tone_quiet_and_subdued`, `tone_calm_and_even`.
- `backend_*` names are the sanitised backend label: `backend_claude`,
  `backend_claude_partial_`, `backend_local_qwen2_5_3b_` (the trailing underscore is real).
  The native local fallback shows up under a new `backend_local_…` name.

### New counters (schema 2)
| counter | meaning | python | swift |
|---|---|---|---|
| `starts_python`, `starts_swift_dev`, `starts_swift_release` | process starts per implementation/build: which implementation(s) produced the day's counters, and restarts | yes | yes |
| `alive_hours` | hourly liveness checks (the first ~90 s after start) ≈ awake hours running; the exposure denominator | yes | yes |
| `fast_path_handled` | commands answered by the offline router (not in `interactions`); total commands = `interactions + fast_path_handled` | yes | yes |
| `tool_<name>`, `tool_unknown` | tool calls dispatched, by tool (`unknown` = not a known tool name); denominator for `emotion_task_fail` | yes | yes |
| `interactions_text` | typed chat commands (a subset of `interactions`) | no text input: always 0 | yes |
| `tts_elevenlabs`, `tts_piper` | replies synthesised by each engine | not counted (python used Piper only) | yes |
| `tts_fallback_offline`, `_quota`, `_timeout`, `_error`, `_sensitive` | ElevenLabs-bound replies sent to Piper, by reason (`sensitive` = privacy routing, not a failure) | — | yes |
| `tts_chars_elevenlabs` | characters (Unicode scalars) of text sent to ElevenLabs: cloud-voice reliance and privacy exposure | — | yes |

A day's counters come from schema-2 code iff it has any `starts_*` or `alive_hours`
counter. On earlier days the new counters are missing because they were not measured,
not because they were zero. Implementation mix for a day: its `starts_*` counters.

### Instrument changes at the Python → Swift switch
These counters keep their names and meanings, but the detector underneath changes:
`stt_segments_dropped` (Whisper segment confidence → SpeechTranscriber confidence),
`speaker_*` (PyTorch Resemblyzer → ONNX port), `wake_*` (openWakeWord, new runtime) and
`tone_*` (same heuristics, new audio front-end). Compare them within `runtime.impl`, or
model the cutover as an intervention (`annotations.jsonl`, id `cutover`).

### Known gaps and interventions — `annotations.jsonl`
Curated, append-only JSON lines. The last line wins per `id`. `kind` is gap, intervention,
incident or note. `to: null` means open until the day before the next `metrics.jsonl` row.
**Nothing is ever backfilled.**
- **2026-08-21 → (next row): no data.** Python JARVIS was deliberately stopped to free RAM
  while the native rewrite was built. No snapshots, no counters.
- 2026-07-23 → 2026-08-20: 15 rows over 29 days. Missing days are days JARVIS was not
  running.

### Analysis rules added by schema 2
1. Last line per `date` still wins. Treat rows without `schema` as `schema 1, impl python,
   build release`.
2. Production-only series: `impl == "python"` before cutover, `impl == "swift" and build ==
   "release"` after. Drop `build == "dev"`.
3. Rates: divide by `alive_hours` (exposure) where present, and by `interactions +
   fast_path_handled` for per-command rates.
4. Files named `usage.json.corrupt-<unix>` are preserved originals of a corrupted counter
   file (native never overwrites them). Merge them by hand if they appear.
```

### 3.10 How an analyst tells rows and days apart (summary)

| question | rows (`metrics.jsonl`) | days (`usage.json`) |
|---|---|---|
| python or swift? | `runtime.impl`; no `schema` ⇒ python | `starts_python` vs `starts_swift_*` present (both ⇒ mixed day) |
| dev or release? | `runtime.build` | `starts_swift_dev` vs `starts_swift_release` |
| instrumentation level | `schema` (absent = 1) | any `starts_*`/`alive_hours` ⇒ schema-2 counters present |
| was the voice pipeline up? | `runtime.voice` | STT/tone/speaker counters > 0 (absence is uninformative) |
| gap or quiet day? | `annotations.jsonl` + row absence | `alive_hours` present ⇒ running |
## 4. Golden vectors

Generator: `native/tools/golden_research.py`, run as `tools/golden.py research` (M0
harness). It imports `jarvis.py` (the **patched** one for schema-2 cases; schema-1 cases
are generated with the §3.7 blocks stripped from the output, so they equal the unpatched
behaviour), then reassigns `RESEARCH_DIR/RESEARCH_METRICS/RESEARCH_USAGE`, every
`*_FILE`/`CORR_FILE`/`HIST_FILE`/`VOICEPRINT_FILE`, `HERE`, `_corr_cache = None` and
`_history` into a fresh `tempfile.mkdtemp()` per case. Time: `jarvis.time = Shim(ts)`,
where `Shim.time()` returns `ts`, `Shim.strftime(fmt, t=None)` is
`real.strftime(fmt, real.localtime(ts if t is None else t))`, `Shim.sleep` raises, and
everything else is proxied. Timezone: `os.environ["TZ"] = case.tz; time.tzset()`.
`research_bump`/`emotion_event` are wrapped (not replaced) to record call order. Every
fixture carries `{"generator": "golden_research.py", "jarvis_py_sha256": …, "python":
"3.14.x", "created": …}`. Bytes are stored base64 (`*_b64`) wherever byte-exactness
matters.

Dir `native/Tests/Fixtures/golden/research/`:

| fixture | Python function(s) | input corpus | shape |
|---|---|---|---|
| `bump.json` | `research_bump` | sequences over a missing file, `{}`, real-shaped multi-day files (days out of order, non-ASCII key, float counter `2.0`, `true` counter), a day rollover at local midnight Europe/London (BST and GMT), plus non-dict root `[]`, non-dict day value, non-numeric counter (Python: no write), truncated JSON, and empty file (Python: wipe → D1) | `{cases:[{name, tz, initial_b64\|null, steps:[{ts,key,n}], final_b64\|null, python_wrote: bool, deviation: null\|"D1"}]}` |
| `keys.json` | the three sanitiser expressions at 1056 / 2351 / 4855, evaluated by calling `set_tone`, `_set_backend` and `emotion_event` with `research_bump` recorded | backend labels: `"claude"`, `"claude (partial)"`, `"claude (claude-opus-5-5)"`, `"local (qwen2.5:3b)"`, `"local (Apple FM)"`, `"  X--y  "`, `"Émile (ä)"`, `"á"`, `"x²"`, `"٣"`, `"😀"`, `"İ"`, `""`; tone: the 5 `analyze_tone` strings plus `""`, `" a , b"`, `"ß-x"`; every `_EMO_DELTAS` key plus `"task_ok"` and `"nope"` (no bump) | `{backend:[{in,out}], tone:[{in,out\|null}], emotion:[{in,out\|null}]}` |
| `feedback.json` | `track_feedback` | ~40 steps: each NEG alternative, case variants, curly apostrophe `that’s wrong` (expect no match), near-rephrases at 29.9 s / 30.1 s, an exact repeat, ratio at about 0.65, >200-char strings (autojunk) | `{steps:[{ts, text, bumps:[…], emotions:[…]}]}` |
| `sequence_matcher.json` | `difflib.SequenceMatcher(None,a,b).ratio()` | 60 pairs incl. empty, unicode, ≥200 chars | `[{a,b,ratio}]` (skip if M1 ships an equivalent fixture; reuse it) |
| `snapshot.json` | `research_snapshot` | 12 sandboxes: all files missing (seed + baselines); real-shaped state files with non-ASCII notes and emoji; emotions with int values, extra numeric key, **no `at`**, a missing dim (baseline path); profile without `facts`; KB without `topics`; corrections with invalid entries; `history.json` with 14 turns incl. a `tool` role; voiceprint present; `jarvis.py` stand-ins with CRLF / lone CR / no final newline; a deterministic git repo; a non-repo dir (git fields `""`). Failure cases: emotions extra key is a string, `profile.json` is a list (expect no row). D5: `jarvis.py` absent. | `{cases:[{name, tz, ts, files:{relpath:b64}, git:"fixture"\|"none", history_turns, expect_line_b64\|null, expect_error: bool, deviation}]}`. `runtime`/`code_native` values are environment-dependent, so they are **not** compared byte-wise; the Swift test injects a fixed `RuntimeInfo` and compares all other keys byte-for-byte, plus the key order and types of `runtime`. |
| `git_fixture.sh` | — | builds the repo: `git init`, 3 commits with fixed `GIT_AUTHOR/COMMITTER_{NAME,EMAIL,DATE}` | the generator and the Swift test run the same script, so the short hash and `"3"` must match |
| `line_count.json` | `sum(1 for _ in open(p))` (and the `errors="replace"` variant for `code_native`) | blobs: empty, `a`, `a\n`, `a\r\nb`, `a\rb\r`, `\r\r\n`, `\n\n`, UTF-8 multibyte, invalid UTF-8 (replace variant only), a 70 KB mix; one tree for `_research_code_native` (nested dirs, `.swift` / `.swiftx` / symlink / hidden file) | `{blobs:[{b64, lines}], tree:{files:{rel:b64}, symlinks:{rel:target}, expect:{bytes,lines,files}}}` |
| `last_date.json` | `_research_last_date` | missing file, empty, 1 row, last row malformed, trailing blank lines, CRLF, last row 9,000 bytes (D2), a >8 KB file with a short last row | `{cases:[{name, b64, python, native, deviation}]}`. `native` is taken from the date the generator wrote into that line, not typed by hand. |
| `pyjson.json` | `json.dumps(v)`, `json.dumps(v, indent=1)`, `round(x, 3)` | floats: `0.0`, `-0.0`, `1e-05`, `1e16`, `1e+22`, `1790000000.1234567`, `0.1+0.2`, `5e-324`; ties for round: `0.0625`, `0.6125`, `2.675`, `0.9995`, `1` (int); strings with `"`, `\`, `/`, control chars, ` `, emoji; nested empty `{}` / `[]` at indent 1 | `[{v_b64 (json text), dumps, dumps_indent1}]`, `[{x, round3_repr}]` (skip what M1 already covers) |
| `tz.json` | `Shim.strftime("%Y-%m-%d")`, `("%z")` | Europe/London across 2026-10-25 01:00 UTC and 2027-03-28; Asia/Kolkata; America/St_Johns | `[{tz, ts, date, z}]` |
| `personality_seed.json`, `emotion_baselines.json` | `json.dumps(_PERSONALITY_SEED)`, `{k: b for k,(b,_) in _EMO_DIMS.items()}` | — | injected into `FileSnapshotSources` by tests |

**Schema-compat check over the REAL dataset (read-only).**
(a) `native/tools/research_schema_check.py`: opens both files `"rb"` and prints only
aggregates. For every row it asserts the 8 schema-1 keys are present **first and in
order**, with the types seen today (`ts` float, `date` str, `code.*` int,int,str,str,
`emotions.*` numbers, `counts.*` int, `voiceprint_enrolled` bool, dicts elsewhere).
Schema-2 rows may only add keys from {`emotions_at`, `schema`, `runtime`,
`code_native`}. Dates are valid and non-decreasing. `usage.json` days are YYYY-MM-DD and
every counter is an int. Every counter name either appears in the §2.3 catalogue or
matches a declared dynamic prefix (`backend_`, `emotion_`, `tone_`, `tool_`,
`tts_fallback_`, `starts_`). It exits non-zero on any violation. It records sha256 and
mtime before and after and asserts both unchanged.
(b) Swift `RealDatasetCompatTests` (runs only when `JARVIS_REAL_DATASET=1`; otherwise
skipped): for every real row, `PyJSON.dumps(PyJSON.loads(line)) == line` byte-for-byte;
`PyJSON.dumps(PyJSON.loads(usage), indent: 1) == usage` byte-for-byte;
`MetricsLog.lastDate()` equals the check script's last date; files are unchanged
(sha256 + mtime). This shows native can read and rewrite the real files without
reformatting a single byte.

## 5. Acceptance checks

Run from `~/jarvis/native`. `PY=/Library/Frameworks/Python.framework/Versions/3.14/bin/python3`.

| id | command | observable proof |
|---|---|---|
| A1 | `$PY tools/golden.py research && git status --porcelain Tests/Fixtures/golden/research` | 11 fixtures + `git_fixture.sh` exist; re-running produces no diff apart from `created` |
| A2 | `swift test --filter ResearchGoldenTests` | green; the output lists each fixture with its case count; zero skips |
| A3 | `$PY tools/research_schema_check.py ../research` | prints `rows 15 dates 15 first 2026-07-23 last 2026-08-20 violations 0 unchanged yes` (counts grow once new rows exist) and exits 0 |
| A4 | `JARVIS_REAL_DATASET=1 swift test --filter RealDatasetCompatTests` | green; logs `roundtrip rows=N/N usage=identical unchanged=yes` |
| A5 | `swift test --filter ResearchLoggerTests` | green. Covers D1–D5, FIFO order of 1,000 concurrent bumps (sum exact, first-bump key order), `hourlyCheck` idempotent within a day, the snapshot written in a temp sandbox, the TTS invariant helper, and that no test path resolves under `~/jarvis/research` (assert on every URL) |
| A6 | `swift test --filter MemoryFootprintTests` | green; `proc_pid_rusage` footprint within 10 % of `task_info(TASK_VM_INFO).phys_footprint` sampled back-to-back; peak ≥ footprint > 0 |
| A7 | dev app launch with `JARVIS_RESEARCH_TICK=60` (debug-only env override: 90 s then 60 s), text-chat window only, voice off, 10 min | log shows `starts_swift_dev` at launch, then ticks at ~90 s and every ~60 s (drift < 10 s each); on the real dataset (dev shares real state), exactly **one** new row for today with `runtime.impl=="swift"`, `build=="dev"`, `voice==false`; `research_schema_check.py` still reports 0 violations |
| A8 | Python patch: `$PY -c "import ast;ast.parse(open('../jarvis.py').read())"`, then the sandboxed oracle case `snapshot.json:all-missing` regenerated from the patched file | parses; the fixture's schema-1 bytes are identical to those from the pre-patch file (`git stash`-free: generator strips schema-2 keys and compares); `git diff --stat ../jarvis.py` shows `+75 −1` |
| A9 | `grep -c 'Schema 2 (additive' ../research/README.md; tail -n 3 ../research/annotations.jsonl \| $PY -m json.tool --json-lines >/dev/null && echo ok` | `1` and `ok`; `git diff` of README shows additions only (`git diff --numstat` deleted = 0; README is gitignored, so compare against a copy saved before editing) |

## 6. Executor tasks

Each executor keeps a worklog (one line per step) and never opens real files in
`research/` except where the task says so. Tests use sandboxes only.

| # | task (≤ ~2 h) | files | spec | verification | deps |
|---|---|---|---|---|---|
| T1 | JSON layer if M1 has not shipped it: `JSONValue`, `JSONObject`, `PyJSON.loads/dumps(indent:)`, `pyRound(_:3)` | `Sources/JarvisCore/Store/JSONValue.swift`, `PyJSON.swift` | §3.1 interface; floats via shortest round-trip digits formatted with Python repr rules; round via `%.3f` then parse (both correctly rounded, ties-to-even on the exact binary value) | `pyjson.json` golden green | M0 harness; check M1 first |
| T2 | Oracle generator | `tools/golden_research.py`, register a `research` subcommand in `tools/golden.py`, `Tests/Fixtures/golden/research/*` | §4 table; sandbox + time shim + TZ; strip-schema-2 mode | A1; spot-check one fixture against a manual `$PY -c` call | M0 golden.py |
| T3 | Keys, line count, git, paths, clock | `ResearchKey.swift`, `PyLineCount.swift`, `GitProbe.swift`, `ResearchPaths.swift`, `ResearchClock.swift` | §3.2; `PyWord.sub` uses Python-3 `\w` = scalars in L*/N* general categories or `_`; `lowercased()` must match `str.lower()` on the corpus | `keys.json`, `line_count.json`, `tz.json`, `git_fixture.sh` goldens green | T1, T2 |
| T4 | UsageStore + MetricsLog incl. D1–D4 | `UsageStore.swift`, `MetricsLog.swift` | §2.1 semantics; byte-identical output; atomic rename; quarantine name `usage.json.corrupt-<Int(now)>` | `bump.json`, `last_date.json` green; D1–D4 unit tests | T1–T3 |
| T5 | Snapshot sources + builder + runtime/host/memory | `SnapshotSources.swift`, `SnapshotBuilder.swift`, `RuntimeInfo.swift` | §3.3 key order; emotions raw + `emotions_at`; D5; failure cases → `.failed`, no row | `snapshot.json` green; A6 | T4 |
| T6 | FeedbackTracker + ResearchLogger façade | `FeedbackTracker.swift`, `ResearchLogger.swift` | §3.2 concurrency; `hourlyCheck` = bump `alive_hours` then conditional snapshot | `feedback.json` green; A5 | T5; M1 SequenceMatcher (or build it here with `sequence_matcher.json`) |
| T7 | Schema-compat tooling | `tools/research_schema_check.py`, `Tests/JarvisCoreTests/Research/RealDatasetCompatTests.swift` | §4 compat check; aggregates only; sha256/mtime guard | A3, A4 | T1, T4 |
| T8 | Python patch H1–H5 + regenerate schema-2 fixtures | `../jarvis.py` | §3.7 exactly; do not start JARVIS; commit on the jarvis repo's working branch with the `.githooks` pre-commit active | A8; pre-commit hook passes | T2; user OK to edit jarvis.py |
| T9 | README additive section + `annotations.jsonl` initial lines | `../research/README.md`, `../research/annotations.jsonl` (both gitignored — no commit) | §3.8 lines, §3.9 text verbatim; back up README to the scratchpad first | A9 | T8 landed (fill the `schema-2` date); **explicit user go-ahead to write in research/** |
| T10 | ResearchScheduler in the app + Info.plist keys | `Sources/JarvisApp/Research/ResearchScheduler.swift`, `scripts/build-app.sh` (add `JARVISBuildChannel` default `dev`, `JARVISGitCommit`, `JARVISGitDirty`) | §3.5; `JARVIS_RESEARCH_TICK` honoured only when channel is dev; append the `native-dev-writes` annotation on first real run (with user OK) | A7 (screenshot of the log plus the check-script output) | T6, M0 guard, M4 app shell |

Emitter wiring is **not** an M1b task. Each milestone (M3, M4, M7, M8, M9, M10, M11,
M12, M1 emotions) must call `ResearchKey.*`, and its acceptance checks must include one
bump test against a sandboxed `ResearchLogger`.

## 7. RAM / permissions

- RAM: the logger is idle except for one check per hour. A snapshot spawns `git` twice
  (≈ a few MB for < 1 s) and walks `native/Sources`. Steady state is expected at < 1 MB
  (not measured; A6/A7 record the footprint in the row itself). The oracle imports
  `jarvis.py` at a measured **43 MB footprint** (this session, sandboxed snapshot). Run
  fixture generation one process at a time. Swift builds and tests are the main cost:
  run them with nothing else heavy open, and never beside Python JARVIS (not started
  anywhere in this plan).
- Permissions: no TCC prompts. Only files under `~/jarvis` are touched, plus `sysctl` and
  `proc_pid_rusage` on its own pid. The app is not sandboxed (repo-root state files,
  ROADMAP rule 3). Writing real `research/` happens only in T9 (user go-ahead) and when
  a dev build runs (user decision: shared real state).
- No package installs; Python stdlib only (`ctypes`, `plistlib`, `struct`, `difflib`).

## 8. Risks and open questions

| id | risk / question | mitigation / recommendation |
|---|---|---|
| R1 | M1 has not published the `JSONValue`/`PyJSON` interface yet (its plan file was an empty template when this was written) | T1 builds it to §3.1. The judge should reconcile the M1 and M1b plans so there is only one encoder. |
| R2 | Byte-identical Python float `repr` in Swift (exponent thresholds differ: Python switches at 1e16 and <1e-4) | `pyjson.json` corpus. Round-trip every real row (A4). |
| R3 | Python+native or two native instances writing concurrently → lost updates (Python's lock is per-process only) | Relies on M0's guard. If M0 slips, add an `flock` on `research/.lock` in T4. |
| R4 | D5: after cutover someone deletes `jarvis.py` → `code.bytes/lines` become `null` (type widening) | Rule: `jarvis.py` stays in the repo forever (add it to ROADMAP at M15). |
| R5 | `runtime.build = "release"` for Python is a convention (Python has no builds); a post-cutover manual Python run would be labelled release | M0 guard plus the frozen `jarvis.py`. Alternative for the user to decide: `"source"`, which breaks the dev/release enum. |
| R6 | Instrument changes at cutover (`stt_segments_dropped`, `speaker_*`, `wake_*`, `tone_*`) | Documented in README §"Instrument changes". Stratify by `runtime.impl`. |
| R7 | The Python patch touches 4 places, not only the snapshot writer (H3 loop, H4 `handle_one`, H5 `execute_tool`) | Each hunk is one line and optional. If the user drops H4/H5, `fast_path_handled`/`tool_*` become swift-only, and the README table must say so. |
| R8 | Python `time.sleep` across system sleep (does the hour pause?) is not verified, so `alive_hours` may not mean exactly the same in both implementations | Native uses `SuspendingClock`. If a comparison needs it, measure Python on a short sleep test. |
| R9 | App Nap delaying the hourly check in an agent app with no windows | A7 measures drift. `beginActivity` option not yet verified. |
| R10 | Python's `research_bump` wipe hazard (D1) remains in Python itself | Optional one-line hardening of Python (copy aside before overwrite). Not included, because it is not additive-schema work: user's call. |
| R11 | `_research_last_date` 8 KB bug in Python. Schema-2 adds ~500 bytes per row (measured 503 on a sandbox row), so Python rows reach 8 KB sooner (max today 4,110) | Python is parked. If Python runs long after schema 2, apply the same full-line read (behaviour-only fix). |
| R12 | `tts_chars_elevenlabs` counts characters *sent*, not *billed*; ElevenLabs' character counting is not verified | README says "sent". Use the account API for quota. |
| R13 | TTS counting path for the `say` fallback (Piper fails) is undefined | M8 to decide: probably count it under `tts_piper`'s sibling `tts_say` (a new additive name). Flagged for the orchestrator. |
| R14 | `counts.corrections`: Python counts its process cache; native counts the file. They diverge only if the file is edited externally mid-run | Accepted. Noted in the tests. |
| R15 | The README text in §3.9 contains `##` headings inside a fenced block; a naive heading parser may misread the plan | Content is fenced; copy between the fences only. |
