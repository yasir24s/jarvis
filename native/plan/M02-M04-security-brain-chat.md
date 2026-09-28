# M2, M3, M4 — Security choke point, Claude/FoundationModels brain, text chat
## 1. Goal and scope (in / explicitly out)

**Goal.** Three milestones that turn the M1 core into a working, guarded brain with a
typed front-end:

- **M2 — Security.** Port every Python guard (shell risk tiers, sudo allowlist, AppleScript
  deny, path classes, AppleScript escaping, delete/move/write tiering, the 25 s
  confirmation gate, the prompt-injection taint guard) and put them behind **one choke
  point**, `ToolGateway.call(...)`. No tool can be reached from the model, the MCP socket,
  the FoundationModels fallback, the fast-path router or the UI without passing through
  it. The compiler enforces this: tool implementations are `internal` to `JarvisTools`,
  and the gateway is the only `public` entry point.
- **M3 — Brain.** A Claude CLI driver (`claude -p`, stream-json in and out, subscription
  OAuth only, explicit allowlisted child environment), an MCP tool server that runs **inside
  the app process** and is reached through a stdio relay (the app binary in
  `--mcp-relay` mode) and a 0600 Unix socket, a FoundationModels fallback that uses the
  same gateway, backend reporting and research counters, and one conversation history
  shared by voice and text.
- **M4 — Text chat.** An `LSUIElement` agent app with a `MenuBarExtra` and a SwiftUI chat
  window, streamed rendering, a text-channel system-prompt addendum, a typed confirmation
  gate authenticated with LocalAuthentication, a user-owned `shouldSpeakReply` policy
  hook, and additive dataset counters for the text channel.

**In scope**
- `JarvisCore/Security/*`: pure, Foundation-only guard functions, golden-tested against
  Python (`_shell_risk`, `_dangerous_applescript`, `_in_home`, `_is_system_path`,
  `_sensitive_path`, `_as_escape`, `_AFFIRM_RE`, the taint sets, the delete/move/write
  tier decisions).
- `JarvisCore/Security/ShellSegmenter.swift`: a **deliberate deviation**. It closes the
  sudo-chaining gap the orchestrator verified (see §2.3 and §8 D-1).
- `JarvisTools/Gateway/*`: `ToolGateway`, `TurnContext` (taint flag, **data sources
  touched**, tool-run log), `ConfirmationGate` (one global slot, 25 s, one-shot).
- `JarvisBrain/*`: `ClaudeDriver`, `StreamJSONParser`, `SentenceSplitter` (the
  `pop_sentences` port), `ClaudeReason` (the `_claude_reason` port), `MCPServer` (a
  JSON-RPC subset), `MCPRelay`, `LocalBrain` (FoundationModels), `BrainRouter`
  (`process_command` pipeline), `BackendReporter`.
- `JarvisApp/Chat/*`, `JarvisApp/MenuBar/*`, `JarvisApp/Relay/RelayMain.swift`, and the
  `--mcp-relay` argv dispatch in `main.swift`.
- `ChildEnvironment`: the child env is an **explicit allowlist**. It never includes
  ANTHROPIC_API_KEY or the ElevenLabs key.
- Golden fixtures for everything deterministic listed above, including the attack corpora
  and the Python-behaviour record of the sudo-chaining gap.

**Explicitly out of scope** (owned elsewhere; this plan uses their interfaces)
- The 46 tool bodies (M5/M6). M5 owns the registry *contents*; this plan owns the
  gateway and the `ToolImpl` protocol the registry must satisfy (§3.4).
- System-prompt assembly (`SYSTEM_PROMPT + personality_context() + … + kb_context()`),
  `HistoryStore`, `research_bump` storage, and the emotions/profile/KB side effects in
  `process_command` (M1/M1b). This plan calls those APIs in Python's order.
- The fast-path router (M7). It calls the gateway with `origin: .fastPath`.
- The voice loop, speaker verification and TTS (M8–M12). This plan defines the hooks
  they call: `ConfirmationGate.consume(_:channel:)`, `TurnContext.dataSources`,
  `SpeechSink`.
- The HUD (M13).
- `run_powershell` and all `IS_WIN` branches.
- Installing `/etc/sudoers.d/jarvis`. It is **not installed on this machine**
  (`/etc/sudoers.d/` is empty, checked 2026-09-28). This plan only *reads* it if present.
## 2. Python reference

All line numbers are for `jarvis.py` as of 2026-09-28 (5,762 lines). The code blocks below
were **copied programmatically from the source lines named**, not retyped. §5 check A-0
re-asserts that each block is a substring of `jarvis.py`.

### 2.1 Table

| function / constant | jarvis.py lines | behaviour | notes |
|---|---|---|---|
| `_SHELL_BLOCK` | 1153-1166 | Alternation of catastrophic patterns, `re.IGNORECASE`. Match means **block**, even with confirmation. | Includes Windows patterns. Port them anyway: they are cheap and only make native stricter. |
| `_SHELL_CONFIRM` | 1167-1173 | Destructive-but-allowable patterns, `re.IGNORECASE`. Match means **confirm**. | |
| `_SUDO_ALLOW` | 1176-1183 | Bounded sudo allowlist. Every entry is anchored `^sudo\s+…`, `re.IGNORECASE`. | **Gap:** only the first command of a chained line is checked (§2.3). `^sudo\s+periodic` is dead: `/usr/sbin/periodic` is absent on macOS 27.2 (checked). The comment says it "mirrors /etc/sudoers.d/jarvis". That file is **not installed** here (§8 R-3). |
| `_shell_risk(cmd)` | 1185-1193 | `strip()`, then: BLOCK match → `"block"`; else `\bsudo\b` present → `"confirm"` if `_SUDO_ALLOW.search` else `"block"`; else CONFIRM match → `"confirm"`; else `"ok"`. | The order matters and is golden-tested. `None` becomes `""`. |
| `_dangerous_shell` | 1195-1196 | `_shell_risk == "block"`. | Windows-only caller. Port it as a helper. |
| `_pending_action`, `_CONFIRM_TIMEOUT`, `_AFFIRM_RE` | 1202-1205 | One global slot `{fn, desc, at}`. Timeout is 25 s. The affirmation regex is `re.I` and uses `.match`, so it is anchored at the start only. | |
| `_gate(desc, fn)` | 1207-1210 | Stashes and returns `f"{desc}, sir — say 'confirm' to proceed."` | This exact string is the tool result the model sees. |
| `_consume_pending(command)` | 1212-1229 | No slot → `None`. Otherwise clear the slot **regardless of outcome**. Stale (>25 s) → `None`. `_AFFIRM_RE.match` → run `fn()`; an exception becomes `f"That failed, sir: {e}"`. Anything else → `None` (cancel, then the utterance is processed normally). | The staleness check is `>`, not `>=`. |
| `_HOME`, `_SYS_ROOTS`, `_in_home`, `_is_system_path` | 1232-1238 | `abspath` then prefix tests. `_is_system_path` is also true for `/` and for `$HOME` itself. | `abspath` does **not** resolve symlinks (see §8 R-6). |
| `_AS_DENY`, `_dangerous_applescript` | 1240-1243 | Denies `do shell script`, `administrator privileges`, `system events` (IGNORECASE, `search`). | Applied **only** in `execute_tool` for `run_applescript` (4185-4190). Internal `_run_applescript` callers (music, notes, messages, mail, Finder trash) are not filtered. They build scripts from `_as_escape`d arguments. |
| `_SENSITIVE_PATHS`, `_sensitive_path` | 1245-1251 | Lower-cased substring test. | **Dead code in Python:** defined but never called (grep: only line 1249 references it). See §8 D-3. |
| `_as_escape(s)` | 1253-1255 | Replaces `\` with `\\`, then `"` with `\"`. | The order matters. |
| `_exec_shell` | 1257-1264 | `subprocess.run(shell=True, timeout=30)`. Returns `(stdout or stderr or "Done.").strip()[:1500]`. Timeout gives `"Command timed out."`. | M5 owns the body. The gateway calls it only after the verdict. |
| `_run_command` | 1266-1275 | block → log, then the sudo-specific or the generic refusal string. confirm → `_gate(f"That will run: {cmd.strip()[:100]}", …)`. ok → exec. | The refusal strings are golden (§2.2). |
| `_run_applescript` | 1394-1407 | `osascript -`, UTF-8, 30 s, `[:1000]`. | No guard of its own. |
| `_to_trash`, `_delete_file` | 2741-2765 | Missing → `"I can't find {path}, sir."`. System path → refuse. Not permanent and in home → Trash, instant. Otherwise → gate: `"That will delete {base} permanently (bypassing the Trash)"` if in home, else `"… outside your home folder"`. | `IS_WIN` branch dropped. |
| `_written_this_session` | 2745 | A set of abspaths this process wrote. It makes overwriting them instant. | Native keeps it per app process, not persisted (parity). |
| `_move_file` | 2767-2785 | System src/dst → refuse. dst exists → gate `"That will overwrite {base(d)}"`. Not both in home → gate `"That will move {base(s)} outside your home folder"`. Otherwise instant. | Clobber is checked **before** home. |
| `_write_file` | 2787-2808 | Empty → `"Which file, sir?"`. System → refuse. New, ours, or in home → instant. Otherwise gate `"That will overwrite {base} outside your home folder"`. | |
| `_read_file` | 2810-2820 | No guard. Reads 4000 chars. | It is UNTRUSTED (taints). |
| `execute_tool` | 4180-4255 | Name dispatch. `run_applescript` passes through `_dangerous_applescript` first. Any exception → `emotion_event("task_fail")` + `"Tool error: {e}"`. Unknown → `"Unknown tool {name}"`. | The gateway reproduces the exception and unknown-tool strings. |
| `fast_path` | 4359-… | Calls `_send_message` and `_type_text` **directly** (fast path lines 285/289 of the function body, which is jarvis.py 4546 and 4550). | Native: the fast path goes through the gateway with `origin: .fastPath`. |
| `UNTRUSTED_TOOLS`, `EXECUTOR_TOOLS` | 4841-4847 | 7 untrusted, 9 executor (incl. `run_powershell`). | Shared by both backends. |
| `LAST_BACKEND`, `_set_backend` | 4850-4855 | Records name and time. `research_bump("backend_" + re.sub(r"\W+", "_", name.lower()))`. | Keys seen in `research/usage.json` today: `backend_claude`, `backend_local_qwen2_5_3b_`. |
| `_backend_report` | 4857-4861 | Name contains "claude" → `"The last request was handled by Claude, through the Agent SDK, sir."`. Otherwise `f"The last request was handled by the local model, sir — {MODEL}."`. | See §8 D-6 on wording. |
| `_claude_taint` | 4866 | Per-turn dict. Reset at `claude_generate` start (4988). | |
| `_claude_env` | 4884-4892 | Prepends `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` to PATH if missing. Adds `API_TIMEOUT_MS`, `CLAUDE_CODE_MAX_RETRIES=1`. The SDK merges this over the **inherited** env (minus `CLAUDECODE`). `ANTHROPIC_API_KEY` is popped from `os.environ` at import (4835-4836). | Native uses an **allowlist** instead (stricter; required by the orchestrator). |
| `_build_claude_server` | 4894-4927 | Bridges every `TOOLS` entry. The handler order is: executor and tainted → block (`is_error: True`, text §2.2); else run `execute_tool` in a thread; **then** if untrusted → taint. MCP server `name="jarvis", version="1.0.0"`. Allowed = `mcp__jarvis__<name>` × 46. | The taint is set *after* the untrusted tool returns. Parallel calls can race (§8 R-5). |
| `_claude_stream` | 4929-4969 | Options: system_prompt, mcp_servers, allowed_tools, `tools=[]`, `setting_sources=[]`, max_turns, model, effort, env. Text blocks → `buf += text` → `pop_sentences` → emit (speak and append to `spoken`). A ResultMessage with subtype ≠ `"success"` raises. If `result` is set and nothing has been spoken or buffered → `buf += result`. Final `pop_sentences(force=True)`. | Blocks are concatenated with **no separator**. |
| `_claude_reason(e)` | 4971-4980 | Keyword classification (verbatim, §2.2). | Golden. |
| `claude_generate` | 4982-5006 | Reset taint. Wall timeout `int(TIMEOUT_MS)/1000 + 15` (60 s). On an exception: if anything was spoken → backend `"claude (partial)"` and return the spoken text; otherwise log the reason and return `None`. Empty reply → `None`. Success → backend `"claude" + (f" ({CLAUDE_MODEL})" if CLAUDE_MODEL else "")`. | |
| `_claude_history_preamble` | 5008-5016 | `_history[-7:-1]`, `"User: "` / `"You: "` prefixes, joined `"\n"`, prefixed `"\n\nRecent conversation:\n"`. Empty → `""`. | Golden. |
| `process_command` | 5018-5105 | kb_note_topic → maybe_learn_profile → maybe_learn_personality → emotion_react → `research_bump("interactions")` → track_feedback → append user and cap 12 → build sys_prompt → offline KB fact → Claude only if `CLAUDE_ENABLED and online` → else `_set_backend(f"local ({MODEL})")` and a 5-round local tool loop with its own taint flag and its own block string → `_history_save()` in `finally`. | The local loop's block string **differs** from the Claude one (§2.2). |
| `_SENT_BOUNDARY`, `_SENT_MAX_CHARS`, `pop_sentences` | 4696-4716 | Boundary `[.!?]+\s+`. Run-on over 160 chars is cut at the last space before 160, or at 160. `force` flushes the rest. Empty entries are dropped. | Golden (pure and chunked-feed). |
| `_history_load` / `_history_save` | 4660-4673 | Keep dicts with role user/assistant, last 12. Save `_history[-12:]`. | M1 owns this. Shared by voice and text. |
| `speaker_ok` | 5180-5198 | **Fails open**: no voiceprint, gate off, or too short → True. | The voice gate on confirmation is **indirect**. |
| `handle_one` | 5548-5589 | `_consume_pending` **first**. A resolved confirm is spoken, sets `_last_reply`, is **not** added to `_history`, does **not** bump `interactions`. Then fast_path, then process_command. | Called only after `speaker_ok(audio)` passes (5657/5668, 5681/5696). |

