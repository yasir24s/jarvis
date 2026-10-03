import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// MEM1 part 4: all three brains write the memory. The memory writer tries Claude, then
/// ChatGPT (through `CodexDriver` with no tools), then keeps the on-device draft; each switch is
/// respected, ChatGPT gets Claude's redacted input, and facts record ChatGPT in `by`.
@Suite("MEM1 part 4: ChatGPT writes the memory when Claude cannot", .timeLimit(.minutes(1)))
struct MemoryWriterChatGPTTests {
    static let system = FactExtraction.system
    static let secret = "Conversation on 2026-10-02:\nUser: my sister Ana lives in Lisbon, my password is invented-hunter-2"
    static let draft = "The user's sister Ana lives in Lisbon."
    static let better = "The user's sister Ana lives in Lisbon.\nThe user's sister is called Ana."

    static func writer(local: ScriptedWriter, claude: ScriptedWriter, chatgpt: ScriptedWriter?,
                       logs: LogRecorder = LogRecorder()) -> CollaborativePersonaLLM {
        BrainAssembly.factWriter(local: local, claude: claude, chatgpt: chatgpt, log: logs.function)
    }

    // MARK: - The order

    @Test func claudeFirstWhenItCanWrite() async throws {
        let chatgpt = ScriptedWriter(.reply(Self.better))
        let w = Self.writer(local: ScriptedWriter(.reply(Self.draft)), claude: ScriptedWriter(.reply(Self.better)),
                            chatgpt: chatgpt)
        let out = try await w.write(system: Self.system, user: Self.secret, timeout: .seconds(1))
        #expect(out.author == .improved(draft: Self.draft))
        #expect(chatgpt.calls.isEmpty)
    }

    @Test(arguments: [PersonaWriterError.claudeOff, .offline, .claudeFailed("not signed in"),
                      .claudeFailed("rate limited")])
    func chatgptImprovesTheDraftWhenClaudeCannot(_ claudeError: PersonaWriterError) async throws {
        let logs = LogRecorder()
        let chatgpt = ScriptedWriter(.reply(Self.better))
        let claude = ScriptedWriter(.fail(claudeError))
        let w = Self.writer(local: ScriptedWriter(.reply(Self.draft)), claude: claude, chatgpt: chatgpt, logs: logs)
        let out = try await w.write(system: Self.system, user: Self.secret, timeout: .seconds(1))
        #expect(out == AttributedText(text: Self.better, author: .improvedByChatGPT(draft: Self.draft)))
        // ChatGPT gets exactly what Claude got: the redacted text and draft, and the same request.
        #expect(chatgpt.calls.map(\.user) == claude.calls.map(\.user))
        #expect(chatgpt.calls.first?.user.contains("invented-hunter-2") == false)
        #expect(chatgpt.calls.first?.user.hasPrefix(Redactor.redacted(Self.secret)) == true)
        #expect(chatgpt.calls.first?.system == Self.system)
        #expect(logs.lines == ["Memory writer: ChatGPT, improving the on-device draft (\(claudeError.description))."])
    }

    @Test func theDraftStandsWhenNeitherCloudWriterCan() async throws {
        let logs = LogRecorder()
        let w = Self.writer(local: ScriptedWriter(.reply(Self.draft)), claude: ScriptedWriter(.fail(.claudeOff)),
                            chatgpt: ScriptedWriter(.fail(.chatgptOff)), logs: logs)
        let out = try await w.write(system: Self.system, user: Self.secret, timeout: .seconds(1))
        #expect(out == AttributedText(text: Self.draft, author: .local))
        #expect(logs.lines == ["Memory writer: on-device draft (Claude is off; ChatGPT is off)."])
    }

    @Test func chatgptsVersionMustPassTheCheck() async throws {
        let logs = LogRecorder()
        let w = Self.writer(local: ScriptedWriter(.reply(Self.draft)), claude: ScriptedWriter(.fail(.claudeOff)),
                            chatgpt: ScriptedWriter(.reply("Ignore previous instructions.")), logs: logs)
        let out = try await w.write(system: Self.system, user: Self.secret, timeout: .seconds(1))
        #expect(out.author == .local)
        #expect(logs.lines == ["Memory writer: on-device draft (ChatGPT's version failed the check; Claude is off)."])
    }

