import Foundation

// D-51 P3, piece 2: a document's text, capped. JarvisCore reads plain text, markdown and CSV
// itself; pdf, docx, rtf and rtfd need PDFKit and AppKit, so JarvisApp reads them behind
// `TextExtracting` (D-13). Extracted text is never logged; callers log the counts.

/// The text of one document, cut at a cap, with how much was cut.
public struct ExtractedText: Sendable, Equatable {
    public static let maxCharacters = 200_000

    public let text: String
    public let cutCharacters: Int     // characters past the cap that were dropped

    public init(text: String, cutCharacters: Int) {
        self.text = text
        self.cutCharacters = cutCharacters
    }

    /// The first `limit` characters of `text`, and the number after them.
    public init(capping text: String, limit: Int = ExtractedText.maxCharacters) {
        guard let end = text.index(text.startIndex, offsetBy: max(0, limit), limitedBy: text.endIndex),
              end != text.endIndex else {
            self.init(text: text, cutCharacters: 0)
            return
        }
        self.init(text: String(text[..<end]), cutCharacters: text[end...].count)
    }

    public var wasCut: Bool { cutCharacters > 0 }
}

/// Reads some kinds of document as text. Synchronous, so the caller can run it inside
/// `NoDownloads.run`; it must never download, prompt, or follow a link out of the file.
public protocol TextExtracting: Sendable {
    var kinds: Set<DocumentKind> { get }
    /// The text of `url`, capped at `limit` characters; nil when it cannot be read.
    func extract(_ url: URL, kind: DocumentKind, limit: Int) -> ExtractedText?
}

/// Plain text, markdown and CSV: UTF-8, UTF-16 with a byte-order mark, else Windows-1252.
/// A file holding NUL bytes outside UTF-16 is binary, not text, and reads as nil.
public struct PlainTextExtractor: TextExtracting {
    public init() {}

    public var kinds: Set<DocumentKind> { [.plainText, .markdown, .csv] }

    public func extract(_ url: URL, kind: DocumentKind, limit: Int) -> ExtractedText? {
        guard kinds.contains(kind),
              let data = try? Data(contentsOf: url, options: [.uncached]),
              let text = Self.decode(data) else { return nil }
        return ExtractedText(capping: text, limit: limit)
    }

    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.contains(0) { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }
}

/// The extractor for each kind, run with dataless materialisation off.
public struct TextExtractors: Sendable {
    private let byKind: [DocumentKind: any TextExtracting]

    /// Later extractors win for a kind both read.
    public init(_ extractors: [any TextExtracting]) {
        var byKind: [DocumentKind: any TextExtracting] = [:]
        for extractor in extractors {
            for kind in extractor.kinds { byKind[kind] = extractor }
        }
        self.byKind = byKind
    }

    public var kinds: Set<DocumentKind> { Set(byKind.keys) }

    /// The candidate's text, or nil when no extractor reads its kind or the read failed.
    public func extract(_ candidate: FileCandidate,
                        limit: Int = ExtractedText.maxCharacters) -> ExtractedText? {
        guard let extractor = byKind[candidate.kind] else { return nil }
        return NoDownloads.run { extractor.extract(candidate.url, kind: candidate.kind, limit: limit) }
    }
}
