import Foundation
@testable import JarvisChat
import Synchronization
import Testing

/// M9a part 3: the push-to-talk controls' logic, over a fake listener, so no test opens the
/// microphone or asks for a permission.
@MainActor
@Suite("M9 push-to-talk")
struct PushToTalkTests {
    /// A clock the test moves by hand.
    final class Hands: @unchecked Sendable {
        var at = ContinuousClock.now
        func advance(_ d: Duration) { at += d }
    }

    struct Rig {
        let talk: PushToTalkModel
        let fake: FakeListener
        let hands: Hands
        let sleep: ManualSleep
        let events: Events
    }

    /// What the hooks saw, in order.
    @MainActor
    final class Events {
        var lines: [String] = []
    }

    static func rig(_ fake: FakeListener = FakeListener()) -> Rig {
        let hands = Hands()
        let sleep = ManualSleep()
        let talk = PushToTalkModel(sleep: { try await sleep.sleep($0) }, now: { hands.at })
        let events = Events()
        talk.onStart = { events.lines.append("stop") }
        talk.onListening = { events.lines.append("listening") }
        talk.onEnded = { events.lines.append("ended \($0)") }
        talk.onHeard = { events.lines.append("heard \($0)") }
        talk.onDenied = { events.lines.append("denied \($0)") }
        talk.connect(fake)
        return Rig(talk: talk, fake: fake, hands: hands, sleep: sleep, events: events)
    }

    /// Waits until a sleep of `d` has been asked for: the timers start on tasks of their own.
    static func asked(_ sleep: ManualSleep, for d: Duration) async -> Bool {
        for _ in 0..<2000 {
            if await sleep.requested.contains(d) { return true }
            try? await Task.sleep(for: .milliseconds(1), clock: .suspending)
        }
        return await sleep.requested.contains(d)
    }

    @Test("held past the threshold, letting go sends the text; starting stopped his speech first")
    func hold() async {
        let r = Self.rig(FakeListener(outcome: .text("What's the time?")))
        r.talk.buttonDown()
        #expect(r.talk.phase == .starting && r.talk.isOn)
        #expect(await eventually { r.talk.phase == .listening })
        r.hands.advance(.milliseconds(800))
        r.talk.buttonUp()
        #expect(await eventually { r.talk.phase == .idle })
        #expect(r.events.lines == ["stop", "listening", "ended true", "heard What's the time?"])
        #expect(r.fake.calls == ["access", "begin", "finish"])
        #expect(r.talk.notice == nil)
    }

    @Test("a click turns listening on, and the next click ends it")
    func click() async {
        let r = Self.rig(FakeListener(outcome: .text("hello")))
        r.talk.buttonDown()
        #expect(await eventually { r.talk.phase == .listening })
        r.hands.advance(.milliseconds(120))
        r.talk.buttonUp()
        #expect(r.talk.phase == .listening)
        r.hands.advance(.seconds(3))
        r.talk.buttonDown()
        #expect(await eventually { r.talk.phase == .idle })
        r.talk.buttonUp()                                   // the second click's release does nothing
        #expect(r.events.lines == ["stop", "listening", "ended true", "heard hello"])
    }

    @Test("letting go while the microphone is still opening ends it once it is open")
    func earlyRelease() async {
        let fake = FakeListener(outcome: .nothing(dropped: 0), beginGate: true)
        let r = Self.rig(fake)
        r.talk.buttonDown()
        #expect(await eventually { fake.calls == ["access", "begin"] })
        r.hands.advance(.milliseconds(900))
        r.talk.buttonUp()
        #expect(r.talk.phase == .starting)
        fake.openGate()
        #expect(await eventually { r.talk.phase == .idle })
        #expect(fake.calls == ["access", "begin", "finish"])
        #expect(r.talk.notice == PushToTalkModel.nothingHeard)
    }

    @Test("holding ⌥Space listens until it comes up")
    func optionSpace() async {
        let r = Self.rig(FakeListener(outcome: .text("turn it down")))
        r.talk.holdBegan()
        #expect(await eventually { r.talk.phase == .listening })
        r.talk.holdBegan()                                  // a second key-down changes nothing
        r.talk.holdEnded()
        #expect(await eventually { r.talk.phase == .idle })
        #expect(r.events.lines.last == "heard turn it down")
        #expect(r.fake.calls == ["access", "begin", "finish"])
    }

    @Test("⌃⌥J toggles")
    func globalToggle() async {
        let r = Self.rig(FakeListener(outcome: .text("x")))
        r.talk.toggle()
        #expect(await eventually { r.talk.phase == .listening })
        r.talk.toggle()
        #expect(await eventually { r.talk.phase == .idle })
        #expect(r.events.lines == ["stop", "listening", "ended true", "heard x"])
    }

    @Test("nothing heard, or nothing clear, sends nothing and says so for a few seconds",
          arguments: [(HeardOutcome.nothing(dropped: 0), PushToTalkModel.nothingHeard),
                      (.nothing(dropped: 2), PushToTalkModel.notClear),
                      (.unavailable, PushToTalkModel.unavailableNotice)])
    func notices(outcome: HeardOutcome, notice: String) async {
        let r = Self.rig(FakeListener(outcome: outcome))
        r.talk.toggle()
        #expect(await eventually { r.talk.phase == .listening })
        r.talk.toggle()
        #expect(await eventually { r.talk.notice == notice })
        #expect(r.events.lines == ["stop", "listening", "ended false"])
        #expect(await Self.asked(r.sleep, for: PushToTalkModel.noticeTime))
        // The longest-listen timer's sleep was cancelled; the notice's is the one left waiting.
        await r.sleep.releaseAll()
        #expect(await eventually { r.talk.notice == nil })
    }

