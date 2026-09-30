import Foundation
import JarvisBrain
import JarvisCore
@testable import JarvisChat
import JarvisTools
import Synchronization
import Testing

/// The speak policy, the "Speak replies" toggle and the hook that asks the policy (plan
/// §3.12, T4.4). Nothing here speaks: there is no speaker before M8.
@Suite("M4 speak policy and toggle (plan 3.12)", .timeLimit(.minutes(1)))
@MainActor
struct SpeakPolicyTests {
    static let reply = ChatMessage(role: .assistant, text: "It is **three** o'clock, sir.", phase: .finished)

    /// A UserDefaults suite of its own, in a temp folder that is removed when `body` returns.
    /// The suite is named by an absolute path, so its plist is written there, never in
    /// ~/Library/Preferences (a named suite leaves an empty plist there even after
    /// `removePersistentDomain`).
    static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-speak-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    static func context(toggle: Bool, windowIsKey: Bool = false, idle: Double = 0,
                        tainted: Bool = false) async throws -> SpeakContext {
        var result: SpeakContext?
        let turn = await TurnContext(channel: .text, startTainted: tainted).summary()
        try withDefaults { defaults in
            let speak = SpeakRepliesToggle(defaults: defaults)
            speak.isOn = toggle
            result = SpeakReplies.context(for: reply, turn: turn, toggle: speak, chatWindowIsKey: windowIsKey,
                                          userIdleSeconds: idle)
        }
        return try #require(result)
    }

    /// A context made directly, for the cases `SpeakReplies.context` does not produce: a voice
    /// conversation, a given length, another voice, and data sources from the named tools.
    static func direct(toggle: Bool = true, voice: Bool = false, chars: Int = 30,
                       backend: String = SpeakReplies.noTTSBackend, tools: [String] = []) async -> SpeakContext {
        let turn = TurnContext(channel: .text)
        for tool in tools { await turn.recordSources(for: tool) }
        return SpeakContext(chatWindowIsKey: false, speakToggleOn: toggle, userIdleSeconds: 0,
                            voiceConversationActive: voice, replyCharCount: chars,
                            turn: await turn.summary(), ttsBackend: backend)
    }

    @Test("the toggle is consent: off never speaks; on speaks whatever the focus and idle time")
    func toggleDecides() async throws {
        for (key, idle, tainted) in [(false, 0.0, false), (true, 0.0, false), (false, 3600.0, true), (true, 3600.0, true)] {
            let off = try await Self.context(toggle: false, windowIsKey: key, idle: idle, tainted: tainted)
            #expect(!shouldSpeakReply(channel: .text, text: Self.reply.text, context: off))
            let on = try await Self.context(toggle: true, windowIsKey: key, idle: idle, tainted: tainted)
            #expect(shouldSpeakReply(channel: .text, text: Self.reply.text, context: on))
        }
    }

    @Test("only typed replies, and never over a voice conversation")
    func channelAndVoiceLoop() async {
        #expect(!shouldSpeakReply(channel: .voice, text: "Done, sir.", context: await Self.direct()))
        #expect(!shouldSpeakReply(channel: .text, text: "Done, sir.", context: await Self.direct(voice: true)))
    }