### 2.2 Verbatim patterns and strings (golden-tested)

Risk tiers, sudo allowlist, `_shell_risk` (1153-1193):
```python
_SHELL_BLOCK = re.compile("|".join([
    r"\brm\b.*\s(/|~)(\s|$)", r"\brm\b.*\s/(System|Library|usr|bin|sbin|etc|var|private)\b",
    r":\s*\(\s*\)\s*\{", r"\bmkfs\b", r"\bnewfs\b", r"diskutil\s+(erase|partition|reformat)",
    r"\bdd\b.*of=/dev/", r">\s*/dev/(r?disk|sd)",
    r"(curl|wget|fetch)\b.*\|\s*(ba|z)?sh", r"\$\(\s*(curl|wget)", r"base64\b.*\|\s*(ba|z)?sh",
    r"\bnc\b\s+-", r"\bncat\b", r"/dev/(tcp|udp)/",
    r"\b(csrutil|spctl|tccutil|softwareupdate\s+-i)\b", r"\blaunchctl\b", r"\b(dscl|sysadminctl)\b",
    r"\bvisudo\b", r"/etc/sudoers", r">\s*/(etc|System|usr|bin|sbin)/",
    r"\bsudo\s+(bash|sh|zsh|-i|su|-s)\b", r"chmod\s+-R\b.*\s(/|/System|/Library|/usr)",
    r"chown\s+-R\b.*\s(/|/System|/Library|/usr)",
    # Windows catastrophic
    r"\bformat\s+[a-z]:", r"\bdel\s+/[sfq]", r"\b(rd|rmdir)\s+/s", r"\bvssadmin\b",
    r"\bbcdedit\b", r"\bdiskpart\b", r"\bcipher\s+/w", r"remove-item\b.*-recurse.*c:\\",
]), re.IGNORECASE)
_SHELL_CONFIRM = re.compile("|".join([
    r"\brm\b", r"\brmdir\b", r"\bunlink\b", r"\bshred\b", r"\bsrm\b",
    r"\bkillall\b", r"\bpkill\b", r"\bkill\s+-9\b",
    r"\bshutdown\b", r"\breboot\b", r"\bhalt\b",
    r"\bdefaults\s+delete\b", r"\bchmod\b", r"\bchown\b",
    r"\bdel\b", r"\btaskkill\b", r"remove-item\b",
]), re.IGNORECASE)
# sudo "to a certain extent" — only these run (with confirmation); anything else is blocked.
# Mirrors /etc/sudoers.d/jarvis; killall/shutdown pinned to exact safe invocations.
_SUDO_ALLOW = re.compile("|".join([
    r"^sudo\s+purge\b", r"^sudo\s+softwareupdate\s+(-l|--list)\b", r"^sudo\s+powermetrics\b",
    r"^sudo\s+diskutil\s+(list|info|verifyVolume)\b", r"^sudo\s+fdesetup\s+status\b",
    r"^sudo\s+log\s+show\b", r"^sudo\s+periodic\s+(daily|weekly|monthly)\b",
    r"^sudo\s+dscacheutil\s+-flushcache\b", r"^sudo\s+killall\s+-HUP\s+mDNSResponder\s*$",
    r"^sudo\s+mdutil\b", r"^sudo\s+pmset\b",
    r"^sudo\s+shutdown\s+-r\s+now\s*$", r"^sudo\s+shutdown\s+-h\s+now\s*$",
]), re.IGNORECASE)

def _shell_risk(cmd):
    c = (cmd or "").strip()
    if _SHELL_BLOCK.search(c):
        return "block"
    if re.search(r"\bsudo\b", c):
        return "confirm" if _SUDO_ALLOW.search(c) else "block"
    if _SHELL_CONFIRM.search(c):
        return "confirm"
    return "ok"
```

Confirmation gate (1202-1229):
```python
_pending_action = {"fn": None, "desc": "", "at": 0.0}
_CONFIRM_TIMEOUT = 25
_AFFIRM_RE = re.compile(r"^\s*(confirm(ed)?|yes|yeah|yep|do it( now)?|go ahead|proceed|"
                        r"go for it|affirmative|please do|that'?s right)\b", re.I)

def _gate(desc, fn):
    """Stash a destructive action and return the spoken confirmation prompt."""
    _pending_action.update(fn=fn, desc=desc, at=time.time())
    return f"{desc}, sir — say 'confirm' to proceed."

def _consume_pending(command):
    """Resolve a pending confirmation. Returns a reply str if it handled the turn,
    or None to let the utterance be processed normally (also the cancel path)."""
    p = _pending_action
    if not p["fn"]:
        return None
    fn, stale = p["fn"], (time.time() - p["at"]) > _CONFIRM_TIMEOUT
    p.update(fn=None, desc="", at=0.0)          # one-shot: clear regardless
    if stale:
        return None
    if _AFFIRM_RE.match(command or ""):
        log("confirmation: approved")
        try:
            return fn()
        except Exception as e:
            return f"That failed, sir: {e}"
    log("confirmation: cancelled")
    return None                                  # not an affirmation → cancel, process normally
```

Path classes, AppleScript deny, sensitive paths, escape (1232-1255):
```python
_HOME = os.path.expanduser("~")
_SYS_ROOTS = ("/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt")
def _in_home(p):
    return os.path.abspath(p).startswith(_HOME + os.sep)
def _is_system_path(p):
    a = os.path.abspath(p)
    return a == "/" or a == _HOME or any(a == r or a.startswith(r + os.sep) for r in _SYS_ROOTS)

_AS_DENY = re.compile(r"do\s+shell\s+script|administrator\s+privileges|system\s+events",
                      re.IGNORECASE)
def _dangerous_applescript(s):
    return bool(_AS_DENY.search(s or ""))

_SENSITIVE_PATHS = ("/.ssh", "id_rsa", "id_ed25519", "/library/keychains", "keychain-db",
                    "login.keychain", "/library/messages", ".aws/credentials",
                    ".config/gh/hosts", "/cookies", ".jarvis_config", "audd_key",
                    "voiceprint", "/com.apple.tcc")
def _sensitive_path(p):
    p = (p or "").lower()
    return any(s in p for s in _SENSITIVE_PATHS)

def _as_escape(s):
    """Escape a string for safe embedding inside an AppleScript double-quoted literal."""
    return (s or "").replace("\\", "\\\\").replace('"', '\\"')
```

`_run_command` refusal strings (1266-1275):
```python
def _run_command(command: str) -> str:
    risk = _shell_risk(command)
    if risk == "block":
        log(f"BLOCKED command: {(command or '')[:120]}")
        if re.search(r"\bsudo\b", command or ""):
            return "That sudo command isn't on my allowed list, sir, so I won't run it."
        return "I won't run that, sir — it's system-damaging, so I've blocked it."
    if risk == "confirm":
        return _gate(f"That will run: {(command or '').strip()[:100]}", lambda: _exec_shell(command))
    return _exec_shell(command)
```

`run_applescript` guard inside `execute_tool` (4184-4190):
```python
        if name == "personality_rewrite": return personality_rewrite_tool(args.get("core", ""))
        if name == "run_applescript":
            s = args.get("script", "")
            if _dangerous_applescript(s):
                log("BLOCKED dangerous AppleScript from LLM")
                return "I won't run that script, sir — it could shell out or automate unsafely."
            return _run_applescript(s)
```

Taint sets (4841-4847; copied through the blank line 4848):
```python
UNTRUSTED_TOOLS = {"web_search", "see_screen", "read_clipboard", "read_file", "get_messages",
                   "get_news", "summarize_page"}
EXECUTOR_TOOLS  = {"run_command", "run_applescript", "run_powershell",
                   "send_message", "send_email", "type_text", "run_shortcut",
                   # Self-writing personality: an injected page must never get to
                   # redefine who JARVIS is or plant instructions in his prompt.
                   "personality_note", "personality_rewrite"}

```

Claude-side taint block (MCP handler, 4911-4915):
```python
                if tool_name in EXECUTOR_TOOLS and _claude_taint["tainted"]:
                    log(f"BLOCKED {tool_name} after untrusted-content ingestion (injection guard)")
                    return {"content": [{"type": "text", "text":
                        "Blocked for safety: I won't run scripts, send messages or email, or "
                        "type keystrokes after reading external content in the same request."}],
```

Local-loop taint block (5088-5091). **This is a different string from the Claude one:**
```python
                if name in EXECUTORS and tainted:
                    result = ("Blocked for safety: I won't run scripts, send messages or email, "
                              "or type keystrokes after reading external content (web, screen, "
                              "clipboard, files) in the same request.")
```

Backend naming (4851-4861):
```python
def _set_backend(name):
    LAST_BACKEND["name"] = name
    LAST_BACKEND["at"] = time.time()
    log(f"Backend: {name}")
    research_bump("backend_" + re.sub(r"\W+", "_", name.lower()))

def _backend_report() -> str:
    name = LAST_BACKEND["name"]
    if "claude" in name.lower():
        return "The last request was handled by Claude, through the Agent SDK, sir."
    return f"The last request was handled by the local model, sir — {MODEL}."
```

`_claude_reason` (4971-4980):
```python
def _claude_reason(e) -> str:
    """Turn an SDK failure into a short spoken/logged reason for the fallback note."""
    s = str(e).lower()
    if any(k in s for k in ("credit", "billing", "quota", "insufficient", "payment")): return "no Agent SDK credit"
    if any(k in s for k in ("401", "403", "unauthor", "not signed", "login")):         return "not signed in"
    if any(k in s for k in ("429", "rate", "overload")):                               return "rate limited"
    if any(k in s for k in ("timeout", "timed out", "cancel")):                        return "timed out"
    if any(k in s for k in ("not found", "clinotfound", "enoent")):                    return "Claude Code CLI not found"
    if any(k in s for k in ("connection", "network", "resolve", "dns", "unreach")):    return "network unreachable"
    return (str(e).strip() or "unavailable")[:80]
```

