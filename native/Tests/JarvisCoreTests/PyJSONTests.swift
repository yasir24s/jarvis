import Foundation
import JarvisCore
import Testing

/// Python dict / truthiness semantics of the value model (M01 §3.1). The byte-level
/// loads/dumps behaviour is covered by PyJSONGoldenTests.
@Suite("PyJSON value model")
struct PyJSONTests {
    private func obj(_ pairs: [(String, JSONValue)]) -> JSONObject {
        JSONObject(pairs.map { JSONObject.Member(key: $0.0, value: $0.1) })
    }

    @Test func assignmentReplacesInPlaceAndAppendsNewKeys() {
        var o = obj([("a", .int(1)), ("b", .int(2))])
        o["a"] = .int(3)
        o["c"] = .int(4)
        #expect(o.keys == ["a", "b", "c"])
        #expect(o["a"] == .int(3))
        #expect(PyJSON.dumps(.object(o)) == #"{"a": 3, "b": 2, "c": 4}"#)
    }

    @Test func removedKeyReinsertsAtTheEnd() {
        var o = obj([("a", .int(1)), ("b", .int(2))])
        #expect(o.removeValue(forKey: "a") == .int(1))
        #expect(o.removeValue(forKey: "a") == nil)
        o["a"] = .int(5)
        #expect(o.keys == ["b", "a"])
        o["b"] = nil                                               // del d["b"]
        #expect(o.keys == ["a"])
        #expect(o.count == 1)
    }

    @Test func setDefaultKeepsExistingAndAppendsMissing() {
        var o = obj([("core", .array([.string("x")]))])
        #expect(o.setDefault("core", .array([])) == .array([.string("x")]))
        #expect(o.setDefault("learned", .array([])) == .array([]))
        #expect(o.keys == ["core", "learned"])
    }

    @Test func initFromPairsHasDictSemantics() {
        let o = obj([("a", .int(1)), ("b", .int(2)), ("a", .int(3))])
        #expect(o.keys == ["a", "b"])
        #expect(o["a"] == .int(3))
    }

    @Test func keysCompareByCodePointNotCanonicalEquivalence() {
        var o = obj([("\u{e9}", .int(1))])
        o["e\u{301}"] = .int(2)                                    // "é" decomposed: a new key
        #expect(o.count == 2)
        #expect(o["\u{e9}"] == .int(1))
        #expect(o["e\u{301}"] == .int(2))
        #expect(JSONValue.string("\u{e9}") != .string("e\u{301}"))
    }

    @Test func pyTruthy() {
        let falsy: [JSONValue] = [.null, .bool(false), .int(0), .double(0), .double(-0.0),
                                  .string(""), .array([]), .object(JSONObject())]
        let truthy: [JSONValue] = [.bool(true), .int(-1), .bigInt("18446744073709551616"),
                                   .double(.nan), .double(0.1), .string("0"), .array([.null]),
                                   .object(obj([("", .null)]))]
        for v in falsy { #expect(!v.pyTruthy, "\(v)") }
        for v in truthy { #expect(v.pyTruthy, "\(v)") }
    }

    @Test func pyFloat() {
        #expect(JSONValue.int(3).pyFloat == 3.0)
        #expect(JSONValue.bool(true).pyFloat == 1.0)
        #expect(JSONValue.double(0.25).pyFloat == 0.25)
        #expect(JSONValue.bigInt("18446744073709551616").pyFloat == 18446744073709551616.0)
        #expect(JSONValue.bigInt("1" + String(repeating: "0", count: 400)).pyFloat == nil)
        #expect(JSONValue.string("1.5").pyFloat == nil)
        #expect(JSONValue.null.pyFloat == nil)
    }

    @Test func accessors() {
        #expect(JSONValue.string("x").stringValue == "x")
        #expect(JSONValue.int(1).stringValue == nil)
        #expect(JSONValue.array([.null]).arrayValue == [.null])
        #expect(JSONValue.object(JSONObject()).objectValue == JSONObject())
        #expect(JSONValue.null.objectValue == nil)
    }

    @Test func loadsKeepsIntFloatAndBigIntApart() throws {
        let v = try PyJSON.loads(Data("[1, 1.0, -0, 9223372036854775808, 1e400]".utf8))
        #expect(v == .array([.int(1), .double(1.0), .int(0), .bigInt("9223372036854775808"),
                             .double(.infinity)]))
    }
}
