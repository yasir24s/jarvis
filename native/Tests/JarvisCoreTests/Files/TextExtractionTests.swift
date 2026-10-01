import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// D-51 P3, piece 2: plain text, markdown and CSV read in JarvisCore, the 200,000-character cap
// and what it cut, and the hand-off of the other kinds to an extractor supplied from above.

private struct FakeDocumentExtractor: TextExtracting {
    let text: String
    var kinds: Set<DocumentKind> { [.pdf, .docx, .rtf, .rtfd] }
    func extract(_ url: URL, kind: DocumentKind, limit: Int) -> ExtractedText? {
        ExtractedText(capping: "\(kind.rawValue): \(text)", limit: limit)
    }
}

private func candidate(_ url: URL, _ kind: DocumentKind) -> FileCandidate {
    FileCandidate(url: url, kind: kind, size: 0, modified: 0)
}

@Suite("Text extraction and its cap (D-51 P3)")
struct TextExtractionTests {
    @Test func plainTextMarkdownAndCSVAreReadInCore() throws {
        let home = try TempHome()
        defer { home.remove() }
        let extractors = TextExtractors([PlainTextExtractor()])
        let txt = try home.write("a.txt", "The user grows tomatoes.\n")
        let md = try home.write("b.md", "# Garden\n\n- tomatoes\n")
        let csv = try home.write("c.csv", "plant,bed\ntomato,3\n")
        #expect(extractors.extract(candidate(txt, .plainText)) ==
                ExtractedText(text: "The user grows tomatoes.\n", cutCharacters: 0))
        #expect(extractors.extract(candidate(md, .markdown))?.text == "# Garden\n\n- tomatoes\n")
        #expect(extractors.extract(candidate(csv, .csv))?.text == "plant,bed\ntomato,3\n")
        #expect(extractors.kinds == [.plainText, .markdown, .csv])
        #expect(extractors.extract(candidate(txt, .pdf)) == nil)             // no pdf reader in Core
    }

    @Test func encodingsAreDecodedAndBinaryIsRefused() {
        #expect(PlainTextExtractor.decode(Data("café ☕".utf8)) == "café ☕")
        #expect(PlainTextExtractor.decode(Data([0xEF, 0xBB, 0xBF]) + Data("bom".utf8)) == "bom")
        let utf16 = "naïve".data(using: .utf16)!                             // with a byte-order mark
        #expect(utf16.starts(with: [0xFF, 0xFE]) || utf16.starts(with: [0xFE, 0xFF]))
        #expect(PlainTextExtractor.decode(utf16) == "naïve")
        #expect(PlainTextExtractor.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café")   // Windows-1252
        #expect(PlainTextExtractor.decode(Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01])) == nil)
    }

    @Test func textIsCappedAtTwoHundredThousandCharactersAndTheCutIsReported() throws {
        let home = try TempHome()
        defer { home.remove() }
        #expect(ExtractedText.maxCharacters == 200_000)
        let long = try home.write("long.txt", String(repeating: "é", count: 200_000) + "TAIL-12345")
        let got = try #require(TextExtractors([PlainTextExtractor()]).extract(candidate(long, .plainText)))
        #expect(got.text.count == 200_000)
        #expect(!got.text.contains("TAIL"))
        #expect(got.cutCharacters == 10 && got.wasCut)

        let exact = try home.write("exact.txt", String(repeating: "a", count: 200_000))
        let whole = try #require(TextExtractors([PlainTextExtractor()]).extract(candidate(exact, .plainText)))
        #expect(whole.cutCharacters == 0 && !whole.wasCut && whole.text.count == 200_000)
    }

    @Test func theCapCountsCharactersNotBytes() {
        let capped = ExtractedText(capping: "👨‍👩‍👧 family 👍🏽", limit: 3)
        #expect(capped.text == "👨‍👩‍👧 f")
        #expect(capped.cutCharacters == "amily 👍🏽".count)
        #expect(ExtractedText(capping: "short", limit: 10) == ExtractedText(text: "short", cutCharacters: 0))
        #expect(ExtractedText(capping: "abc", limit: 0) == ExtractedText(text: "", cutCharacters: 3))
    }

    @Test func otherKindsGoToTheExtractorSuppliedFromAbove() throws {
        let home = try TempHome()
        defer { home.remove() }
        let extractors = TextExtractors([PlainTextExtractor(), FakeDocumentExtractor(text: "page")])
        let pdf = try home.write("a.pdf")
        #expect(extractors.extract(candidate(pdf, .pdf))?.text == "pdf: page")
        #expect(extractors.extract(candidate(pdf, .rtfd))?.text == "rtfd: page")
        #expect(extractors.extract(candidate(pdf, .docx), limit: 4) ==
                ExtractedText(text: "docx", cutCharacters: 6))
    }

    @Test func aMissingOrUnreadableFileReadsAsNil() throws {
        let home = try TempHome()
        defer { home.remove() }
        let extractors = TextExtractors([PlainTextExtractor()])
        #expect(extractors.extract(candidate(home.url("gone.txt"), .plainText)) == nil)
        let locked = try home.write("locked.md", "secret plans")
        #expect(chmod(locked.path(percentEncoded: false), 0) == 0)
        #expect(extractors.extract(candidate(locked, .markdown)) == nil)
    }
}
