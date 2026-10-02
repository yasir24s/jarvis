import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// B2 part 3: BrainRouter's three-way choice. ChatGPT needs `JARVIS_USE_CHATGPT` and a network,
/// gets the same system prompt as Claude, and falls back to the on-device model as Claude does.
/// Each switch turns off its own brain only.
@Suite("B2 brain choice: Claude, ChatGPT, On-device")
struct ChatGPTChoiceTests {
    static let claudeReply = "Claude reply, sir."
    static let chatgptReply = "ChatGPT reply, sir."
    static let localReply = "Local reply, sir."
    static let localBackend = "backend \(LocalBrain.backendName)"

    struct Rig {
        let harness: CoreHarness
        let events: EventLog
        let claude: FakeClaudeBrain
        let chatgpt: FakeClaudeBrain
        let local: FakeLocalBrain
        let router: BrainRouter
        let choice: BrainChoiceTests.Choice

        init(claudeEnv: [String: String] = [:], chatgptEnabled: Bool = true, choice c: BrainChoice,
             chatgptReply: String? = ChatGPTChoiceTests.chatgptReply, withChatGPT: Bool = true) throws {
            events = EventLog()
            let research = EventCounter(events)
            harness = try CoreHarness(research: research)
            claude = FakeClaudeBrain(reply: ChatGPTChoiceTests.claudeReply, events: events)
            chatgpt = FakeClaudeBrain(reply: chatgptReply, events: events)
            local = FakeLocalBrain(.reply(ChatGPTChoiceTests.localReply), events: events)
            let choice = BrainChoiceTests.Choice(c)
            self.choice = choice
            router = BrainRouter(core: harness.core, config: ClaudeConfig(environment: claudeEnv), claude: claude,
                                 chatgpt: withChatGPT ? chatgpt : nil, chatgptEnabled: chatgptEnabled,
                                 local: local, backend: EventBackend(events), research: research,
                                 choice: { choice.get }, log: { _ in })
        }

        func run(online: Bool = true) async -> String {
            await router.process("what time is it", online: online, channel: .text,
                                 turn: TurnContext(channel: .text), sink: RecordingSink())
        }
    }

    @Test func theRouterFollowsTheThreeWayChoiceEachTurn() async throws {
        let rig = try Rig(choice: .chatgpt)
        defer { rig.harness.remove() }
        #expect(await rig.run() == Self.chatgptReply)
        rig.choice.set(.claude)
        #expect(await rig.run() == Self.claudeReply)
        rig.choice.set(.onDevice)
        #expect(await rig.run() == Self.localReply)
        rig.choice.set(.chatgpt)
        #expect(await rig.run() == Self.chatgptReply)
        #expect(await rig.chatgpt.calls.count == 2)
        #expect(await rig.claude.calls.count == 1)
        #expect(await rig.local.calls.count == 1)
    }

    /// ChatGPT, then the on-device model: the router order for a ChatGPT turn.
    @Test(arguments: [nil, ""])
    func chatgptGivingNothingFallsBackToOnDevice(_ reply: String?) async throws {
        let rig = try Rig(choice: .chatgpt, chatgptReply: reply)
        defer { rig.harness.remove() }
        #expect(await rig.run() == Self.localReply)
        #expect(await rig.chatgpt.calls.count == 1)
        #expect(await rig.claude.calls.isEmpty)
        #expect(rig.events.events.contains(Self.localBackend))
    }

    @Test func chatgptChosenButOfflineAnswersOnDevice() async throws {
        let rig = try Rig(choice: .chatgpt)
        defer { rig.harness.remove() }
        #expect(await rig.run(online: false) == Self.localReply)
        #expect(await rig.chatgpt.calls.isEmpty)
    }

    @Test func useChatGPTZeroForcesOnDeviceForAChatGPTPickOnly() async throws {
        let rig = try Rig(chatgptEnabled: false, choice: .chatgpt)
        defer { rig.harness.remove() }
        #expect(await rig.run() == Self.localReply)
        #expect(await rig.chatgpt.calls.isEmpty)
        rig.choice.set(.claude)
        #expect(await rig.run() == Self.claudeReply)
    }

    @Test func useClaudeZeroLeavesChatGPTOn() async throws {
        let rig = try Rig(claudeEnv: ["JARVIS_USE_CLAUDE": "0"], choice: .chatgpt)
        defer { rig.harness.remove() }
        #expect(await rig.run() == Self.chatgptReply)
        rig.choice.set(.claude)
        #expect(await rig.run() == Self.localReply)
        #expect(await rig.claude.calls.isEmpty)
    }

    @Test func noChatGPTBrainAnswersOnDevice() async throws {
        let rig = try Rig(choice: .chatgpt, withChatGPT: false)
        defer { rig.harness.remove() }
        #expect(await rig.run() == Self.localReply)
    }

    /// The same system prompt, memory variant and user text as Claude's, from the same state:
    /// one rig, the Claude turn's history rewound before the ChatGPT turn.
    @Test func chatgptGetsClaudesPrompt() async throws {
        let rig = try Rig(choice: .claude)
        defer { rig.harness.remove() }
        let mark = await rig.router.historyMark()
        _ = await rig.run()
        await rig.router.rewindHistory(to: mark)
        rig.choice.set(.chatgpt)
        _ = await rig.run()
        let claudeCall = try #require(await rig.claude.calls.first)
        let chatgptCall = try #require(await rig.chatgpt.calls.first)
        #expect(chatgptCall.system == claudeCall.system)
        #expect(chatgptCall.user == claudeCall.user)
        #expect(chatgptCall.channel == .text)
    }
}
