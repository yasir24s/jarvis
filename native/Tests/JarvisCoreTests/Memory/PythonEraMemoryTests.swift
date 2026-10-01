import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// P6 part 4 (DEV-P6-05, proposed): reading what Python JARVIS left. The synthetic log has two
/// Python sessions, one native session, paired lines and junk lines (`PythonEraFixture`, all
/// invented); the real ~/jarvis state is never read.
@Suite("P6 Python-era memory sources")
struct PythonEraMemoryTests {
    static let utc = TimeZone(identifier: "UTC")!

    @Test func theLogGivesThePythonSessionsPairedLinesOnly() {
        let r = PythonEraMemory.readLog(PythonEraFixture.log, timeZone: Self.utc)
        #expect(r.pythonSessions == 2 && r.nativeSessions == 1)
        #expect(r.groups.map(\.date) == ["2026-06-10", "2026-06-12"])
        #expect(r.groups.allSatisfy { $0.source == .log })
        #expect(r.groups[0].entries.map { "\($0.role.rawValue): \($0.text)" } == [
            "user: Jarvis, I've started learning the cello this summer",
            "jarvis: Splendid, sir. Shall I warn the neighbours?",
            "user: what's the weather like in Fernwick",
            "jarvis: Mild and grey, sir.",
            "user: I work night shifts at the Fernwick Infirmary",
            "jarvis: Noted, sir. Coffee on standby.",                   // "  (acting)" cut
        ])
        #expect(r.groups[1].entries.map(\.text) == ["I prefer my tea without sugar these days", "As you wish, sir."])
        // "Thanks"; "(upbeat music)", "...???" and the replacement characters; the blank line;
        // the line JARVIS ignored as not the user's voice, and the dismissal he never answered.
        #expect(r.skipped == [.oneWord: 1, .garbled: 3, .empty: 1, .unpaired: 2])
        let all = r.groups.flatMap(\.entries).map(\.text).joined(separator: "\n")
        for never in ["Ashgrove", "native pair", "bees", "before any session", "Wren", "Loading", "[Command]"] {
            #expect(!all.contains(never), "\(never)")
        }
        // Stamped with the session's banner (2026-06-10 09:15:00 here in UTC), on the voice channel.
        #expect(r.groups[0].entries.allSatisfy { $0.timestamp == 1_781_082_900 && $0.channel == "voice" })
    }

    @Test func aLogWithoutPythonSessionsGivesNothing() {
        let native = "\n===== JARVIS (native) starting 2026-09-30 10:00:00 =====\n[Heard]   I keep invented bees\n[JARVIS]  Indeed.\n"
        let r = PythonEraMemory.readLog(native, timeZone: Self.utc)
        #expect(r.groups.isEmpty && r.pythonSessions == 0 && r.nativeSessions == 1 && r.skipped.isEmpty)
        #expect(PythonEraMemory.readLog("", timeZone: Self.utc).groups.isEmpty)
    }

    @Test(arguments: [
        ("", PythonEraMemory.Skip.empty), ("   ", .empty), ("Jarvis.", .oneWord), ("thanks!", .oneWord),
        ("[BLANK_AUDIO]", .garbled), ("(upbeat music)", .garbled), ("*sighs*", .garbled), ("♪ la la ♪", .garbled),
        ("...???", .garbled), ("\u{FFFD}abc def", .garbled), ("#$%&* @!", .garbled), ("12 34", .garbled),
    ])
    func junkIsLeftOut(_ text: String, _ why: PythonEraMemory.Skip) {
        #expect(PythonEraMemory.skipReason(text) == why)
    }

    @Test(arguments: ["I'm 25 today", "my sister lives in Oslo", "(laughs) I passed my driving test", "two words"])
    func realLinesAreKept(_ text: String) {
        #expect(PythonEraMemory.skipReason(text) == nil)
    }

    @Test func theStateFilesGiveTheirMessages() throws {
        var skipped: [PythonEraMemory.Skip: Int] = [:]
        let history = PythonEraMemory.readHistory(try PyJSON.loads(Data(PythonEraFixture.history.utf8)),
                                                  date: "2026-08-01", at: 1, skipped: &skipped)
        #expect(history.map(\.date) == ["2026-08-01"] && history.first?.source == .history)
        #expect(history.first?.entries.map(\.text)
                == ["I'm training for an invented marathon in October", "Then I shall pace myself, sir."])
        let queue = PythonEraMemory.readKnowledgeQueue(try PyJSON.loads(Data(PythonEraFixture.knowledge.utf8)),
                                                       date: "2026-08-02", at: 2, skipped: &skipped)
        #expect(queue.first?.entries.map(\.text) == ["what time does the fernwick bakery open on sundays"])
        #expect(queue.first?.entries.allSatisfy { $0.role == .user } == true)
        #expect(skipped == [.oneWord: 2])                                  // "ok" (and its reply), "hello"
        let corrections = PythonEraMemory.readCorrections(try PyJSON.loads(Data(PythonEraFixture.corrections.utf8)),
                                                          timeZone: Self.utc, fallbackDate: "2000-01-01", fallbackTime: 0)
        #expect(corrections.map(\.date) == ["2026-06-11"])
        #expect(corrections.first?.entries.map(\.text) == ["You misheard me: I said \"Fernwick\", not \"fern wick\"."])
        // Other shapes give nothing.
        #expect(PythonEraMemory.readKnowledgeQueue(.array([]), date: "d", at: 0, skipped: &skipped).isEmpty)
        #expect(PythonEraMemory.readCorrections(.object(JSONObject()), timeZone: Self.utc, fallbackDate: "d",
                                                fallbackTime: 0).isEmpty)
        #expect(PythonEraMemory.readHistory(nil, date: "d", at: 0, skipped: &skipped).isEmpty)
    }

    /// A long day is cut so every batch's transcript holds all of its messages, a user message
    /// stays with its reply, nothing is lost, and the oldest day comes first.
    @Test func batchesFitP2sTranscriptAndKeepPairsTogether() {
        var long: [ArchiveEntry] = []
        for k in 0..<40 {
            long.append(ArchiveEntry(timestamp: 0, date: "2026-06-10", channel: "voice", role: .user,
                                     text: "I said invented thing \(k) " + String(repeating: "and more ", count: 15)))
            long.append(ArchiveEntry(timestamp: 0, date: "2026-06-10", channel: "voice", role: .jarvis,
                                     text: "Reply \(k), sir."))
        }
        let short = [ArchiveEntry(timestamp: 0, date: "2026-06-12", channel: "voice", role: .user, text: "I like tea")]
        let batches = PythonEraMemory.batches([
            PythonEraMemory.Group(source: .log, date: "2026-06-12", entries: short),
            PythonEraMemory.Group(source: .log, date: "2026-06-10", entries: long),
        ])
        #expect(batches.count >= 3)
        #expect(batches.first?.date == "2026-06-10" && batches.last?.date == "2026-06-12")
        for b in batches {
            #expect(FactExtraction.transcript(b.entries).omitted == 0)
            #expect(b.entries.first?.role == .user)
            #expect(b.factSource == "python:" + b.date)
        }
        #expect(batches.filter { $0.date == "2026-06-10" }.flatMap(\.entries) == long)
    }
}
