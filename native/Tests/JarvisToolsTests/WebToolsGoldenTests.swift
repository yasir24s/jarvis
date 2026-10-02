import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// W1 part 1: web_search, get_weather, get_location and get_news against Python's own replies
/// (tools/golden_w1_web.py). Each case serves the same pages by URL that the Python run was
/// served, so the native tool must ask for the same URLs, with the same User-Agent and
/// timeout, to give the same reply; the knowledge base after the call must match too. Nothing
/// here reaches the network: the fetcher is the fake below.
@Suite("W1 web tools (golden)")
struct WebToolsGoldenTests {
    static let epoch: Double = 1_790_582_400

    /// The Python fake's twin: a page by exact URL, every request recorded.
    final class FakeWeb: WebFetching {
        let pages: JSONObject
        private let calls = Mutex<[JSONValue]>([])

        init(pages: JSONObject) { self.pages = pages }

        var requests: [JSONValue] { calls.withLock { $0 } }

        func get(_ url: String, headers: [(String, String)], timeout: Double) async throws -> Data {
            let agent = headers.first { $0.0 == "User-Agent" }?.1
            calls.withLock {
                $0.append(.object(JSONObject([.init(key: "url", value: .string(url)),
                                              .init(key: "user_agent", value: agent.map(JSONValue.string) ?? .null),
                                              .init(key: "timeout", value: .double(timeout))])))
            }
            guard let page = pages[url]?.objectValue else { throw WebFetchError.transport("no route to host") }
            if page["error"] != nil { throw WebFetchError.transport("timed out") }
            if let status = page.int("status") { throw WebFetchError.status(status) }
            if let hex = page.string("hex") { return Self.bytes(hex) }
            return Data((page.string("body") ?? "").utf8)
        }

        static func bytes(_ hex: String) -> Data {
            var data = Data()
            var digits = hex.makeIterator()
            while let a = digits.next(), let b = digits.next() { data.append(UInt8(String([a, b]), radix: 16)!) }
            return data
        }
    }

    func run(_ c: M5Fixture.Case, tool: String) async throws {
        let sandbox = try ToolCoreSandbox(clock: ManualClock(Self.epoch))
        defer { sandbox.remove() }
        let kbPath = sandbox.store.path(.knowledge)
        if let topics = c.input["kb"], topics != .null {
            let kb = JSONValue.object(JSONObject([.init(key: "topics", value: topics), .init(key: "queue", value: .array([]))]))
            try Data(PyJSON.dumps(kb, indent: 1).utf8).write(to: URL(fileURLWithPath: kbPath))
        }
        let web = FakeWeb(pages: c.input.object("pages") ?? JSONObject())
        var platform = ToolPlatform.fake()
        let online: Bool = if case .bool(let b)? = c.input["online"] { b } else { true }
        platform.web = web
        platform.online = { online }
        if tool == "get_news", c.name == "from the environment" {
            platform.newsFeed = GetNews.feed(["JARVIS_NEWS_FEED": "https://news.invalid/feed?x=1"])
        }
        let gateway = await M5Fixture.gateway(platform, clock: ManualClock(Self.epoch), sandbox: sandbox)
        let result = await gateway.call(tool, c.input.object("args") ?? JSONObject(), turn: TurnContext(channel: .text),
                                        origin: .model(.claude))
        #expect(result.text == c.expected.string("reply"), "\(c.name)")

        let expectedRequests = c.expected["requests"]?.arrayValue ?? []
        #expect(web.requests.count == expectedRequests.count, "\(c.name): requests")
        for (got, want) in zip(web.requests, expectedRequests) {
            let g = try #require(got.objectValue), w = try #require(want.objectValue)
            #expect(g.string("url") == w.string("url"), "\(c.name): url")
            #expect(g.string("user_agent") == w.string("user_agent"), "\(c.name): user agent")
            #expect(g.double("timeout") == w.double("timeout"), "\(c.name): timeout")
        }

        let after = FileManager.default.contents(atPath: kbPath).flatMap { try? PyJSON.loads($0) }?
            .objectValue?["topics"]?.objectValue
        let want = c.expected.object("kb")
        #expect((after == nil) == (want == nil), "\(c.name): knowledge.json exists")
        if let after, let want {
            #expect(after.members.map(\.key).sorted() == want.members.map(\.key).sorted(), "\(c.name): topics")
            for m in want.members {
                let got = after[m.key]?.objectValue
                #expect(got?.string("summary") == m.value.objectValue?.string("summary"), "\(c.name): \(m.key)")
                #expect(got?.double("updated") == m.value.objectValue?.double("updated"), "\(c.name): \(m.key) updated")
            }
        }
    }

    @Test(arguments: try M5Fixture.cases("w1_web_search"))
    func webSearch(_ c: M5Fixture.Case) async throws { try await run(c, tool: "web_search") }

    @Test(arguments: try M5Fixture.cases("w1_weather"))
    func weather(_ c: M5Fixture.Case) async throws { try await run(c, tool: "get_weather") }

    @Test(arguments: try M5Fixture.cases("w1_location"))
    func location(_ c: M5Fixture.Case) async throws { try await run(c, tool: "get_location") }

    @Test(arguments: try M5Fixture.cases("w1_news") + M5Fixture.cases("w1_news_feed"))
    func news(_ c: M5Fixture.Case) async throws { try await run(c, tool: "get_news") }

    /// All four are untrusted (web content), so a turn that used one reaches no executor; and a
    /// platform without the network reads as offline, so no fake platform reaches it.
    @Test func theWebToolsAreUntrustedAndOfflineByDefault() async throws {
        #expect(TaintPolicy.untrusted.isSuperset(of: ["web_search", "get_news"]))
        let sandbox = try ToolCoreSandbox(clock: ManualClock(Self.epoch))
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), clock: ManualClock(Self.epoch), sandbox: sandbox)
        let turn = TurnContext(channel: .text)
        let search = await gateway.call("web_search", JSONObject([.init(key: "query", value: .string("Leeds"))]),
                                        turn: turn, origin: .model(.claude))
        #expect(search.text == WebSearch.offline && search.record.outcome == .ran)
        #expect(await turn.taintedBy == ["web_search"])
        let forget = await gateway.call("run_command", JSONObject([.init(key: "command", value: .string("ls"))]),
                                        turn: turn, origin: .model(.claude))
        #expect(forget.record.outcome == .blockedTaint)
        for tool in ["get_weather", "get_location", "get_news"] {
            let r = await gateway.call(tool, JSONObject(), turn: TurnContext(channel: .text), origin: .model(.claude))
            #expect(r.record.outcome == .ran && r.text.contains("offline"), "\(tool)")
        }
    }
}
