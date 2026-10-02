import Foundation
import JarvisCore
import JarvisTools
import Synchronization

/// W1 part 5: JARVIS keeps up with the world. Every `interval` (three hours), at background
/// priority, a pass reads the top UK and world news (BBC News and the Guardian), what is
/// trending in pop culture (Wikipedia's most-read articles and the Guardian's culture feed),
/// and news on the user's own interests, taken from his facts when the pass runs
/// (`ReadingSources.interests`; never his messages' words). Each item's page is opened in the
/// WebKit reader, one at a time, and kept in the web memory unless a page with the same URL or
/// canonical URL is already there.
///
/// A pass opens at most `pageLimit` pages and stops after `timeLimit`. Before each page it waits
/// while a turn runs or a reply is being spoken, on battery, in Low Power Mode and while the Mac
/// is hot (as the file scan does), looking again every `backoff`. Afterwards the pages are
/// summarised in the background (`WebSummaryQueue`), and the pass is noted in the database, so
/// the three hours hold across launches. Logs carry counts, hosts and times, never text.
public actor BackgroundReader {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Now = @Sendable () -> SuspendingClock.Instant

    public static let interval: Duration = .seconds(3 * 3600)
    /// After launch, before a pass that is due.
    public static let startDelay: Duration = .seconds(600)
    public static let pageLimit = 40
    public static let timeLimit: Duration = .seconds(600)
    public static let backoff: Duration = .seconds(60)
    /// Items taken from each source: pages read per interest topic, and topics per pass.
    public static let perFeed = 8
    public static let perTopic = 2
    public static let topics = 6
    static let feedUserAgent = "JARVIS/1.0"

    /// One pass, in counts.
    public struct PassSummary: Sendable, Equatable {
        public var opened = 0
        public var stored = 0
        public var alreadyKept = 0
        public var failed = 0
        public var candidates = 0
        public var topics = 0
        public var stopped = "done"          // "done", "page limit", "time limit", "offline", "cancelled", "no store"

        public init() {}
    }

    /// What decides whether the pass may read now.
    public struct Conditions: Sendable {
        public var power: @Sendable () -> PowerConditions
        public var onBattery: @Sendable () -> Bool
        /// Returns once no reply is being spoken.
        public var waitForSilence: @Sendable () async -> Void

        public init(power: @escaping @Sendable () -> PowerConditions = PowerConditions.current,
                    onBattery: @escaping @Sendable () -> Bool = PowerSource.onBattery,
                    waitForSilence: @escaping @Sendable () async -> Void = {}) {
            self.power = power
            self.onBattery = onBattery
            self.waitForSilence = waitForSilence
        }
    }

    private let memory: WebMemory
    private let facts: MemoryStore
    private let reader: any PageReading
    private let web: any WebFetching
    private let online: @Sendable () async -> Bool
    private let turns: TurnActivity
    private let conditions: Conditions
    private let summaries: WebSummaryQueue?
    private let clock: any JarvisClock
    private let now: Now
    private let sleep: Sleep
    private let log: @Sendable (String) -> Void
    private let task = Mutex<Task<Void, Never>?>(nil)
    private var paused = false

    public init(memory: WebMemory, facts: MemoryStore, reader: any PageReading, web: any WebFetching,
                online: @escaping @Sendable () async -> Bool, turns: TurnActivity, conditions: Conditions = Conditions(),
                summaries: WebSummaryQueue? = nil, clock: any JarvisClock = SystemClock(),
                now: @escaping Now = { SuspendingClock().now },
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.memory = memory
        self.facts = facts
        self.reader = reader
        self.web = web
        self.online = online
        self.turns = turns
        self.conditions = conditions
        self.summaries = summaries
        self.clock = clock
        self.now = now
        self.sleep = sleep
        self.log = log
    }

    // MARK: - Lifecycle

    /// Starts the loop: the first pass when one is due (at least `startDelay` after launch, and
    /// `interval` after the last pass began, as noted in the database), then one every `interval`.
    public nonisolated func start() {
        task.withLock { t in
            guard t == nil else { return }
            t = Task.detached(priority: .background) { [self] in await self.run() }
        }
    }

    /// Cancels the loop; a page being read finishes, nothing is kept after.
    public nonisolated func stop() {
        task.withLock { t in
            t?.cancel()
            t = nil
        }
    }

    private func run() async {
        do {
            var wait = Self.startDelay
            if let last = memory.lastPassStarted() {
                let since = Duration.seconds(max(0, clock.now() - last))
                if since < Self.interval { wait = max(wait, Self.interval - since) }
            }
            try await sleep(wait)
            while !Task.isCancelled {
                _ = await pass()
                try await sleep(Self.interval)
            }
        } catch {
            return
        }
    }

    // MARK: - One pass

    /// One pass, now.
    public func pass() async -> PassSummary {
        var summary = PassSummary()
        let started = now(), startedAt = clock.now()
        let deadline = started.advanced(by: Self.timeLimit)
        defer {
            memory.recordPass(started: startedAt, ended: clock.now(), opened: summary.opened, stored: summary.stored,
                              stopped: summary.stopped)
            log("web reading: pass \(summary.stopped): \(summary.opened) page(s) opened, \(summary.stored) kept, "
                + "\(summary.alreadyKept) already kept, \(summary.failed) failed, from \(summary.candidates) item(s) and "
                + "\(summary.topics) interest(s), in \(Self.seconds(started.duration(to: now())))")
        }
        guard await online() else {
            summary.stopped = "offline"
            return summary
        }
        let items = await candidates(&summary)
        summary.candidates = items.count
        for item in items {
            if Task.isCancelled { summary.stopped = "cancelled"; break }
            if summary.opened >= Self.pageLimit { summary.stopped = "page limit"; break }
            guard memory.isAvailable else { summary.stopped = "no store"; break }
            if memory.hasRead(item.url) { summary.alreadyKept += 1; continue }
            do {
                guard try await mayRead(until: deadline) else { summary.stopped = "time limit"; break }
            } catch {
                summary.stopped = "cancelled"
                break
            }
            summary.opened += 1
            guard let page = try? await reader.read(item.url) else { summary.failed += 1; continue }
            if memory.has(page.canonicalURL) {
                memory.alias(item.url, to: page.canonicalURL)
                summary.alreadyKept += 1
                continue
            }
            if memory.store(page, source: .background, query: item.source) != nil { summary.stored += 1 }
        }
        if summary.stored > 0 { summaries?.kick() }
        return summary
    }

    /// What this pass may read, the groups taken in turn (a news item, a culture item, an
    /// interest's page, and round again) so a pass cut short has some of each.
    func candidates(_ summary: inout PassSummary) async -> [ReadingSources.Item] {
        var groups: [ReadingSources.Group: [ReadingSources.Item]] = [:]
        for feed in ReadingSources.feeds {
            let items = await fetchFeed(feed)
            groups[feed.group, default: []] += Array(items.prefix(Self.perFeed))
        }
        let yesterday = Date(timeIntervalSince1970: clock.now() - 86_400)
        if let body = try? await web.get(ReadingSources.mostReadURL(day: yesterday),
                                         headers: [("User-Agent", Self.feedUserAgent)], timeout: 10),
           let feed = try? PyJSON.loads(body) {
            groups[.culture, default: []] += Array(ReadingSources.mostRead(feed).prefix(Self.perFeed))
        } else {
            log("web reading: Wikipedia's most-read list could not be read")
        }
        let topics = ReadingSources.interests(facts.loadFacts()?.facts ?? [], limit: Self.topics)
        summary.topics = topics.count
        for topic in topics {
            let found = (try? await WebResults.search(topic + " news", limit: Self.perTopic, web: web)) ?? []
            let items = found.map { ReadingSources.Item(url: $0.url, title: $0.title, source: "interest: " + topic) }
            groups[.interests, default: []] += items
        }
        var lists = ReadingSources.Group.allCases.map { groups[$0] ?? [] }
        var seen = Set<String>(), out: [ReadingSources.Item] = []
        while lists.contains(where: { !$0.isEmpty }) {
            for k in lists.indices where !lists[k].isEmpty {
                let item = lists[k].removeFirst()
                if seen.insert(item.url).inserted { out.append(item) }
            }
        }
        return out
    }

    private func fetchFeed(_ feed: ReadingSources.Feed) async -> [ReadingSources.Item] {
        do {
            let body = try await web.get(feed.url, headers: [("User-Agent", Self.feedUserAgent)], timeout: 10)
            return ReadingSources.rss(String(decoding: body, as: UTF8.self), source: feed.name)
        } catch {
            log("web reading: \(feed.name) could not be read")
            return []
        }
    }

    /// Waits until reading is allowed: no turn running, no reply being spoken, on mains power,
    /// not in Low Power Mode, not hot. False when the deadline passes first; throws when cancelled.
    private func mayRead(until deadline: SuspendingClock.Instant) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            guard now() < deadline else { return false }
            try await turns.waitUntilIdle(sleep: sleep)
            await conditions.waitForSilence()
            let power = conditions.power()
            if power.allowsBackgroundWork, !conditions.onBattery(), !turns.isRunning {
                if paused {
                    paused = false
                    log("web reading: resumed")
                }
                return true
            }
            if !paused {
                paused = true
                log("web reading: paused (on battery, Low Power Mode, or the Mac is hot)")
            }
            try await sleep(Self.backoff)
        }
    }

    static func seconds(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.1f s", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }
}
