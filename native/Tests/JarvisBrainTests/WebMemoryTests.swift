import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// W1 part 3: the web memory in memory/web/index.sqlite. One row per page under its canonical
/// URL, searched by FTS5 (stemmed) and by meaning, summarised on the device (pending until
/// then), shown by search_memory as untrusted, and never a fact about the user. Sandboxed roots
/// and invented pages only.
@Suite("W1 web memory", .timeLimit(.minutes(1)))
struct WebMemoryTests {
    static let epoch: Double = 1_790_582_400
    static let utc = TimeZone(identifier: "UTC")!

    struct Rig {
        let sandbox: Sandbox
        let clock = ManualClock(WebMemoryTests.epoch)
        let memory: MemoryStore
        let database: MemoryDatabase
        let web: WebMemory
        let writes = Counter()

        init(embedding: (any SentenceEmbedding)? = nil, lease: HandLease? = nil) throws {
            sandbox = try Sandbox()
            let store = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: lease, clock: clock)
            memory = MemoryStore(store: store, clock: clock, timeZone: WebMemoryTests.utc)
            database = MemoryDatabase(memory: memory, log: { _ in })
            let writes = writes
            web = WebMemory(database: database, embedding: embedding, clock: clock, timeZone: WebMemoryTests.utc,
                            afterWrite: { writes.add() }, log: { _ in })
        }
    }

    final class Counter: Sendable {
        private let n = Mutex(0)
        func add() { n.withLock { $0 += 1 } }
        var value: Int { n.withLock { $0 } }
    }

    static func page(_ slug: String, title: String, text: String, canonical: String? = nil) -> ReadPage {
        ReadPage(requested: "https://news.invalid/\(slug)?ref=feed", finalURL: "https://news.invalid/\(slug)",
                 canonicalURL: canonical ?? "https://news.invalid/\(slug)", title: title, text: text, truncated: false)
    }

    @Test func storesOneRowPerCanonicalURL() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        let first = try #require(rig.web.store(Self.page("storm", title: "Invented storm", text: "A storm moved over Leeds."),
                                               source: .background))
        #expect(rig.web.count == 1 && rig.writes.value == 1)
        let stored = try #require(rig.web.page("https://news.invalid/storm"))
        #expect(stored.id == first && stored.title == "Invented storm" && stored.readAt == Self.epoch)
        #expect(stored.requested == "https://news.invalid/storm?ref=feed" && stored.source == "background")
        #expect(stored.text == "A storm moved over Leeds." && stored.summary.isEmpty && stored.summarizedBy == nil)
        #expect(rig.web.has("https://news.invalid/storm") && !rig.web.has("https://news.invalid/other"))

        // Read again for a search: the same row, its time, source and query updated.
        rig.clock.advance(60)
        let again = rig.web.store(Self.page("storm", title: "Invented storm, updated", text: "A storm moved on."),
                                  source: .search, query: "storm in Leeds")
        #expect(again == first && rig.web.count == 1)
        let updated = try #require(rig.web.page("https://news.invalid/storm"))
        #expect(updated.title == "Invented storm, updated" && updated.readAt == Self.epoch + 60)
        #expect(updated.source == "search" && updated.query == "storm in Leeds" && updated.text == "A storm moved on.")
        let mode = try FileManager.default.attributesOfItem(atPath: rig.database.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func searchFindsStemsRanksTitlesFirstAndCounts() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.web.store(Self.page("a", title: "Gardening in winter", text: "Plants and soil, and the cold."), source: .background)
        rig.clock.advance(10)
        rig.web.store(Self.page("b", title: "A cold week", text: "Some gardeners moved their plants indoors."),
                      source: .background)
        rig.clock.advance(10)
        rig.web.store(Self.page("c", title: "Football results", text: "Nothing about plants at all, only goals."),
                      source: .search, query: "football")
        rig.clock.advance(10)
        rig.web.store(Self.page("d", title: "Cooking", text: "Pasta and sauce."), source: .background)

        let plants = rig.web.search("plants", limit: 2)
        #expect(plants.total == 3 && plants.best.count == 2)
        let gardening = rig.web.search("gardening", limit: 5)          // porter: gardening, gardeners
        #expect(gardening.best.map(\.url).first == "https://news.invalid/a")
        #expect(Set(gardening.best.map(\.url)).isSuperset(of: ["https://news.invalid/a"]))
        let moving = rig.web.search("moving plants", limit: 5)
        #expect(moving.best.first?.url == "https://news.invalid/b")    // moved ~ moving, and plants
        #expect(rig.web.search("the and with", limit: 5).total == 0)  // function words only
        #expect(rig.web.search("tennis", limit: 5).total == 0)
        let hit = try #require(rig.web.search("football", limit: 1).best.first)
        #expect(hit.date == "2026-09-28" && hit.source == "search" && hit.title == "Football results")
        #expect(hit.summary == "Nothing about plants at all, only goals.")    // no summary yet: the text's start
    }

    /// Summaries are written later, on the device: at most five points, each cut, redacted, and
    /// a failed page stays pending.
    @Test func pendingPagesAreSummarised() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.web.store(Self.page("one", title: "One", text: "The first invented page."), source: .background)
        rig.web.store(Self.page("two", title: "Two", text: "The second invented page, which fails."), source: .background)
        #expect(rig.web.pending(limit: 10).map(\.title) == ["One", "Two"])
        struct Scripted: PageSummarizing {
            func summarize(title: String, text: String) async throws -> PageSummary {
                guard title == "One" else { throw PageSummaryError.empty }
                return PageSummary(summary: "  A short summary; the password: hunter2swordfish.  ",
                                   points: (1...7).map { "Point \($0) " + String(repeating: "x", count: 300) }, by: "local")
            }
        }
        #expect(await rig.web.summarizePending(limit: 10, with: Scripted()) == 1)
        let one = try #require(rig.web.page("https://news.invalid/one"))
        #expect(one.summary == "A short summary; the password: " + Redactor.mask && one.summarizedBy == "local")
        #expect(one.points.count == 5 && one.points.allSatisfy { Py.len($0) == WebMemory.pointLength })
        #expect(rig.web.pending(limit: 10).map(\.title) == ["Two"])
        let hit = try #require(rig.web.search("summary", limit: 1).best.first)     // the summary is indexed
        #expect(hit.url == "https://news.invalid/one" && hit.points.count == 5)
    }

    /// With sentence vectors, a page close in meaning is found with no word in common.
    @Test func meaningFindsAPageWithNoSharedWord() async throws {
        let embedding = TableEmbedding([
            "Invented harbour. Boats were moored overnight.": [1, 0, 0],
            "Ships": [0.9, 0.1, 0],
            "Pasta. Cooking for one.": [0, 1, 0],
        ])
        let rig = try Rig(embedding: embedding)
        defer { rig.sandbox.remove() }
        rig.web.store(Self.page("harbour", title: "Invented harbour", text: "Moorings."), source: .background)
        rig.web.store(Self.page("pasta", title: "Pasta", text: "Kitchen."), source: .background)
        struct Fixed: PageSummarizing {
            func summarize(title: String, text: String) async throws -> PageSummary {
                PageSummary(summary: title == "Pasta" ? "Cooking for one." : "Boats were moored overnight.", points: [],
                            by: "local")
            }
        }
        #expect(await rig.web.summarizePending(limit: 5, with: Fixed()) == 2)
        #expect(rig.web.search("Ships", limit: 5).best.map(\.url) == ["https://news.invalid/harbour"])
    }

    struct TableEmbedding: SentenceEmbedding {
        let table: [String: [Double]]
        init(_ table: [String: [Double]]) { self.table = table }
        func vector(for sentence: String) -> [Double]? { table[sentence] }
    }

    /// What JARVIS reads is never a fact about the user: storing and summarising pages writes
    /// neither facts.json nor the archive.
    @Test func nothingFromTheWebBecomesAFact() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        #expect(rig.memory.updateFacts { $0.facts = []; return true })
        let facts = FileManager.default.contents(atPath: rig.memory.path(.facts))
        rig.web.store(Self.page("me", title: "About you", text: "The user lives in Leeds and keeps bees."), source: .background)
        _ = await rig.web.summarizePending(limit: 5, with: LeadSummarizer())
        #expect(FileManager.default.contents(atPath: rig.memory.path(.facts)) == facts)
        #expect(!FileManager.default.fileExists(atPath: rig.memory.path(.archive)))
        #expect(rig.memory.loadFacts()?.facts.isEmpty == true)
    }

    @Test func withoutTheLeaseNothingIsStored() throws {
        let lease = HandLease(false)
        let rig = try Rig(lease: lease)
        defer { rig.sandbox.remove() }
        #expect(rig.web.store(Self.page("x", title: "X", text: "Text."), source: .background) == nil)
        #expect(rig.web.count == 0 && rig.writes.value == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.database.path))
    }

    /// The assembled brain: search_memory, through the gateway, ends with the pages read.
    @Test func theAssembledSearchMemoryListsThePagesRead() async throws {
        let dir = try ShortTempDir()
        defer { dir.remove() }
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let memory = MemoryStore(store: harness.store, clock: ManualClock(CoreHarness.epoch))
        let assembly = BrainAssembly(
            core: harness.core, research: NullCounter(), config: ClaudeConfig(environment: [:]), environment: [:],
            runDirectory: dir.url.appending(path: "run", directoryHint: .isDirectory),
            claudeWorkingDirectory: dir.url.appending(path: "claude-cwd", directoryHint: .isDirectory),
            claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
            localBrain: { _ in FakeLocalBrain(.reply("Local reply, sir.")) }, personaWriter: ScriptedWriter(),
            memory: memory, factWriter: nil, embedding: MemoryWiringTests.TableEmbedding(table: [:]),
            textAuthenticator: FakeAuthenticator(answer: false), online: { false }, log: { _, _ in })
        try await assembly.start()
        defer { Task { await assembly.stop() } }
        let web = try #require(assembly.webMemory)
        #expect(web.store(Self.page("storm", title: "Invented storm", text: "A storm moved over Leeds."),
                          source: .background) != nil)
        let turn = TurnContext(channel: .text)
        let result = await assembly.gateway.call("search_memory", JSONObject([.init(key: "query", value: .string("storm"))]),
                                                 turn: turn, origin: .model(.claude))
        #expect(result.text.contains("From what I've read: 1 web page matches \"storm\""))
        #expect(result.text.contains("(https://news.invalid/storm): A storm moved over Leeds."))
        #expect(await turn.taintedBy == ["web_memory", "search_memory"])
    }

    // MARK: - Summaries

    @Test func theSummaryReplyIsParsed() {
        let parsed = LocalPageSummarizer.parse("SUMMARY: It rained.\nIt was cold.\nPOINTS:\n- Rain\n• Cold\n3. Wind\n* Fog")
        #expect(parsed.summary == "It rained. It was cold." && parsed.points == ["Rain", "Cold", "Wind", "Fog"])
        let plain = LocalPageSummarizer.parse("Just a sentence.")
        #expect(plain.summary == "Just a sentence." && plain.points.isEmpty)
        let many = "SUMMARY: S.\nPOINTS:\n" + (1...8).map { "- P\($0)" }.joined(separator: "\n")
        #expect(LocalPageSummarizer.parse(many).points == ["P1", "P2", "P3", "P4", "P5"])
    }

    /// The on-device model gets as much of the page as fits P3's budget: here the counter says
    /// 1 token per 10 characters against a 2,000-token context, so 1,200 tokens for both.
    @Test func theOnDeviceSummaryUsesThePageStartThatFits() async throws {
        struct Counter: FileTokenCounting {
            var contextSize: Int { 2_000 }
            func tokenCount(instructions: String) async throws -> Int? { instructions.count / 10 }
            func tokenCount(prompt: String) async throws -> Int? { prompt.count / 10 }
        }
        final class Model: PersonaLLM, @unchecked Sendable {
            var prompt = ""
            func complete(system: String, user: String, timeout: Duration) async throws -> String {
                prompt = user
                return "SUMMARY: It is long.\nPOINTS:\n- One"
            }
        }
        let model = Model()
        let summarizer = LocalPageSummarizer(model: model, budget: LocalFileBudget(counter: Counter()))
        let text = String(repeating: "Invented words for a long page. ", count: 2_000)
        let summary = try await summarizer.summarize(title: "Long", text: text)
        #expect(summary == PageSummary(summary: "It is long.", points: ["One"], by: "local"))
        let used = (LocalPageSummarizer.system.count + model.prompt.count) / 10
        #expect(used <= 1_200 && model.prompt.count > 5_000)
        #expect(text.hasPrefix(String(model.prompt.dropFirst("Title: Long\n\nThe page:\n".count))))
    }

    @Test func withoutTheModelTheLeadSentencesAreTheSummary() async throws {
        struct Off: PageSummarizing {
            func summarize(title: String, text: String) async throws -> PageSummary { throw PageSummaryError.empty }
        }
        let text = "First sentence here. Second one follows. " + String(repeating: "More text goes on. ", count: 50)
        let summary = try await FallbackSummarizer(Off()).summarize(title: "T", text: text)
        #expect(summary.by == "lead" && summary.points.isEmpty)
        #expect(summary.summary.hasPrefix("First sentence here. Second one follows.") && Py.len(summary.summary) <= 400)
    }
}
