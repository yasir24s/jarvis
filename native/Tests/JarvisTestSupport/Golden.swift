import Foundation
import JarvisCore

// Golden-fixture loader (plan: M00 §3.7). Fixtures are written by native/tools/golden.py from
// Python JARVIS and located through #filePath — they are not bundled as resources.
// Envelope: {"schema": 1, "suite", "generator", "generated_from", "clock", "cases": [...]},
// each case {"name", "input", "expected"}. Decoded with PyJSON, so floats are exact.

public struct GoldenCase: Sendable, CustomStringConvertible {
    public let suite: String
    public let name: String
    public let input: JSONObject
    public let expected: JSONObject
    /// The envelope's clock: {"epoch", "tz", "local"} the suite ran under.
    public let clock: JSONObject

    /// What Swift Testing shows for a parameterised case.
    public var description: String { name }
}

public struct GoldenFixture: Sendable {
    public let suite: String
    public let url: URL
    public let envelope: JSONObject
    public let cases: [GoldenCase]
}

public enum GoldenError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    case malformed(URL, String)

    public var description: String {
        switch self {
        case let .unreadable(url, why): "golden fixture \(url.lastPathComponent) unreadable: \(why)"
        case let .malformed(url, why): "golden fixture \(url.lastPathComponent) malformed: \(why)"
        }
    }
}

public enum Golden {
    public static let schema: Int64 = 1

    /// native/Tests/Fixtures/golden, found from this file's own location.
    public static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()                                // JarvisTestSupport/
        .deletingLastPathComponent()                                // Tests/
        .appending(path: "Fixtures/golden", directoryHint: .isDirectory)

    public static func url(_ suite: String) -> URL {
        directory.appending(path: "\(suite).golden.json", directoryHint: .notDirectory)
    }

    public static func fixture(_ suite: String) throws -> GoldenFixture {
        let url = url(suite)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw GoldenError.unreadable(url, "\(error)")
        }
        let root: JSONValue
        do { root = try PyJSON.loads(data) } catch {
            throw GoldenError.unreadable(url, "\(error)")
        }
        guard let env = root.objectValue else { throw GoldenError.malformed(url, "not an object") }
        guard case .int(schema)? = env["schema"] else {
            throw GoldenError.malformed(url, "schema is not \(schema)")
        }
        guard env["suite"]?.stringValue == suite else {
            throw GoldenError.malformed(url, "suite is not \(suite)")
        }
        guard let clock = env["clock"]?.objectValue, let raw = env["cases"]?.arrayValue, !raw.isEmpty else {
            throw GoldenError.malformed(url, "missing clock or cases")
        }
        var cases: [GoldenCase] = []
        for (k, c) in raw.enumerated() {
            guard let o = c.objectValue, let name = o["name"]?.stringValue,
                  let input = o["input"]?.objectValue, let expected = o["expected"]?.objectValue else {
                throw GoldenError.malformed(url, "case \(k) lacks name/input/expected objects")
            }
            cases.append(GoldenCase(suite: suite, name: name, input: input, expected: expected, clock: clock))
        }
        return GoldenFixture(suite: suite, url: url, envelope: env, cases: cases)
    }

    public static func cases(_ suite: String) throws -> [GoldenCase] {
        try fixture(suite).cases
    }

    /// Lowercase or uppercase hex → bytes; nil on odd length or a non-hex character.
    public static func bytes(hex: String) -> Data? {
        let u = Array(hex.utf8)
        guard u.count % 2 == 0 else { return nil }
        var out = Data(capacity: u.count / 2)
        var k = 0
        while k < u.count {
            guard let hi = nibble(u[k]), let lo = nibble(u[k + 1]) else { return nil }
            out.append(hi << 4 | lo)
            k += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// Typed lookups for case fields.
public extension JSONObject {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func object(_ key: String) -> JSONObject? { self[key]?.objectValue }
    func array(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
    func int(_ key: String) -> Int64? { if case .int(let i)? = self[key] { i } else { nil } }
    /// A JSON number as Double (Python writes 1790582400.0 as a float, 3 as an int).
    func double(_ key: String) -> Double? {
        switch self[key] {
        case .double(let d)?: d
        case .int(let i)?: Double(i)
        default: nil
        }
    }
    func has(_ key: String) -> Bool { self[key] != nil }
}
