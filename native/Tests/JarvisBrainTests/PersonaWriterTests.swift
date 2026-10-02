import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// The persona writers (P1 piece 2): the collaboration between the on-device draft and
/// Claude's improvement, the on-device writer on a fake model, and the Claude writer on a fake
/// `claude` script. No test runs a real model or a real `claude`.
@Suite("Persona writers: collaboration, on-device, Claude one-shot", .timeLimit(.minutes(1)))
struct PersonaWriterTests {
    static let timeout: Duration = .seconds(60)
    static let listing = (0..<10).map { "- Synthetic style note \($0) here" }.joined(separator: "\n")
    static let convo = "user: that joke was brilliant\nassistant: I do try, sir."

    // MARK: - Collaboration

    /// Claude unavailable (offline, switched off, or failing): the on-device draft is the text.
    @Test(arguments: [PersonaWriterError.offline, .claudeOff, .claudeFailed("timed out")])
    func localDraftStandsWhenClaudeIsUnavailable(_ failure: PersonaWriterError) async throws {
        let local = ScriptedWriter(.reply("The user enjoys a dry joke."))
        let claude = ScriptedWriter(.fail(failure))
        let logs = LogRecorder()
        let writer = CollaborativePersonaLLM(local: local, claude: claude, log: logs.function)

        let text = try await writer.complete(system: PersonaDistill.distillSystem, user: Self.convo, timeout: Self.timeout)

        #expect(text == "The user enjoys a dry joke.")
        #expect(local.calls == [.init(system: PersonaDistill.distillSystem, user: Self.convo, timeout: Self.timeout)])
        #expect(claude.calls.count == 1)
        #expect(logs.lines == ["Personality writer: on-device draft (\(failure.description))."])
    }

    /// Claude gets the same system prompt, the same text with the draft, and the same timeout;
    /// a version that passes CoreState's check replaces the draft.
    @Test(arguments: [
        (PersonaDistill.consolidateSystem, PersonaWriterTests.listing,
         "Synthetic style note one\nSynthetic style note two", "Merged style note one\nMerged style note two"),
        (PersonaDistill.distillSystem, PersonaWriterTests.convo,
         "The user likes jokes.", "The user enjoys a dry joke after a task."),
    ])
    func claudeImprovesTheDraft(_ system: String, _ user: String, _ draft: String, _ improved: String) async throws {
        let local = ScriptedWriter(.reply(draft))
        let claude = ScriptedWriter(.reply(improved))
        let logs = LogRecorder()
        let writer = CollaborativePersonaLLM(local: local, claude: claude, log: logs.function)

        let text = try await writer.complete(system: system, user: user, timeout: Self.timeout)

        #expect(text == improved)
        #expect(local.calls == [.init(system: system, user: user, timeout: Self.timeout)])
        let request = CollaborativePersonaLLM.improveRequest(user: user, draft: draft)
        #expect(claude.calls == [.init(system: system, user: request, timeout: Self.timeout)])
        #expect(request.hasPrefix(user + "\n\n"))
        #expect(request.contains("\n" + draft + "\n"))
        #expect(logs.lines == ["Personality writer: Claude, improving the on-device draft."])
    }

    /// A version CoreState would reject (consolidation outside 1 to 8 lines; a distilled note
    /// not starting "The user", or 200 code points or more) leaves the draft, valid or not.
    @Test(arguments: [
        (PersonaDistill.consolidateSystem, PersonaWriterTests.listing, "Synthetic style note one",
         (1...9).map { "Merged style note \($0)" }.joined(separator: "\n")),
        (PersonaDistill.consolidateSystem, PersonaWriterTests.listing, "Synthetic style note one", "short\n  \n"),
        (PersonaDistill.distillSystem, PersonaWriterTests.convo, "The user likes jokes.", "Sure! The user likes jokes."),
        (PersonaDistill.distillSystem, PersonaWriterTests.convo, "The user likes jokes.", "NONE"),
        (PersonaDistill.distillSystem, PersonaWriterTests.convo, "NONE",
         "The user " + String(repeating: "x", count: 191)),
    ])
    func claudesInvalidVersionLeavesTheDraft(_ system: String, _ user: String, _ draft: String,
                                              _ improved: String) async throws {
        let logs = LogRecorder()
        let writer = CollaborativePersonaLLM(local: ScriptedWriter(.reply(draft)),
                                             claude: ScriptedWriter(.reply(improved)), log: logs.function)

        let text = try await writer.complete(system: system, user: user, timeout: Self.timeout)

        #expect(text == draft)
        #expect(!CollaborativePersonaLLM.passesCoreStateCheck(improved, system: system))
        #expect(logs.lines == ["Personality writer: on-device draft (Claude's version failed the check)."])
    }

