import Foundation
import JarvisBrain
import JarvisCore
@testable import JarvisChat
import JarvisTools
import Testing

/// Stop Speaking sticks: Stop Speaking mutes him (`speechMuted`) until the user resumes speaking.
/// Unmuted, "Speak replies" keeps its old meaning. In a UserDefaults suite of the test's own, never the app's; the "voice"
/// is a recorded list, so nothing plays.
@MainActor
@Suite("Stop Speaking sticks", .timeLimit(.minutes(1)))
struct StopSticksTests {
    final class Suite: @unchecked Sendable {
        let name = "jarvis-stop-sticks-\(UUID().uuidString)"
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    /// What the app's voice does with a line (`AppVoice.speak`): spoken unless speaking is off,
    /// shown instead when it is.
    @MainActor
    final class Voice {
        let mute: SpeechMute
        var spoken: [String] = []
        var shown: [String] = []
        var cancels = 0
        init(_ defaults: UserDefaults) {
            var me: Voice?
            mute = SpeechMute(defaults: defaults, cancel: { me?.cancels += 1 })
            me = self
        }
        func speak(_ text: String) {
            if mute.isMuted { shown.append(text) } else { spoken.append(text) }
        }
    }

    @Test("Stop mutes, stops what is speaking, and the setting is stored")
    func stopMutesAndPersists() {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        toggle.isOn = true
        let voice = Voice(suite.defaults)
        #expect(!voice.mute.isMuted, "not muted until Stop Speaking")
        voice.mute.stop()
        #expect(voice.mute.isMuted)
        #expect(voice.cancels == 1)
        #expect(suite.defaults.object(forKey: SpeechMute.defaultsKey) as? Bool == true)
        #expect(toggle.isOn, "Speak replies is left alone")
    }

    @Test("a relaunch keeps speaking off; only the user's choice turns it back on")
    func relaunchKeepsTheState() {
        let suite = Suite()
        SpeechMute(defaults: suite.defaults, cancel: {}).stop()
        // A new launch reads the stored setting.
        let relaunched = SpeechMute(defaults: suite.defaults, cancel: {})
        #expect(relaunched.isMuted)
        #expect(relaunched.muted)
        relaunched.resume()
        #expect(!SpeechMute(defaults: suite.defaults, cancel: {}).isMuted)
    }

    @Test("a reply that arrives after Stop, for a request made before it, is not spoken; its text is shown")
    func lateReplyIsNotSpoken() async {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        toggle.isOn = true
        let voice = Voice(suite.defaults)
        let gate = Gate()
        let fake = FakeCoordinator { _, sink in
            await gate.park()
            await sink.sentence("Here is the long answer, sir.")
            return .reply("Here is the long answer, sir.")
        }
        let model = ChatViewModel(submitter: fake, minimumGap: .zero)
        model.onReplyFinished = { message, turn in
            let context = SpeakReplies.context(for: message, turn: turn, toggle: toggle, chatWindowIsKey: false,
                                               userIdleSeconds: 0, ttsBackend: "qwen")
            SpeakReplies.replyFinished(message, context: context, research: ResearchRecorder(),
                                       speaker: { text, _ in voice.speak(text) }, log: { _ in })
        }
        let turn = model.sendVoice("Tell me everything")
        await gate.waitUntilParked()
        voice.mute.stop()   // the menus' Stop Speaking, while the brain is still working
        await gate.open()
        await turn?.value
        #expect(voice.spoken.isEmpty)
        #expect(voice.shown == ["Here is the long answer, sir."])
        // The brain's work was not cancelled: the chat has the reply.
        #expect(model.messages.last?.text == "Here is the long answer, sir.")
        #expect(model.messages.last?.stopped == false)
    }

    /// What the app does with a finished reply (AppDelegate's `onReplyFinished`): the speak policy,
    /// then the voice.
    func deliver(to voice: Voice, toggle: SpeakRepliesToggle, micOnly: Bool = false) -> (ChatMessage, TurnSummary) -> Void {
        { message, turn in
            let context = SpeakReplies.context(for: message, turn: turn, toggle: toggle, chatWindowIsKey: false,
                                               userIdleSeconds: 0, ttsBackend: "qwen", speakAnyway: micOnly)
            SpeakReplies.replyFinished(message, context: context, research: ResearchRecorder(),
                                       speaker: { text, _ in voice.speak(text) }, log: { _ in })
        }
    }

    func ask(_ voice: Voice, toggle: SpeakRepliesToggle, channel: Channel, micOnly: Bool = false) async -> ChatViewModel {
        let model = ChatViewModel(submitter: FakeCoordinator(answering: .reply("It's ten past three, sir.")), minimumGap: .zero)
        model.onReplyFinished = deliver(to: voice, toggle: toggle, micOnly: micOnly)
        if channel == .voice {
            await model.sendVoice("What's the time?")?.value
        } else {
            model.draft.text = "What's the time?"
            await model.send()?.value
        }
        return model
    }

