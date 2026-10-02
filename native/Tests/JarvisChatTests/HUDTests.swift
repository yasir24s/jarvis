import Foundation
import JarvisBrain
@testable import JarvisChat
import JarvisTools
import Testing

/// A sleep the test lets go of: each call is recorded and waits until released.
actor ManualSleep {
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    /// Lets the oldest waiting sleep return.
    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    var waiting: Int { waiters.count }
}

@MainActor
private func settle(_ until: () async -> Bool) async {
    for _ in 0..<200 where !(await until()) {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// UI1 part 3: what the HUD shows and when (plan: M08-M13 §3.7, hud.html).
@Suite("UI1 HUD", .serialized)
@MainActor
struct HUDTests {
    @Test func statesCarryHUDLabelsAndLevels() {
        #expect(HUDState.allCases.map(\.label) == ["J.A.R.V.I.S", "Listening", "Processing", "Speaking"])
        #expect(HUDState.allCases.map(\.level) == [0, 0.6, 0.35, 0.6])
    }

    @Test func captionsTakeTheirShareOfTheAudio() {
        // 20, 9 and 9 code points of 38, so 8 s splits 20:9:9.
        let timeline = CaptionTimeline(text: "Twenty letters here. Ten here. Ten again", duration: 8)
        #expect(timeline.lines.map(\.text) == ["Twenty letters here.", "Ten here.", "Ten again"])
        let starts = timeline.lines.map(\.start)
        #expect(starts.count == 3)
        #expect(starts[0] == 0)
        #expect(abs(starts[1] - 8 * 20.0 / 38) < 1e-9)
        #expect(abs(starts[2] - 8 * 29.0 / 38) < 1e-9)
        #expect(timeline.line(at: -0.1) == nil)
        #expect(timeline.line(at: 0) == "Twenty letters here.")
        #expect(timeline.line(at: starts[1] - 0.001) == "Twenty letters here.")
        #expect(timeline.line(at: starts[1]) == "Ten here.")
        #expect(timeline.line(at: 7.99) == "Ten again")
        #expect(timeline.line(at: 60) == "Ten again")
        #expect(CaptionTimeline(text: "", duration: 3).lines.isEmpty)
        #expect(CaptionTimeline(text: "One sentence only.", duration: 2).lines == [.init(text: "One sentence only.", start: 0)])
    }

    @Test func idleShowsThenHidesAfterTwoPointSixSeconds() async {
        let clock = ManualSleep()
        let hud = HUDModel(sleep: { try await clock.sleep($0) })
        #expect(!hud.shown)
        hud.state(.idle)
        #expect(hud.shown && hud.status == "J.A.R.V.I.S" && hud.level == 0)
        await settle { await clock.waiting == 1 }
        #expect(await clock.requested == [.milliseconds(2600)])
        await clock.releaseOne()
        await settle { !hud.shown }
        #expect(!hud.shown)
    }

    @Test func anyStateCancelsTheIdleHide() async {
        let clock = ManualSleep()
        let hud = HUDModel(sleep: { try await clock.sleep($0) })
        hud.state(.idle)
        await settle { await clock.waiting == 1 }
        hud.state(.thinking, text: "Working")
        #expect(hud.status == "Working" && hud.level == 0.35)
        await clock.releaseOne()   // the cancelled timer's sleep returns
        for _ in 0..<20 { await Task.yield() }
        #expect(hud.shown && hud.state == .thinking)
    }

    @Test func aTurnThinksWithTheMessageThenSettles() async {
        let clock = ManualSleep()
        let hud = HUDModel(sleep: { try await clock.sleep($0) })
        hud.turnBegan("What's the weather?")
        #expect(hud.shown && hud.state == .thinking && hud.status == "Processing")
        #expect(hud.caption == "What's the weather?")
        hud.turnEnded(speechFollows: false)
        #expect(hud.state == .idle && hud.caption == nil && hud.shown)
        await settle { await clock.waiting == 1 }
        await clock.releaseOne()
        await settle { !hud.shown }
        #expect(!hud.shown)
    }

    @Test func speechCaptionsAdvanceSentenceBySentence() async {
        let clock = ManualSleep()
        let hud = HUDModel(sleep: { try await clock.sleep($0) })
        hud.turnBegan("Tell me two things.")
        hud.turnEnded(speechFollows: true)
        #expect(hud.state == .thinking && hud.caption == "Tell me two things.")   // until the audio starts
        let timeline = CaptionTimeline(text: "First thing. Second thing.", duration: 4)
        hud.speechStarted(timeline)
        #expect(hud.state == .speaking && hud.status == "Speaking" && hud.level == 0.6)
        #expect(hud.caption == "First thing.")
        await settle { await clock.waiting == 1 }
        // 12 of 25 code points: 1.92 s in.
        #expect(await clock.requested == [.milliseconds(1920)])
        await clock.releaseOne()
        await settle { hud.caption == "Second thing." }
        #expect(hud.caption == "Second thing.")
        hud.speechEnded()
        #expect(hud.state == .idle && hud.caption == nil)
    }

    @Test func speechEndingWithNoSpeechChangesNothing() {
        let hud = HUDModel(sleep: { _ in })
        hud.turnBegan("Hello")
        hud.speechEnded()
        #expect(hud.state == .thinking && hud.caption == "Hello")
    }

    @Test func speechThatNeverStartsStillSettles() {
        let hud = HUDModel(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        hud.turnBegan("Hello")
        hud.turnEnded(speechFollows: true)
        hud.speechEnded()   // the voice gave up without audio
        #expect(hud.state == .idle && hud.caption == nil)
    }

    @Test func speechEndingDuringANewTurnGoesBackToThinking() {
        let hud = HUDModel(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        hud.turnBegan("First")
        hud.turnEnded(speechFollows: true)
        hud.speechStarted(CaptionTimeline(text: "A reply.", duration: 2))
        hud.turnBegan("Second")
        hud.speechEnded()
        #expect(hud.state == .thinking && hud.caption == "Second")
    }

    @Test func showHUDOffKeepsItHidden() {
        let hud = HUDModel(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        hud.turnBegan("Hello")
        #expect(hud.shown)
        hud.enabled = false
        #expect(!hud.shown)
        hud.turnBegan("Again")
        #expect(!hud.shown && hud.state == .thinking)
        hud.enabled = true
        hud.state(.speaking)
        #expect(hud.shown)
    }

    @Test func listeningIsTheMicrophonesHook() {
        let hud = HUDModel(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        hud.listening()
        #expect(hud.state == .listening && hud.status == "Listening" && hud.level == 0.6 && hud.caption == nil)
    }

    @Test func levelIsClamped() {
        let hud = HUDModel(sleep: { _ in })
        hud.level(1.7)
        #expect(hud.level == 1)
        hud.level(-2)
        #expect(hud.level == 0)
    }

    @Test func showHUDIsOnByDefaultAndKept() throws {
        let suite = "ui1-showhud-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ShowHUDSetting(defaults: defaults).isOn)
        ShowHUDSetting(defaults: defaults).isOn = false
        #expect(!ShowHUDSetting(defaults: defaults).isOn)
        #expect(defaults.object(forKey: ShowHUDSetting.defaultsKey) as? Bool == false)
    }

    /// The chat tells the HUD when its turn begins and ends, and ends it after the reply has
    /// gone to the speak policy, so a spoken reply is already queued.
    @Test func chatTurnHooksBracketTheReply() async {
        let order = Order()
        let coordinator = FakeCoordinator { _, sink in
            await sink.delta("Done, sir.")
            return .reply("Done, sir.")
        }
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.onTurnBegan = { order.add("began \($0)") }
        model.onReplyFinished = { _, _ in order.add("reply finished") }
        model.onTurnEnded = { order.add("ended") }
        model.draft.text = "Do it"
        await model.send()?.value
        #expect(order.events == ["began Do it", "reply finished", "ended"])
    }

    @Test func aRefusedTurnNeitherBeginsNorEnds() async {
        let order = Order()
        let model = ChatViewModel(submitter: FakeCoordinator(answering: .busy), minimumGap: .zero)
        model.onTurnBegan = { order.add("began \($0)") }
        model.onTurnEnded = { order.add("ended") }
        model.draft.text = "Do it"
        await model.send()?.value
        #expect(order.events.isEmpty)
    }
}

/// Events in the order they happened, on the main actor.
@MainActor
final class Order {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}
