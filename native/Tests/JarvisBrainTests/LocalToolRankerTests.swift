import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// The per-turn choice of tools (D-7 amended, see DEVIATIONS): when the whole catalog does not
/// fit, the pinned tools, then the tools the previous turn ran, then the rest by how close
/// their name and description are to what was said, as many as fit. The ranking tests use
/// `WordBagEmbedding`, so they are exact on every Mac; the last two run NLEmbedding itself.
@Suite("M3 local model: per-turn tool choice by relevance")
struct LocalToolRankerTests {
    /// SYSTEM_PROMPT with a changelog path as long as the production one, then the line
    /// LocalBrain adds: the instructions a voice turn with no history gives the session.
    static let instructions = SystemPrompt.base(changelogPath: "/private/tmp/jarvis-xy/CHANGELOG.md")
        + LocalBrain.toolHint

    static let pinned = ["get_time", "web_search", "search_memory"]

    static func ranker(_ embedding: any SentenceEmbedding = WordBagEmbedding()) -> LocalToolRanker {
        LocalToolRanker(embedding: embedding)
    }

    static func select(_ text: String, previousText: String? = nil, previousTools: [String] = [],
                       ranker: LocalToolRanker? = LocalToolRankerTests.ranker(),
                       counter: any LocalTokenCounting = EstimatingCounter(),
                       logs: LogRecorder = LogRecorder()) async -> LocalToolSelection {
        let request = LocalToolRequest(text: text, previousText: previousText, previousTools: previousTools)
        return await LocalToolset.select(from: LocalToolsetTests.catalogTools(), instructions: instructions,
                                         counter: counter, request: request, ranker: ranker, log: logs.function)
    }

    @Test("the pinned tools come first, in order, whatever was said")
    func pinnedFirst() async {
        for text in ["what is the weather like in London", "play some music", "zzzz qqqq xxxx"] {
            let s = await Self.select(text)
            #expect(s.tier == .ranked)
            #expect(s.names.prefix(3) == Self.pinned[...])
            #expect(Set(s.names).count == s.names.count)
        }
    }

    @Test("a weather question selects get_weather")
    func weather() async {
        let s = await Self.select("what is the weather like in London")
        #expect(s.tier == .ranked)
        #expect(s.names.contains("get_weather"))
        #expect(s.tools.count < LocalToolset.catalog.count)
    }

    @Test("a music request selects the music tools")
    func music() async {
        let s = await Self.select("play some music")
        #expect(s.tier == .ranked)
        for name in ["music_play", "music_search", "music_control", "music_now_playing"] {
            #expect(s.names.contains(name), "\(name) is missing from \(s.names)")
        }
    }

    @Test("a question about what the user said before keeps search_memory")
    func memoryQuestion() async {
        let s = await Self.select("what did I tell you about my sister's birthday")
        #expect(s.tier == .ranked)
        #expect(s.names.prefix(3) == Self.pinned[...])
        #expect(s.names[2] == "search_memory")
    }

    @Test("a follow-up keeps the tools the previous turn ran, right after the pinned ones, once each")
    func followUp() async {
        // "turn it up more" says nothing about music; the turn before it did.
        let music = await Self.select("turn it up more", previousText: "play some jazz",
                                      previousTools: ["music_play"])
        #expect(music.names[3] == "music_play")
        #expect(music.names.contains("music_control"))
        // A tool the text has nothing to do with is kept all the same. A repeat or a pinned tool
        // in the list takes no second place.
        let kept = await Self.select("what is the weather like in London",
                                     previousTools: ["set_alarm", "set_alarm", "get_time", "not_a_tool"])
        #expect(kept.names[3] == "set_alarm")
        #expect(kept.names.filter { $0 == "set_alarm" }.count == 1)
        #expect(Set(kept.names).count == kept.names.count)
        #expect(kept.names.contains("get_weather"))
    }

