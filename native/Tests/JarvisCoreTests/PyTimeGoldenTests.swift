import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// pytime.golden.json: time.strftime(fmt, time.localtime(t)), datetime.fromtimestamp(t)
/// .isoformat() and datetime.fromisoformat(s).timestamp(), under the suite's TZ.
@Suite("PyTime golden (Python strftime / isoformat / fromisoformat)")
struct PyTimeGoldenTests {
    @Test(arguments: try Golden.cases("pytime"))
    func matchesPython(_ c: GoldenCase) throws {
        let tzName = try #require(c.clock.string("tz"))
        let tz = try #require(TimeZone(identifier: tzName))
        switch c.input.string("op") {
        case "strftime":
            let epoch = try #require(c.input.double("epoch"))
            let format = try #require(c.input.string("format"))
            var got = PyTime.strftime(format, Date(timeIntervalSince1970: epoch), timeZone: tz)
            switch c.input.string("post") {
            case nil: break
            case "lstrip0": got = String(got.drop(while: { $0 == "0" }))       // str.lstrip('0')
            case "replace_space0": got = got.replacingOccurrences(of: " 0", with: " ")
            case let other: Issue.record("unknown post \(other ?? "")")
            }
            #expect(got.utf8.elementsEqual(try #require(c.expected.string("text")).utf8),
                    "native \(got)")

        case "isoformat":
            let epoch = try #require(c.input.double("epoch"))
            let date = Date(timeIntervalSince1970: epoch)
            #expect(date.timeIntervalSince1970 == epoch)          // Date keeps the exact double
            let iso = PyTime.isoformat(date, timeZone: tz)
            #expect(iso == c.expected.string("iso"))
            let back = try #require(PyTime.fromisoformat(iso, timeZone: tz))
            #expect(back.timeIntervalSince1970 == c.expected.double("roundtrip_epoch"))

        case "fromisoformat":
            let s = try #require(c.input.string("iso"))
            let got = PyTime.fromisoformat(s, timeZone: tz)
            if let native = c.expected.object("native") {
                #expect(native.string("divergence") == "fromisoformat-subset")
                #expect(got == nil, "native returns nil for forms outside its subset")
                withKnownIssue("PyTime.fromisoformat subset: Python 3.14 accepts \(s)") {
                    let d = try #require(got)
                    #expect(d.timeIntervalSince1970 == c.expected.double("epoch"))
                }
            } else if c.expected.has("raises") {
                #expect(got == nil, "Python raised ValueError")
            } else {
                let d = try #require(got, "Python parsed it")
                #expect(d.timeIntervalSince1970 == c.expected.double("epoch"))
                #expect(PyTime.isoformat(d, timeZone: tz) == c.expected.string("epoch_iso"))
            }

        case let other:
            Issue.record("unknown op \(other ?? "nil")")
        }
    }
}
