# MCP server and relay security review

Reviewed 30 September 2026 at commit `b9b16f450859aba7bb2166bea46a9337c6211cae`.

Scope: all seven files in `native/Sources/JarvisBrain/MCP/` and `native/Sources/JarvisApp/Relay/RelayMain.swift`. I also traced the gateway, turn context, driver, config writer, parser, assembly and existing MCP tests where needed. Paths below are relative to the repository root.

This was a read-only source review. No source or test changes, no worktree access, no live impersonation, resource-exhaustion test or new test run. Scenarios below are derived from source and need isolated regression tests. Existing tests were inspected, not rerun. Claude's independent acceptance of b9b16f4 is separate from this review.

## Summary

I found no direct route around ToolGateway or a client-controlled taint reset. A normal unrelated process connecting to the real socket fails the executable/parent/token checks, assuming the launch files and executables remain intact. Closed tokens cannot authenticate a new connection.

The main gaps are unbounded buffering and connection admission, plus incomplete cancellation of work already admitted when a turn closes. Malformed JSON-RPC envelopes can also reach tool dispatch. These should have focused tests before the side-effecting M5 tools are exposed.

The stronger claim that *no other same-user process can drive tools* is not established. The plan already acknowledges same-UID malware in R-4, but its suggestion that executable and parent-PID checks are a complete boundary needs qualification; see the final section.

## Findings

### 1. Medium / P2: authenticated traffic has no byte limit or backpressure

Locations:

- `native/Sources/JarvisBrain/MCP/MCPServer.swift:114` and `:117`: after binding, data is appended and lines are consumed without a length limit. The 4 KB limit applies only to the handshake.
- `native/Sources/JarvisBrain/MCP/MCPConnection.swift:22`, `:31`, `:39`: the default AsyncStream buffer is unbounded; reads run continuously and response writes have no outstanding-byte budget.
- `native/Sources/JarvisBrain/MCP/MCPConnection.swift:67`: LineBuffer appends without a cap.
- `native/Sources/JarvisBrain/MCP/MCPRelay.swift:95`: the relay keeps reading and scheduling writes without waiting for the destination to drain.

Failing scenarios: a bound client sends a large stream without a newline, so LineBuffer keeps growing. Alternatively it pipelines short requests while one tool is suspended; DispatchIO keeps feeding the unbounded event stream. A client that requests many tools/list responses but stops reading can grow pending output. The relay has the corresponding slow-consumer problem in both directions.

Impact: memory exhaustion or heavy memory pressure in the app/relay, especially on the target 8 GB Mac. Authentication and JSON nesting limits do not bound total traffic. A malfunctioning legitimate Claude process is sufficient; a raw unrelated client cannot reach the post-handshake path without authentication.

Recommendation: impose per-line and aggregate queued-byte limits before copying/parsing, plus bounded pending replies. Pause upstream reads when the destination is backlogged or disconnect at a defined budget. Include slow reader, incomplete line and pipelined-input tests with small, controlled budgets.

### 2. Medium / P2: connection admission is unbounded before authentication

Locations:

- `native/Sources/JarvisBrain/MCP/MCPServer.swift:52`: default unbounded stream of accepted descriptors.
- `native/Sources/JarvisBrain/MCP/MCPServer.swift:55` and `:69`: drains accept into that stream and launches one unstructured task per connection, without a connection cap.
- `native/Sources/JarvisBrain/MCP/MCPServer.swift:90`: peer inspection and channel allocation happen only when the serve task runs.
- `native/Sources/JarvisBrain/MCP/MCPSocket.swift:75`: backlog 8 limits the kernel's pending queue, not descriptors already accepted into application memory.

Failing scenario: another process under the same UID repeatedly connects to the socket while actor work is busy. Its connections are eventually rejected for the wrong executable, but descriptors and serve tasks can accumulate before those checks execute. The two-second handshake timer starts when MCPConnection is constructed, not when a descriptor first enters the accepted stream. The accept drain also shares the serial I/O queue with connection callbacks.

