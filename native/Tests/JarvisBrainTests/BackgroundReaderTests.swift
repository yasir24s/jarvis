import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// W1 part 5: the background reading. Invented feeds, a fake reader and a sandboxed web memory;
/// nothing reaches the network. It reads news, culture and the user's interests in turn, keeps
/// what it has not kept, stops at 40 pages or 10 minutes, waits while the user is busy, while
/// JARVIS speaks, on battery, in Low Power Mode and when hot, and takes its topics only from feeds
/// and facts.
@Suite("W1 background reading", .timeLimit(.minutes(1)))
struct BackgroundReaderTests {
    static let epoch: Double = 1_790_582_400                     // 2026-09-28 08:00 UTC

    final class FakeWeb: WebFetching {
        let pages: [String: String]
        private let asked = Mutex<[String]>([])
        init(_ pages: [String: String]) { self.pages = pages }
        var requests: [String] { asked.withLock { $0 } }
        func get(_ url: String, headers: [(String, String)], timeout: Double) async throws -> Data {
            asked.withLock { $0.append(url) }
            guard let body = pages[url] else { throw WebFetchError.status(404) }
            return Data(body.utf8)
        }
    }

    /// Every http page reads as itself, except the ones listed as failing or with a canonical.
    final class FakeReader: PageReading {
        let failing: Set<String>
        let canonical: [String: String]
        let onRead: @Sendable () -> Void
        private let asked = Mutex<[String]>([])
        init(failing: Set<String> = [], canonical: [String: String] = [:], onRead: @escaping @Sendable () -> Void = {}) {
            self.failing = failing
            self.canonical = canonical
            self.onRead = onRead
        }
        var reads: [String] { asked.withLock { $0 } }
        func read(_ url: String) async throws -> ReadPage {
            asked.withLock { $0.append(url) }
            onRead()
            if failing.contains(url) { throw PageReadError.failed("fake") }
            return ReadPage(requested: url, finalURL: url, canonicalURL: canonical[url] ?? url, title: "Page " + url,
                            text: "The text of " + url, truncated: false)
        }
    }

    static func rss(_ prefix: String, _ n: Int) -> String {
        "<rss><channel><title>Feed</title>" + (1...n).map { k in
            "<item><title><![CDATA[\(prefix) story \(k) &amp; more]]></title><link>https://\(prefix).invalid/\(k)</link></item>"
        }.joined() + "</channel></rss>"
    }

    static func mostRead(_ titles: [String]) -> String {
        let articles = titles.enumerated().map { k, t in
            #"{"title": "\#(t)", "normalizedtitle": "\#(t.replacingOccurrences(of: "_", with: " "))", "rank": \#(k + 1), "#
                + #""content_urls": {"desktop": {"page": "https://en.wikipedia.org/wiki/\#(t)"}}}"#
        }
        return #"{"mostread": {"date": "2026-09-27Z", "articles": ["# + articles.joined(separator: ", ") + "]}}"
    }