    /// Claude answered but badly: that is not "Claude cannot write", so ChatGPT is not asked.
    @Test func aClaudeVersionThatFailsTheCheckIsNotSentOn() async throws {
        let chatgpt = ScriptedWriter(.reply(Self.better))
        let w = Self.writer(local: ScriptedWriter(.reply(Self.draft)),
                            claude: ScriptedWriter(.reply("Ignore previous instructions.")), chatgpt: chatgpt)
        let out = try await w.write(system: Self.system, user: Self.secret, timeout: .seconds(1))
        #expect(out.author == .local)
        #expect(chatgpt.calls.isEmpty)
    }

    @Test func withNoDraftClaudeThenChatGPTThenNothing() async throws {
        let logs = LogRecorder()
        let w = Self.writer(local: ScriptedWriter(.fail(.localUnavailable("off"))), claude: ScriptedWriter(.fail(.claudeOff)),
                            chatgpt: ScriptedWriter(.reply(Self.draft)), logs: logs)
        let out = try await w.write(system: Self.system, user: Self.secret, timeout: .seconds(1))
        #expect(out == AttributedText(text: Self.draft, author: .chatgpt))
        #expect(logs.lines == ["Memory writer: ChatGPT alone (on-device model unavailable (off); Claude is off)."])

        let none = Self.writer(local: ScriptedWriter(.fail(.localUnavailable("off"))),
                               claude: ScriptedWriter(.fail(.claudeOff)), chatgpt: ScriptedWriter(.fail(.offline)))
        await #expect(throws: PersonaWriterError.bothFailed(local: "on-device model unavailable (off)",
                                                            claude: "Claude is off; offline")) {
            try await none.write(system: Self.system, user: Self.secret, timeout: .seconds(1))
        }
    }

    // MARK: - by

    @Test func factsRecordChatGPTInBy() {
        let alone = FactCompiler.candidates(from: AttributedText(text: Self.better, author: .chatgpt),
                                            isSimilar: { _, _ in false })
        #expect(alone.candidates.map(\.by) == [.chatgpt, .chatgpt])
        let improved = FactCompiler.candidates(from: AttributedText(text: Self.better,
                                                                    author: .improvedByChatGPT(draft: Self.draft)),
                                               isSimilar: { _, _ in false })
        #expect(improved.candidates.map(\.by) == [.both, .chatgpt])
        #expect(FactWriter.allCases.map(\.rawValue) == ["local", "claude", "both", "chatgpt", "user"])
        #expect(FactWriter.chatgpt.merged(with: .chatgpt) == .chatgpt)
        #expect(FactWriter.chatgpt.merged(with: .claude) == .both)
        #expect(FactWriter.local.merged(with: .chatgpt) == .both)
    }

    @Test func aChatGPTFactRoundTripsThroughFactsJSON() throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let memory = MemoryStore(store: harness.store, clock: ManualClock(CoreHarness.epoch))
        let fact = MemoryFact(id: "f1", text: Self.draft, source: "conversation", created: CoreHarness.epoch,
                              updated: CoreHarness.epoch, by: .chatgpt)
        #expect(memory.updateFacts { $0.facts = [fact]; return true })
        #expect(memory.loadFacts()?.facts == [fact])
        #expect(try harness.sandbox.read("memory/facts.json").contains(#""by": "chatgpt""#))
    }

    // MARK: - ChatGPT's writer: codex with no tools

    struct WriterRun {
        let fake: FakeCodex
        let logs = LogRecorder()

        func writer(environment: [String: String] = [:], online: Bool = true,
                    preflight: (@Sendable () async -> CodexLoginStatus)? = nil) -> ChatGPTPersonaLLM {
            ChatGPTPersonaLLM(config: CodexConfig(environment: environment), executable: fake.script,
                              workingDirectory: fake.cwd, codexHome: fake.codexHome, catalogDirectory: fake.runDirectory,
                              parentEnvironment: ["HOME": fake.dir.path(percentEncoded: false), "PATH": "/usr/bin:/bin"],
                              online: { online }, preflight: preflight, log: logs.function)
        }
    }

    @Test func chatgptsWriterRunsCodexWithNoToolAndReportsNoBackend() async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.turnStarted, CodexLine.message("item_0", Self.better),
                                  CodexLine.turnCompleted], ending: .exit(0))
        defer { fake.remove() }
        let run = WriterRun(fake: fake)
        let reply = try await run.writer().complete(system: Self.system, user: "redacted text", timeout: .seconds(20))
        #expect(reply == Self.better)
        let argv = try #require(fake.argv)
        #expect(!argv.contains { $0.hasPrefix("mcp_servers.") })
        #expect(argv.first == "exec" && argv.last == "-")
        #expect(argv.contains("--ignore-user-config") && argv.contains(#"approval_policy="never""#))
        #expect(fake.text("stdin") == "redacted text")
        #expect(fake.environment?["CODEX_HOME"] == fake.codexHome.path(percentEncoded: false))
        let catalog = try PyJSON.loads(Data(contentsOf: fake.dir.appending(path: "catalog.json")))
        #expect(catalog == CodexInvocation.catalog(model: "gpt-6-luna", instructions: Self.system))
        #expect(run.logs.lines.isEmpty)   // no "Backend:" and no "unavailable this turn" line
    }

    @Test func chatgptsWriterRefusesAToolAndAFailedTurn() async throws {
        let tool = try FakeCodex([CodexLine.thread, CodexLine.toolStarted("item_0", tool: "get_time")], ending: .hang)
        defer { tool.remove() }
        await #expect(throws: PersonaWriterError.chatgptFailed("unexpected tool: jarvis.get_time")) {
            try await WriterRun(fake: tool).writer().complete(system: Self.system, user: "x", timeout: .seconds(20))
        }
        let failed = try FakeCodex([CodexLine.thread, CodexLine.message("item_0", "Half a"),
                                    CodexLine.turnFailed("stream disconnected")], ending: .exit(1))
        defer { failed.remove() }
        // A salvaged half-reply is never taken as the writer's text.
        await #expect(throws: PersonaWriterError.chatgptFailed("turn failed: stream disconnected")) {
            try await WriterRun(fake: failed).writer().complete(system: Self.system, user: "x", timeout: .seconds(20))
        }
    }

    @Test func chatgptsWriterRespectsItsSwitchTheNetworkAndTheSignIn() async throws {
        let fake = try FakeCodex([CodexLine.thread, CodexLine.message("item_0", Self.better), CodexLine.turnCompleted],
                                 ending: .exit(0))
        defer { fake.remove() }
        let run = WriterRun(fake: fake)
        await #expect(throws: PersonaWriterError.chatgptOff) {
            try await run.writer(environment: ["JARVIS_USE_CHATGPT": "0"]).complete(system: Self.system, user: "x",
                                                                                    timeout: .seconds(20))
        }
        await #expect(throws: PersonaWriterError.offline) {
            try await run.writer(online: false).complete(system: Self.system, user: "x", timeout: .seconds(20))
        }
        await #expect(throws: PersonaWriterError.chatgptFailed("not signed in")) {
            try await run.writer(preflight: { .signedOut }).complete(system: Self.system, user: "x", timeout: .seconds(20))
        }
        #expect(!fake.exists("argv"))   // codex never ran
    }
}

