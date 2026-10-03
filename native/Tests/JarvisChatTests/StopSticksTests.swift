import Foundation
import JarvisBrain
import JarvisCore
@testable import JarvisChat
import JarvisTools
import Testing

/// Stop Speaking sticks: Stop Speaking turns speaking off (the "Speak Replies" setting) until the
/// user turns it back on. In a UserDefaults suite of the test's own, never the app's; the "voice"
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
        init(_ toggle: SpeakRepliesToggle) {
            var me: Voice?
            mute = SpeechMute(toggle: toggle, cancel: { me?.cancels += 1 })
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
        let voice = Voice(toggle)
        #expect(!voice.mute.isMuted)
        voice.mute.stop()
        #expect(voice.mute.isMuted)
        #expect(voice.cancels == 1)
        #expect(suite.defaults.object(forKey: SpeakRepliesToggle.defaultsKey) as? Bool == false)
    }

    @Test("a relaunch keeps speaking off; only the user's choice turns it back on")
    func relaunchKeepsTheState() {
        let suite = Suite()
        let first = SpeakRepliesToggle(defaults: suite.defaults)
        first.isOn = true
        SpeechMute(toggle: first, cancel: {}).stop()
        // A new launch reads the stored setting.
        let relaunched = SpeechMute(toggle: SpeakRepliesToggle(defaults: suite.defaults), cancel: {})
        #expect(relaunched.isMuted)
        relaunched.resume()
        #expect(!SpeechMute(toggle: SpeakRepliesToggle(defaults: suite.defaults), cancel: {}).isMuted)
    }

    @Test("a reply that arrives after Stop, for a request made before it, is not spoken; its text is shown")
    func lateReplyIsNotSpoken() async {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        toggle.isOn = true
        let voice = Voice(toggle)
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

    @Test("a new request while speaking is off is answered in text, not speech")
    func newRequestWhileMuted() async {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        let voice = Voice(toggle)
        voice.mute.stop()
        for channel in [Channel.voice, .text] {
            let fake = FakeCoordinator(answering: .reply("It's ten past three, sir."))
            let model = ChatViewModel(submitter: fake, minimumGap: .zero)
            model.onReplyFinished = { message, turn in
                // Mic Only Mode speaks every reply whatever the toggle says; speaking off still wins.
                let context = SpeakReplies.context(for: message, turn: turn, toggle: toggle, chatWindowIsKey: false,
                                                   userIdleSeconds: 0, ttsBackend: "qwen", speakAnyway: true)
                SpeakReplies.replyFinished(message, context: context, research: ResearchRecorder(),
                                           speaker: { text, _ in voice.speak(text) }, log: { _ in })
            }
            if channel == .voice {
                await model.sendVoice("What's the time?")?.value
            } else {
                model.draft.text = "What's the time?"
                await model.send()?.value
            }
            #expect(model.messages.last?.text == "It's ten past three, sir.")
        }
        #expect(voice.spoken.isEmpty)
        #expect(voice.shown == ["It's ten past three, sir.", "It's ten past three, sir."])
        #expect(voice.mute.isMuted, "a new request does not turn speaking back on")
    }

    @Test("a timer while speaking is off is a notification and the HUD, not speech; other lines go to the chat")
    func timerWhileMuted() {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        toggle.isOn = true
        let mute = SpeechMute(toggle: toggle, cancel: {})
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
        // Stop Speaking does not suppress future alarms: back on, the next one is spoken.
        mute.resume()
        announcer.announce("Sir, your alarm.", urgent: true)
        #expect(spoken == ["Sir, your alarm."])
    }

    @Test("a line held behind a reply follows the setting as it is when it goes out")
    func heldLineFollowsTheSetting() async {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        toggle.isOn = true
        let mute = SpeechMute(toggle: toggle, cancel: {})
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

    @Test("\"resume speaking\" turns speaking back on and answers; other text goes on to the quick commands")
    func resumeCommand() async {
        let suite = Suite()
        let toggle = SpeakRepliesToggle(defaults: suite.defaults)
        let mute = SpeechMute(toggle: toggle, cancel: {})
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
