import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// W1 part 1: the stdlib pieces the web tools lean on, against Python itself
/// (tools/golden_w1_web.py): `urllib.parse.quote`, `quote_plus` and `urlencode`, and
/// `html.unescape` over every HTML5 entity name and the numeric edge cases.
@Suite("W1 Python URL and HTML helpers (golden)")
struct PyWebGoldenTests {
    @Test(arguments: try Golden.cases("w1_pyurl"))
    func urlQuotingMatchesPython(_ c: GoldenCase) throws {
        if let pairs = c.input["pairs"]?.arrayValue {
            let list = try pairs.map { p -> (String, String) in
                let kv = try #require(p.arrayValue)
                return (try #require(kv[0].stringValue), try #require(kv[1].stringValue))
            }
            #expect(PyURL.urlencode(list) == c.expected["urlencode"]?.stringValue)
            return
        }
        let s = try #require(c.input["s"]?.stringValue), safe = try #require(c.input["safe"]?.stringValue)
        #expect(PyURL.quote(s, safe: safe) == c.expected["quote"]?.stringValue)
        #expect(PyURL.quotePlus(s, safe: safe) == c.expected["quote_plus"]?.stringValue)
    }

    @Test func htmlUnescapeMatchesPythonOnEveryCase() throws {
        let cases = try Golden.cases("w1_html")
        #expect(cases.count == 52 + 2231)
        var failures: [String] = []
        for c in cases {
            let s = try #require(c.input["s"]?.stringValue)
            do {
                let text = try PyHTML.unescape(s)
                if let want = c.expected["text"]?.stringValue {
                    if !Py.eq(text, want) { failures.append(c.name) }
                } else {
                    failures.append(c.name + " (Python raised)")
                }
            } catch {
                if c.expected["error"]?.stringValue != String(describing: error) { failures.append(c.name + " (raised)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20))")
    }
}