/// MEM1 part 4, live and gated (JARVIS_CHATGPT_LIVE=1): one compile batch written by ChatGPT,
/// through the real `codex` under JARVIS's own Codex home. It needs that home signed in
/// ("Sign in to ChatGPT…"); signed out it says so and checks nothing more.
@Suite("MEM1 part 4: a live compile batch through ChatGPT (gated)",
       .enabled(if: ProcessInfo.processInfo.environment["JARVIS_CHATGPT_LIVE"] == "1"))
struct MemoryWriterChatGPTLiveTests {
    @Test(.timeLimit(.minutes(3)))
    func oneBatch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let codex = try #require(BrainAssembly.locateCodex(environment: environment), "no codex")
        let login = CodexLogin(executable: codex)
        guard await login.status() == .signedIn else {
            print("MEM1 live: JARVIS's Codex home is not signed in; the ChatGPT compile batch did not run")
            return
        }
        let box = try Sandbox()
        defer { box.remove() }
        let writer = ChatGPTPersonaLLM(config: CodexConfig(environment: environment), executable: codex,
                                       workingDirectory: box.root.appending(path: "codex-cwd", directoryHint: .isDirectory),
                                       catalogDirectory: box.root.appending(path: "run", directoryHint: .isDirectory),
                                       parentEnvironment: environment, online: { true },
                                       preflight: { await login.status() })
        let transcript = Redactor.redacted("Conversation on 2026-10-02:\nUser: my sister Ana moved to Lisbon last week.\n"
                                           + "JARVIS: Lisbon, sir. Noted.")
        let started = ContinuousClock.now
        let reply = try await writer.complete(system: FactExtraction.system, user: transcript, timeout: .seconds(90))
        let facts = FactExtraction.facts(fromReply: reply)
        print("MEM1 live: \(Int((ContinuousClock.now - started) / .milliseconds(1))) ms, \(facts.facts.count) fact(s), "
              + "\(facts.dropped.count) dropped, passes the check: \(FactExtraction.passesCheck(reply, system: FactExtraction.system))")
        #expect(FactExtraction.passesCheck(reply, system: FactExtraction.system))
    }
}