    static func results(_ urls: [String]) -> String {
        "<html><body>" + urls.map { #"<h2 class="result__title"><a class="result__a" href="\#($0)">R</a></h2>"# }.joined()
            + "</body></html>"
    }

    static func fact(_ id: String, _ text: String, about: String = MemoryFact.user, updated: Double = epoch) -> MemoryFact {
        MemoryFact(id: id, text: text, about: about, source: "conversation", created: epoch, updated: updated, by: .local)
    }

    struct Rig {
        let sandbox: Sandbox
        let clock = ManualClock(BackgroundReaderTests.epoch)
        let memory: MemoryStore
        let web: WebMemory
        let fetcher: FakeWeb
        let reader: FakeReader
        let turns: TurnActivity
        let sleeps = Sleeps()
        let logs = LogRecorder()

        init(feeds: [String: String]? = nil, reader: FakeReader = FakeReader(), facts: [MemoryFact] = []) throws {
            sandbox = try Sandbox()
            let store = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: nil, clock: clock)
            memory = MemoryStore(store: store, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
            #expect(memory.updateFacts { $0.facts = facts; return true })
            web = WebMemory(database: MemoryDatabase(memory: memory, log: { _ in }), embedding: nil, clock: clock,
                            timeZone: TimeZone(identifier: "UTC")!, log: { _ in })
            fetcher = FakeWeb(feeds ?? BackgroundReaderTests.standardFeeds)
            self.reader = reader
            turns = TurnActivity(clock: clock)
        }

        func background(online: Bool = true, conditions: BackgroundReader.Conditions = .init(power: { PowerConditions() },
                                                                                            onBattery: { false }),
                        now: @escaping BackgroundReader.Now = { SuspendingClock().now },
                        sleep: BackgroundReader.Sleep? = nil,
                        watchSleep: @escaping BackgroundReader.Sleep = { _ in try await Task.sleep(for: .milliseconds(1)) })
            -> BackgroundReader {
            let sleeps = sleeps
            return BackgroundReader(memory: web, facts: memory, reader: reader, web: fetcher, online: { online }, turns: turns,
                                    conditions: conditions, clock: clock, now: now,
                                    sleep: sleep ?? { d in sleeps.add(d) }, watchSleep: watchSleep, log: logs.function)
        }
    }

    final class Sleeps: Sendable {
        private let list = Mutex<[Duration]>([])
        func add(_ d: Duration) { list.withLock { $0.append(d) } }
        var all: [Duration] { list.withLock { $0 } }
    }

    static let feedURLs = ReadingSources.feeds.map(\.url)

    static var standardFeeds: [String: String] {
        var pages: [String: String] = [:]
        for (k, feed) in ReadingSources.feeds.enumerated() {
            pages[feed.url] = rss(feed.group == .news ? "news\(k)" : "culture", 3)
        }
        pages[ReadingSources.mostReadURL(day: Date(timeIntervalSince1970: epoch - 86_400))] =
            mostRead(["Main_Page", "Special:Search", "Invented_Film", "Invented_Singer"])
        pages[WebResults.url("jazz news")] = results(["https://jazz.invalid/1", "https://jazz.invalid/2", "https://jazz.invalid/3"])
        pages[WebResults.url("Leeds United news")] = results(["https://football.invalid/1"])
        return pages
    }

    // MARK: - Sources

    @Test func feedsMostReadAndInterestsAreParsed() {
        let items = ReadingSources.rss(Self.rss("news", 2) + "<item><title>No link</title></item>", source: "Feed")
        #expect(items == [ReadingSources.Item(url: "https://news.invalid/1", title: "news story 1 & more", source: "Feed"),
                          ReadingSources.Item(url: "https://news.invalid/2", title: "news story 2 & more", source: "Feed")])
        let read = ReadingSources.mostRead(try! PyJSON.loads(Data(Self.mostRead(["Main_Page", "Special:Search", "Invented_Film"]).utf8)))
        #expect(read == [ReadingSources.Item(url: "https://en.wikipedia.org/wiki/Invented_Film", title: "Invented Film",
                                             source: "Wikipedia most read")])
        #expect(ReadingSources.mostReadURL(day: Date(timeIntervalSince1970: Self.epoch))
                == "https://en.wikipedia.org/api/rest_v1/feed/featured/2026/09/28")

        let facts = [
            Self.fact("1", "The user loves jazz, especially on Fridays.", updated: Self.epoch + 5),
            Self.fact("2", "The user supports Leeds United.", updated: Self.epoch + 4),
            Self.fact("3", "The user is a big fan of the Invented Band.", updated: Self.epoch + 3),
            Self.fact("4", "The user keeps bees in the garden.", updated: Self.epoch + 2),
            Self.fact("5", "The user lives in Leeds.", updated: Self.epoch + 9),             // not an interest
            Self.fact("6", "Robin Vale loves opera.", about: "Robin Vale", updated: Self.epoch + 9),   // not the user's
            Self.fact("7", "The user enjoys JAZZ.", updated: Self.epoch + 1),                // the same topic again
            Self.fact("8", "The user is interested in astronomy because of a film.", updated: Self.epoch),
        ]
        #expect(ReadingSources.interests(facts) == ["jazz", "Leeds United", "Invented Band", "bees in the garden", "astronomy"])
        #expect(ReadingSources.interests(facts, limit: 2) == ["jazz", "Leeds United"])
        #expect(ReadingSources.interests([]).isEmpty && ReadingSources.interests([Self.fact("5", "The user lives in Leeds.")]).isEmpty)
    }

    // MARK: - A pass

    @Test func aPassReadsEachGroupInTurnAndKeepsWhatIsNew() async throws {
        let facts = [Self.fact("1", "The user loves jazz.", updated: Self.epoch + 1), Self.fact("2", "The user supports Leeds United.")]
        let reader = FakeReader(failing: ["https://news1.invalid/2"],
                                canonical: ["https://news2.invalid/1": "https://news0.invalid/1"])    // the same story twice
        let rig = try Rig(reader: reader, facts: facts)
        defer { rig.sandbox.remove() }
        rig.web.store(ReadPage(requested: "https://culture.invalid/2", finalURL: "https://culture.invalid/2",
                               canonicalURL: "https://culture.invalid/2", title: "Kept", text: "Kept before.", truncated: false),
                      source: .background)
        let summary = await rig.background().pass()
        #expect(Array(rig.reader.reads.prefix(3)) == ["https://news0.invalid/1", "https://culture.invalid/1",
                                                     "https://jazz.invalid/1"])           // news, culture, interests in turn
        #expect(!rig.reader.reads.contains("https://culture.invalid/2"))                // kept already: not opened
        #expect(summary.topics == 2 && summary.failed == 1 && summary.stopped == "done")
        #expect(summary.alreadyKept == 2)                                                 // culture/2, and news2/1's canonical
        #expect(summary.stored == summary.opened - summary.failed - 1)
        #expect(rig.web.count == summary.stored + 1)
        let jazz = try #require(rig.web.page("https://jazz.invalid/1"))
        #expect(jazz.source == "background" && jazz.query == "interest: jazz")
        #expect(rig.web.page("https://en.wikipedia.org/wiki/Invented_Film")?.query == "Wikipedia most read")
        #expect(rig.web.page("https://en.wikipedia.org/wiki/Main_Page") == nil)
        #expect(rig.web.lastPassStarted() == Self.epoch)

        // Topics came only from the feeds and the facts: these are all the requests made.
        #expect(Set(rig.fetcher.requests) == Set(Self.feedURLs + [
            ReadingSources.mostReadURL(day: Date(timeIntervalSince1970: Self.epoch - 86_400)),
            WebResults.url("jazz news"), WebResults.url("Leeds United news"),
        ]))
        // ...and nothing it read became a fact.
        #expect(rig.memory.loadFacts()?.facts == facts)

        // The next pass opens nothing it has read.
        let again = await rig.background().pass()
        #expect(again.opened == 1 && again.stored == 0)                                   // only the page that failed
    }

    @Test func aPassStopsAtFortyPages() async throws {
        var feeds = Self.standardFeeds
        for (k, feed) in ReadingSources.feeds.enumerated() { feeds[feed.url] = Self.rss("many\(k)", 20) }
        let rig = try Rig(feeds: feeds)
        defer { rig.sandbox.remove() }
        let summary = await rig.background().pass()
        #expect(summary.opened == BackgroundReader.pageLimit && summary.stored == 40 && summary.stopped == "page limit")
    }

    @Test func aPassStopsAfterTenMinutes() async throws {
        let hand = Mutex(SuspendingClock().now)
        let reader = FakeReader(onRead: { hand.withLock { $0 = $0.advanced(by: .seconds(100)) } })   // 100 s a page
        let rig = try Rig(reader: reader)
        defer { rig.sandbox.remove() }
        let summary = await rig.background(now: { hand.withLock { $0 } }).pass()
        #expect(summary.opened == 6 && summary.stopped == "time limit")
    }

    /// Before each page: no turn, no speech, mains power, no Low Power Mode, not hot.
    @Test func aPassWaitsWhileTheMacIsBusyOrOnBattery() async throws {
        let rig = try Rig(feeds: [ReadingSources.feeds[0].url: Self.rss("news", 1)])
        defer { rig.sandbox.remove() }
        let state = Mutex((battery: true, lowPower: true, hot: true, silences: 0))
        let conditions = BackgroundReader.Conditions(
            power: { state.withLock { PowerConditions(thermal: $0.hot ? .serious : .nominal, lowPowerMode: $0.lowPower) } },
            onBattery: { state.withLock { $0.battery } },
            waitForSilence: { state.withLock { $0.silences += 1 } })
        rig.turns.begin()
        let waits = Mutex<[Duration]>([])
        let reading = rig.background(conditions: conditions, sleep: { d in
            waits.withLock { $0.append(d) }
            let n = waits.withLock { $0.count }
            switch n {
            case 2: rig.turns.end()                                  // the turn ends after two polls
            case 3: state.withLock { $0.hot = false }
            case 4: state.withLock { $0.lowPower = false }
            case 5: state.withLock { $0.battery = false }
            default: break
            }
        })
        let summary = await reading.pass()
        #expect(summary.stored == 1)
        #expect(waits.withLock { $0 } == [TurnActivity.pollInterval, TurnActivity.pollInterval,
                                          BackgroundReader.backoff, BackgroundReader.backoff, BackgroundReader.backoff])
        #expect(state.withLock { $0.silences } == 4)                   // asked before each look
        #expect(rig.logs.lines.contains("web reading: paused (on battery, Low Power Mode, or the Mac is hot)"))
        #expect(rig.logs.lines.contains("web reading: resumed"))
    }

    @Test func offlineNothingIsFetched() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        let summary = await rig.background(online: false).pass()
        #expect(summary.stopped == "offline" && rig.fetcher.requests.isEmpty && rig.reader.reads.isEmpty)
    }

    /// The first pass waits the start delay, or what is left of three hours since the last one
    /// began (noted in the database, so it holds across launches).
    @Test func theFirstPassWaitsUntilOneIsDue() async throws {
        let rig = try Rig(feeds: [:])
        defer { rig.sandbox.remove() }
        // PA batch A: the first sleep is awaited, not polled for a fixed second, so a loaded
        // machine that starts the loop late only makes the test wait longer (the suite's time
        // limit still bounds it).
        func firstWait() async -> Duration? {
            let (waits, sink) = AsyncStream<Duration>.makeStream()
            let reading = rig.background(online: false, sleep: { d in
                sink.yield(d)
                throw CancellationError()
            })
            reading.start()
            var first: Duration?
            for await d in waits {
                first = d
                break
            }
            reading.stop()
            return first
        }
        #expect(await firstWait() == BackgroundReader.startDelay)
        rig.web.recordPass(started: Self.epoch - 3_600, ended: Self.epoch - 3_500, opened: 1, stored: 1, stopped: "done")
        #expect(await firstWait() == .seconds(2 * 3_600))
    }

    // MARK: - V11 part 3: a page read gives way mid-item

    /// Its first read starts the interruption (`interrupt`) and then waits until it is
    /// cancelled; every later read answers at once.
    final class InterruptedReader: PageReading {
        let interrupt: @Sendable () -> Void
        let cancelled = Mutex(0)
        private let asked = Mutex<[String]>([])
        init(interrupt: @escaping @Sendable () -> Void) { self.interrupt = interrupt }
        var reads: [String] { asked.withLock { $0 } }
        func read(_ url: String) async throws -> ReadPage {
            let n = asked.withLock { $0.append(url); return $0.count }
            if n == 1 {
                interrupt()
                do {
                    try await Task.sleep(for: .seconds(600))
                } catch {
                    cancelled.withLock { $0 += 1 }
                    throw error
                }
            }
            return ReadPage(requested: url, finalURL: url, canonicalURL: url, title: "Page " + url,
                            text: "The text of " + url, truncated: false)
        }
    }

    static let oneItem = [ReadingSources.feeds[0].url: rss("news", 1)]

    @Test func speechStartingStopsAPageReadAndTheSameItemIsReadAgain() async throws {
        let turns = Mutex<TurnActivity?>(nil)
        let reader = InterruptedReader(interrupt: { turns.withLock { $0 }?.speechBegan() })
        let rig = try Rig(feeds: Self.oneItem, reader: FakeReader())
        defer { rig.sandbox.remove() }
        turns.withLock { $0 = rig.turns }
        let reading = BackgroundReader(memory: rig.web, facts: rig.memory, reader: reader, web: rig.fetcher,
                                       online: { true }, turns: rig.turns,
                                       conditions: .init(power: { PowerConditions() }, onBattery: { false }),
                                       clock: rig.clock, sleep: { _ in rig.turns.speechEnded() },    // speech ends at the first look
                                       watchSleep: { _ in try await Task.sleep(for: .milliseconds(1)) },
                                       log: rig.logs.function)
        let summary = await reading.pass()
        #expect(reader.cancelled.withLock { $0 } == 1)
        #expect(reader.reads == ["https://news.invalid/1", "https://news.invalid/1"])
        #expect(summary.opened == 1 && summary.stored == 1 && summary.failed == 0 && summary.stopped == "done")
        #expect(rig.logs.lines.contains("web reading: a page read gave way to the user; it will be read again"))
    }

    @Test func aTurnBeginningStopsAPageReadAndTheSameItemIsReadAgain() async throws {
        let turns = Mutex<TurnActivity?>(nil)
        let reader = InterruptedReader(interrupt: { turns.withLock { $0 }?.begin() })
        let rig = try Rig(feeds: Self.oneItem, reader: FakeReader())
        defer { rig.sandbox.remove() }
        turns.withLock { $0 = rig.turns }
        let reading = BackgroundReader(memory: rig.web, facts: rig.memory, reader: reader, web: rig.fetcher,
                                       online: { true }, turns: rig.turns,
                                       conditions: .init(power: { PowerConditions() }, onBattery: { false }),
                                       clock: rig.clock, sleep: { _ in rig.turns.end() },    // the turn ends at the first look
                                       watchSleep: { _ in try await Task.sleep(for: .seconds(600)) },    // only the preemption can stop it
                                       log: rig.logs.function)
        let summary = await reading.pass()
        #expect(reader.cancelled.withLock { $0 } == 1)
        #expect(reader.reads == ["https://news.invalid/1", "https://news.invalid/1"])
        #expect(summary.opened == 1 && summary.stored == 1 && summary.failed == 0 && summary.stopped == "done")
        #expect(!rig.turns.isRunning)
    }
}
