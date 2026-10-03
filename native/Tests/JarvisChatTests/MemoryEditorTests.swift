import Foundation
import JarvisChat
import JarvisCore
import Synchronization
import Testing

/// Batch C part 3: the Memory window's store path (add, edit, delete, restore), the
/// mass-deletion guard and the `jarvis://` routing. Each test has its own temp state folder.
@Suite("Batch C memory window", .timeLimit(.minutes(1)))
@MainActor
struct MemoryEditorTests {
    static let epoch: Double = 1_790_000_000

    final class Lease: StateLease {
        private let held: Mutex<Bool>
        init(_ held: Bool) { self.held = Mutex(held) }
        var isHeld: Bool { held.withLock { $0 } }
        func set(_ value: Bool) { held.withLock { $0 = value } }
    }

    @MainActor
    struct Rig {
        let root: URL
        let store: MemoryStore
        let editor: MemoryEditor
        let clock: ManualClock

        init(facts: [MemoryFact] = [], lease: Lease? = nil) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "jarvis-tests-memwin-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            clock = ManualClock(MemoryEditorTests.epoch)
            store = MemoryStore(store: try StateStore(root: root.path(percentEncoded: false), lease: lease, clock: clock),
                                clock: clock)
            if !facts.isEmpty { #expect(store.updateFacts { $0.facts = facts; return true }) }
            var n = 0
            editor = MemoryEditor(store: store, clock: clock, makeID: { n += 1; return "new-\(n)" })
            editor.reload()
        }

        var onDisk: [MemoryFact] { store.loadFacts()?.facts ?? [] }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static func fact(_ id: String, _ text: String, about: String = MemoryFact.user, source: String = "conversation",
                     by: FactWriter = .local, updated: Double = epoch) -> MemoryFact {
        MemoryFact(id: id, text: text, about: about, source: source, created: epoch, updated: updated, by: by)
    }

    static func many(_ n: Int) -> [MemoryFact] {
        (0..<n).map { fact("f\($0)", "Invented fact number \($0)") }
    }