    @Test("the budget always holds, and the offer is the longest prefix of the ranking that fits")
    func budgetHolds() async throws {
        let all = LocalToolsetTests.catalogTools()
        let ranker = Self.ranker()
        let counters: [any LocalTokenCounting] = [
            EstimatingCounter(), EstimatingCounter(contextSize: 2048), EstimatingCounter(contextSize: 8192),
            EstimatingCounter(contextSize: 16_384),
            FakeCounter(contextSize: 4096, toolCost: 60, instructions: 900),
            FakeCounter(contextSize: 4096, toolCost: 20, perTool: ["search_memory": 700, "run_command": 500],
                        instructions: 1200),
            FakeCounter(contextSize: 4096, toolCost: 50, instructions: 2400),
        ]
        let requests = [
            LocalToolRequest(text: "what is the weather like in London"),
            LocalToolRequest(text: "play some music", previousText: "set an alarm",
                             previousTools: ["set_alarm", "make_note"]),
            LocalToolRequest(text: "turn it up more", previousText: "play some jazz", previousTools: ["music_play"]),
        ]
        var ranked = 0
        for counter in counters {
            for request in requests {
                let s = await LocalToolset.select(from: all, instructions: Self.instructions, counter: counter,
                                                  request: request, ranker: ranker, log: { _ in })
                #expect(s.tools.isEmpty || Double(s.selectedToolTokens + s.instructionTokens) <= s.limit)
                let recount = s.tools.isEmpty ? 0 : try await counter.tokenCount(tools: s.tools)
                #expect(s.selectedToolTokens == recount)
                guard s.tier == .ranked else { continue }
                ranked += 1
                let ordered = try #require(ranker.order(all, for: request))
                #expect(s.names == ordered.prefix(s.tools.count).map(\.name))
                if s.tools.count < ordered.count {
                    let next = try await counter.tokenCount(tools: Array(ordered.prefix(s.tools.count + 1)))
                    #expect(Double(next + s.instructionTokens) > s.limit)
                }
            }
        }
        // The 16K context fits every tool; the other six counters, with three requests each, rank.
        #expect(ranked == 18)
    }

    @Test("pinned tools drop from the tail only when the instructions leave no room for them")
    func pinnedDrop() async {
        // 50 tokens a tool: 2400 + 50 = 2450 fits 2457.6, a second tool does not.
        let s = await Self.select("play some music",
                                  counter: FakeCounter(contextSize: 4096, toolCost: 50, instructions: 2400))
        #expect(s.tier == .ranked)
        #expect(s.names == ["get_time"])
        #expect(s.dropped == ["web_search", "search_memory"])
        #expect(Double(s.selectedToolTokens + s.instructionTokens) <= s.limit)
        // At a 2,200-token context the estimates fit get_time and web_search, but not
        // search_memory's long description.
        let tight = await Self.select("play some music", counter: EstimatingCounter(contextSize: 2200))
        #expect(tight.names == ["get_time", "web_search"])
        #expect(tight.dropped == ["search_memory"])
    }

    @Test("with no sentence vectors, CORE-21 is offered, and both new tools survive the trim")
    func fallback() async {
        let text = "what is the weather like in London"
        let unavailable = await Self.select(text, ranker: Self.ranker(WordBagEmbedding(available: false)))
        let none = await Self.select(text, ranker: nil)
        // A request with nothing to embed (no word of four letters) has no vector either.
        let blank = await Self.select("ok", ranker: Self.ranker())
        for s in [unavailable, none, blank] {
            #expect(s.tier == .core21Trimmed)
            #expect(s.names == Array(LocalToolset.core21.prefix(s.tools.count)))
            #expect(s.names.prefix(3) == Self.pinned[...])
            #expect(s.tools.count < LocalToolset.core21.count)
            #expect(s.dropped == Array(LocalToolset.core21.suffix(LocalToolset.core21.count - s.tools.count).reversed()))
            #expect(Double(s.selectedToolTokens + s.instructionTokens) <= s.limit)
        }
    }

    @Test("the whole catalog fitting skips the ranking: no vector is computed")
    func everythingFits() async {
        let embedding = WordBagEmbedding()
        let s = await LocalToolset.select(
            from: LocalToolsetTests.catalogTools(), instructions: "unused",
            counter: FakeCounter(contextSize: 100_000, toolCost: 10, instructions: 100),
            request: LocalToolRequest(text: "play some music"), ranker: Self.ranker(embedding), log: { _ in })
        #expect(s.tier == .all)
        #expect(s.tools.count == 47)
        #expect(embedding.calls == 0)
    }

    @Test("each tool's vector is computed once, the request's every turn")
    func vectorsAreCached() async {
        let embedding = WordBagEmbedding()
        let ranker = Self.ranker(embedding)
        _ = await Self.select("what is the weather like in London", ranker: ranker)
        // The request, and the 44 tools that are not pinned.
        #expect(embedding.calls == 1 + (LocalToolset.catalog.count - Self.pinned.count))
        let first = embedding.calls
        _ = await Self.select("play some music", ranker: ranker)
        _ = await Self.select("set an alarm for seven", ranker: ranker)
        #expect(embedding.calls == first + 2)
    }

