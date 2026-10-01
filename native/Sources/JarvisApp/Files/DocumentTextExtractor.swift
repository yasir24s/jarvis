import AppKit
import Foundation
import JarvisCore
import PDFKit

/// pdf (PDFKit), and docx, rtf and rtfd (AppKit's NSAttributedString document reading): the
/// document kinds JarvisCore cannot read, behind its `TextExtracting` (D-51 P3, D-13).
/// The document type is always named, so nothing is ever sniffed as HTML (which would load
/// WebKit and could fetch remote resources). A locked PDF is passed over, never unlocked.
struct DocumentTextExtractor: TextExtracting {
    var kinds: Set<DocumentKind> { [.pdf, .docx, .rtf, .rtfd] }

    func extract(_ url: URL, kind: DocumentKind, limit: Int) -> ExtractedText? {
        switch kind {
        case .pdf: pdf(url, limit: limit)
        case .docx: attributed(url, type: .officeOpenXML, limit: limit)
        case .rtf: attributed(url, type: .rtf, limit: limit)
        case .rtfd: attributed(url, type: .rtfd, limit: limit)
        case .plainText, .markdown, .csv: nil
        }
    }

    /// Page by page, keeping pages until the cap and only counting the rest.
    private func pdf(_ url: URL, limit: Int) -> ExtractedText? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        var text = ""
        var kept = 0
        var cut = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.string, !page.isEmpty else { continue }
            let piece = text.isEmpty ? page : "\n" + page
            if kept >= limit {
                cut += piece.count
                continue
            }
            let capped = ExtractedText(capping: piece, limit: limit - kept)
            text += capped.text
            kept += capped.text.count
            cut += capped.cutCharacters
        }
        return ExtractedText(text: text, cutCharacters: cut)
    }

    private func attributed(_ url: URL, type: NSAttributedString.DocumentType,
                            limit: Int) -> ExtractedText? {
        guard let string = try? NSAttributedString(url: url, options: [.documentType: type],
                                                   documentAttributes: nil) else { return nil }
        return ExtractedText(capping: string.string, limit: limit)
    }
}
