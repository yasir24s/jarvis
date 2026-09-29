# Claude CLI probe fixtures

Recorded once on 2026-09-28 by running the real `claude` CLI (version 2.1.282) against a
small Python stub MCP server that logged its stdio traffic. These files are replay data.
Nothing in the test suite runs `claude`.

- `probe-2026-09-28.jsonl`: the 35 NDJSON lines `claude` wrote to stdout. The parser
  tests (A-7) read it.
- `mcp-traffic-2026-09-28.log`: the JSON-RPC lines the stub server saw. `<<` is
  client to server, `>>` is server to client. T3.3 replays it.

## Command

This is the command from plan §2.4 (`native/plan/M02-M04-security-brain-chat.md`). It was
run from an empty temp directory under `env -i`, so `ANTHROPIC_API_KEY` was not set.

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

The prompt was "Call the ping tool exactly once, then reply with exactly: pong". The
run exited 0 with empty stderr.

## Redactions

Only `probe-2026-09-28.jsonl` was changed. The macOS account name occurred 3 times, all
in line 1 (the `system`/`init` event):

- `cwd`: the dashed form `-Users-<name>-` inside the scratch path became `-Users-robin-`.
- `memory_paths.auto`: the leading `/Users/<name>/` became `${HOME}/`, and the dashed
  `-Users-<name>-` inside the project directory name became `-Users-robin-`.

The slash form uses `${HOME}`, the token `native/tools/golden.py` uses for the real home
directory, because the pre-commit hook rejects any `/Users/<name>/` path, stand-ins
included. Every other byte is unchanged, including every `session_id` and `uuid`. Both
files were checked for email addresses and personal names, and none were found.
`mcp-traffic-2026-09-28.log` needed no redaction and is byte-identical to the recording.
