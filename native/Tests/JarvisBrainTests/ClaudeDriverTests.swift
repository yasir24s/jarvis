import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// T3.4 (plan M02-M04 §3.6): the driver against a fake `claude` (ClaudeDriverFakes.swift: a
/// /bin/sh script replaying the probe recording or a hand-made transcript) and a fake MCP
/// bridge. No test runs a real `claude`.
@Suite("M3 Claude driver: run loop R1-R10, salvage, stop sequence", .timeLimit(.minutes(1)))
struct ClaudeDriverTests {
    /// The probe served only this tool, so R3 passes with it as the allowed set.
    static let ping = ["mcp__jarvis__ping"]
    static let system = "You are a test assistant.\n- Reply briefly."
    static let user = "Call the ping tool exactly once, then reply with exactly: pong"
    /// The probe's two refused messages, in order.
    static let probeRefusedIDs = ["msg_011CfVnAMKLzhzDLagZZB3UU", "msg_011CfVnAWdvwURqsySYN9Pkp"]
    static let unavailable = "Claude unavailable this turn — using local model: "

    /// One driver, its fakes and its turn.
    struct Run {
        let fake: FakeClaude
        let bridge: FakeBridge
        let sink = RecordingSink()
        let backend = RecordingBackend()
        let bumps = BumpRecorder()
        let logs = LogRecorder()
        let turn: TurnContext
        let parent: [String: String]
        let config: ClaudeConfig
        let driver: ClaudeDriver

