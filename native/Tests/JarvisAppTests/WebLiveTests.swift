import Foundation
@testable import JarvisApp
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// W1's gated live checks for the reader: a deep search through the real DuckDuckGo and the
/// WebKit reader, with each page's time and what each tab cost in memory. Runs only with
/// JARVIS_WEB_LIVE=1 (the suite never touches the network otherwise) and prints its numbers.
@Suite("W1 reader (live, gated)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JARVIS_WEB_LIVE"] == "1"))
@MainActor
struct WebLiveTests {
    /// The reader, with each read's cost noted.
    final class Measured: PageReading {
        let reader: WebReader
        private let costs = Mutex<[(String, WebReader.Stats?, String?)]>([])
        init(_ reader: WebReader) { self.reader = reader }
        var all: [(String, WebReader.Stats?, String?)] { costs.withLock { $0 } }
        func read(_ url: String) async throws -> ReadPage {
            do {
                let (page, stats) = try await reader.readWithStats(url)
                costs.withLock { $0.append((url, stats, nil)) }
                return page
            } catch {
                costs.withLock { $0.append((url, nil, String(describing: error))) }
                throw error
            }
        }
    }

    struct NoCounts: ResearchCounting { func bump(_ key: String, by n: Int) {} }
    struct NoFrontApp: FrontAppProviding { func frontmostAppName() async -> String { "" } }

    @Test func aDeepSearchReadsAndKeepsItsPages() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let store = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: nil)
        let core = CoreState(store: store, clock: SystemClock(), research: NoCounts(), frontApp: NoFrontApp())
        let reader = Measured(WebReader())
        let kept = Mutex<[String]>([])
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        await BuiltInTools.register(on: gateway, core: core, clock: SystemClock(), timeZone: .current,
                                    web: BuiltInTools.Web(reader: reader, keep: { page, _ in
                                        kept.withLock { $0.append(page.canonicalURL) }
                                    }))
        let clock = ContinuousClock()
        let start = clock.now
        let result = await gateway.call("web_search", JSONObject([.init(key: "query", value: .string("history of Leeds")),
                                                                  .init(key: "deep", value: .bool(true))]),
                                        turn: TurnContext(channel: .text), origin: .model(.claude))
        let total = clock.now - start
        print("W1-live deep search: \(WebReader.seconds(total)) in all, \(reader.all.count) page(s) opened, "
              + "\(kept.withLock { $0.count }) kept; reply \(result.text.count) characters")
        for (url, stats, error) in reader.all {
            let host = URL(string: url)?.host ?? "?"
            if let stats {
                print("W1-live page \(host): \(WebReader.seconds(stats.elapsed)), tab "
                      + "\(stats.tabFootprint.map(WebReader.megabytes) ?? "unknown"), JARVIS +\(WebReader.megabytes(stats.ownFootprintDelta))")
            } else {
                print("W1-live page \(host): not read (\(error ?? "?"))")
            }
        }
        print("W1-live peak tabs \(reader.reader.peakTabs), open now \(reader.reader.openTabs)")
        #expect(result.text.hasPrefix("I read "), "\(result.text.prefix(300))")
        #expect(reader.reader.peakTabs <= WebReading.maxTabs && reader.reader.openTabs == 0)
        #expect(!kept.withLock { $0.isEmpty })
    }
}
