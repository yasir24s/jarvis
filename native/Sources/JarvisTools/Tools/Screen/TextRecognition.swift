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

/// `_ocr_image` (jarvis.py 3888-3918): `VNRecognizeTextRequest` at the accurate level with
/// language correction on, the top candidate of each observation in result order, joined with
/// "\n". Any error gives "", as Python's except does. `perform` blocks, so it runs on a
/// dispatch thread.
struct VisionTextRecognizer: TextRecognizing {
    func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.recognize(image))
            }
        }
    }

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