    @Test("the log line is one line of numbers: not what was said, not which tools it ranked")
    func logLine() async {
        let logs = LogRecorder()
        let s = await Self.select("what is the weather like in London", logs: logs)
        let expected = "Local model: contextSize 4096, limit 2457.6; instructions \(s.instructionTokens) tokens; "
            + "47 tools \(s.allToolTokens) tokens; offering relevance: \(s.tools.count) tools, "
            + "\(s.selectedToolTokens) tokens (estimated: tools chars/2.07, instructions chars/3.5)"
        #expect(logs.lines == [expected])
        for name in LocalToolset.catalog.map(\.name) { #expect(!expected.contains(name)) }
        #expect(!logs.lines.joined().localizedCaseInsensitiveContains("weather"))
        #expect(!logs.lines.joined().localizedCaseInsensitiveContains("london"))
    }

    @Test("what is embedded: the tool's name as words and its description, the last 300 characters of the turn")
    func texts() throws {
        let tool = try #require(LocalToolsetTests.catalogTools().first { $0.name == "get_weather" })
        #expect(LocalToolRanker.text(for: tool).hasPrefix("get weather. "))
        #expect(LocalToolRanker.text(for: tool).hasSuffix(tool.description))
        #expect(LocalToolRanker.text(for: LocalToolRequest(text: "turn it up more", previousText: "play some jazz"))
                == "play some jazz turn it up more")
        #expect(LocalToolRanker.text(for: LocalToolRequest(text: " hello \n")) == "hello")
        let long = LocalToolRanker.text(for: LocalToolRequest(text: String(repeating: "a", count: 5000) + "END",
                                                               previousText: "earlier"))
        #expect(LocalToolRanker.maxTextCharacters == 300)
        #expect(long.count == 300)
        #expect(long.hasSuffix("aaaEND"))
    }

    @Test("the D-7 amendment in tokens, and what is left at SYSTEM_PROMPT length")
    func numbers() {
        let all = LocalToolsetTests.catalogTools()
        func tools(_ names: [String]) -> [DynamicTool] { names.compactMap { n in all.first { $0.name == n } } }
        func kept(_ names: [String], instructions: Int) -> [String] {
            var kept = names
            while !kept.isEmpty,
                  Double(LocalToolset.estimate(tools: tools(kept)) + instructions) > LocalToolset.budgetFraction * 4096 {
                kept.removeLast()
            }
            return kept
        }
        let base = LocalToolset.estimate(
            instructions: SystemPrompt.base(changelogPath: "/private/tmp/jarvis-xy/CHANGELOG.md"))
        let hinted = LocalToolset.estimate(instructions: Self.instructions)
        let old = LocalToolsetTests.measuredCore22
        let oldKept = kept(old, instructions: base)
        let newKept = kept(LocalToolset.core21, instructions: hinted)
        print("NUMBERS estimate: instructions \(base), with the hint \(hinted); "
              + "old CORE-22 \(LocalToolset.estimate(tools: tools(old))) tokens, \(oldKept.count) of 22 kept; "
              + "CORE-21 \(LocalToolset.estimate(tools: tools(LocalToolset.core21))) tokens, "
              + "\(newKept.count) of 21 kept; pinned three \(LocalToolset.estimate(tools: tools(Self.pinned)))")
        #expect(hinted - base <= 30)
        #expect(newKept.prefix(3) == Self.pinned[...])
        // The amendment costs tokens: search_memory's description alone is long.
        #expect(LocalToolset.estimate(tools: tools(LocalToolset.core21))
                > LocalToolset.estimate(tools: tools(old)))
    }

    // MARK: - NLEmbedding

    static let system = SystemSentenceEmbedding()
    static let systemAvailable = system.vector(for: "weather") != nil

    @Test("NLEmbedding: a weather question gets get_weather, a music request music_play, in milliseconds",
          .enabled(if: LocalToolRankerTests.systemAvailable))
    func nlEmbedding() async {
        let ranker = Self.ranker(Self.system)
        let clock = ContinuousClock()
        let texts = ["what's the weather like in London", "play some jazz",
                     "what did I tell you about my sister's birthday", "set an alarm for seven tomorrow"]
        var times: [Duration] = []
        var chosen: [LocalToolSelection] = []
        for text in texts {
            let began = clock.now
            chosen.append(await Self.select(text, ranker: ranker))
            times.append(clock.now - began)
        }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        print("RANKER select ms: first (loads the tools' vectors) \(ms(times[0])), then "
              + times.dropFirst().map { String(format: "%.1f", ms($0)) }.joined(separator: ", ")
              + "; tools offered \(chosen.map(\.tools.count))")
        for (text, s) in zip(texts, chosen) { print("RANKER \(text): \(s.names.joined(separator: " "))") }
        #expect(chosen.allSatisfy { $0.tier == .ranked })
        #expect(chosen[0].names.contains("get_weather"))
        #expect(chosen[1].names.contains("music_play"))
        #expect(chosen[2].names.prefix(3) == Self.pinned[...])
        #expect(times.dropFirst().allSatisfy { $0 < .milliseconds(500) })
    }
}
