import Foundation
import JarvisCore
import JarvisTestSupport
import Testing
@testable import JarvisVoice

// The M10 speaker goldens (tools/golden_m10_speaker.py: the real webrtcvad, resemblyzer and
// jarvis.py functions on the synthetic `say` corpus). Tolerances are the plan's (§4).

/// Every M10 speaker suite, one test at a time. Their preprocessing, mel and ORT work is
/// CPU-heavy in a debug build; run in parallel it starved the M8 timing tests in this target.
@Suite("M10 speaker verification", .serialized)
struct M10Speaker {}

extension M10Speaker {
    /// m10_vad: webrtcvad.Vad(3).is_speech on each whole 30 ms and 20 ms frame.
    @Suite("M10 VAD golden (webrtcvad.Vad(3))")
    struct VADGoldenTests {
        @Test(arguments: try Golden.cases("m10_vad"))
        func flags(_ c: GoldenCase) throws {
            let library = try Vendor.webrtcvad()
            let pcm = try SpeakerCorpus.input(c.input)
            for ms in [30, 20] {
                let vad = try WebRTCVAD(library: library, mode: 3)       // a fresh Vad per clip, as the suite
                let got = SpeakerCorpus.bits(try vad.flags(pcm, frameMs: ms))
                let want = c.expected.string("vad\(ms)") ?? ""
                let mismatches = zip(got, want).filter { $0 != $1 }.count + abs(got.count - want.count)
                #expect(mismatches == 0, "\(c.name) \(ms) ms: \(mismatches) of \(want.count) frames differ")
            }
        }
    }

    /// m10_rz_preprocess: normalize_volume, trim_long_silences and its masks, preprocess_wav.
    @Suite("M10 resemblyzer preprocess golden")
    struct PreprocessGoldenTests {
        @Test(arguments: try Golden.cases("m10_rz_preprocess"))
        func preprocess(_ c: GoldenCase) throws {
            let library = try Vendor.webrtcvad()
            let e = c.expected
            let wav = try SpeakerCorpus.input(c.input).map { Float($0) / 32768 }
            #expect(Int64(wav.count) == e.int("samples"))

            let normalized = ResemblyzerPreprocess.normalizeVolume(wav, targetDBFS: -30, increaseOnly: true)
            let changed = normalized.map(\.bitPattern) != wav.map(\.bitPattern)
            #expect(JSONValue.bool(changed) == e["normalized_changed"], "\(c.name): gain applied \(changed)")
            let normalizedSample = stride(from: 0, to: normalized.count, by: 97).map { normalized[$0] }
            #expect(SpeakerCorpus.sha256(normalized) == e.string("normalized_sha256"),
                    "\(c.name): normalize not bit-identical, every-97th max |Δ| \(SpeakerCorpus.maxDelta(normalizedSample, SpeakerCorpus.f32(e.string("normalized_every97_f32")) ?? []))")

            let flags = try ResemblyzerPreprocess.voiceFlags(normalized, vad: library)
            #expect(SpeakerCorpus.bits(flags) == e.string("flags"), "\(c.name): VAD flags")
            #expect(SpeakerCorpus.bits(ResemblyzerPreprocess.smoothedWindows(flags)) == e.string("smoothed"), "\(c.name): moving average")
            #expect(SpeakerCorpus.bits(ResemblyzerPreprocess.keptWindows(flags)) == e.string("kept"), "\(c.name): dilation")

            let trimmed = try ResemblyzerPreprocess.trimLongSilences(normalized, vad: library)
            #expect(Int64(trimmed.count) == e.int("length"), "\(c.name): trimmed length")
            let sample = stride(from: 0, to: trimmed.count, by: 97).map { trimmed[$0] }
            let want = SpeakerCorpus.f32(e.string("every97_f32")) ?? []
            #expect(sample.count == want.count)
            #expect(SpeakerCorpus.maxDelta(sample, want) <= 1e-6, "\(c.name): max |Δ| \(SpeakerCorpus.maxDelta(sample, want))")
            #expect(SpeakerCorpus.sha256(trimmed) == e.string("sha256"), "\(c.name): trimmed output not bit-identical")

        }

