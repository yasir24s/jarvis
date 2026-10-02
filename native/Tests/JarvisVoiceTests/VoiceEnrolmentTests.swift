import AVFAudio
import Foundation
import JarvisCore
import JarvisTestSupport
import Testing
@testable import JarvisVoice

extension M10Speaker {
    /// M10 part 4: the setup window's takes through the microphone (a fake input here, never the
    /// real mic), the take check, and enrolment from recorded takes against Python's own
    /// (m10_enrol_record: the real Recognizer.record(source, duration=4), then enroll_voice).
    @Suite("M10 enrolment takes (TakeRecorder)")
    struct VoiceEnrolmentTests {
        static let int16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

        /// `samples` as 16 kHz mono Int16 tap buffers of `frames` each.
        static func buffers(_ samples: [Int16], frames: Int = 2048) -> [AVAudioPCMBuffer] {
            stride(from: 0, to: samples.count, by: frames).map { start in
                let count = min(frames, samples.count - start)
                let b = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: AVAudioFrameCount(count))!
                b.frameLength = AVAudioFrameCount(count)
                for i in 0 ..< count { b.int16ChannelData![0][i] = samples[start + i] }
                return b
            }
        }

        /// Records one take while `clip` is pushed through `fake`, as the device would deliver it.
        static func take(of clip: [Int16], recorder: TakeRecorder, fake: FakeMicInput) async throws -> [Int16] {
            let take = Task { try await recorder.record(level: { _ in }) }
            for _ in 0 ..< 400 where !fake.running { try await Task.sleep(for: .milliseconds(5)) }
            #expect(fake.running, "the take opened the microphone")
            for b in buffers(clip) { fake.push(b) }
            return try await take.value
        }

        static func ints(_ value: JSONValue?) -> [Int] {
            (value?.arrayValue ?? []).compactMap { v -> Int? in
                if case .int(let i) = v { return Int(i) }
                return nil
            }
        }

        @Test func aTakeKeepsWhatPythonsRecordFourKeeps() throws {
            let c = try #require(try Golden.cases("m10_enrol_record").first)
            #expect(EnrolmentTake.frames == 49)
            #expect(Self.ints(c.expected["kept_samples"]) == Array(repeating: EnrolmentTake.samples, count: 3))
            // Python reads a 50th chunk and drops it; the take keeps 49.
            #expect(Self.ints(c.expected["chunks_read"]) == [50, 50, 50])
        }

        @Test func aTakeIsTheMicrophonesFirstFortyNineFrames() async throws {
            let fake = FakeMicInput(format: Self.int16Format)
            let recorder = TakeRecorder(makeInput: { fake })
            let clip = try SpeakerCorpus.samples("daniel_enrol_1")
            let take = try await Self.take(of: clip, recorder: recorder, fake: fake)
            #expect(take == Array(clip.prefix(EnrolmentTake.samples)))
            #expect(fake.starts == 1 && fake.stops == 1 && !fake.running, "the microphone closed after the take")
        }

