import CoreGraphics
import Foundation
import Vision

/// Recognises the text in an image. The Vision recogniser is deterministic for a given image
/// and OS, so the golden suite runs it on rendered fixture images; tests that need other text
/// inject a fake.
protocol TextRecognizing: Sendable {
    /// One line per observation, joined with "\n"; "" when nothing is found or Vision fails.
    func recognizeText(in image: CGImage) async -> String
}

/// Which Vision model a request uses.
enum OCRLevel: Sendable { case accurate, fast }

/// The seam under `VisionTextRecognizer`: runs one request at one level and returns the text,
/// or throws. Tests inject a fake to force the accurate level to fail.
typealias OCRPerform = @Sendable (CGImage, OCRLevel) throws -> String

/// Whether the accurate model is known to be broken in this process. On macOS 27.2 beta the
/// accurate request throws an e5rt error after about 50 s; waiting that long on every call is
/// worse than lower quality text, so a failure is remembered and accurate is retried once an
/// hour. The clock is injected so tests need not wait.
final class OCRAccurateHealth: @unchecked Sendable {
    static let shared = OCRAccurateHealth()
    static let retryInterval: TimeInterval = 3600

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var failedAt: Date?

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// True when accurate should be tried: it has not failed, or the last failure is over an hour old.
    var shouldTryAccurate: Bool {
        lock.withLock {
            guard let failedAt else { return true }
            return now().timeIntervalSince(failedAt) >= Self.retryInterval
        }
    }

    var isBroken: Bool { lock.withLock { failedAt != nil } }

    func recordFailure() { lock.withLock { failedAt = now() } }
    func recordSuccess() { lock.withLock { failedAt = nil } }
}

/// `_ocr_image` (jarvis.py 3888-3918): `VNRecognizeTextRequest` at the accurate level with
/// language correction on, the top candidate of each observation in result order, joined with
/// "\n". Any error gives "", as Python's except does. If the accurate request throws, it is
/// retried once at the fast level and the failure is remembered (see `OCRAccurateHealth`); the
/// caller is not told, the text is just lower quality. `perform` blocks, so it runs on a
/// dispatch thread.
struct VisionTextRecognizer: TextRecognizing {
    var health: OCRAccurateHealth = .shared
    var perform: OCRPerform = Self.visionPerform
    var log: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognize(image))
            }
        }
    }

    func recognize(_ image: CGImage) -> String {
        if health.shouldTryAccurate {
            do {
                let text = try perform(image, .accurate)
                health.recordSuccess()
                return text
            } catch {
                health.recordFailure()
                log("OCR: accurate model failed (code \((error as NSError).code)); used fast")
            }
        }
        return (try? perform(image, .fast)) ?? ""
    }

    static func visionPerform(_ image: CGImage, _ level: OCRLevel) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
