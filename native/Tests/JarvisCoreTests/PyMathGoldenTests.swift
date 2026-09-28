import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// pyround.golden.json: repr(round(x, n)) and repr(round(x)).
@Suite("PyMath golden (Python round)")
struct PyRoundGoldenTests {
    @Test(arguments: try Golden.cases("pyround"))
    func matchesPython(_ c: GoldenCase) throws {
        let xText = try #require(c.input.string("x_text"))
        let x = try #require(Double(xText))
        let want = try #require(c.expected.string("text"))
        #expect(PyFloat.repr(x) == xText, "PyFloat.repr of the input")
        if let n = c.input.int("n") {
            let got = PyFloat.repr(PyMath.round(x, Int(n)))
            #expect(got == want, "round(\(xText), \(n))")
        } else {
            #expect(c.input["n"] == .null)
            #expect(String(PyMath.round(x)) == want, "round(\(xText))")
        }
    }
}
