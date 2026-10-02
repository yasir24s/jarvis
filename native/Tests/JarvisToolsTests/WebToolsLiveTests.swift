import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// W1 part 1's gated live checks: each web tool once against the real services, on a
/// sandboxed knowledge base. They run only with JARVIS_WEB_LIVE=1 and print what they got and
/// how long it took; every other run skips them, so the suite never touches the network.
@Suite("W1 web tools (live, gated)", .enabled(if: ProcessInfo.processInfo.environment["JARVIS_WEB_LIVE"] == "1"))
struct WebToolsLiveTests {
    func call(_ tool: String, _ args: [(String, JSONValue)] = []) async throws -> (String, Duration) {
        let sandbox = try ToolCoreSandbox(clock: SystemClock())
        defer { sandbox.remove() }
        var platform = ToolPlatform.fake()
        let live = ToolPlatform.live
        platform.web = live.web
        platform.online = live.online
        platform.newsFeed = live.newsFeed
        let gateway = await M5Fixture.gateway(platform, clock: SystemClock(), sandbox: sandbox)
        let clock = ContinuousClock()
        var text = ""
        let took = await clock.measure {
            text = await gateway.call(tool, JSONObject(args.map { .init(key: $0.0, value: $0.1) }),
                                      turn: TurnContext(channel: .text), origin: .model(.claude)).text
        }
        print("W1-live \(tool): \(took): \(text)")
        return (text, took)
    }

    @Test func webSearch() async throws {
        let (text, _) = try await call("web_search", [("query", .string("Leeds"))])
        #expect(!text.isEmpty && text != WebSearch.offline && text != WebSearch.nothing)
    }

    @Test func weather() async throws {
        let (text, _) = try await call("get_weather", [("location", .string("Leeds"))])
        #expect(text.hasPrefix("It's ") && text.hasSuffix(", sir."))
    }

    @Test func location() async throws {
        let (text, _) = try await call("get_location")
        #expect(text.hasPrefix("You appear to be in "))
    }

    @Test func news() async throws {
        let (text, _) = try await call("get_news")
        #expect(text.hasPrefix("Top headlines. ") && text.components(separatedBy: " ... ").count == 4)
    }
}