Sentence splitter (4696-4716):
```python
_SENT_BOUNDARY = re.compile(r'[.!?]+\s+')
_SENT_MAX_CHARS = 160

def pop_sentences(buf: str, force: bool = False):
    """Split complete sentences off the front of buf. Returns (sentences, remainder).
    If force, also flush a trailing run-on fragment with no terminal punctuation."""
    out, pos = [], 0
    for m in _SENT_BOUNDARY.finditer(buf):
        out.append(buf[pos:m.end()].strip())
        pos = m.end()
    rest = buf[pos:]
    if not force and len(rest) > _SENT_MAX_CHARS:
        cut = rest.rfind(" ", 0, _SENT_MAX_CHARS)
        if cut <= 0:
            cut = _SENT_MAX_CHARS
        out.append(rest[:cut].strip())
        rest = rest[cut:].lstrip()
    if force and rest.strip():
        out.append(rest.strip())
        rest = ""
    return [s for s in out if s], rest
```

History preamble (5008-5016):
```python
def _claude_history_preamble() -> str:
    """A compact transcript of the last few turns, folded into the system prompt so
    Claude gets the same conversational context the local path gets from _history."""
    lines = []
    for m in _history[-7:-1]:   # recent turns, excluding the just-appended current message
        c = (m.get("content") or "").strip()
        if c:
            lines.append(("User: " if m.get("role") == "user" else "You: ") + c)
    return ("\n\nRecent conversation:\n" + "\n".join(lines)) if lines else ""
```

### 2.3 Known gap: sudo chaining (a deliberate deviation in native)

`_shell_risk` runs `_SUDO_ALLOW.search` over the **whole line**, and every allowlist entry
is anchored `^sudo\s+`. Only the first command on the line is checked. `_exec_shell` then
runs the line with `shell=True`, so every command on it executes. I observed this directly
by calling Python's pure function (no side effects):

| input | Python `_shell_risk` |
|---|---|
| `sudo pmset -g` | `confirm` |
| `sudo killall Finder` | `block` |
| `sudo pmset -g; sudo killall Finder` | `confirm` ← the second, disallowed sudo would run after confirmation |

Native keeps a **Python-exact** function, `PyShellRisk.classify`, which is golden-tested
and matches Python, gap included. The function the gateway actually uses is
`ShellPolicy.verdict`. It is at least as strict as Python on every input, and stricter on
chains:
1. `ShellSegmenter` splits the line on the control operators `;`, `&&`, `||`, `|`, `&` and
   newlines. It extracts the bodies of `$(…)`, backticks, `<(…)` and `>(…)` and recurses
   into them. It honours single quotes, double quotes and backslash escapes. Unbalanced
   quotes or substitutions, or a nesting depth over 8, count as **unparseable → block**.
2. Each segment is classified with `PyShellRisk.classify`. The verdict is the most severe
   of: the whole-line Python verdict, every segment's verdict, and the native extension
   rules (§3.2). The order is `block > confirm > ok`.
3. Any segment containing `\bsudo\b` must match the **effective sudo allowlist** on its own.
   That allowlist is the intersection of `_SUDO_ALLOW` and `/etc/sudoers.d/jarvis` when
   that file exists and is readable, and is `_SUDO_ALLOW` minus the dead `periodic` entry
   otherwise (§3.2, §8 R-3).
4. Monotonicity invariant, tested in §5 A-2: `rank(ShellPolicy.verdict(x)) >=
   rank(PyShellRisk.classify(x))` for every corpus input.

Fixtures record **Python's verdict** on every chain vector (`shell_risk.json`). Native's
stricter verdicts on the same vectors live in a separately marked fixture
(`deviations/shell_chain.json`, §4), listed in the deviations table §8.

### 2.4 Claude CLI stream-json: observed live (probe, 2026-09-28)

**Command** (run once, from an empty temp dir, with `env -i` plus an allowlisted env, so
`ANTHROPIC_API_KEY` was not present). The MCP config pointed at a 30-line Python stub
stdio server that logged its traffic. The prompt was *"Call the ping tool exactly once,
then reply with exactly: pong"*.
```
env -i HOME=… USER=… LOGNAME=… TMPDIR=… LANG=en_US.UTF-8 \
  PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
  API_TIMEOUT_MS=45000 CLAUDE_CODE_MAX_RETRIES=1 \
  claude -p --output-format stream-json --verbose --input-format stream-json \
    --include-partial-messages --system-prompt "<sp>" --tools "" --setting-sources= \
    --strict-mcp-config --mcp-config <file.json> --allowedTools mcp__jarvis__ping \
    --max-turns 3 --model claude-opus-5-5 --effort low --no-session-persistence \
    --permission-prompts none
stdin: {"type":"user","message":{"role":"user","content":"<text>"}}\n   then EOF
```
**Result:** exit 0 after 12 s, 35 NDJSON lines, empty stderr. `--max-turns` is accepted
even though `--help` does not list it (the Python SDK passes it too).
`--setting-sources=` (empty) was accepted.

**Events observed, in order.** Every line is one JSON object; `session_id` and `uuid` are
on all of them.
1. `{"type":"system","subtype":"init", "apiKeySource":"none", "model":"claude-opus-5-5",
   "tools":["mcp__jarvis__ping"], "mcp_servers":[{"name":"jarvis","status":"connected",
   "source":"dynamic"}], "permissionMode":"default", "claude_code_version":"2.1.282",
   "cwd":…, "memory_paths":{"auto":…}, "skills":[…], "plugins":[…builtin…], "agents":[…],
   …}`. **`tools` held only the MCP tool, so `--tools ""` removed every built-in.**
   `apiKeySource:"none"` means OAuth/subscription.
2. `{"type":"system","subtype":"status","status":"requesting"}` before each API request.
3. `{"type":"stream_event","event":{…}, "parent_tool_use_id":null}` wrapping raw Messages
   API stream events: `message_start` (`event.message.model` is the **serving model**),
   `content_block_start` (`content_block.type` ∈ text | thinking | tool_use{id,name,input}),
   `content_block_delta` (`delta.type` ∈ `text_delta{text}` | `thinking_delta` |
   `signature_delta` | `input_json_delta{partial_json}`), `content_block_stop`,
   `message_delta` (`delta.stop_reason` ∈ end_turn | tool_use | **refusal**, plus `usage`),
   `message_stop`.
4. **Refusal plus automatic model fallback: this happened on the trivial probe.** Two
   `message_delta`s arrived with `stop_reason:"refusal"` and `stop_details:{"type":"refusal",
   "category":"cyber","explanation":"This request triggered restrictions on violative
   cyber content …"}` and 0 output tokens. Then:
   `{"type":"system","subtype":"model_refusal_fallback","trigger":"refusal","direction":"retry",
   "scope":"session","original_model":"claude-opus-5-5","fallback_model":"claude-opus-4-8",
   "api_refusal_category":"cyber","retracted_message_uuids":[],"content":"Opus 5.5's
   safeguards flagged this session…"}`. Also a synthetic `{"type":"user","isSynthetic":true,
   "message":{"content":[{"type":"text","text":"Your response above was stopped by a safety
   classifier…"}]}}`. Later `message_start`s show `"model":"claude-opus-4-8"`.
5. `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour",
   "overageStatus":"rejected","overageDisabledReason":"org_level_disabled",
   "isUsingOverage":false,"resetsAt":<epoch>,"unifiedWindows":{…"utilization":0.61…}}}`.
6. `{"type":"assistant","message":{"id","model","content":[<ONE block>]},
   "parent_tool_use_id":null}`. **One assistant event per completed content block**
   (thinking, then tool_use, then text), all emitted after that block's deltas.
7. `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":…,"content":
   [{"type":"text","text":"pong-from-tool"}]}]},"tool_use_result":[…]}`.
8. `{"type":"result","subtype":"success","is_error":false,"result":"pong",
   "stop_reason":"end_turn","terminal_reason":"completed","num_turns":3,
   "duration_ms":8629,"duration_api_ms":5308,"ttft_ms":7360,"api_error_status":null,
   "permission_denials":[],"total_cost_usd":0.034266,"usage":{…},
   "modelUsage":{"claude-opus-5-5":{…"costBasis":"list"},"claude-opus-4-8":{…}}}`.
   `total_cost_usd` is a list-price figure. On a subscription it is not billed.

**MCP traffic seen by the stub server** (newline-delimited JSON-RPC over stdio):
```
<< {"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.282",…}},"jsonrpc":"2.0","id":0}
>> {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"jarvis","version":"1.0.0"}}}
<< {"jsonrpc":"2.0","method":"notifications/initialized"}
<< {"method":"tools/list","jsonrpc":"2.0","id":1}
>> {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"ping","description":"…","inputSchema":{"type":"object","properties":{…},"required":[]}}]}}
<< {"method":"tools/call","params":{"name":"ping","arguments":{},"_meta":{"claudecode/toolUseId":"toolu_…","progressToken":2}},"jsonrpc":"2.0","id":2}
>> {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"pong-from-tool"}]}}
```
The config shape that worked: `{"mcpServers":{"jarvis":{"type":"stdio","command":"<abs
path>","args":[…],"env":{}}}}`, passed as a **file path** to `--mcp-config`. Nothing was
registered globally.