Impact: local denial of service through descriptor/task pressure or delayed legitimate connections. No token is needed for this admission path. Exact exhaustion rate was not measured.

Recommendation: cap admitted connections at accept time, close excess descriptors immediately, and bound the accept handoff. Apply cheap peer checks before creating long-lived channels/tasks. Track accepted-but-not-yet-served descriptors so stop() also closes them and late serve tasks cannot recreate connections after stop.

### 3. Medium / P2: turn revocation does not stop already-admitted asynchronous tool work

Locations:

- `native/Sources/JarvisBrain/MCP/MCPTurnRegistry.swift:78`: closeTurn removes the registry entry and files, but neither closes its connection nor cancels its serve/tool task.
- `native/Sources/JarvisBrain/MCP/MCPServer.swift:192` and `:199`: checks openness before awaiting gateway.call; no lifetime handle accompanies the call.
- `native/Sources/JarvisTools/Gateway/ToolGateway.swift:48`, `:55`, `:120`, `:124`: queueing and actor hops separate admission from handler execution; the handler can remain suspended after the initial open check.
- `native/Sources/JarvisTools/Gateway/TurnContext.swift:139`: close() only flips a Boolean; it does not cancel or drain the FIFO.
- `native/Sources/JarvisBrain/MCP/MCPServer.swift:83`: stop() aborts sockets, but does not track/cancel a serve task currently awaiting a handler.

Failing scenario: an authenticated request enters an async tool handler that waits before performing its side effect. Close the TurnContext and registry, or stop the server, while that handler is suspended. Release its wait: nothing in this transport/gateway path prevents the handler from performing the effect afterward. A related queue case exists when an MCP call passes the registry check, then waits behind another gateway operation while only the MCP registry is closed; the still-open shared TurnContext allows it to run later.

Impact: revocation prevents subsequent requests, but does not guarantee that admitted work has ceased. This is chiefly a forward-looking concern for asynchronous side-effecting M5 handlers; this review does not claim an existing arbitrary shell execution exploit. Already-completed effects cannot be undone by cancellation.

Recommendation: define whether turn close cancels or drains admitted work, enforce that contract, and track task lifetimes per binding. For cancellation, handlers need a revocation/cancellation check at their side-effect boundary; Task.cancel alone is cooperative. Preserve shared taint when falling back to the local model, using a separate revocable MCP capability if needed. Add a barrier-controlled handler test covering registry close, turn close and server stop.

An idle bound connection also remains alive after registry close until EOF or server stop. Its later requests receive Turn closed, so this is retained state/resource exposure, not a fresh-token reuse bypass. The existing `requestsAfterCloseTurnAreTurnClosed` test intentionally exercises that response behaviour.

### 4. Low / P3: malformed JSON-RPC envelopes still dispatch tools

Locations:

- `native/Sources/JarvisBrain/MCP/MCPJSONRPC.swift:47`: parse checks for an object and method, but never validates jsonrpc == "2.0".
- `native/Sources/JarvisBrain/MCP/MCPJSONRPC.swift:60`: an invalid ID becomes null in a request rather than an Invalid Request response.
- `native/Sources/JarvisBrain/MCP/MCPJSONRPC.swift:82`: that request can reach callTool.

Failing scenario: a bound client sends `{"jsonrpc":"wrong","id":{},"method":"tools/call","params":{"name":"get_time","arguments":{}}}`. Source tracing shows a tool call with a null response ID, not rejection of the invalid envelope. Replacing get_time with a registered side-effecting tool would reach its normal gateway checks too.

Impact: malformed input can have effects and lose usable request correlation. This is protocol hardening, not an authentication or taint bypass. The plan's JSON-RPC subset specifies jsonrpc:"2.0" at `native/plan/M02-M04-security-brain-chat.md:866`.

Recommendation: reject invalid versions and invalid ID types before dispatch. Distinguish malformed argument types from absent arguments if the compatibility contract permits it. Keep the Python-compatible parser separate from strict transport-envelope validation.

## Same-user process boundary: acknowledged risk, not a new proven exploit

Severity: informational under the accepted R-4 threat model; potentially high impact if hostile same-UID processes are meant to be excluded.