    @Test("unmuted, it is as before: Speak replies off still speaks voice turns, not typed ones")
    func unmutedIsAsBefore() async {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)   // off, as on a new install
        let voice = Voice(suite.defaults)
        _ = await ask(voice, toggle: toggle, channel: .voice)
        _ = await ask(voice, toggle: toggle, channel: .text)
        #expect(voice.spoken == ["It's ten past three, sir."])
        // Mic Only Mode keeps its "speak anyway" for typed replies too.
        _ = await ask(voice, toggle: toggle, channel: .text, micOnly: true)
        #expect(voice.spoken.count == 2)
        toggle.isOn = true
        _ = await ask(voice, toggle: toggle, channel: .text)
        #expect(voice.spoken.count == 3)
        #expect(voice.shown.isEmpty)
    }

    @Test("muted, nothing is spoken, voice turns, typed replies or Mic Only Mode; the text is delivered")
    func newRequestWhileMuted() async {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        toggle.isOn = true
        let voice = Voice(suite.defaults)
        voice.mute.stop()
        for (channel, micOnly) in [(Channel.voice, false), (.text, false), (.text, true)] {
            let model = await ask(voice, toggle: toggle, channel: channel, micOnly: micOnly)
            #expect(model.messages.last?.text == "It's ten past three, sir.")
        }
        #expect(voice.spoken.isEmpty)
        #expect(voice.shown.count == 3)
        #expect(voice.mute.isMuted, "a new request does not unmute")
    }

    @Test("a timer while muted is a notification and the HUD, not speech; other lines go to the chat")
    func timerWhileMuted() {
        let suite = Suite()
        let mute = SpeechMute(defaults: suite.defaults, cancel: {})
        var spoken: [String] = []
        var alerted: [String] = []
        var posted: [String] = []
        let announcer = ReminderAnnouncer(isBusy: { false }, speak: { spoken.append($0) }, post: { posted.append($0) },
                                          muted: { mute.isMuted }, alert: { alerted.append($0) })
        mute.stop()
        announcer.announce("Sir, your timer is done.", urgent: true)
        announcer.announce("Welcome back, sir.")
        #expect(spoken.isEmpty)
        #expect(alerted == ["Sir, your timer is done."])
        #expect(posted == ["Welcome back, sir."])
        // Stop Speaking does not suppress future alarms: unmuted, the next one is spoken.
        mute.resume()
        announcer.announce("Sir, your alarm.", urgent: true)
        #expect(spoken == ["Sir, your alarm."])
    }

    @Test("a line held behind a reply follows the setting as it is when it goes out")
    func heldLineFollowsTheSetting() async {
        let suite = Suite()
        let mute = SpeechMute(defaults: suite.defaults, cancel: {})
        var busy = true
        var spoken: [String] = []
        var alerted: [String] = []
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let announcer = ReminderAnnouncer(isBusy: { busy }, speak: { spoken.append($0) }, post: { _ in },
                                          muted: { mute.isMuted },
                                          alert: { alerted.append($0); continuation.yield() },
                                          sleep: { _ in await Task.yield() })
        announcer.announce("Sir, your reminder.", urgent: true)
        mute.stop()
        busy = false
        var it = stream.makeAsyncIterator()
        _ = await it.next()
        #expect(spoken.isEmpty)
        #expect(alerted == ["Sir, your reminder."])
    }

    @Test("\"resume speaking\" unmutes and answers; other text goes on to the quick commands")
    func resumeCommand() async {
        let suite = Suite()
        let mute = SpeechMute(defaults: suite.defaults, cancel: {})
        mute.stop()
        let next = RecordingFastPath()
        let path = ResumeSpeakingFastPath(next: next, resume: { await MainActor.run { mute.resume() } })
        let turn = TurnContext(channel: .voice)
        #expect(await path.route("What's the time?", turn: turn) == nil)
        #expect(mute.isMuted)
        #expect(await next.asked == ["What's the time?"])
        #expect(await path.route("Resume speaking, please.", turn: turn) == ResumeSpeakingFastPath.reply)
        #expect(!mute.isMuted)
        #expect(await next.asked == ["What's the time?"])
    }

    @Test("only the command as a whole matches")
    func resumeMatching() {
        for text in ["you can speak again", "Jarvis, you can speak again.", "Unmute", "unmute yourself, sir",
                     "Resume speaking", "start speaking again"] {
            #expect(ResumeSpeakingFastPath.matches(text), "\(text)")
        }
        for text in ["unmute the TV", "don't resume speaking", "speak", "stop speaking", ""] {
            #expect(!ResumeSpeakingFastPath.matches(text), "\(text)")
        }
    }

    @Test("the HUD shows a line he would have spoken, marked muted, and the turn's end leaves it up")
    func hudShowsTheMutedLine() {
        let hud = HUDModel(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        hud.turnBegan("What's the time?")
        hud.muted("It's ten past three, sir.")
        hud.turnEnded(speechFollows: false)
        #expect(hud.caption == "It's ten past three, sir.")
        #expect(hud.status == HUDModel.mutedStatus)
        #expect(hud.shown)
        hud.turnBegan("Next")   // anything else takes over as usual
        #expect(hud.caption == "Next")
    }
}

actor RecordingFastPath: FastPathRouting {
    private(set) var asked: [String] = []
    func route(_ text: String, turn: TurnContext) async -> String? {
        asked.append(text)
        return nil
    }
}
