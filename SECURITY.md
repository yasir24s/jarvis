# Security Policy

JARVIS is a local, always-listening voice assistant that can execute shell commands,
run AppleScript, control apps, and read files on the host Mac. That capability is
powerful, so this document sets out the threat model, the controls in place, and the
residual risks an operator should understand.

## Security model
- **Local-first.** The LLM (Ollama), speech-to-text (Whisper), text-to-speech (Piper),
  and speaker recognition all run on-device — no cloud "brain."
- **Minimal, opt-in network egress:** web/Wikipedia lookups, HTTPS geolocation, and
  optional ambient song ID (AudD). Online speech-to-text (Google) is used when available;
  switch to offline Whisper to keep speech on-device.
- **Runs as a user-level LaunchAgent** with the user's privileges plus whatever TCC grants
  the operator chooses (Microphone, Automation, Screen Recording, Full Disk Access).

## Trust boundaries
| Source | Trust | Notes |
|---|---|---|
| Enrolled user's voice | Trusted (after speaker verification) | The only source that should issue commands |
| Other voices / TV / recordings | Untrusted | Filtered by speaker verification (see residual risks) |
| Web results, screen OCR, clipboard, file contents | **Untrusted data** | Never treated as instructions |
| Local model tool-calls | Constrained | Gated by the controls below |

## Controls implemented
1. **Prompt-injection containment (primary control).** Once the model ingests untrusted
   content (`web_search`, `see_screen`, `read_clipboard`, `read_file`, `get_messages`),
   shell and AppleScript execution are disabled for the rest of that request — breaking
   the "read a malicious page → run a command" chain.
2. **Destructive-command denylist.** `run_command` refuses `rm -rf`, `curl|sh`, `sudo`,
   `dd`, `mkfs`, reverse shells, `launchctl`, `chmod 777`, reads of `~/.ssh`/keychains, and
   writes to system paths. `run_applescript` refuses `do shell script`, administrator
   privileges, and System Events automation.
3. **Least-privilege file reads.** `read_file` denies sensitive locations (SSH keys,
   keychains, Messages database, tokens, the voiceprint).
4. **Speaker verification.** With enrollment, only the operator's voice triggers actions.
5. **Injection-safe interpolation.** AppleScript strings are escaped; HUD captions are
   JSON-encoded before injection; URLs are percent-encoded; YouTube IDs are constrained.
6. **No plaintext network secrets.** Geolocation uses HTTPS; all HTTPS uses the `certifi`
   CA bundle.
7. **Secret hygiene.** `.gitignore` plus a tracked pre-commit hook (`.githooks/pre-commit`)
   block committing tokens, keys, the voiceprint, logs, and personal caches.
8. **Untrusted-content prompt rule.** The system prompt instructs the model to treat
   external content as data, never as instructions.
9. **File integrity.** The project directory is made non-writable by group/other (the
   `.app` bundle runs the live source).

## Residual risks & limitations (read this)
- **Denylists are not exhaustive.** They raise the bar, but a novel payload could evade
  pattern matching. The primary defense is the injection-containment control (#1), not the
  denylist.
- **Voice replay.** Speaker verification is not liveness-aware; a recording of the
  operator's voice could pass, and speaker ID is optional (off until enrolled).
- **Small-model behaviour.** The local 3B model has limited instruction-hierarchy
  robustness; the controls assume the model *can* be manipulated and constrain it externally.
- **Third-party egress when online.** Online STT (Google), AudD (ambient audio), and web
  lookups send data off-device. Run offline (Whisper) and skip AudD to avoid this.
- **TCC scope.** With Full Disk Access / Automation granted, a successful compromise has
  broad reach — grant only what you use.
- **Lock screen.** macOS reserves microphone-while-locked for Siri; JARVIS does not (and
  cannot) bypass that.

## Hardening recommendations for operators
- Enroll your voice; keep the repo private if it reflects your exact setup.
- Grant only the TCC permissions you actually use.
- Prefer offline STT if you don't want speech leaving the device.
- Periodically review `run_command` activity in `logs/`.

## Future work
- Sandbox `run_command` (restricted execution profile) and move from a denylist to an
  allowlist of approved operations.
- Require a confirmation step for any state-changing command.
- Liveness / anti-replay for speaker verification.

## Reporting a vulnerability
Please report security issues **privately** via GitHub Security Advisories
(**Security ▸ Report a vulnerability**) on this repository, rather than opening a public
issue. Include reproduction steps and impact; you'll get an acknowledgement and a fix
timeline.
