import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// W1 part 6: the storage rule on fake volumes of several sizes. memory/ may use 10% of the
/// volume, and 3% of it must stay free; at either limit the oldest web pages are compacted
/// (text dropped, summary, key points and URL kept, compressed), never the conversations, facts,
/// journal or backups. Sandboxed roots and invented pages only.
@Suite("W1 storage rule", .serialized, .timeLimit(.minutes(2)))
struct MemoryBudgetTests {
    static let epoch: Double = 1_790_582_400

    /// A volume of `total` bytes whose free space grows by whatever the memory folder sheds.
    final class FakeVolume: VolumeProbing {
        let total: Int64
        let startFree: Int64
        let folder: String
        let startUsage: Int64
        init(total: Int64, free: Int64, folder: String) {
            self.total = total
            self.startFree = free
            self.folder = folder
            startUsage = MemoryBudget.size(of: folder)
        }
        func capacity() -> (total: Int64, available: Int64)? {
            (total, startFree + (startUsage - MemoryBudget.size(of: folder)))
        }
    }

    struct Rig {
        let sandbox: Sandbox
        let clock = ManualClock(MemoryBudgetTests.epoch)
        let memory: MemoryStore
        let web: WebMemory
        let logs = LogRecorder()
        var folder: String { memory.root + "/memory" }

