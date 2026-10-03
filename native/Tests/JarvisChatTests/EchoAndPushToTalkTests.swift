import Foundation
import Synchronization
@testable import JarvisChat
import Testing

/// Live fix 4: JARVIS's own "…, sir" leaked into a push-to-talk transcript. Push-to-talk now
/// waits for his speech to stop before the microphone opens, and a trailing ", sir" that echoes
/// his last line within 2 s is taken off a voice transcript.
@Suite("Echo filter and push-to-talk stopping him first (live fix 4)", .serialized)
@MainActor
struct EchoAndPushToTalkTests {
    @Test func aTrailingSirThatEchoesHisLastLineIsTakenOff() {
        let t = 1_790_582_400.0
        #expect(EchoFilter.strip("Do I have any reminders, sir?", lastLine: "Right away, sir.", spokeAt: t, now: t + 1.5)
                == "Do I have any reminders?")
        #expect(EchoFilter.strip("what's the time, Sir", lastLine: "Yes, sir?", spokeAt: t, now: t) == "what's the time")
    }

    @Test func otherwiseTheTranscriptIsLeftAlone() {
        let t = 1_790_582_400.0
        // Too long after he spoke.
        #expect(EchoFilter.strip("Do I have any reminders, sir?", lastLine: "Right away, sir.", spokeAt: t, now: t + 2.5) == nil)
        // His last line did not end in "sir".
        #expect(EchoFilter.strip("Do I have any reminders, sir?", lastLine: "It is ten o'clock.", spokeAt: t, now: t) == nil)
        // No trailing ", sir", or nothing before it.
        #expect(EchoFilter.strip("Do I have any reminders?", lastLine: "Right away, sir.", spokeAt: t, now: t) == nil)
        #expect(EchoFilter.strip(", sir", lastLine: "Right away, sir.", spokeAt: t, now: t) == nil)
        #expect(EchoFilter.strip("call sir alan", lastLine: "Right away, sir.", spokeAt: t, now: t) == nil)
        // He has not spoken.
        #expect(EchoFilter.strip("hello, sir", lastLine: nil, spokeAt: nil, now: t) == nil)
    }

    @Test func pushToTalkOpensTheMicrophoneOnlyAfterHisSpeechHasStopped() async {
        let fake = FakeListener(outcome: .text("Do I have any reminders set"))
        let talk = PushToTalkModel(sleep: { try await Task.sleep(for: $0) }, now: { ContinuousClock.now })
        let order = Mutex<[String]>([])
        let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
        talk.onStart = { order.withLock { $0.append("stop") } }
        talk.beforeListening = {
            order.withLock { $0.append("waiting for him to stop") }
            await withCheckedContinuation { c in release.withLock { $0 = c } }
            order.withLock { $0.append("he stopped") }
        }
        talk.connect(fake)
        talk.buttonDown()
        #expect(await eventually { release.withLock { $0 } != nil })
        #expect(fake.calls.isEmpty)                                // the microphone is not open yet
        release.withLock { $0 }?.resume()
        #expect(await eventually { talk.phase == .listening })
        #expect(order.withLock { $0 } == ["stop", "waiting for him to stop", "he stopped"])
        #expect(fake.calls == ["access", "begin"])
        talk.cancel()
    }
}
