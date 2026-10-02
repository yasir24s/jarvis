import Foundation
import JarvisCore
import JarvisTestSupport
import Testing
@testable import JarvisVoice

/// M9 part 2: the transcriber's vocabulary against Python's `_whisper_prompt` (golden suite
/// m9_vocabulary, J:915-931). Each case writes the files Python's case wrote, reads the name and
/// the meant words through CoreState as the app does, and compares `Vocabulary.prompt` with
/// Python's string byte for byte. The contextual strings append the same extras.
@Suite("M9 vocabulary golden")
struct VocabularyGoldenTests {
    static let suite = "m9_vocabulary"

    @Test("the default prompt is WHISPER_PROMPT, and its vocabulary is the plan's 14 words")
    func defaultPrompt() throws {
        let c = try #require(try Golden.cases(Self.suite).first { $0.name == "default_prompt" })
        #expect(Array(Vocabulary.defaultPrompt.utf8) == Array((c.expected.string("whisper_prompt") ?? "").utf8))
        let words = Vocabulary.words(in: Vocabulary.defaultPrompt)
        #expect(words == ["Jarvis", "calendar", "reminder", "alarm", "timer", "volume", "brightness",
                          "screenshot", "weather", "news", "Safari", "Chrome", "thank you", "that's all Jarvis"])
        #expect(Vocabulary.basePrompt(environment: [:]) == Vocabulary.defaultPrompt)
        #expect(Vocabulary.basePrompt(environment: ["JARVIS_WHISPER_PROMPT": ""]) == "")
        #expect(Vocabulary.basePrompt(environment: ["JARVIS_WHISPER_PROMPT": "Vocabulary: a"]) == "Vocabulary: a")
    }

    @Test(arguments: try Golden.cases(suite).filter { $0.name != "default_prompt" })
    func prompt(_ c: GoldenCase) async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        if let p = c.input.string("profile") { try sb.write("profile.json", p) }
        if let k = c.input.string("corrections") { try sb.write("corrections.json", k) }
        let root = sb.root.path(percentEncoded: false)
        let clock = JarvisCore.ManualClock(1_790_582_400)
        let core = CoreState(store: try StateStore(root: root, lease: nil, clock: clock), clock: clock,
                             research: NoCounter(), frontApp: NoFrontApp())
        let base = try #require(c.input.string("base"))
        let want = try #require(c.expected.string("prompt"))
        let inputs = await core.whisperVocabularyInputs()
        let got = Vocabulary.prompt(base: base, name: inputs.name, meant: inputs.meant)
        #expect(Array(got.utf8) == Array(want.utf8), "\(c.name): got \(got.debugDescription), want \(want.debugDescription)")
        let strings = Vocabulary.contextualStrings(base: base, name: inputs.name, meant: inputs.meant)
        #expect(strings == Vocabulary.words(in: base) + Vocabulary.extras(name: inputs.name, meant: inputs.meant))
    }

    @Test("the prompt's words: after the last label, split on commas, trimmed of spaces and one full stop")
    func words() {
        #expect(Vocabulary.words(in: "Vocabulary: one, two. Vocabulary: three , four.") == ["three", "four"])
        #expect(Vocabulary.words(in: "Vocabulary:  alpha ,beta.. , ,  gamma .") == ["alpha", "beta.", "gamma"])
        #expect(Vocabulary.words(in: "Just a sentence about JARVIS.") == ["Just a sentence about JARVIS"])
        #expect(Vocabulary.words(in: "") == [])
        #expect(Vocabulary.words(in: "Vocabulary:") == [])
    }

    @Test("extras keep the first of each by code point, so the two spellings of café both stay")
    func extras() {
        #expect(Vocabulary.extras(name: "Ada", meant: ["kettle", "Ada", "kettle"]) == ["Ada", "kettle"])
        #expect(Vocabulary.extras(name: "", meant: ["x"]) == ["x"])
        #expect(Vocabulary.extras(name: nil, meant: []) == [])
        #expect(Vocabulary.extras(name: nil, meant: ["caf\u{e9}", "cafe\u{301}"]).count == 2)
    }
}

private struct NoCounter: ResearchCounting {
    func bump(_ key: String, by n: Int) {}
}

private struct NoFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "" }
}
