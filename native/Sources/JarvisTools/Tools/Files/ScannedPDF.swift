import CoreGraphics
import Darwin
import Foundation
import JarvisCore
import Synchronization

/// read_file's OCR for a scanned PDF (P4; native-only, Python reads every file as text). A PDF
/// whose first pages show no text (no text-showing operator in their content streams) has its
/// first `pageLimit` pages rendered with CoreGraphics (CGPDFDocument: PDFKit stays in JarvisApp)
/// and read by the screen tools' Vision recognizer, one page at a time, within `timeout`. The
/// reply says it is OCR and how many pages were read, and stays within read_file's 4000 code
/// points. Anything else (not a PDF, a PDF with text, a locked or unreadable one) is nil, and
/// read_file reads it as Python does.
enum ScannedPDF {
    static let pageLimit = 5
    static let timeout: Duration = .seconds(30)
    /// The longest side of a rendered page, in pixels: about 200 dpi for A4, and a bound on memory.
    static let maxPixels: CGFloat = 2500

    /// The OCR reply for `path`, or nil when read_file should read it as text.
    static func ocr(path: String, recognizer: any TextRecognizing, timeout: Duration = timeout) async -> String? {
        guard !path.unicodeScalars.contains("\0"), looksLikePDF(path),
              let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL),
              !document.isEncrypted || document.isUnlocked || document.unlockWithPassword(""),
              document.numberOfPages > 0 else { return nil }
        let total = document.numberOfPages
        let pages = (1...min(total, pageLimit)).compactMap { document.page(at: $0) }
        guard !pages.isEmpty, !pages.contains(where: hasText) else { return nil }

        let run = Run(), work = Pages(pages: pages)
        // Not a child task: a Vision request cannot be cancelled, so at the time limit this is
        // left to end its current page, and its result is dropped.
        Task.detached(priority: .userInitiated) {
            for page in work.pages {
                guard !run.isDone else { return }
                var text = ""
                if let image = render(page) { text = await recognizer.recognizeText(in: image) }
                run.add(text)
            }
            run.finish()
        }
        let timer = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            run.finish(timedOut: true)
        }
        await run.wait()
        timer.cancel()
        return reply(run.texts, total: total, stopped: run.timedOut)
    }

    /// The pages to read, handed to the reading task. CGPDFDocument and its pages are not
    /// changed after they are opened, and are only read.
    private struct Pages: @unchecked Sendable {
        let pages: [CGPDFPage]
    }

    /// "(OCR of a scanned PDF: read N of its M pages[, stopped at the time limit])", N being
    /// the pages read, then their text, blank-line separated; "No text was found." when there is
    /// none. At most read_file's limit of code points.
    static func reply(_ texts: [String], total: Int, stopped: Bool) -> String {
        let head = "(OCR of a scanned PDF: read \(texts.count) of its \(total) page\(total == 1 ? "" : "s")"
            + (stopped ? ", stopped at the time limit)" : ")")
        let body = texts.map { Py.strip($0) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Py.prefix(body.isEmpty ? head + " No text was found." : head + "\n" + body, ReadFile.limit)
    }

    /// A ".pdf" name, or "%PDF-" as the first bytes.
    static func looksLikePDF(_ path: String) -> Bool {
        if Py.lower((path as NSString).pathExtension) == "pdf" { return true }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var head = [UInt8](repeating: 0, count: 5)
        return Darwin.read(fd, &head, 5) == 5 && head == Array("%PDF-".utf8)
    }

    /// Whether the page's content stream shows any text (Tj, TJ, ' or ").
    static func hasText(_ page: CGPDFPage) -> Bool {
        guard let table = CGPDFOperatorTableCreate() else { return true }
        defer { CGPDFOperatorTableRelease(table) }
        let found: CGPDFOperatorCallback = { _, info in
            info?.assumingMemoryBound(to: Bool.self).pointee = true
        }
        for op in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(table, op, found) }
        var shows = false
        withUnsafeMutablePointer(to: &shows) { flag in
            let stream = CGPDFContentStreamCreateWithPage(page)
            let scanner = CGPDFScannerCreate(stream, table, flag)
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
        }
        return shows
    }

    /// The page's crop box on white, upright, at up to 2x and at most `maxPixels` on its longer
    /// side.
    static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        let width = turned ? box.height : box.width, height = turned ? box.width : box.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(2, maxPixels / max(width, height))
        let pixels = (w: Int((width * scale).rounded()), h: Int((height * scale).rounded()))
        guard pixels.w > 0, pixels.h > 0,
              let context = CGContext(data: nil, width: pixels.w, height: pixels.h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels.w, height: pixels.h))
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// One OCR run: the pages read so far, and a single wake-up when it finishes or times out.
    final class Run: Sendable {
        private struct State {
            var texts: [String] = []
            var done = false
            var timedOut = false
            var waiter: CheckedContinuation<Void, Never>?
        }

        private let state = Mutex(State())

        var texts: [String] { state.withLock { $0.texts } }
        var isDone: Bool { state.withLock { $0.done } }
        var timedOut: Bool { state.withLock { $0.timedOut } }

        /// A page read before the end; one after it is dropped.
        func add(_ text: String) {
            state.withLock { if !$0.done { $0.texts.append(text) } }
        }

        /// The first call ends the run and wakes the waiter; later calls do nothing.
        func finish(timedOut: Bool = false) {
            let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
                guard !s.done else { return nil }
                s.done = true
                s.timedOut = timedOut
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.done { return true }
                    s.waiter = c
                    return false
                }
                if now { c.resume() }
            }
        }
    }
}