        /// Conversations, a journal, facts and their backups, then `pages` pages of about 40 KB,
        /// a minute apart, the even ones summarised.
        init(pages: Int = 24) async throws {
            sandbox = try Sandbox()
            var root = sandbox.root.path(percentEncoded: false)
            while root.hasSuffix("/") { root.removeLast() }
            let store = try StateStore(root: root, lease: nil, clock: clock)
            memory = MemoryStore(store: store, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
            for k in 0..<20 { #expect(memory.archive("Invented message \(k) about the garden.", role: .user, channel: "text")) }
            #expect(memory.journal(tool: "get_time", outcome: .ran, args: JSONObject(), reply: "It is noon, sir."))
            #expect(memory.updateFacts { $0.facts = [MemoryFact(id: "f", text: "The user keeps bees.", source: "conversation",
                                                                  created: MemoryBudgetTests.epoch, updated: MemoryBudgetTests.epoch,
                                                                  by: .local)]; return true })
            web = WebMemory(database: MemoryDatabase(memory: memory, log: { _ in }), embedding: nil, clock: clock,
                            timeZone: TimeZone(identifier: "UTC")!, log: { _ in })
            for k in 0..<pages {
                clock.set(MemoryBudgetTests.epoch + Double(k * 60))
                let text = "Invented page \(k) about weather. " + String(repeating: "Words of page \(k), with more words. ", count: 1_100)
                let id = web.store(ReadPage(requested: "https://news.invalid/\(k)", finalURL: "https://news.invalid/\(k)",
                                            canonicalURL: "https://news.invalid/\(k)", title: "Page \(k)", text: text,
                                            truncated: false), source: .background)
                if k % 2 == 0, let id {
                    #expect(web.setSummary(id, PageSummary(summary: "Summary of page \(k), marked zebra\(k).",
                                                           points: ["Point \(k)"], by: "local")))
                }
            }
            web.reclaim()
        }

        /// The bytes of what must never be compacted away.
        func kept() -> [String: Data?] {
            var out: [String: Data?] = [:]
            for f in ["memory/archive.jsonl", "memory/journal.jsonl", "memory/facts.json"] {
                out[f] = FileManager.default.contents(atPath: memory.root + "/" + f)
            }
            let backups = memory.root + "/memory/backups"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? [] {
                out["backups/" + name] = FileManager.default.contents(atPath: backups + "/" + name)
            }
            return out
        }

        func budget(total: Int64, free: Int64) -> MemoryBudget {
            MemoryBudget(folder: folder, volume: FakeVolume(total: total, free: free, folder: folder), web: web,
                         log: logs.function)
        }
    }

    @Test(arguments: [Int64(1) << 40, Int64(512) << 30, Int64(64) << 30])
    func aRoomyVolumeCompactsNothing(_ total: Int64) async throws {
        let rig = try await Rig(pages: 4)
        defer { rig.sandbox.remove() }
        let check = try #require(rig.budget(total: total, free: total / 2).check())
        #expect(check.cap == Int64(Double(total) * 0.10) && check.floor == Int64(Double(total) * 0.03))
        #expect(check.compacted == 0 && check.within && rig.logs.lines.isEmpty)
        #expect(rig.web.uncompacted().pages == 4)
    }

    /// Over 10% of a small volume: the oldest pages lose their text until memory/ fits, newest
    /// last; everything else is untouched, and what a compacted page said can still be found.
    @Test(arguments: [0.8, 0.5])
    func overTheCapTheOldestPagesAreCompacted(_ share: Double) async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        let before = rig.kept()
        let used = MemoryBudget.size(of: rig.folder)
        let total = Int64(Double(used) * share * 10)                      // the cap is `share` of what memory/ uses
        let check = try #require(rig.budget(total: total, free: total / 2).check())
        #expect(check.within && check.compacted > 0 && check.used <= check.cap)
        #expect(check.cap == Int64(Double(total) * 0.10))
        print("W1-budget: volume \(MemoryBudget.mb(total)), cap \(MemoryBudget.mb(check.cap)): memory/ \(MemoryBudget.mb(used)) "
              + "→ \(MemoryBudget.mb(check.used)) after compacting \(check.compacted) of 24 pages")
        let compacted = (0..<24).filter { rig.web.page("https://news.invalid/\($0)")?.compacted == true }
        #expect(compacted == Array(0..<compacted.count))                 // the oldest, in order
        #expect(compacted.count < 24 && compacted.count == check.compacted)
        let old = try #require(rig.web.page("https://news.invalid/0"))
        #expect(old.text == nil && old.title == "Page 0" && old.summary == "Summary of page 0, marked zebra0."
                && old.points == ["Point 0"])
        let unsummarised = try #require(rig.web.page("https://news.invalid/1"))
        #expect(unsummarised.text == nil && unsummarised.summary.hasPrefix("Invented page 1 about weather."))
        #expect(rig.web.has("https://news.invalid/0") && rig.web.count == 24)
        #expect(rig.web.search("zebra0", limit: 1).best.first?.url == "https://news.invalid/0")
        let newest = try #require(rig.web.page("https://news.invalid/23"))
        #expect(newest.text != nil && !newest.compacted)
        #expect(rig.kept() == before)
        #expect(rig.logs.lines.count == 1 && rig.logs.lines[0].hasPrefix("memory: compacted \(check.compacted) web page(s), oldest first"))
    }

    /// Free space under 3% of the volume compacts the same way, until 3% is free again.
    @Test func belowTheFloorPagesAreCompacted() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        let used = MemoryBudget.size(of: rig.folder)
        let total = Int64(100) << 30                                     // 100 GB: the cap is far off
        let floor = Int64(Double(total) * 0.03)
        let check = try #require(rig.budget(total: total, free: floor - used / 3).check())
        #expect(check.within && check.compacted > 0 && check.available >= check.floor)
        print("W1-budget: floor \(MemoryBudget.mb(floor)): free \(MemoryBudget.mb(floor - used / 3)) → "
              + "\(MemoryBudget.mb(check.available)) after compacting \(check.compacted) of 24 pages")
        #expect(rig.web.page("https://news.invalid/0")?.compacted == true)
        #expect(rig.web.page("https://news.invalid/23")?.compacted == false)
    }

    /// When nothing but what is never compacted is over the cap, every page is compacted, a
    /// warning is logged, and nothing else is touched or removed.
    @Test func onlyTheKeptFilesOverTheCapRemoveNothing() async throws {
        let rig = try await Rig(pages: 6)
        defer { rig.sandbox.remove() }
        let before = rig.kept()
        let check = try #require(rig.budget(total: 1_000, free: 1_000).check())
        #expect(!check.within && check.compacted == 6 && rig.web.uncompacted().pages == 0 && rig.web.count == 6)
        #expect(rig.kept() == before)
        #expect(rig.logs.lines.last?.hasPrefix("memory: WARNING over the storage rule with no web page left to compact") == true)
    }

    /// The web memory checks the rule after each write.
    @Test func everyStoreChecksTheRule() async throws {
        let rig = try await Rig(pages: 12)
        defer { rig.sandbox.remove() }
        let used = MemoryBudget.size(of: rig.folder)
        let hook = BudgetHook()
        let web = WebMemory(database: MemoryDatabase(memory: rig.memory, log: { _ in }), embedding: nil, clock: rig.clock,
                            timeZone: TimeZone(identifier: "UTC")!, afterWrite: { hook.check() }, log: { _ in })
        let total = Int64(Double(used) * 0.9 * 10)
        hook.set(MemoryBudget(folder: rig.folder, volume: FakeVolume(total: total, free: total / 2, folder: rig.folder),
                              web: web, log: rig.logs.function))
        rig.clock.set(Self.epoch + 86_400)
        web.store(ReadPage(requested: "https://news.invalid/new", finalURL: "https://news.invalid/new",
                           canonicalURL: "https://news.invalid/new", title: "New", text: String(repeating: "New words. ", count: 4_000),
                           truncated: false), source: .search, query: "new")
        #expect(web.page("https://news.invalid/0")?.compacted == true)
        #expect(web.page("https://news.invalid/new")?.compacted == false)
        #expect(rig.logs.lines.contains { $0.hasPrefix("memory: compacted ") })
    }

    /// The live volume reads the real disk's size (read only).
    @Test func theLiveVolumeReadsTheDisk() throws {
        let space = try #require(LiveVolume(path: FileManager.default.temporaryDirectory.path(percentEncoded: false)
                                                + "/no-such-folder/inside").capacity())
        #expect(space.total > 0 && space.available >= 0 && space.available <= space.total)
    }
}
