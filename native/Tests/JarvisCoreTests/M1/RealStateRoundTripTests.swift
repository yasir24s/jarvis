import Foundation
import JarvisCore
import Testing

// M01 §5 A8, §6 T13: load → dump reproduces the REAL state files' bytes. OPT-IN: it runs only
// when JARVIS_ROUNDTRIP_DIR names a directory holding COPIES of the state files (the
// `~/jarvis/*.json` state files, plus research/usage.json). It never opens the live repo and
// only ever reads. The state is private: for each present file it prints exactly
// `identical: <file>` or `differs: <file> at byte N`, and a failure names files only. No
// content is ever printed. (A file PyJSON cannot parse reports `at byte 0 (unparseable)`.)

private let roundTripDir = ProcessInfo.processInfo.environment["JARVIS_ROUNDTRIP_DIR"].flatMap { $0.isEmpty ? nil : $0 }

@Suite("Real state round-trip (read-only copies, JARVIS_ROUNDTRIP_DIR)")
struct RealStateRoundTripTests {
    /// Every state file jarvis.py writes, with the style its writer uses, plus usage.json.
    static let files: [(name: String, indent: Int?)] =
        StateFile.allCases.map { ($0.rawValue, $0.indent) } + [("research/usage.json", 1)]

    @Test(.enabled(if: roundTripDir != nil, "set JARVIS_ROUNDTRIP_DIR to a scratch copy of the state files"))
    func realStateRoundTrips() throws {
        let dir = URL(filePath: try #require(roundTripDir), directoryHint: .isDirectory)
        var present = 0
        var differing: [String] = []
        for (name, indent) in Self.files {
            let url = dir.appending(path: name, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            present += 1
            let bytes = try Data(contentsOf: url)
            guard let value = try? PyJSON.loads(bytes) else {
                print("differs: \(name) at byte 0 (unparseable)")
                differing.append(name)
                continue
            }
            let dumped = Data(PyJSON.dumps(value, indent: indent).utf8)
            if dumped == bytes {
                print("identical: \(name)")
            } else {
                print("differs: \(name) at byte \(Self.firstDifference(dumped, bytes))")
                differing.append(name)
            }
        }
        #expect(present > 0, "no state files found in JARVIS_ROUNDTRIP_DIR")
        #expect(differing.isEmpty, "round-trip differs for: \(differing.joined(separator: ", "))")
    }

    static func firstDifference(_ a: Data, _ b: Data) -> Int {
        let x = [UInt8](a), y = [UInt8](b)
        var i = 0
        while i < min(x.count, y.count) && x[i] == y[i] { i += 1 }
        return i
    }
}