    /// No draft (the on-device model unavailable or failing): Claude alone, on the original text.
    @Test(arguments: [PersonaWriterError.localUnavailable("deviceNotEligible"), .localFailed("timed out after 60 seconds")])
    func claudeAloneWhenTheLocalModelFails(_ failure: PersonaWriterError) async throws {
        let local = ScriptedWriter(.fail(failure))
        let claude = ScriptedWriter(.reply("The user enjoys a dry joke."))
        let logs = LogRecorder()
        let writer = CollaborativePersonaLLM(local: local, claude: claude, log: logs.function)

        let text = try await writer.complete(system: PersonaDistill.distillSystem, user: Self.convo, timeout: Self.timeout)

        #expect(text == "The user enjoys a dry joke.")
        #expect(claude.calls == [.init(system: PersonaDistill.distillSystem, user: Self.convo, timeout: Self.timeout)])
        #expect(logs.lines == ["Personality writer: Claude alone (\(failure.description))."])
    }

    @Test func bothFailingThrows() async throws {
        let logs = LogRecorder()
        let writer = CollaborativePersonaLLM(local: ScriptedWriter(.fail(.localUnavailable("modelNotReady"))),
                                             claude: ScriptedWriter(.fail(.offline)), log: logs.function)

        await #expect(throws: PersonaWriterError.bothFailed(local: "on-device model unavailable (modelNotReady)",
                                                            claude: "offline")) {
            try await writer.complete(system: PersonaDistill.consolidateSystem, user: Self.listing, timeout: Self.timeout)
        }
        #expect(logs.lines == ["Personality writer: none (on-device model unavailable (modelNotReady); offline)."])
    }

    /// A prompt that is neither PersonaDistill prompt has no check, so the draft stands.
    @Test func anotherPromptKeepsTheDraft() async throws {
        let writer = CollaborativePersonaLLM(local: ScriptedWriter(.reply("The user likes jokes.")),
                                             claude: ScriptedWriter(.reply("The user enjoys a dry joke.")),
                                             log: { _ in })
        let text = try await writer.complete(system: "Some other prompt.", user: Self.convo, timeout: Self.timeout)
        #expect(text == "The user likes jokes.")
    }

    /// Through CoreState: an improved consolidation lands in personality.json, and with both
    /// writers failing the file is untouched and nothing is counted, as when Ollama failed.
    @Test func coreStateWritesOnlyWhatAWriterProduced() async throws {
        let notes = (0..<10).map { i in
            JSONValue.object(JSONObject([.init(key: "note", value: .string("Synthetic style note \(i) here")),
                                         .init(key: "added", value: .double(1_780_000_000 + Double(i)))]))
        }
        let seed = PyJSON.dumps(.object(JSONObject([.init(key: "core", value: .array([.string("Synthetic trait.")])),
                                                    .init(key: "learned", value: .array(notes))])), indent: 1)

        let failing = try CoreHarness(research: EventCounter(EventLog()), files: ["personality.json": seed])
        defer { failing.sandbox.remove() }
        await failing.core.consolidatePersonalityIfDue(using: CollaborativePersonaLLM(
            local: ScriptedWriter(.fail(.localUnavailable("modelNotReady"))), claude: ScriptedWriter(.fail(.offline)),
            log: { _ in }))
        #expect(try failing.sandbox.read("personality.json") == seed)

        let events = EventLog()
        let working = try CoreHarness(research: EventCounter(events), files: ["personality.json": seed])
        defer { working.sandbox.remove() }
        await working.core.consolidatePersonalityIfDue(using: CollaborativePersonaLLM(
            local: ScriptedWriter(.reply("Synthetic style note one")),
            claude: ScriptedWriter(.reply("Merged style note one\nMerged style note two")), log: { _ in }))
        let saved = try #require(PyJSON.loads(Data(try working.sandbox.read("personality.json").utf8)).objectValue)
        #expect(saved["learned"]?.arrayValue?.compactMap { $0.objectValue?["note"]?.stringValue }
            == ["Merged style note one", "Merged style note two"])
        #expect(events.events == ["bump personality_consolidations+1"])
    }

    /// Every branch's log line names the writer and the cause, never a prompt or reply.
    @Test func logLinesHoldNoPersonalityText() async throws {
        let logs = LogRecorder()
        let secret = "The user secretly prefers Klingon"
        let branches: [(ScriptedWriter, ScriptedWriter)] = [
            (ScriptedWriter(.reply(secret + ".")), ScriptedWriter(.reply(secret + " poetry."))),
            (ScriptedWriter(.reply(secret + ".")), ScriptedWriter(.reply("Nope " + secret))),
            (ScriptedWriter(.reply(secret + ".")), ScriptedWriter(.fail(.claudeFailed("rate limited")))),
            (ScriptedWriter(.fail(.localFailed("GenerationError.guardrailViolation"))), ScriptedWriter(.reply(secret))),
            (ScriptedWriter(.fail(.localUnavailable("modelNotReady"))), ScriptedWriter(.fail(.offline))),
        ]
        for (local, claude) in branches {
            let writer = CollaborativePersonaLLM(local: local, claude: claude, log: logs.function)
            _ = try? await writer.complete(system: PersonaDistill.distillSystem, user: "user: " + secret,
                                           timeout: Self.timeout)
        }
        #expect(logs.lines.count == branches.count)
        #expect(logs.lines.allSatisfy { $0.hasPrefix("Personality writer: ") && !$0.contains("Klingon") })
    }

    // MARK: - On-device writer

    /// One session per call, holding the system prompt and no tools, greedy; the reply is the
    /// last cumulative snapshot, and the session is gone once the call returns.
    @Test func localWriterUsesOneGreedySessionWithNoTools() async throws {
        let model = PersonaModel(steps: [.snapshot("The user"), .snapshot("The user likes brevity.")])
        let writer = LocalPersonaLLM(model: model)

        let first = try await writer.complete(system: PersonaDistill.distillSystem, user: Self.convo, timeout: Self.timeout)
        let second = try await writer.complete(system: PersonaDistill.distillSystem, user: Self.convo, timeout: Self.timeout)

        #expect(first == "The user likes brevity.")
        #expect(second == first)
        #expect(model.log.sessions == [.init(instructions: PersonaDistill.distillSystem, toolCount: 0),
                                       .init(instructions: PersonaDistill.distillSystem, toolCount: 0)])
        #expect(model.log.prompts == [Self.convo, Self.convo])
        #expect(model.log.options == [LocalPersonaLLM.options, LocalPersonaLLM.options])
        #expect(LocalPersonaLLM.options.samplingMode == .greedy)
        #expect(!model.log.sessionAlive)
    }

    @Test func localWriterThrowsWhenTheModelIsUnavailable() async throws {
        let model = PersonaModel(reason: "modelNotReady", steps: [.snapshot("unused")])
        await #expect(throws: PersonaWriterError.localUnavailable("modelNotReady")) {
            try await LocalPersonaLLM(model: model).complete(system: "s", user: "u", timeout: Self.timeout)
        }
        #expect(model.log.sessions.isEmpty)
    }

    /// A failed generation throws the error's type only: its payload never reaches a log.
    @Test func localWriterThrowsWhenGenerationFails() async throws {
        let model = PersonaModel(steps: [.snapshot("The user"), .fail(FakeModelError(description: "quoted prompt text"))])
        await #expect(throws: PersonaWriterError.localFailed("FakeModelError")) {
            try await LocalPersonaLLM(model: model).complete(system: "s", user: "u", timeout: Self.timeout)
        }
        #expect(!model.log.sessionAlive)
    }

    /// The timeout ends a generation that never finishes, and cancels it.
    @Test func localWriterTimesOut() async throws {
        let model = PersonaModel(steps: [.snapshot("The user"), .hang])
        let writer = LocalPersonaLLM(model: model, timeoutWait: { _ in })
        let elapsed = await SuspendingClock().measure {
            await #expect(throws: PersonaWriterError.localFailed("timed out after 60.0 seconds")) {
                try await writer.complete(system: "s", user: "u", timeout: Self.timeout)
            }
        }
        #expect(elapsed < .seconds(10))
        #expect(!model.log.sessionAlive)
        #expect(model.log.cancelled == 1)
    }

    // MARK: - Claude writer

    /// The probe's init line as a one-shot sees it: no MCP server and no tool.
    static func oneShotInit(apiKeySource: String = "none", mcp: Bool = false) throws -> String {
        var obj = try #require(PyJSON.loads(Data(try Transcript.initLine().utf8)).objectValue)
        if !mcp {
            obj["tools"] = .array([])
            obj["mcp_servers"] = .array([])
        }
        obj["apiKeySource"] = .string(apiKeySource)
        return PyJSON.dumps(.object(obj), ensureASCII: false)
    }

    static func reply(_ text: String) throws -> [String] {
        [try oneShotInit(), Transcript.messageStart("msg_1"), Transcript.delta("The user "),
         Transcript.delta(String(text.dropFirst("The user ".count))), Transcript.stop("end_turn"),
         Transcript.result(text: text)]
    }

    /// The turn's argv in the turn's order, less `--mcp-config` and `--allowedTools`, one
    /// turn; the forbidden flags are refused here too.
    @Test func oneShotArgvIsTheTurnsLessMCPAndTools() throws {
        let exe = URL(fileURLWithPath: "/opt/claude-test/bin/claude")
        let inv = try ClaudeInvocation(oneShot: exe, systemPrompt: "You maintain a persona.",
                                       config: ClaudeConfig(environment: [:]))
        #expect(inv.executable == exe)
        #expect(inv.arguments == [
            "-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
            "--include-partial-messages",
            "--system-prompt", "You maintain a persona.",
            "--tools", "",
            "--setting-sources=",
            "--strict-mcp-config",
            "--max-turns", "1",
            "--model", "claude-opus-5-5",
            "--effort", "low",
            "--no-session-persistence",
            "--permission-prompts", "none",
        ])
        let noEffort = try ClaudeInvocation(oneShot: exe, systemPrompt: "s",
                                            config: ClaudeConfig(environment: ["JARVIS_CLAUDE_EFFORT": " "]))
        #expect(!noEffort.arguments.contains("--effort"))
        #expect(throws: ClaudeInvocationError.forbiddenFlag("--dangerously-skip-permissions")) {
            try ClaudeInvocation(oneShot: exe, systemPrompt: "--dangerously-skip-permissions",
                                 config: ClaudeConfig(environment: [:]))
        }
        #expect(throws: ClaudeInvocationError.forbiddenFlag("--bare")) {
            try ClaudeInvocation(oneShot: exe, systemPrompt: "s",
                                 config: ClaudeConfig(environment: ["JARVIS_CLAUDE_MODEL": "--bare"]))
        }
    }

    /// One Claude writer on a fake `claude`, with the driver tests' parent environment.
    struct ClaudeRun {
        let fake: FakeClaude
        let logs = LogRecorder()
        let config: ClaudeConfig
        let parent: [String: String]
        let writer: ClaudePersonaLLM

        init(_ fake: FakeClaude, config: ClaudeConfig = ClaudeConfig(environment: [:]), online: Bool = true,
             timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }) {
            self.fake = fake
            self.config = config
            parent = ["HOME": fake.dir.path(percentEncoded: false), "USER": "robin", "LOGNAME": "robin",
                      "TMPDIR": FileManager.default.temporaryDirectory.path(percentEncoded: false),
                      "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            writer = ClaudePersonaLLM(config: config, executable: fake.script, workingDirectory: fake.cwd,
                                      parentEnvironment: parent, online: { online }, timeoutWait: timeoutWait,
                                      stopGrace: .seconds(30), log: logs.function)
        }

        func complete() async throws -> String {
            try await writer.complete(system: PersonaDistill.distillSystem, user: PersonaWriterTests.convo,
                                      timeout: PersonaWriterTests.timeout)
        }
    }

    /// A turn's argv less the MCP config and the allowed tools, one turn; the turn's child
    /// environment and working directory; the stdin line; the streamed text back.
    @Test func claudeWriterMakesOneShotCallWithNoToolsOrMCP() async throws {
        let run = ClaudeRun(try FakeClaude(transcript: try Self.reply("The user enjoys a dry joke."), ending: .exit(0)))
        defer { run.fake.remove() }

        let text = try await run.complete()

        #expect(text == "The user enjoys a dry joke.")
        let argv = try #require(run.fake.argv)
        #expect(argv == (try ClaudeInvocation(oneShot: run.fake.script, systemPrompt: PersonaDistill.distillSystem,
                                             config: run.config)).arguments)
        #expect(!argv.contains("--mcp-config"))
        #expect(!argv.contains("--allowedTools"))
        #expect(argv.contains("--strict-mcp-config"))
        let tools = try #require(argv.firstIndex(of: "--tools"))
        #expect(argv[tools + 1] == "")
        let turns = try #require(argv.firstIndex(of: "--max-turns"))
        #expect(argv[turns + 1] == "1")
        #expect(run.fake.environment == ChildEnvironment.forClaude(parent: run.parent, config: run.config, log: { _ in }))
        #expect(run.fake.text("stdin") == ClaudeDriver.stdinLine(user: Self.convo))
        let cwd = try #require(ClaudeDriverTests.realPath(run.fake.cwd))
        #expect(run.fake.text("cwd") == cwd + "\n")
        #expect(try FileManager.default.attributesOfItem(atPath: cwd)[.posixPermissions] as? Int == 0o700)
        #expect(run.logs.lines.isEmpty)
    }

    /// Claude switched off or offline: it throws before starting `claude`.
    @Test(arguments: [false, true])
    func claudeWriterOffOrOfflineNeverStartsClaude(_ switchedOff: Bool) async throws {
        let config = ClaudeConfig(environment: switchedOff ? ["JARVIS_USE_CLAUDE": "0"] : [:])
        let run = ClaudeRun(try FakeClaude(transcript: try Self.reply("The user enjoys a dry joke."), ending: .exit(0)),
                            config: config, online: switchedOff)
        defer { run.fake.remove() }

        await #expect(throws: switchedOff ? PersonaWriterError.claudeOff : .offline) {
            try await run.complete()
        }
        #expect(!run.fake.exists("argv"))
    }

    /// The init event must show subscription auth, no MCP server and no tool; anything else
    /// stops the child before its text is used.
    @Test(arguments: [("ANTHROPIC_API_KEY", false, "subscription-only: apiKeySource=ANTHROPIC_API_KEY"),
                      ("none", true, "an MCP server was loaded")])
    func claudeWriterHoldsTheInitEventToTheRules(_ source: String, _ mcp: Bool, _ reason: String) async throws {
        let transcript = [try Self.oneShotInit(apiKeySource: source, mcp: mcp)] + Array(try Self.reply("The user x y z.").dropFirst())
        let run = ClaudeRun(try FakeClaude(transcript: transcript, ending: .exit(0)))
        defer { run.fake.remove() }

        await #expect(throws: PersonaWriterError.claudeFailed(reason)) {
            try await run.complete()
        }
    }

    /// R9 and R6: an error result throws; a refused message's text is dropped, and with
    /// nothing else there is no reply.
    @Test func claudeWriterThrowsOnAnErrorResultOrARefusal() async throws {
        let failed = ClaudeRun(try FakeClaude(transcript: [try Self.oneShotInit(), Transcript.messageStart("msg_1"),
                                                           Transcript.result(subtype: "error_during_execution", isError: true,
                                                                             text: "The user quoted text", status: 500)],
                                              ending: .exit(1)))
        defer { failed.fake.remove() }
        await #expect(throws: PersonaWriterError.claudeFailed("result: error_during_execution 500")) {
            try await failed.complete()
        }

        let refused = ClaudeRun(try FakeClaude(transcript: [try Self.oneShotInit(), Transcript.messageStart("msg_1"),
                                                            Transcript.delta("The user refused text"),
                                                            Transcript.stop("refusal"),
                                                            Transcript.result(text: "The user refused text")],
                                               ending: .exit(0)))
        defer { refused.fake.remove() }
        await #expect(throws: PersonaWriterError.claudeFailed("empty response")) {
            try await refused.complete()
        }
    }

    /// The timeout stops a `claude` that never answers (SIGTERM, as a turn's does).
    @Test func claudeWriterTimesOut() async throws {
        let run = ClaudeRun(try FakeClaude(transcript: [try Self.oneShotInit()], ending: .hang), timeoutWait: { _ in
            try await Task.sleep(for: .milliseconds(200))
        })
        defer { run.fake.remove() }

        let elapsed = await SuspendingClock().measure {
            await #expect(throws: PersonaWriterError.claudeFailed("timed out")) {
                try await run.complete()
            }
        }
        #expect(elapsed < .seconds(20))
        #expect(run.logs.lines.contains { $0.hasPrefix("Claude: stopping claude (timeout after 60000 ms): SIGTERM") })
    }
}