    @Test("an added fact is written through the store, stamped by the user, with the manual source")
    func add() throws {
        let rig = try Rig(facts: [Self.fact("a", "Likes invented tea")])
        defer { rig.remove() }
        #expect(rig.editor.add("  Owns an invented bicycle  "))
        let added = try #require(rig.onDisk.first { $0.id == "new-1" })
        #expect(added.text == "Owns an invented bicycle")
        #expect(added.by == .user)
        #expect(added.source == MemoryEditor.manualSource)
        #expect(added.about == MemoryFact.user)
        #expect(rig.editor.facts.count == 2)
        // A duplicate, an empty line and an over-long line are refused, and nothing is written.
        #expect(!rig.editor.add("Owns an invented bicycle"))
        #expect(!rig.editor.add("   "))
        #expect(!rig.editor.add(String(repeating: "x", count: MemoryFact.maxLength + 1)))
        #expect(rig.onDisk.count == 2)
        // The write took the store's backup path: facts.json has a backup now.
        let backups = rig.root.appending(path: "memory/backups").path(percentEncoded: false)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? []).isEmpty == false)
    }

    @Test("a fact about someone else keeps its relation; one about the user drops it")
    func addAboutSomeone() throws {
        let rig = try Rig()
        defer { rig.remove() }
        #expect(rig.editor.add("Her birthday is in invented May", about: "Avery", relation: "sister"))
        #expect(rig.editor.add("Prefers invented mornings", about: "", relation: "ignored"))
        let facts = rig.onDisk
        #expect(facts.first { $0.about == "Avery" }?.relation == "sister")
        #expect(facts.first { $0.about == MemoryFact.user }?.relation == nil)
    }

    @Test("an edit keeps the id, source and creation time and marks the fact as the user's")
    func edit() throws {
        let rig = try Rig(facts: [Self.fact("a", "Likes invented tea", source: "file:abc", by: .claude)])
        defer { rig.remove() }
        rig.clock.advance(100)
        #expect(rig.editor.edit(id: "a", text: "Likes invented coffee", about: "user", relation: nil))
        let f = try #require(rig.onDisk.first)
        #expect(f.id == "a" && f.text == "Likes invented coffee" && f.source == "file:abc")
        #expect(f.created == Self.epoch && f.updated == Self.epoch + 100)
        #expect(f.by == .user)
        // No change, or a missing id, writes nothing.
        #expect(!rig.editor.edit(id: "a", text: "Likes invented coffee", about: "user", relation: nil))
        #expect(!rig.editor.edit(id: "gone", text: "Anything", about: "user", relation: nil))
    }

    @Test("a brain producing the same fact later does not relabel the user's edit")
    func userWins() {
        #expect(FactWriter.user.merged(with: .claude) == .user)
        #expect(FactWriter.user.merged(with: .user) == .user)
        #expect(FactWriter.local.merged(with: .user) == .both)
    }

    @Test("delete moves facts to the forgotten bin, and restore puts them back")
    func deleteAndRestore() throws {
        let rig = try Rig(facts: Self.many(20))
        defer { rig.remove() }
        #expect(rig.editor.delete(ids: ["f3", "f4"]))
        #expect(rig.onDisk.count == 18)
        #expect(Set(rig.editor.forgotten.map(\.fact.id)) == ["f3", "f4"])
        #expect(rig.editor.forgotten.allSatisfy { $0.forgotten == Self.epoch })
        #expect(rig.editor.restore(ids: ["f3"]))
        #expect(rig.onDisk.count == 19)
        #expect(rig.onDisk.contains { $0.id == "f3" })
        #expect(rig.editor.forgotten.map(\.fact.id) == ["f4"])
        // Nothing picked is nothing done.
        #expect(!rig.editor.delete(ids: ["nope"]))
    }

    @Test("a delete of more than dropLimit facts at once meets the mass-deletion guard")
    func guardRefuses() throws {
        let rig = try Rig(facts: Self.many(30))
        defer { rig.remove() }
        let ids = Set((0...MemoryStore.dropLimit).map { "f\($0)" })   // dropLimit + 1
        #expect(!rig.editor.delete(ids: ids))
        #expect(rig.editor.status.hasPrefix("Refused"))
        #expect(rig.onDisk.count == 30)
        #expect(rig.editor.forgotten.isEmpty)
        // dropLimit at once is the user's explicit pick, exempt as forget_memory's ids are.
        #expect(rig.editor.delete(ids: Set((0..<MemoryStore.dropLimit).map { "f\($0)" })))
        #expect(rig.onDisk.count == 30 - MemoryStore.dropLimit)
    }

    @Test("without the state lock nothing is written")
    func lease() throws {
        let lease = Lease(true)
        let rig = try Rig(facts: [Self.fact("a", "Likes invented tea")], lease: lease)
        defer { rig.remove() }
        lease.set(false)
        #expect(!rig.editor.add("Owns an invented kite"))
        #expect(!rig.editor.delete(ids: ["a"]))
        #expect(rig.editor.status.hasPrefix("Not saved"))
        lease.set(true)
        #expect(rig.onDisk.map(\.id) == ["a"])
    }

    @Test("an unreadable facts.json is left as it is")
    func unreadable() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let path = rig.store.path(.facts)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: URL(filePath: path))
        #expect(!rig.editor.add("Owns an invented kite"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "{not json")
    }

    @Test("the filters: about, source kind, writer, date and text")
    func filters() throws {
        let rig = try Rig(facts: [
            Self.fact("a", "Likes invented tea", by: .local, updated: Self.epoch),
            Self.fact("b", "Plays invented chess", about: "Avery", source: "file:9f", by: .claude,
                      updated: Self.epoch - 10 * 86_400),
            Self.fact("c", "Owns an invented boat", source: MemoryEditor.manualSource, by: .user, updated: Self.epoch - 3600),
        ])
        defer { rig.remove() }
        let e = rig.editor
        #expect(e.shown.map(\.id) == ["a", "c", "b"])   // newest first
        e.filter = .init(about: "Avery");  #expect(e.shown.map(\.id) == ["b"])
        e.filter = .init(source: "file");  #expect(e.shown.map(\.id) == ["b"])
        e.filter = .init(writer: .user);   #expect(e.shown.map(\.id) == ["c"])
        e.filter = .init(withinDays: 7);   #expect(e.shown.map(\.id) == ["a", "c"])
        e.filter = .init(query: "CHESS");  #expect(e.shown.map(\.id) == ["b"])
        #expect(e.aboutChoices == ["Avery", "user"])
        #expect(e.sourceChoices == ["conversation", "file", "manual"])
    }

    @Test("the archive is browsed read-only, newest first, with search")
    func archive() throws {
        let rig = try Rig()
        defer { rig.remove() }
        #expect(rig.store.archive("Remind me about the invented regatta", role: .user, channel: "text"))
        rig.clock.advance(5)
        #expect(rig.store.archive("Very good, sir.", role: .jarvis, channel: "text"))
        rig.editor.reload()
        #expect(rig.editor.shownArchive().map(\.text) == ["Very good, sir.", "Remind me about the invented regatta"])
        rig.editor.archiveQuery = "regatta"
        #expect(rig.editor.shownArchive().count == 1)
    }

    @Test("with no store yet the window says so and changes nothing")
    func unavailable() {
        let e = MemoryEditor()
        e.reload()
        #expect(!e.isAvailable)
        #expect(!e.add("Anything"))
        #expect(e.status.contains("not available"))
    }

    @Test("jarvis://memory routes to the Memory window; other links do not",
          arguments: [("jarvis://memory", true), ("JARVIS://Memory/", true), ("jarvis:memory", true),
                      ("jarvis://other", false), ("https://memory", false), ("jarvis://", false)])
    func routing(_ link: String, _ isMemory: Bool) throws {
        let url = try #require(URL(string: link))
        #expect((JarvisURLRoute(url) == .memory) == isMemory)
    }
}

