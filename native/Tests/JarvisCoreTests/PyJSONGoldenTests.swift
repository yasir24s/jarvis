import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// Every case in pyjson.golden.json: Python's json.load(open(path)) outcome for the input
/// bytes, then json.dumps in four styles. Native must reproduce each byte for byte.
@Suite("PyJSON golden (Python json.loads / json.dumps)")
struct PyJSONGoldenTests {
    /// (expected key, indent, ensureASCII) — the styles golden_m0.py records.
    private static let styles: [(String, Int?, Bool)] = [
        ("dumps", nil, true), ("indent1", 1, true), ("indent0", 0, true), ("noascii", nil, false),
    ]

    @Test(arguments: try Golden.cases("pyjson"))
    func matchesPython(_ c: GoldenCase) throws {
        let data = try Self.inputBytes(c)
        let exp = c.expected

        if let raises = exp.string("raises") {
            #expect(throws: PyJSONError.self, "Python raised \(raises)") { try PyJSON.loads(data) }
            do {
                _ = try PyJSON.loads(data)
            } catch {
                #expect(Self.kind(of: error) == Self.kind(python: raises, message: exp.string("message")),
                        "Python: \(raises) \(exp.string("message") ?? ""); native: \(error)")
            }
            return
        }

        if let native = exp.object("native") {
            switch native.string("divergence") {
            case "depth":
                // M01 §3.1 rule 7: native caps nesting at 512; Python 3.14's limit is its C stack.
                #expect(throws: PyJSONError.depth) { try PyJSON.loads(data) }
                withKnownIssue("M01 §3.1 rule 7: nesting > 512 throws .depth; Python accepts it") {
                    try Self.checkStyles(try PyJSON.loads(data), exp)
                }
            case "R6":
                // M01 §8 R6: a lone surrogate escape becomes U+FFFD in native.
                let v = try PyJSON.loads(data)
                try Self.checkStyles(v, native)
                withKnownIssue("M01 §8 R6: lone surrogate escape → U+FFFD; Python keeps it") {
                    try Self.checkStyles(v, exp)
                }
            case let other:
                Issue.record("unknown divergence \(other ?? "nil")")
            }
            return
        }

        try Self.checkStyles(try PyJSON.loads(data), exp)
    }

    /// Independent oracle for the fixture reader itself: every string PyJSON decoded from the
    /// pyjson fixture must equal, scalar for scalar, what Foundation's JSONSerialization reads.
    @Test func fixtureStringsAgreeWithFoundation() throws {
        let url = Golden.url("pyjson")
        let data = try Data(contentsOf: url)
        let ours = try PyJSON.loads(data)
        let theirs = try JSONSerialization.jsonObject(with: data)
        var compared = 0
        func walk(_ a: JSONValue, _ b: Any, _ path: String) {
            switch a {
            case .string(let s):
                guard let t = b as? String else { Issue.record("\(path): not a string"); return }
                var mine = Array(s.unicodeScalars)
                // Observed 2026-09-28: JSONSerialization drops a LEADING U+FEFF from a string
                // value (case reject_bom_text's json_text "\u{FEFF}{}"); Python keeps it, as
                // PyJSON does. Compare the rest so the check stays meaningful there.
                if mine.first == "\u{FEFF}" && t.unicodeScalars.first != "\u{FEFF}" { mine.removeFirst() }
                #expect(mine == Array(t.unicodeScalars), "\(path)")
                compared += 1
            case .array(let items):
                guard let bs = b as? [Any], bs.count == items.count else { Issue.record("\(path): array"); return }
                for (k, item) in items.enumerated() { walk(item, bs[k], "\(path)[\(k)]") }
            case .object(let o):
                guard let bd = b as? [String: Any], bd.count == o.count else { Issue.record("\(path): object"); return }
                for m in o.members {
                    guard let bv = bd[m.key] else { Issue.record("\(path).\(m.key): missing"); continue }
                    walk(m.value, bv, "\(path).\(m.key)")
                }
            default:
                break
            }
        }
        walk(ours, theirs, "$")
        #expect(compared > 500)
    }

    // MARK: helpers

    static func inputBytes(_ c: GoldenCase) throws -> Data {
        if let text = c.input.string("json_text") { return Data(text.utf8) }
        if let hex = c.input.string("json_hex") { return try #require(Golden.bytes(hex: hex)) }
        let pieces = try #require(c.input.array("json_text_repeat"), "case \(c.name) has no input")
        var text = ""
        for p in pieces {
            let pair = try #require(p.arrayValue)
            guard case .string(let s)? = pair.first, case .int(let n)? = pair.last else {
                throw GoldenError.malformed(Golden.url("pyjson"), "\(c.name): bad json_text_repeat")
            }
            text += String(repeating: s, count: Int(n))
        }
        return Data(text.utf8)
    }

    /// Compares every recorded style; `<style>_codepoints` carries a text that holds a lone
    /// surrogate (unwritable as UTF-8), `omitted` lists styles too large to store.
    static func checkStyles(_ v: JSONValue, _ exp: JSONObject) throws {
        var checked = 0
        for (key, indent, ascii) in styles {
            let got = PyJSON.dumps(v, indent: indent, ensureASCII: ascii)
            if let text = exp.string("\(key)_text") {
                // Bytes, not String ==: Swift's == treats "é" and "e\u{301}" as equal.
                #expect(got.utf8.elementsEqual(text.utf8),
                        "\(key): native \(got.debugDescription.prefix(400)) python \(text.debugDescription.prefix(400))")
                checked += 1
            } else if let points = exp.array("\(key)_codepoints") {
                let want = points.compactMap { v -> UInt32? in
                    if case .int(let i) = v { UInt32(i) } else { nil }
                }
                #expect(got.unicodeScalars.map(\.value) == want, "\(key) code points")
                checked += 1
            } else {
                let omitted = exp.array("omitted")?.compactMap(\.stringValue) ?? []
                #expect(omitted.contains("\(key)_text"), "no expectation recorded for \(key)")
            }
        }
        #expect(checked > 0)
    }

    enum Kind: Equatable { case invalidUTF8, bom, syntax, depth }

    static func kind(of error: any Error) -> Kind? {
        switch error as? PyJSONError {
        case .invalidUTF8?: .invalidUTF8
        case .bom?: .bom
        case .syntax?: .syntax
        case .depth?: .depth
        case nil: nil
        }
    }

    static func kind(python: String, message: String?) -> Kind? {
        switch python {
        case "UnicodeDecodeError": .invalidUTF8
        case "JSONDecodeError": (message ?? "").hasPrefix("Unexpected UTF-8 BOM") ? .bom : .syntax
        case "ValueError": .syntax                               // int literal > 4300 digits
        case "RecursionError": .depth
        default: nil
        }
    }
}