// MARK: - Fakes

/// A PersonaLLM that plays its steps in order and records every call.
final class ScriptedWriter: PersonaLLM {
    enum Step: Sendable {
        case reply(String)
        case fail(PersonaWriterError)
    }

    struct Call: Sendable, Equatable {
        let system: String
        let user: String
        let timeout: Duration
    }

    private let state: Mutex<(steps: [Step], calls: [Call])>

    init(_ steps: Step...) {
        state = Mutex((steps, []))
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func complete(system: String, user: String, timeout: Duration) async throws -> String {
        let step = state.withLock { s -> Step? in
            s.calls.append(Call(system: system, user: user, timeout: timeout))
            return s.steps.isEmpty ? nil : s.steps.removeFirst()
        }
        switch step {
        case .reply(let text)?: return text
        case .fail(let error)?: throw error
        case nil: throw PersonaWriterError.claudeFailed("unscripted call")
        }
    }
}

/// The on-device model for LocalPersonaLLM: records each session's instructions and tool
/// count, each prompt and options, and whether the last session is still alive.
final class PersonaModel: LocalLanguageModel {
    enum Step: Sendable {
        case snapshot(String)
        case fail(any Error)
        case hang
    }

    struct Session: Sendable, Equatable {
        let instructions: String
        let toolCount: Int
    }