References: `native/plan/M02-M04-security-brain-chat.md:1237`; `native/Sources/JarvisBrain/MCP/MCPTurnRegistry.swift:60`; `native/Sources/JarvisBrain/Claude/ClaudeInvocation.swift:35` and `:76`; `native/Sources/JarvisBrain/MCP/MCPServer.swift:149`; `native/Sources/JarvisBrain/MCP/MCPTurnRegistry.swift:103`.

0700/0600 protect against other users, not another process with this UID. O_EXCL/O_NOFOLLOW protect file creation; they do not stop that process rewriting a config after creation. The following launch-race scenario warrants an isolated test if the stronger guarantee matters:

1. A same-UID process watches the run directory and rewrites a newly created MCP config before Claude consumes it.
2. It changes the command to a launcher that redirects stdin/stdout to attacker-controlled pipes and then execs the real JARVIS relay, retaining the direct Claude parent PID.
3. The real relay reads the real token and connects. Its UID, executable path, parent PID and token can all satisfy the existing checks, while tool-call bytes come from the other process.

This depends on winning the config-read race and on the actual Claude launch behaviour; I did not reproduce it. It does not bypass ToolGateway or confirmations. It shows why a filename-based config plus process ancestry should not be described as proving the origin of every input byte. A harmless get_time exchange would be enough for a future reproduction; do not use destructive tools.

The relay also does not authenticate the server before sending its token (`MCPRelay.swift:40` and `:55`). A same-UID process able to replace the socket pathname can impersonate the server and return the public OK marker. That can capture/forge relay traffic, but possession of the token alone still does not satisfy the real server's parent/executable checks. Both observations fall within the existing same-UID malware limitation.

If this threat is in scope, revisit the transport/launch design with protected endpoint capabilities or an OS-enforced process boundary. More chmod calls or a second secret in another same-user file will not establish that boundary. If it is out of scope, document it explicitly and retain the existing checks as defence in depth.

## Controls confirmed in source

- Socket directory: final component must be a directory owned by the current UID, made 0700; socket is made 0600. Final-component symlinks and non-socket stale entries are refused. Parent-component replacement is not comprehensively defended; the default trusted Application Support location matters.
- Token: 32 bytes from SecRandomCopyBytes, checked error status, hex encoded; exclusive/no-follow 0600 creation; config carries only its path. Failed claims do not consume the token; the first successful claim sets bound. Comparison walks all expected bytes without an early mismatch return. No claim is made about compiler-level constant-time guarantees.
- Revocation: registry removal rejects fresh claims and later requests on an existing binding. File unlink failures are ignored, but a leftover token is absent from the registry and cannot authenticate by itself. A new registry after restart has no old entries.
- Peer checks: same UID, kernel peer PID, executable path and registered Claude parent PID are required. These identify a process at connection time; they are not code-signature verification or protection against writable launch inputs.
- Gateway: every parsed tools/call action routes through the injected gateway with the bound TurnContext and .model(.claude). Per-turn FIFO preserves tool ordering; successful untrusted reads taint that same context. Client-supplied turn/taint fields are not used. Existing tests cover read_file followed by blocked run_command.
- Parsing: invalid UTF-8, malformed JSON and batch arrays fail; PyJSON limits nesting to 512 and integer literals to 4,300 digits. These do not impose a message-byte limit.
- Descriptors: socket setup uses close-on-exec and SO_NOSIGPIPE; DispatchIO cleanup closes the server connection descriptor. RelayMain ignores SIGPIPE and keeps diagnostics on stderr. Normal EOF/error paths have cleanup. Admission queues and suspended work remain the concerns above.

## Suggested next checks

Use isolated sockets and inert fake handlers to test bounded input/output, pre-auth admission limits, revocation during a suspended handler, and malformed envelopes. Extend peer tests beyond in-process socketpairs: existing MCPHarness makes the test process its own peer and uses its parent as the registered Claude PID, so it does not prove the complete real Claude-to-relay launch chain. No claim of exhaustive security acceptance is made here.