        /// The whole path: three takes through the microphone, the check, and enroll(takes:),
        /// against enroll_voice on the takes Python's record(4) made of the same clips.
        @Test func enrolsFromRecordedTakesAsPythonDoes() async throws {
            let c = try #require(try Golden.cases("m10_enrol_record").first)
            let want = try NPYVector.decode(try #require(Data(base64Encoded: c.expected.string("npy_b64") ?? "")))
            let fake = FakeMicInput(format: Self.int16Format)
            let recorder = TakeRecorder(makeInput: { fake })
            let encoder = try SpeakerCorpus.sharedEncoder()
            var takes: [[Int16]] = []
            for name in ["daniel_enrol_1", "daniel_enrol_2", "daniel_enrol_3"] {
                let take = try await Self.take(of: try SpeakerCorpus.samples(name), recorder: recorder, fake: fake)
                #expect(try await TakeQuality.of(take, encoder: encoder).isGood, "\(name) is a good take")
                takes.append(take)
            }
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "m10-enrol-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            let voiceprint = Voiceprint(url: url, encoder: encoder, research: BumpRecorder(), log: { _ in })
            #expect(try await voiceprint.enroll(takes: takes) == .saved(takes: 3))
            let got = try NPYVector.decode(Data(contentsOf: url))
            let cosine = SpeakerCorpus.cosine(got, want)
            #expect(cosine >= 0.999, "voiceprint cosine \(cosine) against Python's")
        }

        /// Enrolling over a voiceprint keeps the old one as voiceprint.npy.previous.
        @Test func reEnrollingKeepsThePreviousVoiceprint() async throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "m10-prev-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            let old = (0 ..< 256).map { Float($0) / 256 }
            try Voiceprint.save(old, to: url)
            let oldBytes = try Data(contentsOf: url)
            let voiceprint = Voiceprint(url: url, encoder: try SpeakerCorpus.sharedEncoder(), research: BumpRecorder(), log: { _ in })
            let takes = try ["daniel_enrol_1", "daniel_enrol_2", "daniel_enrol_3"].map {
                Array(try SpeakerCorpus.samples($0).prefix(EnrolmentTake.samples))
            }
            #expect(try await voiceprint.enroll(takes: takes) == .saved(takes: 3))
            #expect(try Data(contentsOf: Voiceprint.previousURL(for: url)) == oldBytes)
            #expect(try NPYVector.decode(Data(contentsOf: url)) != old)
            #expect(Voiceprint.previousURL(for: url).lastPathComponent == "voiceprint.npy.previous")
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(left == ["voiceprint.npy", "voiceprint.npy.previous"], "no temporary file is left")
        }

        @Test func silenceIsTooLittleVoiceAndSpeechIsGood() async throws {
            let encoder = try SpeakerCorpus.sharedEncoder()
            let silence = [Int16](repeating: 0, count: EnrolmentTake.samples)
            #expect(try await TakeQuality.of(silence, encoder: encoder) == .tooLittleVoice(voicedSamples: 0))
            let short = Array(try SpeakerCorpus.samples("daniel_short").prefix(EnrolmentTake.samples))
            let quality = try await TakeQuality.of(short, encoder: encoder)
            #expect(quality == .tooLittleVoice(voicedSamples: 7680), "\"Yes.\" is 0.48 s of voice")
        }

        @Test func aMicrophoneThatWillNotOpenFailsTheTake() async {
            let fake = FakeMicInput(format: Self.int16Format, failFormat: true)
            let recorder = TakeRecorder(makeInput: { fake })
            await #expect(throws: TakeError.microphone(.noInputDevice("fake: no channels"))) {
                try await recorder.record(level: { _ in })
            }
        }

        @Test func aDeviceThatSendsNothingEndsTheTake() async throws {
            let fake = FakeMicInput(format: Self.int16Format)
            let recorder = TakeRecorder(makeInput: { fake }, timeout: .milliseconds(300))
            let take = Task { try await recorder.record(level: { _ in }) }
            for _ in 0 ..< 400 where !fake.running { try await Task.sleep(for: .milliseconds(5)) }
            for b in Self.buffers([Int16](repeating: 100, count: 3 * MicFrame.sampleCount)) { fake.push(b) }
            await #expect(throws: TakeError.interrupted(frames: 3)) { try await take.value }
            #expect(!fake.running)
        }

        @Test func cancellingATakeClosesTheMicrophone() async throws {
            let fake = FakeMicInput(format: Self.int16Format)
            let recorder = TakeRecorder(makeInput: { fake })
            let take = Task { try await recorder.record(level: { _ in }) }
            for _ in 0 ..< 400 where !fake.running { try await Task.sleep(for: .milliseconds(5)) }
            take.cancel()
            await #expect(throws: CancellationError.self) { try await take.value }
            #expect(!fake.running && fake.stops == 1)
        }

        @Test func theMeterSeesEveryFrame() async throws {
            let fake = FakeMicInput(format: Self.int16Format)
            let recorder = TakeRecorder(makeInput: { fake })
            let levels = LogRecorder()
            let take = Task { try await recorder.record(level: { levels.sink(String($0)) }) }
            for _ in 0 ..< 400 where !fake.running { try await Task.sleep(for: .milliseconds(5)) }
            for b in Self.buffers(try SpeakerCorpus.samples("daniel_long")) { fake.push(b) }
            _ = try await take.value
            #expect(levels.logged.count == EnrolmentTake.frames)
            #expect(levels.logged.compactMap(Double.init).contains { $0 > 0.5 }, "speech moves the meter")
        }
    }
}
