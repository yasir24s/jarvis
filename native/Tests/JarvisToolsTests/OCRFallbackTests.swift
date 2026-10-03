import CoreGraphics
import Foundation
@testable import JarvisTools
import Testing

/// A clock the tests move by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Records which levels were asked for; accurate throws while `accurateWorks` is false.
final class FakeVision: @unchecked Sendable {
    struct Broken: Error {}
    private let lock = NSLock()
    private var levels: [OCRLevel] = []
    private var works = false
    var accurateWorks: Bool {
        get { lock.withLock { works } }
        set { lock.withLock { works = newValue } }
    }
    var accurateCalls: Int { lock.withLock { levels.filter { $0 == .accurate }.count } }
    var fastCalls: Int { lock.withLock { levels.filter { $0 == .fast }.count } }

    func perform(_ image: CGImage, _ level: OCRLevel) throws -> String {
        lock.withLock { levels.append(level) }
        switch level {
        case .fast: return "fast text"
        case .accurate:
            if accurateWorks { return "accurate text" }
            throw Broken()
        }
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func add(_ line: String) { lock.withLock { stored.append(line) } }
}

/// Detects, once per process, whether the accurate Vision model is broken on this machine, by
/// running the real recogniser on a fixture image and looking at the shared health state.
enum OCRProbe {
    static let accurateBroken: Task<Bool, Never> = Task {
        guard let image = try? FixtureScreen.decode("m5_ocr/plain.png") else { return false }
        _ = await VisionTextRecognizer().recognizeText(in: image)
        return OCRAccurateHealth.shared.isBroken
    }

    static let reason: Comment = "the accurate Vision model throws on this OS (e5rt error); the golden text is accurate-model output"
}

@Suite("OCRFallbackTests")
struct OCRFallbackTests {
    private func make() -> (VisionTextRecognizer, FakeVision, FakeClock, LogLines, OCRAccurateHealth) {
        let vision = FakeVision()
        let clock = FakeClock()
        let logs = LogLines()
        let health = OCRAccurateHealth(now: { clock.now })
        let recognizer = VisionTextRecognizer(health: health, perform: { try vision.perform($0, $1) },
                                              log: { logs.add($0) })
        return (recognizer, vision, clock, logs, health)
    }

    private var image: CGImage {
        get throws { try FixtureScreen.decode("m5_ocr/blank.png") }
    }

    @Test func aThrowingAccurateModelFallsBackToFastAndLogsOneLine() async throws {
        let (recognizer, vision, _, logs, _) = make()
        let text = await recognizer.recognizeText(in: try image)
        #expect(text == "fast text")
        #expect(vision.accurateCalls == 1)
        #expect(vision.fastCalls == 1)
        #expect(logs.lines.count == 1)
        #expect(logs.lines.first?.hasPrefix("OCR: accurate model failed (code ") == true)
        #expect(logs.lines.first?.hasSuffix("); used fast") == true)
        #expect(logs.lines.first?.contains("fast text") == false)
    }

    @Test func aRememberedFailureSkipsAccurateUntilAnHourPasses() async throws {
        let (recognizer, vision, clock, logs, health) = make()
        _ = await recognizer.recognizeText(in: try image)
        #expect(health.isBroken)
        clock.advance(3599)
        _ = await recognizer.recognizeText(in: try image)
        _ = await recognizer.recognizeText(in: try image)
        #expect(vision.accurateCalls == 1)                       // not retried inside the hour
        #expect(vision.fastCalls == 3)
        #expect(logs.lines.count == 1)
        clock.advance(1)                                          // an hour since the failure
        _ = await recognizer.recognizeText(in: try image)
        #expect(vision.accurateCalls == 2)                       // retried, failed again
        #expect(logs.lines.count == 2)
        _ = await recognizer.recognizeText(in: try image)
        #expect(vision.accurateCalls == 2)                       // the new failure is remembered
    }

    @Test func accurateIsUsedAgainOnceItWorks() async throws {
        let (recognizer, vision, clock, logs, health) = make()
        _ = await recognizer.recognizeText(in: try image)
        vision.accurateWorks = true
        clock.advance(3600)
        #expect(await recognizer.recognizeText(in: try image) == "accurate text")
        #expect(!health.isBroken)
        #expect(await recognizer.recognizeText(in: try image) == "accurate text")
        #expect(logs.lines.count == 1)
    }

    @Test func aWorkingAccurateModelNeverTouchesFast() async throws {
        let (recognizer, vision, _, logs, _) = make()
        vision.accurateWorks = true
        #expect(await recognizer.recognizeText(in: try image) == "accurate text")
        #expect(vision.fastCalls == 0)
        #expect(logs.lines.isEmpty)
    }
}