        /// No timing races: the wall timeout fires only through a test's `timeoutWait`, and
        /// the SIGTERM-to-SIGKILL grace is 30 s, far longer than a child dying of SIGTERM
        /// takes, so SIGKILL can only come into a test that asks for it
        /// (`timeoutSendsTermThenKill` uses the real 2 s).
        init(_ fake: FakeClaude, channel: Channel = .voice, config: ClaudeConfig = ClaudeConfig(environment: [:]),
             timeout: Duration = .seconds(30),
             timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) },
             stopGrace: Duration = .seconds(30), executable: URL? = nil, failOpen: Bool = false) {
            self.fake = fake
            self.config = config
            bridge = FakeBridge(runDirectory: fake.runDirectory, failOpen: failOpen)
            turn = TurnContext(channel: channel)
            parent = ["HOME": fake.dir.path(percentEncoded: false), "USER": "robin", "LOGNAME": "robin",
                      "TMPDIR": FileManager.default.temporaryDirectory.path(percentEncoded: false),
                      "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            driver = ClaudeDriver(config: config, executable: executable ?? fake.script, bridge: bridge,
                                  workingDirectory: fake.cwd, research: bumps, backend: backend,
                                  parentEnvironment: parent, allowedTools: ClaudeDriverTests.ping,
                                  timeout: timeout, timeoutWait: timeoutWait, stopGrace: stopGrace,
                                  log: logs.function)
        }

        func generate() async -> String? {
            await driver.generate(system: ClaudeDriverTests.system, user: ClaudeDriverTests.user, turn: turn, sink: sink)
        }

        /// open, setClaudePID with the child's pid, close: once each, for this turn.
        func bridgeSawOneFullTurn() async -> Bool {
            let id = await turn.turnID
            guard let pid = await bridge.pid, pid > 0 else { return false }
            return await bridge.calls == [.open(id), .pid(pid, id), .close(id)]
        }
    }

    static func eventually(seconds: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: - The probe replay

    @Test func probeReplay() async throws {
        let fake = try FakeClaude(transcript: Transcript.probe(), ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "pong")
        #expect(await run.sink.sentences == ["pong"])
        #expect(await run.sink.deltas == ["p", "ong"])
        #expect(await run.sink.retractedIDs == Self.probeRefusedIDs)
        #expect(run.bumps.bumps == ["claude_refusal_fallback+1"])
        #expect(await run.backend.names == ["claude"])
        #expect(await run.bridgeSawOneFullTurn())
        #expect(await run.driver.servingModel == "claude-opus-4-8")
        #expect(await run.driver.lastError == nil)
        #expect(await run.driver.lastExit == 0)
        #expect(await run.turn.isOpen)
        #expect(run.logs.lines == ["Claude refusal fallback: claude-opus-5-5→claude-opus-4-8 (cyber)"])
    }

    @Test func argvEnvironmentCwdAndStdin() async throws {
        let fake = try FakeClaude(transcript: Transcript.probe(), ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "pong")
        let expected = try ClaudeInvocation(
            executable: fake.script, systemPrompt: Self.system,
            mcpConfig: ClaudeInvocation.mcpConfigURL(in: fake.runDirectory, turnID: await run.turn.turnID),
            allowedTools: Self.ping, config: run.config)
        let argv = try #require(fake.argv)
        #expect(argv == expected.arguments)
        for arg in argv {
            #expect(!ClaudeInvocation.forbiddenFlags.contains { arg == $0 || arg.hasPrefix($0 + "=") })
            #expect(!arg.contains("bypassPermissions"))
        }
        #expect(fake.text("stdin") == ClaudeDriver.stdinLine(user: Self.user))
        #expect(fake.environment == ChildEnvironment.forClaude(parent: run.parent, config: run.config, log: { _ in }))
        // The driver made claude-cwd (mode 0700), ran claude in it, and it is still empty.
        let cwd = try #require(Self.realPath(fake.cwd))
        #expect(fake.text("cwd") == cwd + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: cwd)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cwd).isEmpty)
    }

    @Test func aNonDefaultModelKeepsPythonsBackendName() async throws {
        let fake = try FakeClaude(transcript: Transcript.probe(), ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake, config: ClaudeConfig(environment: ["JARVIS_CLAUDE_MODEL": "claude-sonnet-test"]))
        #expect(await run.generate() == "pong")
        #expect(await run.backend.names == ["claude (claude-sonnet-test)"])
        let argv = try #require(fake.argv)
        let model = try #require(argv.firstIndex(of: "--model"))
        #expect(argv[model + 1] == "claude-sonnet-test")
    }

    // MARK: - R1-R3: the init event

    struct InitEdit: Sendable, CustomTestStringConvertible {
        let from: String
        let to: String
        let error: String
        var testDescription: String { error + " (" + to + ")" }

        static let all = [
            InitEdit(from: #""apiKeySource":"none""#, to: #""apiKeySource":"ANTHROPIC_API_KEY""#,
                     error: "subscription-only: apiKeySource=ANTHROPIC_API_KEY"),
            InitEdit(from: #""status":"connected""#, to: #""status":"failed""#, error: "tool bridge not connected"),
            InitEdit(from: #""tools":["mcp__jarvis__ping"]"#, to: #""tools":["mcp__jarvis__ping","Bash"]"#,
                     error: "unexpected tool set"),
            InitEdit(from: #""tools":["mcp__jarvis__ping"]"#, to: #""tools":[]"#, error: "unexpected tool set"),
        ]
    }

    @Test(arguments: InitEdit.all)
    func initGuardStopsTheChild(_ edit: InitEdit) async throws {
        var lines = try Transcript.probe()
        try #require(lines[0].components(separatedBy: edit.from).count == 2)
        lines[0] = lines[0].replacingOccurrences(of: edit.from, with: edit.to)
        let fake = try FakeClaude(transcript: lines, ending: .hang)
        defer { fake.remove() }
        let run = Run(fake)                         // no wall timeout: only the guard can stop it
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == edit.error)
        #expect(await run.driver.lastExit == -SIGTERM)   // the child died of SIGTERM
        #expect(await !run.turn.isOpen)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(await run.sink.sentences.isEmpty)
        #expect(await run.sink.deltas.isEmpty)
        #expect(await run.backend.names.isEmpty)
        #expect(run.logs.lines == ["Claude: stopping claude (\(edit.error)): SIGTERM",
                                   Self.unavailable + ClaudeReason.reason(edit.error)])
    }

    // MARK: - Fail closed without init

    struct EarlyLine: Sendable, CustomTestStringConvertible {
        let name: String
        let line: String
        var testDescription: String { name }

        static let all = [
            EarlyLine(name: "message_start", line: Transcript.messageStart("msg_early")),
            EarlyLine(name: "text delta", line: Transcript.delta("Hello there. ")),
            EarlyLine(name: "assistant text block", line: Transcript.block("msg_early", "Hello there.")),
            EarlyLine(name: "tool result", line: Transcript.toolResult("pong-from-tool")),
            EarlyLine(name: "stop reason", line: Transcript.stop("end_turn")),
            EarlyLine(name: "result", line: Transcript.result(text: "pong")),
        ]
    }

    @Test(arguments: EarlyLine.all)
    func outputBeforeInitStopsTheChild(_ early: EarlyLine) async throws {
        let fake = try FakeClaude(transcript: [early.line] + Transcript.probe(), ending: .hang)
        defer { fake.remove() }
        let run = Run(fake)
        let error = "no init event before content"
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == error)
        #expect(await run.driver.lastExit == -SIGTERM)
        #expect(await !run.turn.isOpen)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(await run.sink.sentences.isEmpty)
        #expect(await run.sink.deltas.isEmpty)
        #expect(await run.backend.names.isEmpty)
        #expect(run.bumps.bumps.isEmpty)
        #expect(run.logs.lines == ["Claude: stopping claude (\(error)): SIGTERM",
                                   Self.unavailable + ClaudeReason.reason(error)])
    }

    @Test func statusAndRateLimitLinesMayComeBeforeInit() async throws {
        let fake = try FakeClaude(transcript: [#"{"type":"system","subtype":"status","status":"requesting"}"#,
                                               Transcript.rateLimit(status: "allowed", overage: false)]
                                      + Transcript.probe(), ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "pong")
        #expect(await run.driver.lastError == nil)
    }

    // MARK: - R8-R10

    @Test func overageStopsTheChild() async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine(), Transcript.rateLimit(status: "allowed", overage: true)],
                                  ending: .hang)
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == "overage billing refused")
        #expect(await run.driver.lastExit == -SIGTERM)
        #expect(await !run.turn.isOpen)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(run.logs.lines == ["Claude: stopping claude (overage billing refused): SIGTERM",
                                   Self.unavailable + ClaudeReason.reason("overage billing refused")])
    }

    struct ResultCase: Sendable, CustomTestStringConvertible {
        let subtype: String
        let isError: Bool
        let text: String?
        let status: Int?
        let error: String
        var testDescription: String { error.count > 60 ? String(error.prefix(60)) + "…" : error }

        static let all = [
            ResultCase(subtype: "error_during_execution", isError: true,
                       text: String(repeating: "e", count: 150) + String(repeating: "f", count: 150), status: 500,
                       error: "result: error_during_execution 500 " + String(repeating: "e", count: 150)
                           + String(repeating: "f", count: 50)),
            ResultCase(subtype: "success", isError: true, text: "API Error: 529 overloaded", status: nil,
                       error: "result: success API Error: 529 overloaded"),
            ResultCase(subtype: "error_max_turns", isError: false, text: nil, status: nil, error: "result: error_max_turns"),
        ]
    }

    @Test(arguments: ResultCase.all)
    func resultErrorFallsBack(_ c: ResultCase) async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine(), Transcript.messageStart("msg_test_1"),
                                               Transcript.result(subtype: c.subtype, isError: c.isError, text: c.text,
                                                                 status: c.status)],
                                  ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == c.error)
        #expect(await run.driver.lastExit == 0)          // not stopped: it exited by itself
        #expect(await run.bridgeSawOneFullTurn())
        #expect(await run.sink.sentences.isEmpty)
        #expect(await run.backend.names.isEmpty)
        #expect(run.logs.lines == [Self.unavailable + ClaudeReason.reason(c.error)])
    }

    @Test func eofWithoutResultReportsTheExitAndTheStderrTail() async throws {
        // 9013 bytes of stderr: the error keeps the ring's last 8192, stripped.
        let stderr = "HEAD" + String(repeating: "x", count: 9000) + "TAIL-END\n"
        let fake = try FakeClaude(transcript: [Transcript.initLine()], stderr: stderr, ending: .exit(3))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        let error = "exit 3: " + String(repeating: "x", count: 8192 - 9) + "TAIL-END"
        #expect(await run.driver.lastError == error)
        #expect(await run.driver.lastExit == 3)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(run.logs.lines == [Self.unavailable + ClaudeReason.reason(error)])
    }

    @Test func aRejectedRateLimitIsPartOfTheReason() async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine(), Transcript.rateLimit(status: "rejected", overage: false)],
                                  stderr: "boom\n", ending: .exit(1))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == "exit 1: boom")
        let reason = ClaudeReason.reason("rate limit rejected: exit 1: boom")
        #expect(reason != ClaudeReason.reason("exit 1: boom"))
        #expect(run.logs.lines == [Self.unavailable + reason])
    }

    // MARK: - Timeout and cancellation

    @Test func timeoutSendsTermThenKill() async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine()], ending: .hangIgnoringTerm)
        defer { fake.remove() }
        // The timeout fires only after the fake has written `stdin`, which it does after its
        // first command, `trap '' TERM`: the SIGTERM cannot reach a shell that is still
        // starting and kill it before it ignores SIGTERM.
        let fired = Stamp()
        let run = Run(fake, timeout: .seconds(1), timeoutWait: { _ in
            while !fake.exists("stdin") { try await Task.sleep(for: .milliseconds(10)) }
            fired.mark()
        }, stopGrace: ClaudeDriver.stopGrace)
        #expect(await run.generate() == nil)
        let end = ContinuousClock.now
        let firedAt = try #require(fired.instant)
        #expect(end - firedAt >= ClaudeDriver.stopGrace)   // SIGKILL only after the 2 s grace
        #expect(await run.driver.lastError == "timeout after 1000 ms")
        #expect(run.logs.lines == ["Claude: stopping claude (timeout after 1000 ms): SIGTERM",
                                   "Claude: claude still running 2 s after SIGTERM: SIGKILL",
                                   Self.unavailable + ClaudeReason.reason("timeout after 1000 ms")])
        #expect(await !run.turn.isOpen)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(await run.driver.lastExit == -SIGKILL)   // SIGTERM was ignored
        let pid = try #require(await run.bridge.pid)
        #expect(await Self.eventually { Self.isGone(pid) })
    }

    @Test func cancellingTheCallerStopsTheChild() async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine()], ending: .hang)
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
        #expect(run.logs.lines == ["Claude: stopping claude (cancelled): SIGTERM",
                                   Self.unavailable + ClaudeReason.reason("cancelled")])
    }

    // MARK: - Salvage

    static func partialTranscript() throws -> [String] {
        [try Transcript.initLine(), Transcript.messageStart("msg_test_1"),
         Transcript.delta("It is sunny. "), Transcript.delta("It is wa")]
    }

    @Test func partialOnVoiceReturnsTheSpokenSentences() async throws {
        let fake = try FakeClaude(transcript: Self.partialTranscript(), stderr: "stream ended\n", ending: .exit(1))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "It is sunny.")
        #expect(await run.sink.sentences == ["It is sunny."])
        #expect(await run.sink.deltas == ["It is sunny. ", "It is wa"])
        #expect(await run.backend.names == ["claude (partial)"])
        #expect(await run.driver.lastError == "exit 1: stream ended")
        #expect(await run.driver.lastExit == 1)
        #expect(await run.bridgeSawOneFullTurn())
        #expect(run.logs.lines.isEmpty)
    }

    @Test func partialOnTextAlsoReturnsTheShownFragment() async throws {
        let fake = try FakeClaude(transcript: Self.partialTranscript(), stderr: "stream ended\n", ending: .exit(1))
        defer { fake.remove() }
        let run = Run(fake, channel: .text)
        #expect(await run.generate() == "It is sunny. It is wa")
        #expect(await run.sink.sentences == ["It is sunny."])
        #expect(await run.backend.names == ["claude (partial)"])
    }

    @Test(arguments: [Channel.voice, .text])
    func aShownFragmentAloneCountsOnlyOnText(_ channel: Channel) async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine(), Transcript.messageStart("msg_test_1"),
                                               Transcript.delta("It is wa")],
                                  stderr: "stream ended\n", ending: .exit(1))
        defer { fake.remove() }
        let run = Run(fake, channel: channel)
        let reply = await run.generate()
        #expect(await run.sink.sentences.isEmpty)
        if channel == .text {
            #expect(reply == "It is wa")
            #expect(await run.backend.names == ["claude (partial)"])
            #expect(run.logs.lines.isEmpty)
        } else {
            #expect(reply == nil)
            #expect(await run.backend.names.isEmpty)
            #expect(run.logs.lines == [Self.unavailable + ClaudeReason.reason("exit 1: stream ended")])
        }
    }

    @Test func emptySuccessFallsBack() async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine(), Transcript.result(text: "")], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == nil)
        #expect(await run.backend.names.isEmpty)
        #expect(run.logs.lines == [Self.unavailable + "empty response"])
    }

    // MARK: - R5, R6, R9 text

    @Test func refusalDropsOnlyThatMessagesUnemittedText() async throws {
        let fake = try FakeClaude(transcript: [
            Transcript.initLine(),
            Transcript.messageStart("msg_a"), Transcript.delta("Sure. "), Transcript.delta("Here is how"),
            Transcript.stop("refusal"),
            Transcript.messageStart("msg_b", model: "claude-opus-4-8"), Transcript.delta("Hello there."),
            Transcript.block("msg_b", "Hello there."), Transcript.stop("end_turn"),
            Transcript.result(text: "Hello there."),
        ], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "Sure. Hello there.")    // emitted sentences stand
        #expect(await run.sink.sentences == ["Sure.", "Hello there."])
        #expect(await run.sink.deltas == ["Sure. ", "Here is how", "Hello there."])
        #expect(await run.sink.retractedIDs == ["msg_a"])
        #expect(await run.backend.names == ["claude"])
    }

    @Test func refusalKeepsAnEarlierMessagesText() async throws {
        // buf is "Let me check.Here is how" (no boundary) when msg_b is refused: only msg_b's
        // part goes. Dropping all of buf would give ["Something else."] (R9 feeds the result
        // text into a blank buf); dropping nothing would give ["Let me check.Here is how"].
        let fake = try FakeClaude(transcript: [
            Transcript.initLine(),
            Transcript.messageStart("msg_a"), Transcript.delta("Let me check."), Transcript.stop("tool_use"),
            Transcript.messageStart("msg_b"), Transcript.delta("Here is how"), Transcript.stop("refusal"),
            Transcript.result(text: "Something else."),
        ], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "Let me check.")
        #expect(await run.sink.sentences == ["Let me check."])
        #expect(await run.sink.retractedIDs == ["msg_b"])
    }

    @Test func blockTextIsFedWhenNoDeltaCame() async throws {
        let fake = try FakeClaude(transcript: [
            Transcript.initLine(), Transcript.messageStart("msg_a"), Transcript.block("msg_a", "Hello there."),
            Transcript.stop("end_turn"), Transcript.result(text: "Hello there."),
        ], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "Hello there.")
        #expect(await run.sink.sentences == ["Hello there."])
        #expect(await run.sink.deltas == ["Hello there."])
    }

    @Test func resultTextIsUsedWhenNothingElseCame() async throws {
        let fake = try FakeClaude(transcript: [Transcript.initLine(), Transcript.result(text: "pong")], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == "pong")
        #expect(await run.sink.sentences == ["pong"])
        #expect(await run.sink.deltas == ["pong"])
        #expect(await run.backend.names == ["claude"])
    }

    @Test func lineSeparatorsInsideJSONStringsDoNotSplitLines() async throws {
        let text = "One\u{2028}two\u{85}three."
        let lines = [try Transcript.initLine(), Transcript.messageStart("msg_a"), Transcript.delta(text),
                     Transcript.result(text: text)]
        #expect(lines[2].unicodeScalars.contains("\u{2028}") && lines[2].unicodeScalars.contains("\u{85}"))
        let fake = try FakeClaude(transcript: lines, ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake)
        #expect(await run.generate() == text)
        #expect(await run.sink.sentences == [text])
    }

    // MARK: - Before claude runs

    @Test func aBridgeFailureFallsBackWithoutStartingClaude() async throws {
        let fake = try FakeClaude(transcript: Transcript.probe(), ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake, failOpen: true)
        let id = await run.turn.turnID
        #expect(await run.generate() == nil)
        #expect(!fake.exists("argv"))
        #expect(await run.bridge.calls == [.open(id), .close(id)])
        let error = try #require(await run.driver.lastError)
        #expect(error.hasPrefix("tool bridge: "))
        #expect(run.logs.lines == [Self.unavailable + ClaudeReason.reason(error)])
    }

    @Test func aMissingClaudeIsCLINotFound() async throws {
        let fake = try FakeClaude(transcript: [], ending: .exit(0))
        defer { fake.remove() }
        let run = Run(fake, executable: fake.dir.appending(path: "no-such-claude", directoryHint: .notDirectory))
        let id = await run.turn.turnID
        #expect(await run.generate() == nil)
        #expect(await run.driver.lastError == ClaudeLocator.notFoundMessage)
        #expect(await run.driver.lastExit == nil)
        #expect(await run.bridge.calls == [.open(id), .close(id)])
        #expect(run.logs.lines == [Self.unavailable + ClaudeReason.reason(ClaudeLocator.notFoundMessage)])
    }

    // MARK: - Helpers with fixed values

    @Test func backendNamesTimeoutsAndTheStdinLine() {
        #expect(ClaudeDriver.successBackend(model: ClaudeConfig.defaultModel) == "claude")
        #expect(BackendReporter.counterKey(ClaudeDriver.successBackend(model: ClaudeConfig.defaultModel)) == "backend_claude")
        #expect(ClaudeDriver.successBackend(model: "claude-sonnet-test") == "claude (claude-sonnet-test)")
        #expect(ClaudeDriver.wallTimeout(for: ClaudeConfig(environment: [:])) == .seconds(60))
        #expect(ClaudeDriver.wallTimeout(for: ClaudeConfig(environment: ["JARVIS_CLAUDE_TIMEOUT_MS": "1000"])) == .seconds(16))
        #expect(ClaudeDriver.wallTimeout(for: ClaudeConfig(environment: ["JARVIS_CLAUDE_TIMEOUT_MS": "soon"])) == .seconds(60))
        #expect(ClaudeDriver.defaultAllowedTools == DataSourceMap.toolNames.map(ClaudeInvocation.allowedToolName))
        #expect(ClaudeDriver.defaultAllowedTools.count == 46)
        #expect(ClaudeDriver.stdinLine(user: "Say \"hi\" to Sam, caf\u{E9}")
                == #"{"type":"user","message":{"role":"user","content":"Say \"hi\" to Sam, caf\u00e9"}}"# + "\n")
    }
}
