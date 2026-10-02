import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// B2 part 2: the ChatGPT driver against a fake `codex` (CodexDriverFakes.swift: a /bin/sh
/// script replaying exec's JSON events) and a bridge that writes the turn's MCP config. No test
/// runs a real `codex`.
@Suite("B2 ChatGPT driver: C1-C6, salvage, stop sequence, errors", .timeLimit(.minutes(1)))
struct CodexDriverTests {
    static let tools = ["get_time", "run_command"]
    static let system = "You are a test assistant.\n- Reply briefly."
    static let user = "What's the time? It's “urgent” — reply briefly."
    static let unavailable = "ChatGPT unavailable this turn — using local model: "

    struct Run {
        let fake: FakeCodex
        let bridge: ConfigBridge
        let sink = RecordingSink()
        let backend = RecordingBackend()
        let bumps = BumpRecorder()
        let logs = LogRecorder()
        let turn: TurnContext
        let parent: [String: String]
        let driver: CodexDriver

        /// As ClaudeDriverTests' Run: the timeout fires only through `timeoutWait`, and the
        /// grace is 30 s unless a test asks for the real one.
        init(_ fake: FakeCodex, channel: Channel = .voice, config: CodexConfig = CodexConfig(environment: [:]),
             timeout: Duration = .seconds(30),
             timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) },
             stopGrace: Duration = .seconds(30), executable: URL? = nil, failOpen: Bool = false,
             parent extra: [String: String] = [:]) {
            self.fake = fake
            bridge = ConfigBridge(runDirectory: fake.runDirectory, failOpen: failOpen)
            turn = TurnContext(channel: channel)
            var parent = ["HOME": fake.dir.path(percentEncoded: false), "USER": "robin", "LOGNAME": "robin",
                          "TMPDIR": FileManager.default.temporaryDirectory.path(percentEncoded: false),
                          "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            parent.merge(extra) { _, new in new }
            self.parent = parent
            driver = CodexDriver(config: config, executable: executable ?? fake.script, bridge: bridge,
                                 workingDirectory: fake.cwd, research: bumps, backend: backend,
                                 parentEnvironment: parent, allowedTools: CodexDriverTests.tools,
                                 timeout: timeout, timeoutWait: timeoutWait, stopGrace: stopGrace,
                                 log: logs.function)
        }

        func generate() async -> String? {
            await driver.generate(system: CodexDriverTests.system, user: CodexDriverTests.user, turn: turn, sink: sink)
        }

        func bridgeSawOneFullTurn() async -> Bool {
            let id = await turn.turnID
            guard let pid = await bridge.pid, pid > 0 else { return false }
            return await bridge.calls == [.open(id), .pid(pid, id), .close(id)]
        }
    }

    static func eventually(seconds: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let end = SuspendingClock.now + .seconds(seconds)
        while SuspendingClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func toolTurn(reply: String = "It's 1:09 pm. Anything else?") -> [String] {
        [CodexLine.thread, CodexLine.turnStarted,
         CodexLine.toolStarted("item_0", tool: "get_time"), CodexLine.toolCompleted("item_0", tool: "get_time"),
         CodexLine.message("item_1", reply), CodexLine.turnCompleted]
    }

    // MARK: - What codex is given

    @Test func argvEnvironmentCwdStdinAndCatalog() async throws {
        let fake = try FakeCodex(Self.toolTurn(), ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake, parent: ["OPENAI_API_KEY": "sk-test-not-real", "CODEX_HOME": "/tmp/elsewhere",
                                     "ANTHROPIC_API_KEY": "x", "CLAUDE_CODE_OAUTH_TOKEN": "y", "SHELL": "/bin/zsh",
                                     "HTTPS_PROXY": "http://proxy.test:8080", "JARVIS_CODEX_CLI": "/x/codex"])
        #expect(await run.generate() == "It's 1:09 pm. Anything else?")

        let id = await run.turn.turnID
        let catalog = CodexInvocation.catalogURL(in: fake.runDirectory, turnID: id)
        let expected = try CodexInvocation(
            executable: fake.script, workingDirectory: fake.cwd, catalog: catalog,
            relay: .init(command: ConfigBridge.relayCommand,
                         arguments: ["--mcp-relay", fake.runDirectory.appending(path: "mcp.sock").path(percentEncoded: false),
                                     "--token-file",
                                     fake.runDirectory.appending(path: "turn-\(id.uuidString.lowercased()).token").path(percentEncoded: false)]),
            enabledTools: Self.tools, config: CodexConfig(environment: [:]))
        #expect(fake.argv == expected.arguments)

        // An allowlist, not the parent minus a denylist: no key, token, CODEX_HOME or Claude's.
        let env = try #require(fake.environment)
        #expect(Set(env.keys).isSubset(of: ChildEnvironment.codexAllowlist))
        #expect(env["CODEX_HOME"] == nil && env["OPENAI_API_KEY"] == nil && env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil && env["JARVIS_CODEX_CLI"] == nil)
        #expect(env["HOME"] == run.parent["HOME"] && env["USER"] == "robin" && env["LANG"] == "en_US.UTF-8")
        #expect(env["SHELL"] == "/bin/zsh" && env["HTTPS_PROXY"] == "http://proxy.test:8080")

        #expect(fake.text("cwd")?.trimmingCharacters(in: .newlines) == Self.realPath(fake.cwd))
        let mode = try FileManager.default.attributesOfItem(atPath: fake.cwd.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(fake.text("stdin") == Self.user)   // all of it, as typed, and nothing else

        // The catalog codex was given held the system prompt, and is gone after the turn.
        let copied = try PyJSON.loads(Data(contentsOf: fake.dir.appending(path: "catalog.json")))
        #expect(copied == CodexInvocation.catalog(model: "gpt-6-luna", instructions: Self.system))
        #expect(!FileManager.default.fileExists(atPath: catalog.path(percentEncoded: false)))
        #expect(await run.bridgeSawOneFullTurn())
    }

    // MARK: - C3 and success

    @Test func aToolTurnIsAnswered() async throws {
        let fake = try FakeCodex(Self.toolTurn(), ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "It's 1:09 pm. Anything else?")
        #expect(await run.sink.deltas == ["It's 1:09 pm. Anything else?"])
        #expect(await run.sink.sentences == ["It's 1:09 pm.", "Anything else?"])
        #expect(await run.backend.names == ["chatgpt (gpt-6-luna)"])
        #expect(await run.driver.lastToolCalls == ["jarvis.get_time"])
        #expect(await run.driver.lastBuiltIns == [])
        #expect(await run.driver.lastError == nil)
        #expect(await run.driver.lastExit == 0)
        let usage = try #require(await run.driver.lastUsage)
        #expect(usage.input == 1834 && usage.output == 21)
        #expect(run.logs.lines.isEmpty)
        #expect(await run.turn.isOpen)   // only a stop revokes the turn
    }

    /// exec's JSON has no text deltas, so each message reaches the sink as it completes: the
    /// first while codex is still running.
    @Test func eachMessageIsStreamedAsItCompletes() async throws {
        let fake = try FakeCodex([[CodexLine.thread, CodexLine.turnStarted, CodexLine.message("item_0", "Checking now.")],
                                  [CodexLine.toolStarted("item_1", tool: "get_time"),
                                   CodexLine.toolCompleted("item_1", tool: "get_time"),
                                   CodexLine.message("item_2", "It's 1:09 pm."), CodexLine.turnCompleted]],
                                 pause: 1.0, ending: .exit(0))
        defer { fake.remove() }
        let firstDelta = Stamp()
        let sink = StampingSink(first: firstDelta)
        let run = Run(fake)
        let reply = await run.driver.generate(system: Self.system, user: Self.user, turn: run.turn, sink: sink)
        let end = ContinuousClock.now
        #expect(reply == "Checking now.\n\nIt's 1:09 pm.")
        let first = try #require(firstDelta.instant)
        #expect(end - first >= .milliseconds(700), "the first message waited for the end of the turn")
        let deltas = await sink.deltas, sentences = await sink.sentences
        #expect(deltas == ["Checking now.", "\n\n", "It's 1:09 pm."])
        #expect(sentences == ["Checking now.", "It's 1:09 pm."])
    }

    @Test func anEmptyReplyFallsBack() async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.message("item_0", "  "), CodexLine.turnCompleted],
                                 ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(run.logs.lines == [Self.unavailable + "empty response"])
        #expect(await run.backend.names == [])
    }

    // MARK: - C1 and C2: nothing but JARVIS's tools

    @Test(arguments: ["command_execution", "file_change", "web_search", "collab_tool_call", "todo_list", "image_view"])
    func aBuiltInToolStopsTheTurn(_ type: String) async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.turnStarted, CodexLine.item(type)], ending: .hang)
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == "built-in tool: \(type)")
        #expect(await run.driver.lastBuiltIns == [type])
        #expect(await run.driver.lastExit == -SIGTERM)
        #expect(run.logs.lines == ["ChatGPT: stopping codex (built-in tool: \(type)): SIGTERM",
                                   Self.unavailable + CodexReason.reason("built-in tool: \(type)")])
        #expect(await !run.turn.isOpen)   // the stop revoked the MCP turn
        #expect(await run.bridgeSawOneFullTurn())
    }

    @Test(arguments: [("other", "get_time"), ("jarvis", "delete_everything")])
    func aCallToAnotherServerOrToolStopsTheTurn(_ server: String, _ tool: String) async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.toolStarted("item_0", server: server, tool: tool)],
                                 ending: .hang)
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == "unexpected tool: \(server).\(tool)")
        #expect(await run.driver.lastToolCalls == [])
    }

    @Test func contentBeforeTheThreadEventStopsTheTurn() async throws {
        let fake = try FakeCodex([CodexLine.message("item_0", "Hello."), CodexLine.thread], ending: .hang)
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == "no thread event before content")
        #expect(await run.sink.deltas == [])
    }

    // MARK: - C4 and C5: errors, each a reason

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        let name: String
        let lines: [String]
        let ending: FakeCodex.Ending
        let error: String
        let reason: String
        var testDescription: String { name }

        static let signedOut = "Reconnecting... 1/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://chatgpt.com/backend-api/codex/responses)"
        static let usage = "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), or try again later."
        static let offline = "Reconnecting... waiting for network (Connection failed: error sending request)"
        static let retries = "exceeded retry limit, last status: 429 Too Many Requests"
        static let demand = "We’re currently experiencing high demand, which may cause temporary errors."

        static let all: [ErrorCase] = [
            // A retry notice that cannot succeed stops codex at once; it would retry for ~25 s
            // signed out, and wait for the network with no end offline.
            ErrorCase(name: "signed out", lines: [CodexLine.thread, CodexLine.turnStarted, CodexLine.error(signedOut)],
                      ending: .hang, error: signedOut, reason: "not signed in"),
            ErrorCase(name: "usage limit", lines: [CodexLine.thread, CodexLine.error(usage)],
                      ending: .hang, error: usage, reason: "rate limited"),
            ErrorCase(name: "offline", lines: [CodexLine.thread, CodexLine.turnStarted, CodexLine.error(offline)],
                      ending: .hang, error: offline, reason: "network unreachable"),
            ErrorCase(name: "rate limited after retries",
                      lines: [CodexLine.thread, CodexLine.error(retries), CodexLine.turnFailed(retries)],
                      ending: .hang, error: retries, reason: "rate limited"),
            // A server error codex gives up on ends the turn with turn.failed.
            ErrorCase(name: "turn failed", lines: [CodexLine.thread, CodexLine.error("Reconnecting... 1/5 (" + demand + ")"),
                                                   CodexLine.turnFailed(demand)],
                      ending: .exit(1), error: "turn failed: " + demand,
                      reason: Py.prefix("turn failed: " + demand, 80)),
        ]
    }

    @Test(arguments: ErrorCase.all)
    func eachErrorIsLoggedAsAReason(_ c: ErrorCase) async throws {
        let fake = try FakeCodex(c.lines, ending: c.ending)
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == c.error)
        #expect(run.logs.lines.last == Self.unavailable + c.reason)
        #expect(await run.backend.names == [])
        #expect(await run.bridgeSawOneFullTurn())
    }

    @Test func aMissingCodexIsCLINotFound() async throws {
        let fake = try FakeCodex([CodexLine.thread], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake, executable: fake.dir.appending(path: "no-such-codex"))
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == CodexLocator.notFoundMessage)
        #expect(run.logs.lines == [Self.unavailable + "Codex CLI not found"])
        #expect(await run.driver.lastExit == nil)
    }

    @Test func endingWithoutTurnCompletedReportsTheExit() async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.turnStarted], stderr: "thread panicked\n", ending: .exit(3))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == "exit 3: thread panicked")
    }

    @Test func aBridgeFailureFallsBackWithoutStartingCodex() async throws {
        let fake = try FakeCodex([CodexLine.thread], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake, failOpen: true)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError?.hasPrefix("tool bridge: ") == true)
        #expect(!fake.exists("argv"))
        let id = await run.turn.turnID
        #expect(await run.bridge.calls == [.open(id), .close(id)])
    }

    // MARK: - Salvage

    /// A message is complete when it arrives, so what was shown is what was spoken: both
    /// channels keep the first message when the turn then fails.
    @Test(arguments: [Channel.voice, .text])
    func aFailureAfterAMessageKeepsIt(_ channel: Channel) async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.message("item_0", "It is sunny. Let me check the time."),
                                  CodexLine.toolStarted("item_1", tool: "get_time"),
                                  CodexLine.turnFailed("stream disconnected before completion")], ending: .exit(1))
        defer { fake.remove() }
        let run = Run(fake, channel: channel)
        #expect(await run.generate() == "It is sunny. Let me check the time.")
        #expect(await run.sink.sentences == ["It is sunny.", "Let me check the time."])
        #expect(await run.backend.names == ["chatgpt (partial)"])
        #expect(await run.driver.lastError == "turn failed: stream disconnected before completion")
        #expect(run.logs.lines.isEmpty)
    }

    // MARK: - The stop sequence

    @Test func timeoutSendsTermThenKill() async throws {
        let fake = try FakeCodex([CodexLine.thread], ending: .hangIgnoringTerm)
        defer { fake.remove() }
        let fired = Stamp()
        let run = Run(fake, timeout: .seconds(1), timeoutWait: { _ in
            while !fake.exists("stdin") { try await Task.sleep(for: .milliseconds(10)) }
            fired.mark()
        }, stopGrace: CodexDriver.stopGrace)
        #expect(await run.generate() == nil)
        let end = ContinuousClock.now
        let firedAt = try #require(fired.instant)
        #expect(end - firedAt >= CodexDriver.stopGrace)
        #expect(await run.driver.lastError == "timeout after 1000 ms")
        #expect(run.logs.lines == ["ChatGPT: stopping codex (timeout after 1000 ms): SIGTERM",
                                   "ChatGPT: codex still running 2 s after SIGTERM: SIGKILL",
                                   Self.unavailable + "timed out"])
        #expect(await !run.turn.isOpen)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(await run.driver.lastExit == -SIGKILL)
    }

    /// UI1's Stop cancels the turn's task: codex is stopped and the MCP turn revoked.
    @Test func cancellingTheCallerStopsTheChild() async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.turnStarted], ending: .hang)
        defer { fake.remove() }
        let run = Run(fake)
        let task = Task { await run.generate() }
        #expect(await Self.eventually { fake.exists("stdin") })
        task.cancel()
        #expect(await task.value == nil)
        #expect(await run.driver.lastError == "cancelled")
        #expect(await run.driver.lastExit == -SIGTERM)
        #expect(await !run.turn.isOpen)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(run.logs.lines == ["ChatGPT: stopping codex (cancelled): SIGTERM", Self.unavailable + "timed out"])
    }

    // MARK: - Names

    @Test func backendNamesAndReasons() {
        #expect(CodexDriver.wallTimeout(for: CodexConfig(environment: [:])) == .seconds(60))
        #expect(CodexDriver.wallTimeout(for: CodexConfig(environment: ["JARVIS_CHATGPT_TIMEOUT_MS": "x"])) == .seconds(60))
        #expect(CodexDriver.wallTimeout(for: CodexConfig(environment: ["JARVIS_CHATGPT_TIMEOUT_MS": "5000"])) == .seconds(20))
        #expect(CodexDriver.successBackend(model: "gpt-6-luna") == "chatgpt (gpt-6-luna)")
        #expect(BackendReporter.counterKey("chatgpt (gpt-6-luna)") == "backend_chatgpt_gpt_6_luna_")
        #expect(BackendReporter.counterKey(CodexDriver.partialBackend) == "backend_chatgpt_partial_")
        #expect(CodexReason.reason("unexpected status 401 Unauthorized: Missing bearer") == "not signed in")
        #expect(CodexReason.reason("exceeded retry limit, last status: 429 Too Many Requests") == "rate limited")
        #expect(CodexReason.reason("Reconnecting... waiting for network (Connection failed: error sending request)")
                == "network unreachable")
        #expect(CodexReason.reason("enoent: codex") == "Codex CLI not found")
        #expect(CodexReason.reason("timeout after 60000 ms") == "timed out")
        #expect(CodexReason.reason("  ") == "unavailable")
    }
}

/// A sink that records like RecordingSink and stamps the first delta. It keeps its own
/// arrays: a call to RecordingSink's `delta` from another actor resolves to ReplySink's
/// default `delta`, which does nothing.
actor StampingSink: ReplySink {
    let first: Stamp
    private(set) var sentences: [String] = []
    private(set) var deltas: [String] = []

    init(first: Stamp) {
        self.first = first
    }

    func sentence(_ text: String) {
        sentences.append(text)
    }

    func delta(_ text: String) {
        first.mark()
        deltas.append(text)
    }

    func retracted(messageID: String) {}
}