/// Batch C part 3: the Desktop shortcut the install script places, and the URL scheme the app
/// registers. The script runs on a temp folder standing in for the Desktop.
@Suite("Batch C memory shortcut", .timeLimit(.minutes(1)))
struct MemoryShortcutTests {
    static let script = AppShellTests.native.appending(path: "scripts/install-memory-shortcut.sh")

    @Test("the script places JARVIS Memory.webloc pointing at jarvis://memory, only if absent")
    func places() throws {
        let desk = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-desk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: desk) }
        let first = try UpdateScriptTests.run(Self.script, [], environment: ["JARVIS_DESKTOP": desk.path(percentEncoded: false)],
                                              in: FileManager.default.temporaryDirectory)
        #expect(first.status == 0)
        let shortcut = desk.appending(path: "JARVIS Memory.webloc")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: shortcut), format: nil) as? [String: Any]
        #expect(plist?["URL"] as? String == "jarvis://memory")
        // An existing file of that name is never replaced.
        try Data("the user's own".utf8).write(to: shortcut)
        let second = try UpdateScriptTests.run(Self.script, [], environment: ["JARVIS_DESKTOP": desk.path(percentEncoded: false)],
                                               in: FileManager.default.temporaryDirectory)
        #expect(second.status == 0)
        #expect(try String(contentsOf: shortcut, encoding: .utf8) == "the user's own")
        // No temp file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.path(percentEncoded: false)) == ["JARVIS Memory.webloc"])
    }

    @Test("Info.plist registers the jarvis URL scheme")
    func scheme() throws {
        let url = AppShellTests.native.appending(path: "Resources/Info.plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(JarvisURLRoute.scheme) == true })
    }
}
