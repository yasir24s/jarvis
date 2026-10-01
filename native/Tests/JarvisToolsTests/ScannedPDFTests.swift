import CoreGraphics
import CoreText
import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// P4: read_file reads a scanned PDF by OCR. The PDFs are rendered here into a temporary
/// folder from the G17 fixture image (m5_ocr/plain.png) or from CoreText, never the user's
/// files; the first test runs the real Vision recogniser, the rest a fake.
@Suite("P4 read_file OCR for scanned PDFs", .timeLimit(.minutes(1)))
struct ScannedPDFTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "jarvis-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `pages` pages, each only `image` (no text layer), one point per pixel.
    static func imagePDF(_ image: CGImage, pages: Int, at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// One page with `text` drawn as text (a text layer).
    static func textPDF(_ text: String, at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }

    static func call(_ path: String, recognizer: any TextRecognizing) async throws
        -> (result: ToolCallResult, turn: TurnContext) {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(recognizer: recognizer), sandbox: sandbox)
        let turn = TurnContext(channel: .text)
        let result = await gateway.call("read_file", JSONObject([.init(key: "path", value: .string(path))]),
                                        turn: turn, origin: .model(.claude))
        return (result, turn)
    }

    /// The real recogniser on the fixture image, rendered as an image-only PDF.
    @Test func aScannedPDFIsReadByOCR() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "scan.pdf")
        try Self.imagePDF(try FixtureScreen.decode("m5_ocr/plain.png"), pages: 1, at: url)
        let (result, turn) = try await Self.call(url.path(percentEncoded: false), recognizer: VisionTextRecognizer())
        print("OCR reply: \(result.text.debugDescription)")
        #expect(result.text.hasPrefix("(OCR of a scanned PDF: read 1 of its 1 page)\n"))
        #expect(result.text.contains("The quick brown fox jumps over the lazy dog."))
        #expect(result.text.contains("Meeting moved to Thursday at 3:30 PM in room 204."))
        #expect(result.record.outcome == .ran)
        #expect(await turn.tainted)                              // still untrusted content
    }

    @Test func aPDFWithATextLayerIsReadAsPythonReadsIt() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "typed.pdf")
        try Self.textPDF("A typed synthetic letter.", at: url)
        let fake = FakeRecognizer("never used")
        let (result, _) = try await Self.call(url.path(percentEncoded: false), recognizer: fake)
        #expect(result.text == ReadFile.contents(of: url.path(percentEncoded: false)))
        #expect(result.text.hasPrefix("%PDF-"))
        #expect(fake.calls == 0)
    }

    @Test func atMostFivePagesAreRead() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "long scan.PDF")
        try Self.imagePDF(try FixtureScreen.decode("m5_ocr/blank.png"), pages: 7, at: url)
        let fake = FakeRecognizer("Synthetic page text.")
        let (result, _) = try await Self.call(url.path(percentEncoded: false), recognizer: fake)
        #expect(result.text == "(OCR of a scanned PDF: read 5 of its 7 pages)\n"
                + Array(repeating: "Synthetic page text.", count: 5).joined(separator: "\n\n"))
        #expect(fake.calls == 5)
    }

    /// read_file's 4000 code points hold for OCR text too.
    @Test func theReplyKeepsReadFilesLimit() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "scan")                     // no extension: found by "%PDF-"
        try Self.imagePDF(try FixtureScreen.decode("m5_ocr/blank.png"), pages: 2, at: url)
        let (result, _) = try await Self.call(url.path(percentEncoded: false),
                                              recognizer: FakeRecognizer(String(repeating: "é", count: 3000)))
        #expect(Py.len(result.text) == ReadFile.limit)
        #expect(result.text.hasPrefix("(OCR of a scanned PDF: read 2 of its 2 pages)\n"))
    }

    @Test func nothingRecognisedSaysSo() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "blank.pdf")
        try Self.imagePDF(try FixtureScreen.decode("m5_ocr/blank.png"), pages: 1, at: url)
        let (result, _) = try await Self.call(url.path(percentEncoded: false), recognizer: FakeRecognizer("  \n"))
        #expect(result.text == "(OCR of a scanned PDF: read 1 of its 1 page) No text was found.")
    }

    /// A file named .pdf that is not one is read as Python reads it.
    @Test func aBrokenPDFIsReadAsText() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "notes.pdf")
        try Data("%PDF-1.7 but nothing else follows".utf8).write(to: url)
        let fake = FakeRecognizer("never used")
        let (result, _) = try await Self.call(url.path(percentEncoded: false), recognizer: fake)
        #expect(result.text == "%PDF-1.7 but nothing else follows")
        #expect(fake.calls == 0)
    }

    /// A recogniser that takes 2 s a page: the reply comes at the limit, marked, with nothing
    /// the slow page would have added.
    @Test func theOCRStopsAtTheTimeLimit() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "slow.pdf")
        try Self.imagePDF(try FixtureScreen.decode("m5_ocr/blank.png"), pages: 2, at: url)
        let clock = SuspendingClock()
        let start = clock.now
        let text = await ScannedPDF.ocr(path: url.path(percentEncoded: false), recognizer: SlowRecognizer(),
                                        timeout: .milliseconds(300))
        let elapsed = start.duration(to: clock.now)
        #expect(text == "(OCR of a scanned PDF: read 0 of its 2 pages, stopped at the time limit) No text was found.")
        #expect(elapsed < .milliseconds(1500))
        #expect(ScannedPDF.timeout == .seconds(30) && ScannedPDF.pageLimit == 5)
    }
}

/// Two seconds a page.
struct SlowRecognizer: TextRecognizing {
    func recognizeText(in image: CGImage) async -> String {
        try? await Task.sleep(for: .seconds(2))
        return "Too late."
    }
}