        /// x.astype(np.int16) on arm64, from the values numpy gave (golden suite notes).
        @Test func int16CastMatchesNumpy() {
            let inputs: [Float] = [40000, -40000, .nan, 1e10, -1e10, 32767.4, 32767.6, -32768.6, 2.5, 3.5, -2.5]
            #expect(inputs.map(ResemblyzerPreprocess.numpyInt16) == [-25536, 25536, 0, -1, 0, 32767, 32767, -32768, 2, 3, -2])
        }
    }

    /// m10_rz_slices: compute_partial_slices(n, 1.3, 0.75) for 531 lengths.
    @Suite("M10 partial slices golden")
    struct PartialSlicesGoldenTests {
        @Test(arguments: try Golden.cases("m10_rz_slices"))
        func slices(_ c: GoldenCase) throws {
            let n = Int(try #require(c.input.int("n")))
            let slices = SpeakerEncoder.partialSlices(samples: n)
            #expect(slices.map { "\($0.lowerBound):\($0.upperBound)" }.joined(separator: ",") == c.expected.string("mel"))
            #expect(slices.map { "\($0.lowerBound * 160):\($0.upperBound * 160)" }.joined(separator: ",") == c.expected.string("wav"))
        }
    }

    /// m10_rz_mel: the Slaney filterbank, wav_to_mel_spectrogram, and the ONNX encoder against
    /// torch on Python's own mels.
    @Suite("M10 mel and encoder golden")
    struct MelGoldenTests {
        @Test func filterbank() throws {
            let c = try #require(try Golden.cases("m10_rz_mel").first { $0.name == "filterbank" })
            let want = try #require(SpeakerCorpus.f32(c.expected.string("f32")))
            let got = ResemblyzerPreprocess.melFilterbank
            #expect(got.count == 40 * 201 && want.count == got.count)
            let delta = SpeakerCorpus.maxDelta(got, want)
            #expect(delta <= 1e-7, "filterbank max |Δ| \(delta)")
        }

        static func clipCases() throws -> [GoldenCase] { try Golden.cases("m10_rz_mel").filter { $0.name != "filterbank" } }

        @Test(arguments: try MelGoldenTests.clipCases())
        func melAndEncoder(_ c: GoldenCase) async throws {
            let e = c.expected
            let encoder = try SpeakerCorpus.sharedEncoder()
            let pre = try await encoder.preprocess(try SpeakerCorpus.input(c.input))
            #expect(Int64(pre.count) == e.int("preprocessed_length"))

            // Swift's mel of the padded wav against librosa's.
            let slices = SpeakerEncoder.partialSlices(samples: pre.count)
            // np.pad only when the last partial reaches past the end; a longer wav stays as it is.
            let padLength = max(slices[slices.count - 1].upperBound * 160, pre.count)
            #expect(Int64(padLength) == e.int("padded_length"))
            let mel = ResemblyzerPreprocess.melSpectrogram(pre + [Float](repeating: 0, count: padLength - pre.count))
            let wantMel = try #require(SpeakerCorpus.f32(e.string("mel_f32")))
            let shape: [Int] = (e.array("mel_shape") ?? []).compactMap { v -> Int? in
                if case .int(let i) = v { return Int(i) }
                return nil
            }
            #expect(shape == [mel.frames, 40])
            let peak = wantMel.max() ?? 1
            let melDelta = SpeakerCorpus.maxDelta(mel.values, wantMel)
            #expect(melDelta <= 1e-4 * peak, "\(c.name): mel max |Δ| \(melDelta), limit \(1e-4 * peak)")

            // ORT on Python's own partial batch, built from its mel, against torch's partials.
            let wantPartials = try #require(SpeakerCorpus.f32(e.string("partials_f32")))
            var batch: [Float] = []
            for s in slices { batch += wantMel[s.lowerBound * 40 ..< s.upperBound * 40] }
            let partials = try await encoder.partialEmbeddings(batch, count: slices.count)
            let partialDelta = SpeakerCorpus.maxDelta(partials, wantPartials)
            #expect(partials.count == wantPartials.count)
            #expect(partialDelta <= 1e-5, "\(c.name): ORT vs torch partials max |Δ| \(partialDelta)")

            // End to end from Swift's own preprocessing and mel.
            let embed = try await encoder.embedUtterance(pre)
            let wantEmbed = try #require(SpeakerCorpus.f32(e.string("embed_f32")))
            let cosine = SpeakerCorpus.cosine(embed, wantEmbed)
            #expect(cosine >= 0.999, "\(c.name): embedding cosine \(cosine)")
        }
    }

    /// m10_rz_embed: jarvis.py's _embed(AudioData) per input, None included.
    @Suite("M10 embedding golden (jarvis._embed)")
    struct EmbedGoldenTests {
        @Test(arguments: try Golden.cases("m10_rz_embed"))
        func embed(_ c: GoldenCase) async throws {
            let encoder = try SpeakerCorpus.sharedEncoder()
            let got = await encoder.embed(try SpeakerCorpus.input(c.input))
            let want = SpeakerCorpus.f32(c.expected.string("embed_f32"))
            #expect((got == nil) == (want == nil), "\(c.name): Swift \(got == nil ? "None" : "an embedding"), Python \(want == nil ? "None" : "an embedding")")
            if let got, let want {
                let cosine = SpeakerCorpus.cosine(got, want)
                #expect(cosine >= 0.999, "\(c.name): cosine \(cosine)")
                #expect(abs(SpeakerCorpus.cosine(got, got) - 1) < 1e-6)
            }
        }
    }

    /// m10_speaker: enroll_voice, np.save's bytes, speaker_ok at both thresholds, barge-in, the
    /// gate off, no voiceprint, forget_voice.
    @Suite("M10 speaker decisions golden (jarvis.speaker_ok)")
    struct SpeakerDecisionGoldenTests {
        static let suite = "m10_speaker"

        static func named(_ name: String) throws -> GoldenCase {
            try #require(try Golden.cases(suite).first { $0.name == name })
        }

        /// Python's synthetic voiceprint: np.save's bytes from enroll_voice on the three Daniel takes.
        static func pythonVoiceprint() throws -> Data {
            try #require(Data(base64Encoded: try named("enroll_three").expected.string("npy_b64") ?? ""))
        }

        static func temp() throws -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "m10-speaker-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        @Test func constants() throws {
            let e = try Self.named("constants").expected
            #expect(e.double("SPEAKER_THRESHOLD") == Voiceprint.threshold)
            #expect(e.double("WAKE_SPK_THRESHOLD") == Voiceprint.wakeThreshold)
            // The expression Voiceprint.cosine ports, read from speaker_ok's AST.
            #expect(e.string("sim_expression") == "float(np.dot(emb, _voiceprint) / (np.linalg.norm(emb) * np.linalg.norm(_voiceprint) + 1e-09))")
        }

        @Test func linesAreEnrollVoicesAndForgetVoices() throws {
            let three = try Self.named("enroll_three").expected
            let silent = try Self.named("enroll_all_silent").expected
            let missing = try Self.named("enroll_backend_missing").expected
            let forget = try Self.named("forget").expected
            let strings = { (o: JSONObject, k: String) in o.array(k)?.compactMap(\.stringValue) ?? [] }
            #expect(strings(three, "spoken") == [Voiceprint.Lines.starting, Voiceprint.Lines.set])
            #expect(strings(silent, "spoken") == [Voiceprint.Lines.starting, Voiceprint.Lines.nothingCaptured])
            #expect(strings(missing, "spoken") == [Voiceprint.Lines.notReady])
            #expect(forget.string("reply") == Voiceprint.Lines.cleared && forget.string("reply_again") == Voiceprint.Lines.cleared)
            #expect(strings(three, "chimes") == ["Tink", "Glass"] && strings(silent, "chimes") == ["Tink"])
        }

        /// np.save's bytes, reproduced from the same float32 values.
        @Test func npySaveBytesAreIdentical() throws {
            let python = try Self.pythonVoiceprint()
            let values = try NPYVector.decode(python)
            #expect(NPYVector.encode(values) == python)
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            try Voiceprint.save(values, to: url)
            #expect(try Data(contentsOf: url) == python)
            try Voiceprint.save(values.map { -$0 }, to: url)             // over an existing file
            #expect(try NPYVector.decode(Data(contentsOf: url)) == values.map { -$0 })
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["voiceprint.npy"])
        }

        static let enrollCases = ["enroll_three", "enroll_one_silent", "enroll_all_silent"]

        @Test(arguments: SpeakerDecisionGoldenTests.enrollCases)
        func enroll(_ name: String) async throws {
            let c = try Self.named(name)
            let takes = try (c.input.array("takes") ?? []).compactMap(\.stringValue).map { take in
                take == "silence" ? [Int16](repeating: 0, count: 64000) : try SpeakerCorpus.samples(take)
            }
            #expect(takes.count == 3)
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let log = LogRecorder()
            let voiceprint = Voiceprint(url: dir.appending(path: "voiceprint.npy"), encoder: try SpeakerCorpus.sharedEncoder(),
                                   research: BumpRecorder(), log: log.sink)
            let outcome = try await voiceprint.enroll(takes: takes)
            if let b64 = c.expected.string("npy_b64"), let want = Data(base64Encoded: b64) {
                #expect(outcome == .saved(takes: Int(try #require(c.expected.int("embedded_takes")))))
                let saved = try Data(contentsOf: dir.appending(path: "voiceprint.npy"))
                #expect(saved.prefix(128) == want.prefix(128), "the NPY header")
                let cosine = SpeakerCorpus.cosine(try NPYVector.decode(saved), try NPYVector.decode(want))
                #expect(cosine >= 0.999, "\(name): voiceprint cosine \(cosine)")
                #expect(await voiceprint.isEnrolled)
                #expect(log.logged.contains("Voiceprint enrolled and saved."))
            } else {
                #expect(outcome == .nothingCaptured)
                #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "voiceprint.npy").path))
                #expect(await !voiceprint.isEnrolled)
            }
        }

        /// enroll_voice without its backend says it is not ready and saves nothing; here, enroll throws.
        @Test func enrollWithoutTheEncoderThrows() async throws {
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let nowhere = dir.appending(path: "missing")
            let encoder = SpeakerEncoder(assets: .checkout(vendor: nowhere, buildProducts: nowhere))
            let voiceprint = Voiceprint(url: dir.appending(path: "voiceprint.npy"), encoder: encoder, research: BumpRecorder(), log: { _ in })
            await #expect(throws: (any Error).self) { try await voiceprint.enroll(takes: [try SpeakerCorpus.samples("daniel_enrol_1")]) }
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "voiceprint.npy").path))
        }

        @Test func loadReadsPythonsFile() async throws {
            let e = try Self.named("load").expected
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            try Self.pythonVoiceprint().write(to: url)
            let log = LogRecorder()
            let voiceprint = Voiceprint(url: url, encoder: try SpeakerCorpus.sharedEncoder(), research: BumpRecorder(), log: log.sink)
            await voiceprint.load()
            let got = try #require(await voiceprint.current)
            #expect(got.map(\.bitPattern) == SpeakerCorpus.f32(e.string("f32"))?.map(\.bitPattern))
            #expect(log.logged == (e.array("logged")?.compactMap(\.stringValue) ?? []))
        }

        static func verifyCases() throws -> [GoldenCase] { try Golden.cases(suite).filter { $0.name.hasPrefix("verify_") } }

        @Test(arguments: try SpeakerDecisionGoldenTests.verifyCases())
        func verify(_ c: GoldenCase) async throws {
            let e = c.expected
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            try Self.pythonVoiceprint().write(to: url)
            let encoder = try SpeakerCorpus.sharedEncoder()
            let clip = try SpeakerCorpus.input(c.input)
            let pySim = e.double("sim")

            // The similarity itself, when Python had an embedding.
            let vector = try NPYVector.decode(Self.pythonVoiceprint())
            let embedding = await encoder.embed(clip)
            #expect((embedding == nil) == (pySim == nil), "\(c.name): embedding presence")
            if let embedding, let pySim {
                let sim = Double(Voiceprint.cosine(embedding, vector))
                #expect(abs(sim - pySim) <= 1e-3, "\(c.name): sim \(sim) vs Python \(pySim)")
            }

            for (label, threshold) in [("default", nil), ("wake", Voiceprint.wakeThreshold)] as [(String, Double?)] {
                let want = try #require(e.object(label))
                let bumps = BumpRecorder(), log = LogRecorder()
                let voiceprint = Voiceprint(url: url, encoder: encoder, research: bumps, log: log.sink)
                await voiceprint.load()
                let ok = await voiceprint.speakerOK(clip, threshold: threshold)
                let thr = threshold ?? Voiceprint.threshold
                if let pySim, abs(pySim - thr) <= 1e-3 { continue }          // too close to call
                #expect(JSONValue.bool(ok) == want["ok"], "\(c.name) \(label): decision")
                #expect(bumps.bumped == (want.array("bumps")?.compactMap(\.stringValue) ?? []), "\(c.name) \(label): counters")
                let pyLines = (want.array("printed")?.compactMap(\.stringValue) ?? []).map { $0.replacingOccurrences(of: "[JARVIS] ", with: "") }
                    + (want.array("logged")?.compactMap(\.stringValue) ?? [])
                let swiftLines = log.logged.filter { $0.hasPrefix("(ignored") || $0.hasPrefix("Speaker match") }
                // f"{sim:.2f}" may round the other way when the sims straddle a boundary.
                let nearRounding = pySim.map { x in abs(x * 100 - (x * 100).rounded(.down) - 0.5) < 0.1 } ?? false
                #expect(swiftLines == pyLines || nearRounding, "\(c.name) \(label): \(swiftLines) vs \(pyLines)")
            }

            let voiceprint = Voiceprint(url: url, encoder: encoder, research: BumpRecorder(), log: { _ in })
            await voiceprint.load()
            let barge = await voiceprint.matchesForBargeIn(clip)
            if let pySim, abs(pySim - Voiceprint.threshold) <= 1e-3 { return }
            #expect(JSONValue.bool(barge) == e["barge_in"], "\(c.name): barge-in")
        }

        @Test func gateOffAcceptsWithoutEmbedding() async throws {
            let e = try Self.named("gate_off").expected
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            try Self.pythonVoiceprint().write(to: url)
            let encoder = try SpeakerCorpus.encoder()
            let bumps = BumpRecorder()
            let voiceprint = Voiceprint(url: url, encoder: encoder, research: bumps, log: { _ in })
            await voiceprint.load()
            await voiceprint.setEnabled(false)
            #expect(JSONValue.bool(await voiceprint.speakerOK(try SpeakerCorpus.samples("samantha_cmd"))) == e["ok"])
            #expect(bumps.bumped.isEmpty && e.int("embedded") == 0)
            #expect(await !encoder.isLoaded, "nothing was embedded")
        }

        @Test func noVoiceprintAcceptsAndBargeInRefuses() async throws {
            let e = try Self.named("no_voiceprint").expected
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let encoder = try SpeakerCorpus.encoder()
            let bumps = BumpRecorder()
            let voiceprint = Voiceprint(url: dir.appending(path: "voiceprint.npy"), encoder: encoder, research: bumps, log: { _ in })
            await voiceprint.load()
            let clip = try SpeakerCorpus.samples("samantha_cmd")
            #expect(JSONValue.bool(await voiceprint.speakerOK(clip)) == e["ok"])
            #expect(JSONValue.bool(await voiceprint.matchesForBargeIn(clip)) == e["barge_in"])
            #expect(bumps.bumped.isEmpty && e.int("embedded") == 0)
            #expect(await !encoder.isLoaded)
        }

        @Test func forgetRemovesTheFile() async throws {
            let e = try Self.named("forget").expected
            let dir = try Self.temp()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            try Self.pythonVoiceprint().write(to: url)
            let voiceprint = Voiceprint(url: url, encoder: try SpeakerCorpus.encoder(), research: BumpRecorder(), log: { _ in })
            await voiceprint.load()
            #expect(await voiceprint.isEnrolled)
            #expect(await voiceprint.forget() == e.string("reply"))
            let enrolled = await voiceprint.isEnrolled
            #expect(JSONValue.bool(!FileManager.default.fileExists(atPath: url.path) && !enrolled) == e["file_removed"])
            #expect(await voiceprint.forget() == e.string("reply_again"))
        }
    }
}