    @Test("an empty reply, or one over the limit, is not read aloud")
    func length() async {
        #expect(SpeakRules.replyLimit == 600)
        #expect(!shouldSpeakReply(channel: .text, text: "", context: await Self.direct(chars: 0)))
        for count in [1, 599, 600, 601] {
            let text = String(repeating: "x", count: count)
            #expect(shouldSpeakReply(channel: .text, text: text, context: await Self.direct(chars: count))
                    == (count <= 600))
        }
    }

    @Test("blank text and stale length metadata cannot enable speech")
    func actualTextIsChecked() async {
        for text in ["", " \t\n", "\u{00A0}\u{2003}", String(repeating: "x", count: 601)] {
            #expect(!shouldSpeakReply(channel: .text, text: text, context: await Self.direct(chars: 1)))
        }
        for count in [-1, 0, 601] {
            #expect(!shouldSpeakReply(channel: .text, text: "Done.", context: await Self.direct(chars: count)))
        }
    }

    @Test("length uses Unicode scalars, not bytes or grapheme clusters")
    func unicodeLength() async {
        let emoji = String(repeating: "\u{1F600}", count: 600)
        #expect(shouldSpeakReply(channel: .text, text: emoji, context: await Self.direct(chars: 600)))
        let combining = String(repeating: "e\u{0301}", count: 301)
        #expect(combining.count == 301 && combining.unicodeScalars.count == 602)
        #expect(!shouldSpeakReply(channel: .text, text: combining, context: await Self.direct(chars: 301)))
    }

    @Test("a cloud voice never reads out personal content; a local voice may")
    func personalContent() async {
        let text = "You have two new messages, sir."
        for tool in ["get_messages", "read_clipboard", "see_screen", "read_file", "get_calendar",
                     "set_reminder", "find_contact", "send_email", "make_note", "get_location"] {
            #expect(!shouldSpeakReply(channel: .text, text: text, context: await Self.direct(backend: "elevenlabs", tools: [tool])))
            #expect(shouldSpeakReply(channel: .text, text: text, context: await Self.direct(backend: "piper", tools: [tool])))
        }
        #expect(shouldSpeakReply(channel: .text, text: text, context: await Self.direct(backend: "elevenlabs", tools: ["get_news"])))
    }

    @Test("the toggle is off at first, and persists across launches")
    func togglePersists() throws {
        try Self.withDefaults { defaults in
            #expect(SpeakRepliesToggle.defaultsKey == "speakReplies")
            let first = SpeakRepliesToggle(defaults: defaults)
            #expect(!first.isOn)
            first.isOn = true
            #expect(defaults.bool(forKey: SpeakRepliesToggle.defaultsKey))
            // A later launch reads it back.
            let second = SpeakRepliesToggle(defaults: defaults)
            #expect(second.isOn)
            second.isOn = false
            #expect(!SpeakRepliesToggle(defaults: defaults).isOn)
        }
    }

    @Test("the toggle and the finished row feed SpeakContext", arguments: [false, true])
    func toggleFeedsTheContext(toggle: Bool) async throws {
        let context = try await Self.context(toggle: toggle, windowIsKey: true, idle: 42, tainted: true)
        #expect(context.speakToggleOn == toggle)
        #expect(context.chatWindowIsKey)
        #expect(context.userIdleSeconds == 42)
        #expect(!context.voiceConversationActive)
        #expect(context.replyCharCount == Self.reply.text.unicodeScalars.count)
        #expect(context.turn.channel == .text)
        #expect(context.turn.tainted)
        #expect(context.ttsBackend == SpeakReplies.noTTSBackend)
    }

    @Test("the policy's no: nothing is spoken, counted or logged")
    func policySaysNo() async throws {
        let research = ResearchRecorder()
        var spoken: [String] = []
        var logged: [String] = []
        let context = try await Self.context(toggle: false)
        let said = SpeakReplies.replyFinished(Self.reply, context: context, research: research,
                                              speaker: { text, _ in spoken.append(text) }, log: { logged.append($0) })
        #expect(!said)
        #expect(spoken.isEmpty && logged.isEmpty && research.counts.isEmpty)
    }

    @Test("a yes before M8 has no speaker: nothing is spoken or counted, and the log says so")
    func yesWithoutASpeaker() async throws {
        let research = ResearchRecorder()
        var logged: [String] = []
        let context = try await Self.context(toggle: true)
        let said = SpeakReplies.replyFinished(Self.reply, context: context, research: research, speaker: nil,
                                              log: { logged.append($0) })
        #expect(said)
        #expect(research.counts.isEmpty)
        #expect(logged == ["speak policy: yes, but typed replies are not spoken until M8"])
    }

    @Test("a yes with a speaker bumps text_reply_spoken and hands over the text and the turn")
    func yesWithASpeaker() async throws {
        let research = ResearchRecorder()
        var spoken: [(String, UUID)] = []
        let context = try await Self.context(toggle: true)
        let said = SpeakReplies.replyFinished(Self.reply, context: context, research: research,
                                              speaker: { spoken.append(($0, $1.turnID)) }, log: { _ in })
        #expect(said)
        #expect(research.counts == ["text_reply_spoken": 1])
        #expect(spoken.map(\.0) == [Self.reply.text])
        #expect(spoken.map(\.1) == [context.turn.turnID])
    }
}
