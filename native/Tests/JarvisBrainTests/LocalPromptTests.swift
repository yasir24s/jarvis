import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// od/phase2 item 3: the on-device model's short prompt, the keyword-first ranker and the cap.
@Suite("OD2 slimmer on-device prompt and fewer tools")
struct LocalPromptTests {
    static let base = SystemPrompt.base(changelogPath: NSHomeDirectory() + "/state/CHANGELOG.md")

    @Test("SYSTEM_PROMPT ends with the sentence compact() looks for")
    func endMarker() {
        #expect(Self.base.hasSuffix(LocalPrompt.baseEnd))
    }

    @Test("compact swaps SYSTEM_PROMPT for the short one and keeps everything after it")
    func compactKeepsTheRest() {
        let rest = " (Personality: dry.)\n\nABOUT YOU: You were first built in Python. "
            + LocalPrompt.changelogPointer + "Asked about any of this, answer as yourself: dry, brief, 'sir'."
        let local = LocalPrompt.compact(Self.base + rest)
        #expect(local.hasPrefix(LocalPrompt.base))
        #expect(local.hasSuffix("answer as yourself: dry, brief, 'sir'."))
        #expect(local.contains("(Personality: dry.)"))
        #expect(!local.contains("CHANGELOG") && !local.contains("rule 7"))
        // No example reply for the model to open with.
        #expect(!LocalPrompt.base.contains("Done, sir"))
        // A system without SYSTEM_PROMPT is left alone.
        #expect(LocalPrompt.compact("You are a test assistant.") == "You are a test assistant.")
    }

    @Test("the persona survives: JARVIS, 'sir', dry wit, brevity")
    func personaKept() {
        for word in ["JARVIS", "'sir'", "witty", "dry wit", "usually one sentence"] {
            #expect(LocalPrompt.base.contains(word), "\(word)")
        }
        // Under 40% of SYSTEM_PROMPT's length.
        #expect(LocalPrompt.base.unicodeScalars.count * 5 < Self.base.unicodeScalars.count * 2)
    }

    @Test("keywords: words, prefixes, one typo, phrases and paths")
    func keywords() {
        #expect(LocalToolKeywords.hits("get_battery", in: "Is the laptop charging right now?") > 0)
        #expect(LocalToolKeywords.hits("delete_file", in: "Delete ~/Desktop/old-draft.txt") > 0)
        #expect(LocalToolKeywords.hits("set_reminder", in: "Give me a nudge about the parking ticket") > 0)
        #expect(LocalToolKeywords.hits("send_message", in: "msg sam that the meetin moved to 3") > 0)
        #expect(LocalToolKeywords.hits("music_play", in: "plaay sum taylor swift") > 0)
        #expect(LocalToolKeywords.hits("set_alarm", in: "wake me at 7") > 0)
        #expect(LocalToolKeywords.hits("get_battery", in: "tell me a joke") == 0)
        #expect(LocalToolKeywords.hits("personality_note", in: "Stop calling me sir, it's a bit much") > 0)
    }

    @Test("every keyword table entry is a catalog tool")
    func keywordsNameCatalogTools() {
        let names = Set(LocalToolset.catalog.map(\.name))
        #expect(Set(LocalToolKeywords.table.keys).isSubset(of: names))
    }

    @Test("a keyword match puts the tool right after the pinned ones, whatever the vectors say")
    func keywordFirst() throws {
        let tools = LocalToolset.dynamicTools(LocalToolset.catalog, gateway: ToolGateway(log: { _ in }),
                                              turn: TurnContext(channel: .text), budget: LocalCallBudget(),
                                              log: { _ in })
        let ranker = LocalToolRanker(embedding: WordBagEmbedding())
        let order = try #require(ranker.order(tools, for: LocalToolRequest(text: "is the laptop charging")))
        let names = order.map(\.name)
        #expect(Array(names.prefix(3)) == LocalToolset.pinned)
        let battery = try #require(names.firstIndex(of: "get_battery"))
        #expect(battery < LocalToolset.maxRankedTools)
    }
}
