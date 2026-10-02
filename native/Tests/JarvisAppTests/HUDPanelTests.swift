import AppKit
import Foundation
@testable import JarvisApp
import JarvisChat
import JarvisVoice
import SwiftUI
import Testing

/// A player that records what it was asked to do, and can fail.
final class RecordingPlayer: SpeechPlayer {
    struct Failure: Error {}
    let fails: Bool
    let log: @Sendable (String) async -> Void

    init(fails: Bool = false, log: @escaping @Sendable (String) async -> Void) {
        self.fails = fails
        self.log = log
    }

    func play(_ chunk: PCMChunk) async throws {
        await log("play \(chunk.samples.count)")
        if fails { throw Failure() }
    }

    func stop() async {
        await log("stop")
    }
}

/// UI1 part 3: the panel is §3.7's, the controller honours JARVIS_NO_HUD, and the voice's player
/// reports each piece of audio around playing it.
@Suite("UI1 HUD panel")
@MainActor
struct HUDPanelTests {
    @Test func panelIsSection37s() {
        let panel = HUDPanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.styleMask.contains(.titled))
        #expect(!panel.isOpaque && panel.backgroundColor == .clear && !panel.hasShadow)
        #expect(panel.level.rawValue == Int(CGWindowLevelForKey(.screenSaverWindow)))
        #expect(panel.ignoresMouseEvents && !panel.hidesOnDeactivate && !panel.canHide)
        #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]))
        #expect(panel.becomesKeyOnlyIfNeeded && !panel.canBecomeKey && !panel.canBecomeMain)
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(HUDPanel.frame(on: screen) == NSRect(x: 28, y: 48, width: 360, height: 430))
        let second = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
        #expect(HUDPanel.frame(on: second) == NSRect(x: -1892, y: 248, width: 360, height: 430))
    }

    @Test func noHUDMeansNoPanel() {
        #expect(HUDController.make(model: HUDModel(), environment: ["JARVIS_NO_HUD": "1"]) == nil)
        #expect(HUDController.make(model: HUDModel(), environment: [:]) != nil)
    }

    @Test func playerReportsAroundEachPiece() async throws {
        let order = Order()
        let events = PlaybackEvents()
        events.started = { order.add("started \($0.samples.count)") }
        events.ended = { order.add("ended") }
        let log: @Sendable (String) async -> Void = { line in await order.add(line) }
        let player = ReportingPlayer(RecordingPlayer(log: log), events: events)
        try await player.play(PCMChunk(samples: [0, 0, 0], sampleRate: 24_000))
        #expect(order.events == ["started 3", "play 3", "ended"])

        let failing = ReportingPlayer(RecordingPlayer(fails: true, log: log), events: events)
        await #expect(throws: RecordingPlayer.Failure.self) {
            try await failing.play(PCMChunk(samples: [0], sampleRate: 24_000))
        }
        #expect(order.events.suffix(3) == ["started 1", "play 1", "ended"])
        await player.stop()
        #expect(order.events.last == "stop")
    }

    /// The captions are of the reply as the queue speaks it: cleaned, and without a short
    /// opening acknowledgement right after one has played.
    @Test func captionsFollowTheTextAsHeard() {
        #expect(AppVoice.heard("Very good, sir. The **report** is ready.", afterAcknowledgement: false)
                == TextClean.clean("Very good, sir. The **report** is ready."))
        #expect(AppVoice.heard("Very good, sir. The report is ready.", afterAcknowledgement: true)
                == Acknowledgement.spokenText(TextClean.clean("Very good, sir. The report is ready.")!))
        #expect(AppVoice.heard("", afterAcknowledgement: false) == nil)
    }
}

/// Events in the order they happened, on the main actor.
@MainActor
final class Order {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

/// UI1 part 3: the HUD as it draws, next to hud.html's own (UI1_SNAPSHOT_DIR).
@Suite("UI1 HUD snapshots", .serialized, .enabled(if: UISnapshot.enabled))
@MainActor
struct HUDSnapshotTests {
    @Test func hudInEachState() async throws {
        let backdrop = Color(white: 0.16)
        let sleepLong: HUDModel.Sleep = { _ in try await Task.sleep(for: .seconds(600)) }

        let idle = HUDModel(sleep: sleepLong)
        idle.state(.idle)
        let thinking = HUDModel(sleep: sleepLong)
        thinking.turnBegan("What's on my calendar this afternoon?")
        let speaking = HUDModel(sleep: sleepLong)
        speaking.turnBegan("What's on my calendar this afternoon?")
        speaking.turnEnded(speechFollows: true)
        speaking.speechStarted(CaptionTimeline(text: "You have two things, sir. The review is at two.", duration: 4))

        for (name, model) in [("idle", idle), ("thinking", thinking), ("speaking", speaking)] {
            let view = HUDView(model: model).background(backdrop)
            let url = try await UISnapshot.write(view, size: HUDPanel.size, name: "ui1-part3-hud-\(name)",
                                                 settle: .milliseconds(900))
            print("UI1 snapshot \(url.path)")
        }
    }
}

/// UI1 part 3: what the HUD costs, measured on screen with the real panel (UI1_MEASURE=1). It
/// shows at the bottom left for about half a minute.
@Suite("UI1 HUD CPU", .serialized, .enabled(if: ProcessInfo.processInfo.environment["UI1_MEASURE"] == "1"))
@MainActor
struct HUDCPUTests {
    @Test func hudCPUShownAndHidden() async throws {
        _ = ReactorCPUTests.cpuInAppLoop(over: 0.5)
        let model = HUDModel()
        let controller = try #require(HUDController.make(model: model, environment: [:]))
        model.turnBegan("What's on my calendar this afternoon?")
        _ = ReactorCPUTests.cpuInAppLoop(over: 2)
        let thinking = ReactorCPUTests.cpuInAppLoop(over: 8)
        model.turnEnded(speechFollows: true)
        model.speechStarted(CaptionTimeline(text: "You have two things, sir. The review is at two. The call is at four.",
                                            duration: 8))
        _ = ReactorCPUTests.cpuInAppLoop(over: 1)
        let speaking = ReactorCPUTests.cpuInAppLoop(over: 6)
        model.speechEnded()   // idle: hides 2.6 s later
        // The hide timer is a task on the main actor, which a run loop nested in this test's own
        // main-actor job never gets to; awaiting lets it run.
        try await Task.sleep(for: .seconds(3.5))
        #expect(!controller.panel.isVisible)
        let hidden = ReactorCPUTests.cpuInAppLoop(over: 10)
        let hiddenLater = ReactorCPUTests.cpuInAppLoop(over: 10)
        print(String(format: "UI1 CPU HUD: thinking %.2f%%, speaking %.2f%%, hidden %.2f%% then %.2f%%",
                     thinking, speaking, hidden, hiddenLater))
        #expect(!model.shown)
        #expect(hiddenLater < 0.2)   // the first window still holds the hide's own settling
        withExtendedLifetime(controller) {}
    }
}