    @Test("denied access says so in the composer, and the chat explains once")
    func denied() async {
        let fake = FakeListener(outcome: .text("x"), access: .microphoneDenied)
        let r = Self.rig(fake)
        r.talk.buttonDown()
        #expect(await eventually { r.talk.notice == PushToTalkModel.microphoneOff })
        r.talk.buttonUp()
        r.talk.buttonDown()
        #expect(await eventually { r.events.lines.count == 5 })
        #expect(r.events.lines == ["stop", "ended false", "denied microphoneDenied", "stop", "ended false"])
        #expect(fake.calls == ["access", "access"])
        #expect(PushToTalkModel.explanation(.microphoneDenied)?.contains("Privacy & Security, then Microphone") == true)
        #expect(PushToTalkModel.explanation(.speechRecognitionDenied)?.contains("Speech Recognition") == true)
        #expect(PushToTalkModel.explanation(.granted) == nil)
    }

    @Test("a microphone that will not open says so")
    func cannotOpen() async {
        let r = Self.rig(FakeListener(outcome: .text("x"), beginFails: true))
        r.talk.toggle()
        #expect(await eventually { r.talk.notice == PushToTalkModel.cannotStart })
        #expect(r.talk.phase == .idle)
        #expect(r.events.lines == ["stop", "ended false"])
    }

    @Test("the level jumps up and falls back by a quarter a frame; the live text shows while listening")
    func levelAndPreview() async {
        let fake = FakeListener(outcome: .text("set a timer"))
        let r = Self.rig(fake)
        var levels: [Double] = []
        r.talk.onLevel = { levels.append($0) }
        r.talk.toggle()
        #expect(await eventually { r.talk.phase == .listening })
        fake.send(level: 1.0)
        #expect(await eventually { r.talk.level == 1.0 })
        fake.send(level: 0)
        #expect(await eventually { r.talk.level == 0.75 })
        fake.send(level: 0.9)
        #expect(await eventually { r.talk.level == 0.9 })
        fake.send(preview: "set a")
        #expect(await eventually { r.talk.preview == "set a" })
        r.talk.toggle()
        #expect(await eventually { r.talk.phase == .idle })
        #expect(r.talk.preview == "" && r.talk.level == 0)
        #expect(levels == [1.0, 0.75, 0.9, 0])
        fake.send(preview: "late")                           // after the end: ignored
        try? await Task.sleep(for: .milliseconds(20))
        #expect(r.talk.preview == "")
    }

    @Test("a session left on ends by itself after the longest listen")
    func longest() async {
        let r = Self.rig(FakeListener(outcome: .text("still talking")))
        r.talk.toggle()
        #expect(await eventually { r.talk.phase == .listening })
        #expect(await Self.asked(r.sleep, for: PushToTalkModel.longest))
        await r.sleep.releaseOne()
        #expect(await eventually { r.talk.phase == .idle })
        #expect(r.events.lines.last == "heard still talking")
    }

    @Test("cancel drops the utterance")
    func cancel() async {
        let r = Self.rig(FakeListener(outcome: .text("never")))
        r.talk.toggle()
        #expect(await eventually { r.talk.phase == .listening })
        r.talk.cancel()
        #expect(r.talk.phase == .idle)
        #expect(await eventually { r.fake.calls.last == "cancel" })
        #expect(r.events.lines == ["stop", "listening", "ended false"])
    }

    @Test("without a listener the controls do nothing")
    func unconnected() {
        let talk = PushToTalkModel()
        talk.buttonDown()
        talk.toggle()
        #expect(talk.phase == .idle && !talk.isConnected)
    }
}

/// The microphone and transcriber, faked: it records calls and returns a fixed outcome.
final class FakeListener: VoiceListening, @unchecked Sendable {
    private struct State {
        var calls: [String] = []
        var level: (@Sendable (Double) -> Void)?
        var preview: (@Sendable (String) -> Void)?
        var gate: CheckedContinuation<Void, Never>?
        var gateOpen = false
    }
    private let state = Mutex(State())
    let outcome: HeardOutcome
    let accessAnswer: ListeningAccess
    let beginFails: Bool
    let beginGate: Bool

    init(outcome: HeardOutcome = .nothing(dropped: 0), access: ListeningAccess = .granted,
         beginFails: Bool = false, beginGate: Bool = false) {
        self.outcome = outcome
        self.accessAnswer = access
        self.beginFails = beginFails
        self.beginGate = beginGate
    }

    var calls: [String] { state.withLock { $0.calls } }

    func access() async -> ListeningAccess {
        state.withLock { $0.calls.append("access") }
        return accessAnswer
    }

    func begin(level: @escaping @Sendable (Double) -> Void,
               preview: @escaping @Sendable (String) -> Void) async throws {
        state.withLock {
            $0.calls.append("begin")
            $0.level = level
            $0.preview = preview
        }
        if beginGate {
            await withCheckedContinuation { c in
                let open = state.withLock { s -> Bool in
                    if s.gateOpen { return true }
                    s.gate = c
                    return false
                }
                if open { c.resume() }
            }
        }
        if beginFails { throw CancellationError() }
    }

    func openGate() {
        let c = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.gateOpen = true
            defer { s.gate = nil }
            return s.gate
        }
        c?.resume()
    }

    func finish() async -> HeardOutcome {
        state.withLock { $0.calls.append("finish") }
        return outcome
    }

    func cancel() async {
        state.withLock { $0.calls.append("cancel") }
    }

    func send(level v: Double) { state.withLock { $0.level }?(v) }
    func send(preview t: String) { state.withLock { $0.preview }?(t) }
}

extension ManualSleep {
    /// Lets every waiting sleep return.
    func releaseAll() {
        while waiting > 0 { releaseOne() }
    }
}
