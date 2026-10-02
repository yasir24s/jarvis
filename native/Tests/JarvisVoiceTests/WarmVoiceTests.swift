import Foundation
import Testing
@testable import JarvisVoice

/// V1 part 5: typing starts the helper and has it load the model, so the reply waits for neither.
@Suite("V1 warm voice")
struct WarmVoiceTests {
    static func quick(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    @Test func warmingStartsTheHelperAndLoadsTheModelOnce() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.1, 0.2]) }
        let f5 = F5Engine(launcher: launcher, timeout: .seconds(5))
        await f5.warm()
        #expect(launcher.launches == 1)
        #expect(launcher.commands == ["load"])
        #expect(await eventually { f5.lastFootprintMB == 900 }, "the load reply's footprint is kept")
        await f5.warm()
        #expect(launcher.launches == 1 && launcher.commands == ["load"], "a helper already asked is left alone")
        let reply = try await SpeechQueue.collect(f5.synthesize("Good evening, sir.",
                                                                context: SynthesisContext(turnID: UUID())))
        #expect(reply.samples == [0.1, 0.2])
        #expect(launcher.launches == 1, "the reply used the warm helper")
        await f5.release()
        await f5.warm()
        #expect(launcher.launches == 2 && launcher.commands == ["load", "load"], "a released helper is started again")
    }

    @Test func aHelperThatHasRepliedIsNotAskedToLoad() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.3]) }
        let f5 = F5Engine(launcher: launcher, timeout: .seconds(5))
        _ = try await SpeechQueue.collect(f5.synthesize("Hello.", context: SynthesisContext(turnID: UUID())))
        await f5.warm()
        #expect(launcher.launches == 1)
        #expect(launcher.commands.isEmpty)
    }

    /// Not installed, or a helper that cannot start: nothing happens, and nothing counts as a
    /// failure, so F5 stays available for the reply.
    @Test func warmingDoesNothingWhenTheVoiceCannotStart() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.3]) }
        let f5 = F5Engine(launcher: launcher, timeout: .seconds(5))
        launcher.setInstalled(false)
        await f5.warm()
        #expect(launcher.launches == 0)
        launcher.setInstalled(true)
        launcher.setLaunchFails(true)
        await f5.warm()
        await f5.warm()
        #expect(launcher.launches == 0)
        #expect(f5.isAvailable, "two failed warms are not two failures")
        launcher.setLaunchFails(false)
        let reply = try await SpeechQueue.collect(f5.synthesize("Hello.", context: SynthesisContext(turnID: UUID())))
        #expect(reply.samples == [0.3])
    }

    /// The queue warms the voice, except when the speed or reference changed since the last
    /// reply: that reply restarts the voice anyway.
    @Test func theQueueWarmsUnlessASettingChangedSinceTheLastReply() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let speed = LiveVoiceSettingsTests.Setting(1.2)
        let reference = LiveVoiceSettingsTests.Setting("default")
        let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: Self.quick), player: FakePlayer(),
                                 speed: { speed.current }, reference: { reference.current }, log: { _ in })
        await speech.warm()
        #expect(await f5.warms == 1, "before any reply there is nothing to compare")
        await speech.say("Hello.", turn: UUID())
        await speech.idle()
        await speech.warm()
        #expect(await f5.warms == 2)
        speed.set(1.3)
        await speech.warm()
        #expect(await f5.warms == 2)
        await speech.say("Faster.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 1)
        await speech.warm()
        #expect(await f5.warms == 3)
        reference.set("dry")
        await speech.warm()
        #expect(await f5.warms == 3)
    }

    @Test func theHelperExitsAfterTenIdleMinutes() {
        #expect(VoiceHelperSetup.idleExitSeconds == 600)
    }
}
