import Foundation
import JarvisCore
import JarvisTestSupport
import Testing
@testable import JarvisVoice

extension M10Speaker {
    /// m10_thresholds: JARVIS_SPK_THRESH and JARVIS_WAKE_SPK_THRESH read as jarvis.py reads them,
    /// with float(); where Python's float() refuses a value (and Python JARVIS would not start),
    /// the default is used and the reason logged (DEV-M10-03).
    @Suite("M10 speaker thresholds golden (float(os.environ.get(...)))")
    struct SpeakerThresholdsTests {
        @Test func theExpressionsAreJarvisPys() throws {
            let c = try #require(try Golden.cases("m10_thresholds").first { $0.name == "expressions" })
            #expect(c.expected.string("SPEAKER_THRESHOLD") == "float(os.environ.get('JARVIS_SPK_THRESH', '0.60'))")
            #expect(c.expected.string("WAKE_SPK_THRESHOLD") == "float(os.environ.get('JARVIS_WAKE_SPK_THRESH', '0.38'))")
            #expect(SpeakerThresholds.defaults == SpeakerThresholds(speaker: 0.60, wake: 0.38))
        }

        static func cases() throws -> [GoldenCase] { try Golden.cases("m10_thresholds").filter { $0.name != "expressions" } }

        @Test(arguments: try SpeakerThresholdsTests.cases())
        func eachValue(_ c: GoldenCase) throws {
            let raw = c.input.string("value")
            for (name, variable, fallback) in [("SPEAKER_THRESHOLD", SpeakerThresholds.speakerVariable, 0.60),
                                               ("WAKE_SPK_THRESHOLD", SpeakerThresholds.wakeVariable, 0.38)] {
                let want = try #require(c.expected.object(name))
                let log = LogRecorder()
                let env = raw.map { [variable: $0] } ?? [:]
                let got = SpeakerThresholds.from(env, log: log.sink)
                let value = name == "SPEAKER_THRESHOLD" ? got.speaker : got.wake
                if let bits = want.string("bits") {
                    let hex = withUnsafeBytes(of: value.bitPattern.littleEndian) { $0.map { String(format: "%02x", $0) }.joined() }
                    #expect(hex == bits, "\(name) for \(raw.debugDescription): \(value) vs Python \(want.string("repr") ?? "")")
                    #expect(log.logged.isEmpty)
                } else {
                    #expect(want.string("error") == "ValueError")
                    #expect(value == fallback, "\(name) falls back for \(raw.debugDescription)")
                    #expect(log.logged.count == 1, "the refusal is logged once: \(log.logged)")
                    #expect(log.logged.allSatisfy { $0.contains("is not a number Python's float() reads") })
                }
            }
        }

        /// The voiceprint uses them: a stricter bar from the environment refuses a clip the
        /// default accepts.
        @Test func theVoiceprintHonoursThem() async throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "m10-thr-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            let golden = try #require(try Golden.cases("m10_speaker").first { $0.name == "enroll_three" })
            try #require(Data(base64Encoded: golden.expected.string("npy_b64") ?? "")).write(to: url)
            let clip = try SpeakerCorpus.samples("daniel_short")                 // sim 0.74 with Python
            let strict = SpeakerThresholds.from(["JARVIS_SPK_THRESH": "0.9", "JARVIS_WAKE_SPK_THRESH": "0.8"])
            let encoder = try SpeakerCorpus.sharedEncoder()
            for (thresholds, command, wake) in [(SpeakerThresholds.defaults, true, true), (strict, false, false)] {
                let voiceprint = Voiceprint(url: url, encoder: encoder, research: BumpRecorder(), thresholds: thresholds, log: { _ in })
                await voiceprint.load()
                #expect(await voiceprint.speakerOK(clip, for: .command) == command)
                #expect(await voiceprint.speakerOK(clip, for: .wake) == wake)
                #expect(await voiceprint.matchesForBargeIn(clip) == command)
            }
        }
    }
}