**Flags that must NOT be used.** `--bare` forces API-key auth ("OAuth and keychain are never
read"). `--dangerously-skip-permissions` and `--allow-dangerously-skip-permissions` must
not be used either.

## 3. Swift design

### 3.0 Targets (`native/Package.swift` additions)

```swift
.target(name: "JarvisTools", dependencies: ["JarvisCore"]),              // gateway + (M5/M6) tools
.target(name: "JarvisBrain", dependencies: ["JarvisCore", "JarvisTools"]),// Claude, MCP, FoundationModels
.executableTarget(name: "JarvisApp", dependencies: ["JarvisCore", "JarvisTools", "JarvisBrain"]),
.testTarget(name: "JarvisToolsTests", dependencies: ["JarvisTools"]),
.testTarget(name: "JarvisBrainTests", dependencies: ["JarvisBrain"]),
```
There are no remote dependencies. `JarvisCore` stays Foundation-only. Swift 6 language
mode, strict concurrency, deployment `.macOS("26.0")`. APIs newer than 26.0 are wrapped in
`if #available` (§3.8).

**The choke point is structural.** Everything under `Sources/JarvisTools/Tools/**` (M5/M6)
is `internal`. The only `public` way to run a tool is
`ToolGateway.call(_:_:turn:origin:)`. `JarvisBrain` (MCP server, local model), `JarvisApp`
(chat, fast path, voice loop) and the M7 router can only reach tools through it. M5 must
not add `public` to any tool implementation. §5 A-5 checks this with `grep`.

### 3.1 Python-regex compatibility layer — `Sources/JarvisCore/Security/PyRegex.swift`

```swift
public struct PyRegex: Sendable {
    public init(_ pythonPattern: String, ignoreCase: Bool) throws   // compiles an ICU pattern
    public func search(_ s: String) -> Bool                         // Python re.search
    public func matchAtStart(_ s: String) -> Bool                   // Python re.match
}
```
- Engine: `NSRegularExpression` on NSString/UTF-16. Do **not** use Swift `Regex`, which
  matches on grapheme clusters by default. `NSRegularExpression` is `Sendable` on this SDK;
  if it is not, wrap it in `@unchecked Sendable` with a comment.
- Python `re` and ICU do **not** agree on every character-class, anchor and case-folding
  rule. The executor must **not** reason about which rules differ. `tools/golden.py`
  (module `golden_security.py`, §4) emits `py_re_tables.json` from Python's own `re`, by
  enumerating code points. That file holds Python's exact sets for `\s`, `\w`, `.` and
  `IGNORECASE` equivalence of ASCII letters. `PyRegex` then transliterates the small syntax
  subset these patterns use into ICU, using explicit classes built from those tables.
  The subset is: literals; escapes `\b \s \w \W \d \$ \( \) \. \\ \| \{ \:`; `[...]`;
  `(...)`, `(?:...)`; `|`; `* + ? {m,n}`; `^`, `$`.
- Ground truth is the differential corpus (§4, `pyregex_diff.json`): seeded random strings
  whose expectations are Python's own outputs. The test fails on **any** disagreement.

### 3.2 Security guards — `Sources/JarvisCore/Security/`

| file | declarations (all `public`, `Sendable`, pure) | Python |
|---|---|---|
| `RiskTier.swift` | `enum RiskTier: String, Comparable { case ok, confirm, block }` (rank ok<confirm<block) | tier strings |
| `PyShellRisk.swift` | `enum PyShellRisk { static let blockPatterns: [String]; static let confirmPatterns: [String]; static let sudoAllowPatterns: [String]; static func classify(_ cmd: String?) -> RiskTier }` | `_shell_risk`, **exact, gap included** |
| `ShellSegmenter.swift` | `struct ShellSegment { let text: String; let depth: Int }`; `enum ShellParseError: Error { case unbalancedQuote, unbalancedSubstitution, tooDeep }`; `enum ShellSegmenter { static func segments(_ line: String) -> Result<[ShellSegment], ShellParseError> }` | none (deviation X-1) |
| `SudoAllowlist.swift` | `struct SudoAllowlist { let patterns: [PyRegex]; static let python: SudoAllowlist; static func effective(sudoersFile: URL?) -> SudoAllowlist; func allows(_ segment: String) -> Bool }` | `_SUDO_ALLOW` |
| `ShellPolicy.swift` | `enum ShellPolicy { static func verdict(_ cmd: String, sudo: SudoAllowlist) -> ShellVerdict }`; `struct ShellVerdict { let tier: RiskTier; let pythonTier: RiskTier; let reasons: [String]; let isSudo: Bool }` | combines Python and extensions |
| `AppleScriptPolicy.swift` | `enum AppleScriptPolicy { static func isDangerous(_ s: String?) -> Bool; static func escape(_ s: String?) -> String }` | `_dangerous_applescript`, `_as_escape` |
| `PathPolicy.swift` | `enum PathPolicy { static func pyAbspath(_ p: String, cwd: String) -> String; static func inHome(_ p: String, home: String, cwd: String) -> Bool; static func isSystemPath(_ p: String, home: String, cwd: String) -> Bool; static func isSensitive(_ p: String?) -> Bool; static func resolvedIsSystemPath(_ p: String, home: String) -> Bool }` | `_in_home`, `_is_system_path`, `_sensitive_path` |
| `FileMutationPolicy.swift` | `enum FileDecision: Equatable { case notFound(String), refuse(String), instant(FileOp), gate(desc: String, op: FileOp) }`; `enum FileOp: Equatable { case trash(String), hardDelete(String), move(String, String), write(String) }`; `protocol FileProbe: Sendable { func exists(_ p: String) -> Bool; func isDir(_ p: String) -> Bool }`; `enum FileMutationPolicy { static func delete(path:permanent:probe:home:cwd:) -> FileDecision; static func move(src:dst:probe:home:cwd:) -> FileDecision; static func write(path:probe:writtenThisSession:home:cwd:) -> FileDecision }` | decision branches of `_delete_file` / `_move_file` / `_write_file`, exact strings |
| `Affirmation.swift` | `enum Affirmation { static func matches(_ s: String?) -> Bool }` | `_AFFIRM_RE.match` |
| `TaintPolicy.swift` | `enum TaintPolicy { static let untrusted: Set<String>; static let executors: Set<String>; static let blockedTextClaude: String; static let blockedTextLocal: String }` | 4841-4847, 4914-4915, 5089-5091 |
| `GuardStrings.swift` | refusal and prompt strings: `sudoNotAllowed`, `systemDamaging`, `gatePrompt(desc)`, `confirmFailed(err)`, `appleScriptRefused`, `toolError(e)`, `unknownTool(name)` | §2.2 verbatim |

`pyAbspath` reproduces `os.path.abspath` exactly: it joins with cwd when the path is
relative, then applies `posixpath.normpath` rules, which are lexical and do **not**
resolve symlinks. `~` expansion happens in the tool before this call (Python calls
`expanduser` first). `home` is injected so tests are hermetic. The golden corpus uses the
real home string recorded by golden.py.

**Native extension rules.** These are stricter-only, and each is listed in §8's
deviations table with its own fixture:
- **X-1 segmentation** (§2.3). The verdict is the maximum of the whole line and every
  segment. Any sudo segment must individually pass `SudoAllowlist.effective`.
  Unparseable input → block, with the refusal string `systemDamaging`.
- **X-2 effective sudo allowlist.** It is the intersection of `_SUDO_ALLOW` and the
  commands granted by the sudoers source file. Python's `^sudo\s+periodic` is removed
  (the binary is absent). `/etc/sudoers.d/*` is normally mode 0440 root, so the app
  cannot read it. The **source of truth is therefore a repo file**,
  `native/Resources/sudoers/jarvis`. It is drafted in task T2.3 as a *proposal*; the user
  installs it manually with `visudo -cf` (§8 D-2). `effective(sudoersFile:)` parses only
  `Cmnd_Alias`/`NOPASSWD:` lines of that file. If the file is missing, it falls back to
  `python` minus periodic.
- **X-3 resolved system path.** Run `PathPolicy.isSystemPath` on **both** the Python
  lexical abspath **and** the `realpath(3)` resolution of the nearest existing ancestor.
  Either being true → refuse. This covers symlinks and non-canonical path spellings,
  which Python's lexical check does not.
- **X-4 keychain-secret extraction.** Any segment invoking the `security` CLI with a
  secret-reading subcommand (`find-generic-password`, `find-internet-password`,
  `dump-keychain`, `export`) → block. This protects the ElevenLabs key (§3.11).
- **X-5 sensitive paths (decision D-3, default ON).** `_sensitive_path` is enforced for
  `read_file`, `write_file`, `delete_file` and `move_file`. Read or write → refuse with
  `"That's a protected credentials location, sir, so I won't touch it."`. Python defines
  this list but never uses it.

### 3.3 The choke point — `Sources/JarvisTools/Gateway/`

```swift
// ToolImpl.swift — M5/M6 conform their internal tool types to this.
protocol ToolImpl: Sendable {
    static var name: String { get }
    static var schema: ToolSchema { get }                 // Python TOOLS entry, verbatim JSON
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome
}
public enum ToolOutcome: Sendable {
    case text(String)
    case needsConfirmation(desc: String, action: @Sendable () async throws -> String)
}
// VerifiedShellCommand: the only input run_command's impl accepts; init is fileprivate to
// ToolGateway.swift, so no tool can execute an unverified command line.
public struct VerifiedShellCommand: Sendable { public let line: String; public let verdict: ShellVerdict }

// ToolGateway.swift
public enum ToolOrigin: Sendable { case model(BackendKind), fastPath, confirmation, ui }
public enum BackendKind: String, Sendable { case claude, local }
public struct ToolCallResult: Sendable { public let text: String; public let isError: Bool; public let record: ToolRunRecord }
public actor ToolGateway {
    public static let shared: ToolGateway
    public func toolList() -> [ToolSchema]                             // Python TOOLS order
    public func call(_ name: String, _ args: JSONObject, turn: TurnContext, origin: ToolOrigin) async -> ToolCallResult
    public var onToolError: (@Sendable (String) async -> Void)?        // M1 wires emotion_event("task_fail")
}
```
**`call` algorithm, in this order.** Every step appends to `turn`'s log.
1. `await turn.isOpen`, else return `isError: true`, text `"Turn closed."`. This stops
   stale CLI processes.
2. Look up `name`. If unknown → `"Unknown tool \(name)"` (Python string), `isError: false`.
   The MCP layer maps unknown names to a JSON-RPC error before this point (§3.7).
3. **Taint check.** If `TaintPolicy.executors.contains(name) && await turn.tainted` →
   return `blockedTextClaude` if origin is `.model(.claude)`, else `blockedTextLocal`.
   `isError` is `true` for Claude (Python sets `is_error: True`). Log `BLOCKED <name> after
   untrusted-content ingestion (injection guard)`. Bump `taint_block` (additive counter).
4. **Static pre-guards.** `run_applescript`: `AppleScriptPolicy.isDangerous` → the
   `appleScriptRefused` string. `run_command`: `ShellPolicy.verdict` → block gives
   `sudoNotAllowed` if the line matches `\bsudo\b`, else `systemDamaging`; confirm makes
   the gateway itself produce `.needsConfirmation(desc: "That will run: " +
   String(line.trimmed.prefix(100)), …)`; ok gives `VerifiedShellCommand`. Log the block
   as `BLOCKED command: <first 120 chars>`.
5. Record the tool's `DataSource`s into `turn` (§3.3.1) **before** running. Touching
   counts even if the tool later throws.
6. Run the impl. A thrown error → `await onToolError?(name)`, text
   `"Tool error: \(error)"`, `isError: false` (parity).
7. `.needsConfirmation` → `await ConfirmationGate.shared.stash(desc:action:turn:)`. The
   text is `"\(desc), sir — say 'confirm' to proceed."`.
8. **Only after the result exists:** if `TaintPolicy.untrusted.contains(name)` →
   `await turn.markTainted(by: name)` (Python order).
9. **Serialization.** Calls for the same `turnID` run strictly one at a time, in arrival
   order, through a per-turn FIFO (an `AsyncStream` consumer task per turn). This is
   deviation X-6: stricter than Python's Claude bridge, which could run parallel calls
   before the taint was set.

#### 3.3.1 `TurnContext` — `Sources/JarvisTools/Gateway/TurnContext.swift`
```swift
public enum Channel: String, Sendable { case voice, text }
public enum DataSource: String, Sendable, CaseIterable {
    case messages, calendar, reminders, contacts, email, notes, files, clipboard, screen,
         location, web, news, music, system, shortcuts, personality, alarms, apps, settings
}
public struct ToolRunRecord: Sendable { let name: String; let origin: ToolOrigin; let outcome: Outcome
    enum Outcome: Sendable { case ran, blockedTaint, blockedGuard, gated, failed, unknown } }
public struct TurnSummary: Sendable {       // what M8 reads when choosing ElevenLabs vs Piper
    public let turnID: UUID; public let channel: Channel; public let tainted: Bool
    public let taintedBy: [String]; public let dataSources: Set<DataSource>
    public let toolRuns: [ToolRunRecord]; public let startedPasteTainted: Bool
}
public actor TurnContext {
    public init(channel: Channel, startTainted: Bool = false)
    public let turnID: UUID
    public var isOpen: Bool { get }
    public var tainted: Bool { get }
    public func markTainted(by tool: String)
    public func recordSources(for tool: String)      // uses DataSourceMap
    public func record(_ r: ToolRunRecord)
    public func close()                              // revokes MCP token, flushes FIFO
    public func summary() -> TurnSummary
}
```
`DataSourceMap.sources(for:)` is a static table covering **all 46 tools**. It is filled
here and not left to M5:

| sources | tools |
|---|---|
| messages | get_messages, send_message (+contacts) |
| email, contacts | send_email |
| contacts | find_contact |
| calendar | get_calendar, create_event |
| reminders | set_reminder |
| alarms | set_alarm |
| notes | make_note |
| files | read_file, search_files, find_files, delete_file, move_file, write_file |
| clipboard | read_clipboard |
| screen | see_screen, take_screenshot, summarize_page (+web) |
| location | get_location, get_weather (+web) |
| web | web_search |
| news | get_news (+web) |
| music | music_now_playing, music_search, music_play, music_control, find_song_by_lyrics |
| system | run_command, run_applescript, get_battery, get_time, get_cpu_usage, get_wifi_status, set_volume, set_brightness, run_diagnostics, type_text, notify |
| shortcuts | run_shortcut, list_shortcuts |
| apps | find_apps |
| settings | open_settings, system_control |
| personality | personality_note, personality_rewrite |

A unit test asserts that the table's keys equal the 46 names in `tools_list.json`.
Deciding which sources are "sensitive" for TTS routing belongs to **M8**, not here. The
turn exposes the raw set. Populating it happens only in gateway step 5. Fast-path actions
(`origin: .fastPath`) and confirmed actions (`origin: .confirmation`, which run inside the
*confirming* turn's context) populate it the same way.

#### 3.3.2 `ConfirmationGate` — `Sources/JarvisTools/Gateway/ConfirmationGate.swift`
```swift
public actor ConfirmationGate {
    public static let shared: ConfirmationGate
    public static let timeout: Duration = .seconds(25)
    public struct Pending: Sendable { public let desc: String; public let deadline: ContinuousClock.Instant }
    public var pending: Pending? { get }
    public nonisolated var updates: AsyncStream<Pending?> { get }       // chat card + HUD
    func stash(desc: String, action: @escaping @Sendable () async throws -> String, turn: TurnContext) // internal: gateway only
    public func consume(_ input: String, via port: InputPort, runIn turn: TurnContext) async -> ConsumeResult
}
public enum ConsumeResult: Sendable { case notHandled, handled(String) }
public struct InputPort: Sendable { /* init is internal; created only by TurnCoordinator */ let channel: Channel; let authenticator: ConfirmAuthenticator? }
public protocol ConfirmAuthenticator: Sendable { func authenticate(reason: String) async -> Bool }
```
`consume` semantics are Python's `_consume_pending`, exactly. No slot → `.notHandled`.
Otherwise **clear the slot first, whatever the outcome**. Then `now - stashedAt > 25 s`
(strictly greater, `ContinuousClock`) → `.notHandled`. Then `!Affirmation.matches(input)`
→ `.notHandled` (cancel; the caller processes the input normally). Then, only for
`port.channel == .text`: `await port.authenticator.authenticate(reason: desc)`. False →
`.handled("Confirmation cancelled, sir.")` (deviation X-7, §3.4). Then run the action
under `runIn` with `origin: .confirmation`. A thrown error →
`.handled("That failed, sir: \(error)")`. Success → `.handled(result)`.
`InputPort` can only be constructed by `TurnCoordinator` (§3.5). The MCP server, the
gateway and the tools never hold one, so **the model cannot confirm its own action**.
In Python the equivalent holds because only `handle_one` calls `_consume_pending`.

### 3.4 Typed confirmation: the text-channel equivalent of the voiceprint

In Python, voice confirmation is gated **indirectly**: `handle_one` only runs after
`speaker_ok(audio)`. That check fails **open** when no voiceprint is enrolled. Text has no
voiceprint, so native uses **LocalAuthentication** (Touch ID, or the login password as
fallback):
- **Trigger.** A typed message where `Affirmation.matches` is true while a confirmation is
  pending, **or** the card's Confirm button. Any other typed text cancels the slot and
  proceeds normally (parity). The card's Cancel button calls `consume("cancel", …)`, then
  shows a local "Cancelled." row, and nothing is sent to the brain.
- **Authentication.** Create a fresh `LAContext()` for every confirmation. Set
  `touchIDAuthenticationAllowableReuseDuration = 0` and `localizedFallbackTitle = "Use
  Password"`. Call `evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "confirm:
  \(desc)")`. If the prompt is still up after 60 s, call `invalidate()` and treat it as
  false. If `canEvaluatePolicy` is false (no login password), text confirmation is
  **refused**: `"I can't verify it's you at the keyboard, sir — say 'confirm' instead."`.
- **Why this is at least as strict as voice.** Neither `type_text` nor AppleScript can
  complete a Touch ID or password system prompt, because it runs out of process. The voice
  path can fail open; this one never does. It also closes a text-only hole: a model that
  types "confirm" into the chat window through `type_text`. That would need an untainted
  turn, and it would still fail the LocalAuthentication step.
- **Staleness** is measured at submission, as in Python. Time spent in the auth prompt
  does not count toward the 25 s.
- **Counters.** `text_confirm_approved` and `text_confirm_denied` (additive).
- **Parity notes.** A resolved confirmation is **not** appended to history and does
  **not** bump `interactions`, as in `handle_one`.

### 3.5 `TurnCoordinator` (one turn at a time, across channels) — `Sources/JarvisBrain/TurnCoordinator.swift`
```swift
public struct UserInput: Sendable { public let text: String; public let channel: Channel; public let pasted: Bool }
public actor TurnCoordinator {
    public init(gateway: ToolGateway, brain: BrainRouter, fastPath: FastPathRouting, history: HistoryStoring)
    public func submit(_ input: UserInput, sink: ReplySink) async -> TurnOutcome   // .busy if a turn is running
}
```
Python's `handle_one` is sequential, so native allows exactly one turn at a time. A text
submit during a voice turn returns `.busy`. The composer keeps the text and shows "JARVIS
is busy — voice turn in progress." It is **not** queued (decision D-10). The order of
steps mirrors `handle_one`:
1. Trim; empty → return.
2. `ConfirmationGate.consume` with this channel's `InputPort`. Handled → emit the result
   and return.
3. `fastPath` (M7, gateway `origin: .fastPath`).
4. `BrainRouter.process`.
A new `TurnContext(channel:startTainted:)` is created per turn. `startTainted` is
`input.pasted` under X-8 (decision D-8, default ON). Typed text that arrived by paste or
drag-and-drop is external content, so executor tools are blocked for that turn. `close()`
runs in `defer`.

### 3.6 Claude CLI driver — `Sources/JarvisBrain/Claude/`

| file | contents |
|---|---|
| `ClaudeConfig.swift` | `struct ClaudeConfig { enabled; model; effort; maxTurns; timeoutMS }`, parsed from env exactly like 4825-4829. The defaults are `JARVIS_USE_CLAUDE != "0"`, effort `"low"`, maxTurns `Int(v) ?? 6` (with `"" → 6`), timeout `"45000"`. **Model:** `JARVIS_CLAUDE_MODEL`, else `"claude-opus-5-5"` (a fixed decision; Python's default is `None`, see D-5). |
| `ChildEnvironment.swift` | `static func forClaude(parent: [String:String], config:) -> [String:String]`. This is an **allowlist, not the inherited env minus a denylist** (orchestrator rule). |
| `ClaudeLocator.swift` | `static func find(path: String) -> URL?`. Searches the PATH built for the child. Missing → error `"enoent: claude"`, which `_claude_reason` maps to `"Claude Code CLI not found"`. |
| `ClaudeInvocation.swift` | Builds argv and writes the per-turn MCP config (§3.7). |
| `StreamJSONParser.swift` | `enum ClaudeEvent { case initInfo(apiKeySource:String, tools:[String], mcp:[String:String], model:String), status(String), textDelta(msgID:String, text:String), blockText(msgID:String, text:String), messageStart(msgID:String, model:String), stopReason(msgID:String, String), refusalFallback(from:String, to:String, category:String), rateLimit(status:String, isUsingOverage:Bool), toolResult, result(subtype:String, isError:Bool, text:String?, apiErrorStatus:Int?), unknown(type:String) }`. It parses one NDJSON line at a time. Unknown types are ignored, and the probe's full line set is a test fixture. |
| `SentenceSplitter.swift` | `enum SentenceSplitter { static func pop(_ buf: String, force: Bool) -> (sentences: [String], rest: String) }`. An exact `pop_sentences` port: boundary via `PyRegex("[.!?]+\\s+")`, cut at `lastIndex(of: " ")` before 160, `strip()` = Python whitespace set from `py_re_tables.json`. |
| `ClaudeReason.swift` | `static func reason(_ message: String) -> String`. An exact `_claude_reason`: `lowercased()`, the same keyword order, and the fallback `String(msg.trimmed.prefix(80))` or `"unavailable"`. |
| `ClaudeDriver.swift` | `actor ClaudeDriver { func generate(system: String, user: String, turn: TurnContext, sink: ReplySink) async -> String? }`. It never throws and returns `nil` so the caller falls back. |

**Child env** (`forClaude`):
- **Always** set: `HOME`, `USER`, `LOGNAME`, `TMPDIR` (copied from parent);
  `LANG` = parent's or `en_US.UTF-8`; `PATH`; `API_TIMEOUT_MS` = timeoutMS;
  `CLAUDE_CODE_MAX_RETRIES=1`.
- `PATH` is the parent's (or `/usr/bin:/bin:/usr/sbin:/sbin` if unset), with
  `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` prepended if missing. This
  follows the loop order in 4889-4891, so the result is
  `/usr/local/bin:/opt/homebrew/bin:~/.local/bin:<parent>`. It is golden-checked against
  `_claude_env()["PATH"]` for a fixed parent PATH.
- Copied **only if** present in the parent: `LC_ALL`, `SHELL`, `HTTPS_PROXY`,
  `HTTP_PROXY`, `NO_PROXY`, `ALL_PROXY`, and their lowercase forms.
- **Post-build assertion.** No key matches
  `^(ANTHROPIC_|CLAUDECODE$|CLAUDE_CODE_(?!MAX_RETRIES$))|ELEVEN|_KEY$|_TOKEN$|_SECRET$`,
  and no value contains any value registered in `SecretRegistry` (§3.11). A violation
  drops the key and logs `child env: dropped <KEY>` (the key name only). In DEBUG it is
  an `assertionFailure`.
- The probe ran under exactly this env shape and authenticated by OAuth
  (`apiKeySource:"none"`).
- `cwd` = `~/Library/Application Support/JARVIS/claude-cwd/` (mode 0700, kept empty), so
  no project `CLAUDE.md` or `.mcp.json` can be picked up.

**argv**, in this order. Each flag reproduces an SDK option:
```
<claude> -p --output-format stream-json --verbose --input-format stream-json
  --include-partial-messages                 # native addition: earlier speech; same text
  --system-prompt <sys>                      # system_prompt
  --tools ""                                 # tools=[]  (probe: init.tools had only MCP tools)
  --setting-sources=                         # setting_sources=[]
  --strict-mcp-config                        # native addition (stricter): only our server
  --mcp-config <run/turn-<uuid>.mcp.json>    # mcp_servers={"jarvis": ...}
  --allowedTools <comma-joined 46 × mcp__jarvis__<name>, TOOLS order>   # allowed_tools
  --max-turns <maxTurns>                     # max_turns
  --model <model>                            # model
  --effort <effort>                          # effort (omit if empty, like `effort or None`)
  --no-session-persistence                   # native addition: no transcripts on disk
  --permission-prompts none                  # native addition: anything unapproved is denied
```
Stdin gets exactly one line,
`{"type":"user","message":{"role":"user","content":<user text>}}`, then close.
**Forbidden flags:** `--bare`, `--dangerously-skip-permissions`,
`--allow-dangerously-skip-permissions`, `--permission-mode bypassPermissions`.

**Run loop.** Use `Process` with three `Pipe`s. Read stdout with
`FileHandle.bytes.lines` and keep stderr in an 8 KB ring buffer. The wall timeout is
`Double(timeoutMS)/1000 + 15`, as in 4992. On timeout, cancellation or a guard trip:
SIGTERM, wait 2 s, then SIGKILL; then `turn.close()`. Per-event rules:
- **R1** `init.apiKeySource != "none"` → kill, error `"subscription-only: apiKeySource=<v>"`.
- **R2** `init.mcp_servers["jarvis"] != "connected"` → kill, error `"tool bridge not connected"`.
- **R3** `Set(init.tools) != Set(46 allowed names)` → kill, error `"unexpected tool set"`.
  This is the defence against built-ins or foreign MCP tools showing up.
- **R4** `textDelta` with `parent_tool_use_id == null` → `buf += text`, then
  `SentenceSplitter.pop`, then emit.
- **R5** `blockText` → feed it **only if** no delta was seen for that `msgID`. This keeps
  the text identical to Python's `buf += block.text` with no separator.
- **R6** `stopReason == "refusal"` → discard that message's un-emitted buffer. Emitted
  sentences stand. In text, rows fed by a retracted message are shown struck through.
- **R7** `refusalFallback` → `servingModel = to`; `research_bump("claude_refusal_fallback")`
  (additive); log `from→to` and the category.
- **R8** `rateLimit.isUsingOverage == true` → kill, error `"overage billing refused"`
  (subscription-only; decision D-4). A `status != "allowed"` is remembered for the reason.
- **R9** `result`: `subtype != "success" || isError` → error
  `"result: <subtype> <apiErrorStatus> <text prefix 200>"`. Otherwise, if `text` is
  non-empty and nothing was emitted and `buf` is blank → `buf += text`. Then
  `pop(force: true)` and emit.
- **R10** EOF with no `result` → error `"exit <code>: <stderr tail>"`.
- **Salvage** (4996-4999). On any error, if anything was emitted → `setBackend("claude
  (partial)")` and return the emitted text joined by `" "`. Otherwise log `Claude
  unavailable this turn — using local model: \(ClaudeReason.reason(err))` and return
  `nil`. A success with empty text → the log line `…: empty response` and `nil`.
- **"Emitted"** means sentences passed to `ReplySink.sentence(_:)`. The text channel also
  gets raw `ReplySink.delta(_:)` for live rendering. For text, any displayed delta counts
  as emitted for salvage.
- **Success backend name** (see D-5). Python's formula is
  `"claude" + (" (\(model))" if model set)`. Native keeps key continuity: when
  `model == "claude-opus-5-5"` (the default), the name is `"claude"`, giving counter
  `backend_claude`, as today. For any other model the Python formula applies.

### 3.7 MCP server + relay — `Sources/JarvisBrain/MCP/`, `Sources/JarvisApp/Relay/`

**Files and paths.**
- `run` dir: `~/Library/Application Support/JARVIS/run/`, mode 0700. Socket `run/mcp.sock`,
  mode 0600: create with `umask(0o177)` around `bind`, then `chmod`. Assert
  `path.utf8.count < 104` (`sun_path`). At start, unlink a stale socket only if `lstat`
  shows a socket owned by our uid.
- Per turn: `run/turn-<uuid>.token` (32 bytes from `SecRandomCopyBytes`, hex; opened with
  `O_CREAT|O_EXCL|O_NOFOLLOW`, 0600) and `run/turn-<uuid>.mcp.json` (0600):
  `{"mcpServers":{"jarvis":{"type":"stdio","command":"<Bundle.main.executablePath>","args":["--mcp-relay","<socket>","--token-file","<token path>"],"env":{}}}}`.
  Both files are deleted at `turn.close()`. The token never appears in argv or the env,
  and is never logged.

**Relay mode** (`main.swift`, `Relay/RelayMain.swift`). `main.swift` checks
`CommandLine.arguments.dropFirst().first == "--mcp-relay"` **before** any
AppKit/SwiftUI touch and **before** the M0 single-instance/exclusion guard. It then calls
`RelayMain.run(socket:tokenFile:)` and `exit()`s. The relay:
1. Connects. Sends `{"jarvis_relay":1,"token":"<hex>"}\n`. Waits up to 2 s for
   `{"jarvis_relay_ok":1}\n`.
2. Pumps bytes stdin→socket and socket→stdout (two `DispatchIO` channels). It parses
   nothing and writes nothing else to stdout; diagnostics go to stderr.
3. Exits 0 on EOF from either side, and 1 on handshake failure.

**Server handshake** (`MCPServer.accept`). All of these must hold, or the server closes
the connection and logs `relay rejected: <reason>`:
- `getpeereid` uid == `getuid()`.
- `LOCAL_PEERPID` → pid.
- `proc_pidpath(pid)` == our own executable path.
- `proc_pidinfo(PROC_PIDTBSDINFO).pbi_ppid` == the `claude` pid the driver registered
  for that token.
- The token matches an **open** turn (constant-time compare).
- It is the **first** connection for that token.
- The handshake line is ≤ 4 KB and arrives within 2 s.

The connection is then bound to that `TurnContext`. There is no other way to name a turn.

**JSON-RPC subset.** Newline-delimited, one object per line, `jsonrpc:"2.0"`. Encode with
`JSONSerialization` (not pretty-printed; newlines inside strings are escaped).
| method | reply |
|---|---|
| `initialize` | `{"protocolVersion": <client's if ∈ {"2025-11-25","2025-06-18","2025-03-26","2024-11-05"} else "2025-11-25">, "capabilities":{"tools":{"listChanged":false}}, "serverInfo":{"name":"jarvis","version":"1.0.0"}}` |
| `notifications/initialized`, `notifications/cancelled`, other `notifications/*` | none (logged) |
| `ping` | `{}` |
| `tools/list` | `{"tools":[{"name","description","inputSchema": <Python parameters, verbatim>}] }` × 46, in TOOLS order. Params schema is `parameters or {"type":"object","properties":{}}` (4908). |
| `tools/call` | `params.name` not in the registry → error `-32602 "Unknown tool: <name>"`. Otherwise `gateway.call(name, arguments ?? {}, turn, .model(.claude))` → `{"content":[{"type":"text","text":<text>}]}`, plus `"isError":true` only when the gateway says so. `_meta` is ignored. |
| other method with `id` | error `-32601 "Method not found"` |
| unparseable line | error `-32700 "Parse error"`, `id:null` |
| no `method`, or a batch array | error `-32600 "Invalid Request"` |
| any request after `turn.close()` | error `-32000 "Turn closed"` |

Error shape: `{"jsonrpc":"2.0","id":<id>,"error":{"code":<int>,"message":<str>}}`.

**Taint is enforced server-side, per turn.** The taint state lives on the `TurnContext`
bound at handshake, and the gateway checks it (§3.3 step 3). A CLI process has no way to
reset it. A new turn means a new token, a new context and a clean taint flag, matching
the reset at 4988.

### 3.8 FoundationModels fallback — `Sources/JarvisBrain/Local/`

| file | contents |
|---|---|
| `DynamicTool.swift` | `struct DynamicTool: Tool { typealias Arguments = GeneratedContent; typealias Output = String; let name: String; let description: String; let parameters: GenerationSchema; let turn: TurnContext; func call(arguments: GeneratedContent) async throws -> String }`. `call` does `JSONObject(parsing: arguments.jsonString)` → `ToolGateway.shared.call(name, obj, turn:, origin: .model(.local))` → `.text`. |
| `SchemaBridge.swift` | `static func generationSchema(for tool: ToolSchema) throws -> GenerationSchema`. `object` → `DynamicGenerationSchema(name: "<tool>_args", description:, properties:)`. Property `string` → `DynamicGenerationSchema(type: String.self)`; with an `enum` → `DynamicGenerationSchema(name: "<tool>_<prop>", anyOf: [String])`. `integer` → `(type: Int.self)`. `boolean` → `(type: Bool.self)`. Not in `required` → `Property(…, isOptional: true)`. Then `GenerationSchema(root:dependencies: [])`. The measured TOOLS use only string/integer/boolean, with enums on `music_search.by` and `music_control.action`. Any other type throws, and the test covers all 46. |
| `LocalToolset.swift` | `static func select(model: SystemLanguageModel, instructions: String) async -> [DynamicTool]` (budget below) |
| `LocalBrain.swift` | `actor LocalBrain { func generate(system: String, history: [HistoryEntry], user: String, channel: Channel, turn: TurnContext, sink: ReplySink) async -> String }` |

- **SDK facts, verified in the macOS 27.2 SDK swiftinterface.** `Tool`
  (`Arguments: ConvertibleFromGeneratedContent`, `Output: PromptRepresentable`) is macOS
  26.0. `GeneratedContent` is `Generable`, has `jsonString` and `init(json:)`.
  `DynamicGenerationSchema` (inits above) and `GenerationSchema(root:dependencies:)` are
  26.0. `LanguageModelSession(model:tools:instructions:)` and
  `streamResponse(to:options:)`, whose `Snapshot.content` is **cumulative**, are 26.0.
  `SystemLanguageModel.contextSize` is back-deployed and **returns a hard-coded 4096
  before macOS 27**. `tokenCount(for:)` (tools, instructions, prompt) needs **macOS 26.4**.
  `LanguageModelError` (incl. `.contextSizeExceeded`) needs **macOS 27**; on 26.x catch
  `LanguageModelSession.GenerationError` (`.exceededContextWindowSize`).
  `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)`.
- **Budget, measured with chars ÷ ~3.5 as a rough token estimate.** SYSTEM_PROMPT is 3,557
  chars. Today's contexts: personality 1,323, emotion 349, kb 492, app 99, tone 0,
  profile 0. TOOLS JSON is 14,713 chars (~4.2 k tokens). The total is **~6 k tokens,
  more than 4096**. The real macOS 27 `contextSize` is **not measured**, because that
  needs a Swift run; task T3.6 measures it.
  Note that Python's own fallback already sends all 46 tools with `num_ctx 4096` (5069),
  so it is context-starved too.
- **`LocalToolset.select`.** Compute `tokenCount(for: allTools) + tokenCount(for:
  instructions)` (26.4+; below that, use chars/3.5). If the result ≤ 0.6 × `contextSize`
  → all 46. Otherwise use **CORE-22** (decision D-7): get_time, get_battery,
  get_cpu_usage, get_wifi_status, set_volume, set_brightness, music_now_playing,
  music_play, music_control, set_reminder, set_alarm, make_note, get_calendar,
  create_event, find_apps, open_settings, system_control, run_shortcut, list_shortcuts,
  notify, find_files, run_command. If that still does not fit, drop tools from the tail
  until it fits and log what was dropped. All of them still go through the same gateway.
- **Semantics** (5043-5105).
  - Backend name `"local (apple-foundation-model)"`, giving counter
    `backend_local_apple_foundation_model` (additive, a new key).
  - History is folded into the instructions like the Claude preamble (`_history[-7:-1]`,
    D-11). Python passes 12 raw turns to Ollama; that would not fit.
  - Options: `temperature 0.6`, `maximumResponseTokens` 200 for voice (Python
    `num_predict`) and 600 for text (D-12).
  - The stream diffs cumulative snapshots into deltas, then feeds `SentenceSplitter`.
  - Empty reply → retry up to 2 times, then `"Sorry, sir — could you say that again?"`.
  - More than 10 tool calls in one turn → `"I got stuck working through that, sir."`.
    Python bounds 5 *rounds*; FoundationModels exposes no round count, so this is an
    approximation (§8).
  - Any error → pop the user entry from history and reply `"My local reasoning core had an
    error, sir."` (5099-5103).
  - `availability != .available` is handled the same way, with the reason logged.
  - One `LanguageModelSession` per turn; it is released after the turn (RAM).

### 3.9 `BrainRouter` (the `process_command` port) — `Sources/JarvisBrain/BrainRouter.swift`
`func process(_ text: String, online: Bool, channel: Channel, turn: TurnContext, sink: ReplySink) async -> String`
runs Python's order exactly, calling M1/M1b APIs:
1. kbNoteTopic
2. learnProfile
3. learnPersonality
4. emotionReact
5. `bump("interactions")`, plus `bump("channel_text")` if `.text`
6. trackFeedback
7. `history.append(user)`, cap 12
8. `sys = PromptBuilder.system()`
9. If offline and `kb` fact → `sys += " (Previously learned: \(fact.prefix(300)))"`
10. `sys += ChannelAddendum.text(channel)`
11. If `config.enabled && online` → `ClaudeDriver.generate(system: sys + preamble, …)`
12. Reply → `history.append(assistant)`, `save()`, return
13. Otherwise `setBackend("local (apple-foundation-model)")` → `LocalBrain`
14. `history.save()` in `defer`

`ChannelAddendum.text(.voice) == ""`, so the voice prompt stays byte-identical to Python.
`ChannelAddendum.text(.text)` is this string:
```
\n\nCHANNEL: TEXT CHAT. The user typed this message and will READ your reply on screen; it is not spoken aloud. The spoken-reply rules above about brevity and no markdown do not apply here: you may answer in a few short paragraphs, and you may use light Markdown (bold, italics, inline code, short bullet lists) when it genuinely helps. Still no emoji, still address the user as 'sir', still keep the JARVIS voice.
```
**History** is one `HistoryStore` actor (M1), shared by voice and text. Entries hold
**only** `role`/`content`, so the `history.json` schema is unchanged and Python can still
read it after a rollback.

### 3.10 Backend reporting — `Sources/JarvisBrain/BackendReporter.swift`
`actor BackendReporter { func set(_ name: String); func report(localModelName: String) -> String; var last: (name: String, at: Date) }`.
- The counter key is `"backend_" + PyRegex("\\W+").sub("_", name.lowercased())`, a port
  of `re.sub`. It is golden-tested on names including `"claude (partial)"` and
  `"local (qwen2.5:3b)"`.
- `report` returns Python's strings verbatim (D-6). The local display name is
  `"Apple's on-device model"`.
- The M7 fast phrase "which model are you using" calls `report`.

### 3.11 Secrets — `Sources/JarvisCore/Secrets/`
- `SecretStore.read(service: "com.jarvis.assistant", account: "elevenlabs") -> String?`
  uses `SecItemCopyMatching` with `kSecClassGenericPassword`. It is read on demand and
  held only in memory.
- `SecretRegistry.register(_:)`: M0's logger replaces every registered value with
  `‹redacted›` before writing.

**Rules, tested in §5 A-9:**
- (a) Never pass it to `setenv`, and never put it in any child env. `ChildEnvironment` is
  the only env builder for `claude`. Tool subprocesses inherit the app env, which never
  contains the key.
- (b) Never write it to repo, state or research files, or to `history.json`.
- (c) Never log it.
- (d) X-4 blocks `security` secret-reading subcommands in `run_command`.
- (e) Never put it in argv.

`ANTHROPIC_API_KEY` is handled the same way: it is never read and never forwarded.

### 3.12 M4 text chat — `Sources/JarvisApp/`

| file | contents |
|---|---|
| `main.swift` | relay dispatch (§3.7), then `JarvisApp.main()` |
| `JarvisApp.swift` | `@main`-free `struct JarvisApp: App`. `MenuBarExtra("JARVIS", systemImage: "circle.hexagongrid.fill") { MenuBarMenu() }.menuBarExtraStyle(.menu)` plus `Window("JARVIS", id: "chat") { ChatView() }`. `NSApp.setActivationPolicy(.accessory)`. The Info.plist key `LSUIElement = YES` is added by the M0 bundle script. |
| `MenuBar/MenuBarMenu.swift` | "Open Chat" (`openWindow(id:"chat")` + `NSApp.activate()`), the last backend line, a "Speak replies" toggle (the input to the user's policy), Quit |
| `Chat/ChatViewModel.swift` | `@MainActor @Observable final class ChatViewModel` holding `messages: [ChatMessage]`, `pending: ConfirmationGate.Pending?`, `busy: Bool`, `func send()`, and `ReplySink` conformance. Deltas are coalesced into UI updates at ≤ 30 Hz. |
| `Chat/ChatView.swift` | transcript + `ConfirmationCard` (desc, a 25 s countdown, Confirm/Cancel) + composer |
| `Chat/Composer.swift` | an `NSViewRepresentable` over an `NSTextView` subclass that overrides `paste(_:)` and drag-drop to set `pasted = true` (X-8). Return sends; ⇧Return adds a newline. |
| `Chat/MarkdownText.swift` | Finished assistant rows use `AttributedString(markdown:, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`. While streaming, plain text. Links render but only open on click. |
| `Chat/LAConfirmAuthenticator.swift` | `ConfirmAuthenticator` via `LAContext` (§3.4) |
| `Chat/SpeakPolicy.swift` | **USER DECISION POINT** (below) |

**Speaking typed replies is a decision for the user.** `SpeakPolicy.swift` ships with a
stub that returns `false` and a `// TODO(user)` marker:
```swift
public struct SpeakContext: Sendable {
    let chatWindowIsKey: Bool; let speakToggleOn: Bool; let userIdleSeconds: Double
    let voiceConversationActive: Bool; let replyCharCount: Int
    let turn: TurnSummary            // dataSources/tainted — sensitive content awareness
    let ttsBackend: String           // "elevenlabs" | "piper" (M8)
}
/// USER DECISION: return true to have JARVIS read this typed-channel reply aloud.
public func shouldSpeakReply(channel: Channel, text: String, context: SpeakContext) -> Bool
```
Trade-offs to write into the doc comment:
- **Always speak.** Consistent persona, but noisy while you read, and it doubles the
  output.
- **Speak only when the window is not key, or you are idle.** Useful when you walk away,
  but a surprise at other times.
- **Never speak** (the stub). Quiet and private, but the text channel loses the voice.
- **Length cap.** Long markdown replies sound bad; strip markdown before TTS.
- **Privacy.** When `turn.dataSources` holds personal sources, ElevenLabs (cloud) sends
  that text off-device. M8 can route it to Piper. The policy may also refuse to speak
  at all.
- **Cost and latency.** Cloud TTS usage grows with every spoken reply.

When the policy says true: bump `text_reply_spoken` and hand the text to M8's speaker
with the `TurnSummary`.

**Additive dataset counters (text channel and brain).** `channel_text`,
`text_confirm_approved`, `text_confirm_denied`, `text_reply_spoken`,
`claude_refusal_fallback`, `taint_block`, `backend_local_apple_foundation_model`. All go
through M1b's `research_bump`. No existing key changes meaning, except the
`interactions` question in D-9.

### 3.13 Concurrency summary

**Actors:**
- `ToolGateway`
- `TurnContext`
- `ConfirmationGate`
- `TurnCoordinator`
- `ClaudeDriver`
- `LocalBrain`
- `BackendReporter`
- `MCPServer` (socket I/O on a private serial `DispatchQueue`, bridged with
  `AsyncStream`)

**Main-actor types:** `ChatViewModel` and the views.

`ReplySink` is `Sendable` with `async` methods. All payload types are `Sendable`
value types. There are no `@unchecked Sendable` types except the `NSRegularExpression`
wrapper, if needed. The relay is synchronous code in its own process.

## 4. Golden vectors

**Generator.** `native/tools/golden_security.py` and `native/tools/golden_brain.py`, which
M0's `tools/golden.py` dispatches to, run with the Python 3.14 framework binary. They
import `jarvis` and call **only pure functions**, or functions whose side effects are
monkeypatched away.

> **Sandbox rule (learned on 2026-09-28).** Calling `jarvis.emotion_context()` **rewrote
> `emotions.json`**: it decays, then saves. Generators must first repoint every `*_FILE`,
> `RESEARCH_DIR` and `RESEARCH_USAGE` at a temp copy. golden.py should assert that the
> mtimes of `~/jarvis/*.json` and `research/*` are unchanged after a run.

**Fixture shape** (all files under `native/Tests/Fixtures/golden/`):
```json
{"generator":"golden_security.py","fn":"_shell_risk","jarvis_sha256":"<sha256>",
 "python":"3.14.x","home":"/Users/yasir24s","cwd":"/","cases":[{"id":"...","category":"...","input":"...","expect":"..."}]}
```
Tests fail if `jarvis_sha256` ≠ the current `jarvis.py`. Deviation fixtures live in
`golden/deviations/`. Each case is `{"python": <generated>, "native": <hand-specified>,
"deviation": "X-n"}`. Only the `native` half is hand-written.

| fixture | Python oracle | corpus |
|---|---|---|
| `py_re_tables.json` | `re` | Python's class sets, emitted by enumerating code points (§3.1) |
| `pyregex_diff.json` | `re.search`/`re.match` on every §2.2 pattern | seeded random strings (seed 20260928), ≥ 400 per pattern |
| `shell_risk.json` | `_shell_risk` | benign commands (≥ 200 everyday commands); every `_SHELL_CONFIRM` alternative; every `_SHELL_BLOCK` alternative; every `_SUDO_ALLOW` entry, plus near-misses; the attack categories named in the brief; the chained-sudo vectors in §2.3. **Case authoring:** see the note below this table. |
| `deviations/shell_chain.json` | `_shell_risk` (python half) | the same chain and substitution vectors; `native` = the X-1 verdict |
| `deviations/sudo_effective.json` | `_SUDO_ALLOW.search` | one case per allowlist entry; `native` follows the draft sudoers file (X-2) |
| `applescript_deny.json` | `_dangerous_applescript` | ≥ 100: benign app-control scripts, plus the three deny phrases with case and whitespace variation |
| `as_escape.json` | `_as_escape` | quotes, backslashes, mixed, empty, None, non-ASCII |
| `path_policy.json` | `os.path.abspath`, `_in_home`, `_is_system_path`, `_sensitive_path` | relative, `..`, `.`, repeated slashes, home itself, each `_SYS_ROOTS` entry and its prefix look-alikes, and every `_SENSITIVE_PATHS` entry |
| `file_mutation.json` | `_delete_file`, `_move_file`, `_write_file`, with `_gate`, `_to_trash`, `shutil.*`, `open`, `os.remove` and `os.path.exists/isdir` monkeypatched to recorders over a fake FS | every branch of §2.1 rows 2747-2808, with exact strings |
| `affirm.json` | `_AFFIRM_RE.match` | every alternative, with trailing words, leading spaces and near-misses |
| `gate_consume.json` | `_gate` + `_consume_pending`, with `time.time` patched | sequences: stash → input at t ∈ {0, 24.9, 25, 25.1} → result; non-affirm cancels; one-shot; raising fn |
| `taint.json` | `UNTRUSTED_TOOLS`, `EXECUTOR_TOOLS`, both block strings | sets and strings |
| `tools_list.json` | `TOOLS` + `_claude_allowed` | 46 schemas in order, plus the allowed-name list |
| `pop_sentences.json` | `pop_sentences` | ≥ 300 pure cases, plus chunked-feed cases: the same text split into fixed chunk lists and fed the way 4955-4968 does |
| `claude_reason.json` | `_claude_reason` | every keyword, keyword-order collisions, empty, and an 81+ char unknown string |
| `backend_key.json` | the `re.sub(r"\W+","_",name.lower())` of `_set_backend` | `claude`, `claude (partial)`, `claude (claude-opus-5-5)`, `local (qwen2.5:3b)`, `local (apple-foundation-model)` |
| `history_preamble.json` | `_claude_history_preamble` (with `_history` patched) | 0-13 entries, empty contents, roles |
| `claude_env_path.json` | `_claude_env()["PATH"]` (env patched) | 6 parent PATHs |
| `../claude/probe-2026-09-28.jsonl` | the live CLI (not Python) | copy from the scratch probe file if it still exists, otherwise re-run the probe once (§2.4) |

**Authoring the attack cases.** The `shell_risk.json` attack cases are written by a person
or a security-scoped task. Their expectations always come from running Python. This plan
deliberately does not list payload strings.

## 5. Acceptance checks

Run from `~/jarvis/native`. Python JARVIS must **not** be running
(`pgrep -f jarvis.py` prints nothing). Each check passes only on the observable output
named in its row.

| id | command | pass = observed |
|---|---|---|
| A-0 | `python3 tools/check_plan_verbatim.py plan/M02-M04-security-brain-chat.md ../jarvis.py` (T2.1 writes it: every ```python block in §2.2 must be a substring of jarvis.py) | `all N blocks verbatim` |
| A-1 | `swift test --filter 'PyRegexDiffTests\|PyShellRiskGoldenTests\|AppleScriptGoldenTests\|PathPolicyGoldenTests\|FileMutationGoldenTests\|AffirmGoldenTests\|GateConsumeGoldenTests'` | 0 failures; each test prints its case count (≥ the §4 minimums) |
| A-2 | `swift test --filter ShellPolicyMonotonicTests` | `rank(native) >= rank(python)` on every `shell_risk.json` case; 0 failures |
| A-3 | `swift test --filter DeviationFixtureTests` | every `deviations/*.json` case matches its `native` value, and its `python` value matches the oracle |
| A-4 | `swift test --filter ToolGatewayTests` | taint: executor after untrusted → the exact string for each backend; untrusted marks taint only after returning; FIFO serialization (a concurrent `web_search`+`run_command` on one turn gets a deterministic result); closed turn → "Turn closed."; `dataSources` equals the §3.3.1 map; the DataSourceMap keys equal 46 |
| A-5 | `grep -rnE '^\s*public ' Sources/JarvisTools/Tools \| wc -l` and `grep -rnE 'ToolRegistry\|\.run\(_? *args' Sources/JarvisBrain Sources/JarvisApp` | `0` and no output: nothing bypasses the gateway |
| A-6 | `swift test --filter MCPServerTests` | replaying the §2.4 MCP transcript over a `socketpair` gives byte-equivalent JSON replies (after key-order normalization); tools/list equals `tools_list.json`; every error row of §3.7 is produced; the handshake rejects a wrong token, a second connection, and a wrong ppid |
| A-7 | `swift test --filter ClaudeStreamParserTests` | the recorded probe JSONL parses into the expected event sequence: 1 init, 2 refusals, 1 fallback (5.5→4.8), 1 tool_use, text "pong", result success |
| A-8 | `swift test --filter ChildEnvironmentTests` | with a parent env holding `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and a registered sentinel secret, the built env's keys ⊆ the allowlist, and no value contains the sentinel |
| A-9 | live, with the dev app built by M0's script: `…/JARVIS.app/Contents/MacOS/JARVIS --brain-smoke "what time is it"` (a DEBUG-only headless mode added in T3.5) | stdout shows `init apiKeySource=none`, `tools=46`, `mcp jarvis=connected`, a `tools/call get_time` line in the server log, a reply sentence, `backend=claude`; `usage.json` today has `backend_claude` +1 |
| A-10 | live: `--brain-smoke --inject-taint-test` (runs a turn with `startTainted:true` and a prompt asking the model to run `echo hi` via run_command) | the log line `BLOCKED run_command after untrusted-content ingestion (injection guard)`; `echo` never ran; `taint_block` +1 |
| A-11 | live: `--brain-smoke --force-local "what time is it"` | `backend=local (apple-foundation-model)`, and the reply mentions the time. **Record** the logged `contextSize` and tool token count |
| A-12 | UI: launch the app, open the chat from the menu bar, type `what time is it`, then `screencapture -x /tmp/claude-501/m4-chat.png` | the screenshot shows the streamed reply in the window and the menu bar icon; no Dock icon |
| A-13 | UI: type a prompt that leads to a confirm-tier action (e.g. "delete ~/Desktop/m4-test.txt permanently", on a test file), then type `confirm` | the confirmation card appears with a countdown; the system auth sheet appears; cancelling it gives "Confirmation cancelled, sir." and the file still exists; approving it deletes the file; `text_confirm_*` counters bump |
| A-14 | RAM: `ps -o rss=,comm= -p $(pgrep -f 'JARVIS.app/Contents/MacOS/JARVIS$')` with the chat idle; during an A-9 turn also `pgrep -fl -- --mcp-relay` and `ps -o rss=` for the relay and `claude` | the three numbers recorded in PARITY.md §RAM |

## 6. Executor tasks

Every executor gets a worklog (the orchestrator's convention) and writes code **from the
start**, reading source on demand; no front-loaded reading. Each task ends with its §5
checks observed and a commit on the milestone branch.

| id | ≤2 h task | files | done when | deps |
|---|---|---|---|---|
| T2.1 | `golden_security.py` (§4 rows up to `taint.json`) + `check_plan_verbatim.py` + sandbox/mtime assertion | `native/tools/` | fixtures written; A-0 passes; the mtime check shows no state writes | M0 golden.py |
| T2.2 | `PyRegex` + the transliterator + `PyRegexDiffTests` | `JarvisCore/Security/PyRegex.swift` | A-1 (diff part) 0 failures | T2.1 |
| T2.3 | `PyShellRisk`, `ShellSegmenter`, `SudoAllowlist`, `ShellPolicy`, X-1/X-2/X-4; draft `native/Resources/sudoers/jarvis` (a **proposal** for the user; not installed) | `JarvisCore/Security/*` | A-1 (shell), A-2, A-3 | T2.2 |
| T2.4 | `AppleScriptPolicy`, `PathPolicy` (+X-3, X-5), `FileMutationPolicy`, `Affirmation`, `TaintPolicy`, `GuardStrings` | `JarvisCore/Security/*` | A-1 (rest) | T2.2 |
| T2.5 | `JarvisTools` target: `ToolImpl`, `ToolGateway`, `TurnContext`, `DataSourceMap`, `ConfirmationGate`, `VerifiedShellCommand`, stub tools for tests | `JarvisTools/Gateway/*`, Package.swift | A-4, A-5 | T2.3, T2.4 |
| T3.1 | `golden_brain.py` (from `tools_list.json` on); copy the probe JSONL; `StreamJSONParser`, `SentenceSplitter`, `ClaudeReason`, `BackendReporter` key | `JarvisBrain/Claude/*` | A-7 + the golden tests for pop/reason/key/preamble/PATH | T2.1 |
| T3.2 | `ChildEnvironment`, `ClaudeLocator`, `ClaudeInvocation`, `SecretStore`/`SecretRegistry` | `JarvisBrain/Claude/*`, `JarvisCore/Secrets/*` | A-8 | T3.1 |
| T3.3 | `MCPServer` (socket, handshake, JSON-RPC) + `RelayMain` + `main.swift` dispatch | `JarvisBrain/MCP/*`, `JarvisApp/Relay/*` | A-6 | T2.5 |
| T3.4 | `ClaudeDriver` run loop R1-R10, salvage, timeout/kill, per-turn token and config files | `JarvisBrain/Claude/ClaudeDriver.swift` | unit tests with a fake `claude` script replaying the probe JSONL, plus a timeout and a partial case | T3.2, T3.3 |
| T3.5 | `TurnCoordinator`, `BrainRouter`, `ChannelAddendum`, the `--brain-smoke` DEBUG mode | `JarvisBrain/*`, `JarvisApp/main.swift` | A-9, A-10 (**live**; one run each) | T3.4, M1 APIs |
| T3.6 | `DynamicTool`, `SchemaBridge`, `LocalToolset`, `LocalBrain`; measure `contextSize` + token counts | `JarvisBrain/Local/*` | schema test for all 46; A-11; the measured numbers written into §8 R-7 | T2.5, T3.5 |
| T4.1 | App shell: `JarvisApp`, `MenuBarMenu`, chat `Window`, `.accessory` policy | `JarvisApp/*` | A-12 (screenshot looked at) | T3.5 |
| T4.2 | `ChatViewModel`, streaming render, `Composer` (paste → X-8), `MarkdownText` | `JarvisApp/Chat/*` | a streamed reply visible in a screenshot; the paste test turn is tainted | T4.1 |
| T4.3 | `ConfirmationCard`, `LAConfirmAuthenticator`, text counters | `JarvisApp/Chat/*` | A-13 | T4.2 |
| T4.4 | `SpeakPolicy.swift` stub + doc comment, the "Speak replies" toggle wiring; A-14 RAM numbers | `JarvisApp/Chat/SpeakPolicy.swift` | stub returns false; the toggle persists; RAM recorded | T4.3 |

## 7. RAM / permissions

- **Planning-time constraints:** ~1 GB free on an 8 GB M2. No `swift build` and no
  Python JARVIS while planning. The one CLI probe used about 12 s of wall time.
- **Per-turn cost.** Each Claude turn spawns `claude` (RSS **not measured**) and one relay.
  The relay is the app binary, so it links SwiftUI/AppKit; its RSS is **not measured**.
  If A-14 shows more than ~40 MB, move the relay to a tiny helper executable (§8 R-8).
  Nothing stays resident between turns.
- **FoundationModels.** Inference is system-managed. The app-side cost is **not measured**
  (A-14). There is one session per turn, released afterwards.
- **Permissions, M2-M4 only:**
  - LocalAuthentication: no entitlement or TCC prompt, just the auth sheet.
  - Keychain: an item created by the app is readable without prompts.
  - Unix socket: no TCC.
  - The app must **not** be sandboxed: it spawns `~/.local/bin/claude` and uses
    `Application Support` paths directly.
  - Automation, Accessibility and Screen Recording belong to M5/M6.
- **Shared state.** The app uses the bundle id `com.jarvis.assistant`, the real
  `history.json` and the real `research/usage.json`. It must never run concurrently with
  Python (the M0 guard). Relay mode must bypass that guard (§3.7).

## 8. Risks and open questions

### 8.1 Deviations from Python. Each is stricter unless noted, and each has its own fixture or test.

| id | deviation | why | evidence |
|---|---|---|---|
| X-1 | Shell segmentation: every segment is classified, sudo is checked per segment, unparseable → block | verified sudo-chaining gap (§2.3) | `deviations/shell_chain.json` |
| X-2 | Effective sudo allowlist = `_SUDO_ALLOW` ∩ the sudoers source file; `periodic` removed | the OS file will be tighter; `periodic` is absent | `deviations/sudo_effective.json` |
| X-3 | System-path check also on the resolved path | Python's check is lexical only | `PathPolicyDeviationTests` |
| X-4 | `security` secret-reading subcommands blocked | protects the Keychain-held ElevenLabs key | `deviations/shell_chain.json` |
| X-5 | `_sensitive_path` enforced for file tools | Python defines it but never calls it | D-3 |
| X-6 | Tool calls serialized per turn | Python's Claude bridge could race taint | A-4 |
| X-7 | Typed confirm needs LocalAuthentication; a failed auth gives "Confirmation cancelled, sir." | text has no voiceprint | A-13 |
| X-8 | Pasted/dropped text starts the turn tainted | there is no Python text channel | D-8 |
| X-9 | Allowlisted child env; `--strict-mcp-config`, `--permission-prompts none`, `--no-session-persistence` | orchestrator rule; stricter | A-8 |
| X-10 | R1/R3/R8 kill-switches (API-key auth, unexpected tools, overage) | subscription-only | unit tests |
| X-11 | `result.is_error` treated as failure | Python could speak an error string as the reply | unit test |
| X-12 (behavioural, not a security change) | `--include-partial-messages`; FoundationModels replaces Ollama; history folded into instructions; 10-call cap | latency; Ollama is not used by native | A-11 |

### 8.2 Decisions for the user

- **D-1.** Accept X-1 as the fix for the chaining gap. This plan assumes yes, since it
  comes from orchestrator policy.
- **D-2.** Contents of `/etc/sudoers.d/jarvis`. T2.3 drafts a *proposal* that is tighter
  than `_SUDO_ALLOW`, per the orchestrator:
  - `purge` with no args only;
  - `mdutil -s` only;
  - `powermetrics` dropped (`-o` writes files as root);
  - no `periodic`.
  The user installs it manually. Until then, `sudo` from a non-TTY child simply fails.
- **D-3.** Enforce sensitive paths (default **ON**). This can refuse legitimate requests,
  for example "read my ssh config".
- **D-4.** Kill a turn when `isUsingOverage` is true (default **ON**).
- **D-5.** Default model `claude-opus-5-5` while keeping the counter `backend_claude`. The
  alternative is the Python formula, which forks the dissertation series into
  `backend_claude_claude_opus_5_5`.
- **D-6.** Keep Python's report string "through the Agent SDK", or reword it for the CLI.
  Default: verbatim.
- **D-7.** The CORE-22 local tool set, used if 46 tools do not fit the on-device context.
- **D-8.** Paste taints the turn (default **ON**).
- **D-9.** Should text turns bump `interactions`? Default **yes**, which keeps the meaning
  "one command handled"; `channel_text` lets the analysis split voice from text. Say no
  if `interactions` must stay voice-only.
- **D-10.** Busy while voice runs: reject rather than queue (default reject).
- **D-11 / D-12.** Local history folding; the 600-token text reply cap.
- **D-13.** `shouldSpeakReply`: the user writes it (§3.12).

### 8.3 Risks and open questions

- **R-1 Opus 5.5 refusals: observed.** The trivial probe was refused twice
  (`category:"cyber"`), and the CLI fell back to `claude-opus-4-8` for the session.
  JARVIS's system prompt ("FULL control … run ANY shell command") may trigger this
  often. Each refused attempt added seconds (TTFT was 7.4 s on the probe). Native records
  the actual serving model (R7) and counts `claude_refusal_fallback`. Whether to reword
  the prompt is a question for the user, and it conflicts with byte-identical prompt
  parity.
- **R-2 CLI surface drift.** `--max-turns` is undocumented in `--help`. The event shapes
  come from one probe of v2.1.282. Pin the version check (`claude --version`) at app
  start and log a mismatch.
- **R-3.** `/etc/sudoers.d/jarvis` is **absent** (the brief said it exists; CHANGELOG:29
  says "installed manually"). Such files are normally unreadable (0440 root), hence the
  repo source-of-truth design.
- **R-4.** The per-launch token is a same-uid secret that lives in a 0600 file. It binds a
  connection to a turn; it does not stop same-uid malware. The uid, ppid and executable
  path checks are the real boundary.
- **R-5.** Python's Claude taint could race with parallel calls. Native serializes (X-6),
  so the native result can differ from Python on those edge cases.
- **R-6.** Taint does not carry across turns in either implementation. A reply that
  summarized hostile content re-enters as history. Open question.
- **R-7.** The on-device context size on macOS 27 is unmeasured (T3.6 measures it). On
  26.x it is fixed at 4096.
- **R-8.** The relay is the full app binary (brief decision). If its RSS is high, move to
  a helper executable in `Contents/MacOS/`.
- **R-9.** `TurnSummary.dataSources` does not cover sensitive data re-entering through the
  history preamble. M8 should treat that as a known limit.
- **R-10.** A limit on this plan itself: the model safety filter stopped two attempts to
  write detailed attack-corpus generation rules. §4 therefore specifies the attack
  corpora only by category and oracle, and their content needs a human or a
  security-scoped task.
- **R-11. Incident.** While planning, I called `emotion_context()` to measure prompt
  size, and it rewrote `~/jarvis/emotions.json`. The values are now the baselines
  (0.6/0.6/0.7/0.8) with `at` set to 2026-09-28. After roughly 52 days idle, the decay
  would have given the same values, but it **was** a state write. No backup of the prior
  bytes exists.