    final class Log: Sendable {
        struct State {
            var sessions: [Session] = []
            var prompts: [String] = []
            var options: [GenerationOptions] = []
            var cancelled = 0
            weak var last: PersonaSession?
        }

        let state = Mutex(State())
        var sessions: [Session] { state.withLock { $0.sessions } }
        var prompts: [String] { state.withLock { $0.prompts } }
        var options: [GenerationOptions] { state.withLock { $0.options } }
        var cancelled: Int { state.withLock { $0.cancelled } }
        var sessionAlive: Bool { state.withLock { $0.last != nil } }
    }

    let reason: String?
    let steps: [Step]
    let log = Log()

    init(reason: String? = nil, steps: [Step]) {
        self.reason = reason
        self.steps = steps
    }

    func unavailableReason() async -> String? { reason }

    func tools(for request: LocalToolRequest, instructions: String, gateway: ToolGateway, turn: TurnContext,
               budget: LocalCallBudget) async -> [DynamicTool] {
        Issue.record("the persona writer must not ask for a turn's tools")
        return []
    }

    func session(instructions: String, tools: [DynamicTool]) async -> any LocalModelSession {
        let session = PersonaSession(steps: steps, log: log)
        log.state.withLock {
            $0.sessions.append(Session(instructions: instructions, toolCount: tools.count))
            $0.last = session
        }
        return session
    }
}

final class PersonaSession: LocalModelSession {
    let steps: [PersonaModel.Step]
    let log: PersonaModel.Log

    init(steps: [PersonaModel.Step], log: PersonaModel.Log) {
        self.steps = steps
        self.log = log
    }

    func streamResponse(to prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, any Error> {
        log.state.withLock {
            $0.prompts.append(prompt)
            $0.options.append(options)
        }
        let steps = self.steps, log = self.log
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        switch step {
                        case .snapshot(let text): continuation.yield(text)
                        case .fail(let error): throw error
                        case .hang:
                            do {
                                try await Task.sleep(for: .seconds(3600))
                            } catch {
                                log.state.withLock { $0.cancelled += 1 }
                                throw error
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
