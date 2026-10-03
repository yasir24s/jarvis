import Foundation
import Testing
@testable import JarvisVoice

/// F5Engine over a fake helper: the protocol, the PCM files, crashes, timeouts, the rest after
/// two failures in a row, and cancellation.
@Suite("M8 F5Engine (fake helper)")
struct F5EngineTests {
    let folder: TempFolder
    let context = SynthesisContext(turnID: UUID())

    init() throws {
        folder = try TempFolder()
    }

    private func engine(_ launcher: FakeLauncher, timeout: Duration = .seconds(5),
                        clock: ManualClock? = nil) -> F5Engine {
        if let clock {
            return F5Engine(launcher: launcher, timeout: timeout, now: { clock.now })
        }
        return F5Engine(launcher: launcher, timeout: timeout)
    }

    private func samples(_ engine: F5Engine, _ text: String) async throws -> [Float] {
        try await SpeechQueue.collect(engine.synthesize(text, context: context)).samples
    }

    private func reason(_ engine: F5Engine, _ text: String) async -> FallbackReason? {
        do {
            _ = try await samples(engine, text)
            return nil
        } catch let error as SpeechEngineError {
            return error.reason
        } catch {
            return nil
        }
    }

    @Test func speaksReadsAndDeletesTheFile() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.25, -0.5, 1]) }
        let f5 = engine(launcher)
        let got = try await samples(f5, "Good evening, sir.")
        #expect(got == [0.25, -0.5, 1])
        #expect(folder.files.isEmpty, "the PCM file is deleted once read")
        #expect(launcher.launches == 1)
        #expect(f5.lastFootprintMB == 1050)
        let request = try #require(launcher.requests.first)
        #expect(request["text"] == "Good evening, sir.")
        #expect(UUID(uuidString: request["id"] ?? "") != nil)
    }

    @Test func requestLineIsOneJSONObject() throws {
        let line = try F5Engine.requestLine(id: "A", text: "Line one\u{2028}\"quoted\"\nnext")
        #expect(!line.contains("\n"))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
        #expect(object == ["id": "A", "text": "Line one\u{2028}\"quoted\"\nnext"])
    }

    @Test func f5IsGivenDigitsSpelledOut() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.1]) }
        let f5 = engine(launcher)
        _ = try await samples(f5, "It's 3:45 PM.")
        #expect(launcher.requests.first?["text"] == "It's three forty-five PM.")
    }

    @Test func oneHelperServesEveryRequest() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.1, 0.2]) }
        let f5 = engine(launcher)
        for text in ["One.", "Two.", "Three."] {
            #expect(try await samples(f5, text).count == 2)
        }
        #expect(launcher.launches == 1)
        #expect(launcher.requests.map { $0["text"] } == ["One.", "Two.", "Three."])
    }

    @Test func errorReplyThrowsAndKeepsTheHelper() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, text in
            text == "bad" ? .fail("text too long") : .speak([0.5])
        }
        let f5 = engine(launcher)
        #expect(await reason(f5, "bad") == .error)
        #expect(try await samples(f5, "good") == [0.5])
        #expect(launcher.launches == 1)
        #expect(f5.isAvailable, "one failure, then a success, leaves F5 available")
    }

    @Test func crashFailsTheRequestAndTheNextStartsAFreshHelper() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { launch, _, _ in
            launch == 1 ? .crash : .speak([0.5, 0.5])
        }
        let f5 = engine(launcher)
        #expect(await reason(f5, "First.") == .error)
        #expect(try await samples(f5, "Second.").count == 2)
        #expect(launcher.launches == 2, "restarted once after the crash")
        #expect(f5.isAvailable)
    }

    @Test func idleExitIsNotAFailure() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .fail("boom") }
        let f5 = engine(launcher)
        #expect(await reason(f5, "One.") == .error)   // failure 1
        launcher.connections[0].exit()                 // the helper's 5-minute idle exit
        launcher.setScript { _, _, _ in .speak([0.3]) }
        #expect(await eventually { await f5.isConnected == false })
        #expect(try await samples(f5, "Two.") == [0.3])
        #expect(launcher.launches == 2)
        #expect(f5.isAvailable)
    }

    @Test func twoFailuresInARowRestF5ForTenMinutes() async throws {
        defer { folder.remove() }
        let clock = ManualClock()
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .crash }
        let f5 = engine(launcher, clock: clock)
        #expect(await reason(f5, "One.") == .error)
        #expect(f5.isAvailable)
        #expect(await reason(f5, "Two.") == .error)
        #expect(!f5.isAvailable)
        #expect(await reason(f5, "Three.") == .disabled)
        #expect(launcher.launches == 2, "a resting F5 starts no helper")
        clock.advance(by: .seconds(599))
        #expect(!f5.isAvailable)
        launcher.setScript { _, _, _ in .speak([0.7]) }
        clock.advance(by: .seconds(1))
        #expect(f5.isAvailable)
        #expect(try await samples(f5, "Four.") == [0.7])
    }

    @Test func noReplyInTimeIsATimeoutAndKillsTheHelper() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { launch, _, _ in
            launch == 1 ? .silent : .speak([0.4])
        }
        let f5 = engine(launcher, timeout: .milliseconds(100))
        let start = SuspendingClock.now
        #expect(await reason(f5, "Slow.") == .timeout)
        // Load-proof: the timeout is 100 ms, and a timeout that never fired would wait on the silent
        // helper forever, so a 30 s bound keeps the meaning without failing on a busy machine.
        #expect(SuspendingClock.now - start < .seconds(30))
        #expect(launcher.connections[0].terminated)
        #expect(try await samples(f5, "Next.") == [0.4])
        #expect(launcher.launches == 2)
    }

    @Test func notInstalledIsDisabledAndStartsNothing() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.1]) }
        launcher.setInstalled(false)
        let f5 = engine(launcher)
        #expect(!f5.isAvailable)
        #expect(await reason(f5, "Hello.") == .disabled)
        #expect(launcher.launches == 0)
    }

    @Test func launchFailureCountsAsAFailure() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.1]) }
        launcher.setLaunchFails(true)
        let f5 = engine(launcher)
        #expect(await reason(f5, "One.") == .error)
        #expect(await reason(f5, "Two.") == .error)
        #expect(!f5.isAvailable)
    }

    @Test func aFileOutsideTheFolderIsRefusedAndLeftAlone() async throws {
        defer { folder.remove() }
        let elsewhere = try TempFolder()
        defer { elsewhere.remove() }
        let outside = elsewhere.url.appending(path: "keep.f32")
        try Data(count: 4).write(to: outside)
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speakOutside(outside.path(percentEncoded: false)) }
        let f5 = engine(launcher)
        #expect(await reason(f5, "Hello.") == .error)
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    }

    @Test func aSampleCountMismatchIsAnErrorAndTheFileIsStillDeleted() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speakClaiming([0.1, 0.2], claimed: 3) }
        let f5 = engine(launcher)
        #expect(await reason(f5, "Hello.") == .error)
        #expect(folder.files.isEmpty)
    }

    @Test func cancellingDiscardsTheLateReplyAndItsFile() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .silent }
        let f5 = engine(launcher)
        let task = Task { try await samples(f5, "Never mind.") }
        #expect(await eventually { launcher.requests.count == 1 })
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        // The helper finishes the abandoned request later; its audio is deleted, not played.
        let id = try #require(launcher.requests.first?["id"])
        let file = folder.url.appending(path: "\(id).f32")
        try Data(count: 8).write(to: file)
        launcher.connections[0].yieldLine(
            #"{"id":"\#(id)","ok":true,"path":"\#(file.path(percentEncoded: false))","samples":2,"rate":24000}"#)
        #expect(await eventually { folder.files.isEmpty })
        #expect(f5.isAvailable, "a cancellation is not a failure")
    }

    @Test func releaseClosesTheHelperGracefully() async throws {
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.1]) }
        let f5 = engine(launcher)
        _ = try await samples(f5, "Hello.")
        await f5.release()
        #expect(launcher.connections[0].closedGracefully)
        #expect(await f5.isConnected == false)
        _ = try await samples(f5, "Again.")
        #expect(launcher.launches == 2)
    }
}
