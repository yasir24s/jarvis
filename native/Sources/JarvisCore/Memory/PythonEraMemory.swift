import Foundation

// P6 part 4 (DEV-P6-05, proposed): what Python JARVIS left that can become memory, for the
// one-time `--import-python-memory`. Pure text logic over the bytes of logs/jarvis.log,
// history.json, knowledge.json and corrections.json; the batches go through P2's compile in
// JarvisBrain (`PythonImport`). Nothing here logs or keeps the text.

public enum PythonEraMemory {
    /// Where a group of messages came from.
    public enum Source: String, Sendable, CaseIterable {
        case log                 // logs/jarvis.log, the Python sessions
        case history             // history.json
        case knowledge           // knowledge.json's "queue"
        case corrections         // corrections.json
    }

    /// Why something the user said is left out.
    public enum Skip: String, Sendable, CaseIterable {
        case empty
        case oneWord             // one word or none
        case garbled             // a replacement character, a bracketed annotation, or mostly symbols
        case unpaired            // a heard line JARVIS did not answer (not the user's voice, or a dismissal)
    }

    /// One source's messages from one day (the local date they were said), in order.
    public struct Group: Sendable, Equatable {
        public let source: Source
        public let date: String
        public var entries: [ArchiveEntry]

        public init(source: Source, date: String, entries: [ArchiveEntry]) {
            self.source = source
            self.date = date
            self.entries = entries
        }
    }

    /// What the log gave: a group per Python session date, in log order, and what was left out.
    public struct LogReading: Sendable, Equatable {
        public var groups: [Group] = []
        public var skipped: [Skip: Int] = [:]
        public var pythonSessions = 0
        public var nativeSessions = 0
    }

    public static let heardPrefix = "[Heard]   "        // print(f"[Heard]   {text}")
    public static let replyPrefix = "[JARVIS]  "        // print(f"[JARVIS]  {reply}"); log() has one space
    public static let actingSuffix = "  (acting)"       // a fast-path reply that acts as it speaks

    private static let pythonBanner = compile(#"^===== JARVIS starting (\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2}):(\d{2}) =====$"#)
    private static let anyBanner = compile(#"^===== JARVIS "#)

    // MARK: - logs/jarvis.log

    /// The Python sessions of jarvis.log. A session runs from a "===== JARVIS starting <date>
    /// <time> =====" line to the next banner; a "===== JARVIS (native) starting" section, and
    /// anything before the first banner, is left out whole. In a session, each "[Heard]   <text>"
    /// line is paired with the first "[JARVIS]  <reply>" line after it and before the next heard
    /// line (two spaces: Python's log() lines have one); a fast path's "  (acting)" is cut, and a
    /// reply is its first line. A heard line that is empty, one word or garbled is left out with
    /// its reply, and so is one with no reply.
    public static func readLog(_ text: String, timeZone: TimeZone) -> LogReading {
        var reading = LogReading()
        var session: (date: String, start: Double)?
        var heard: String?
        func flushUnpaired() {
            if heard != nil { reading.skipped[.unpaired, default: 0] += 1 }
            heard = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if line.hasPrefix("=====") {
                if let m = pythonBanner.match(line) {
                    flushUnpaired()
                    let date = m.groups[1] ?? ""
                    session = (date, startTime(date, m.groups[2], m.groups[3], m.groups[4], timeZone: timeZone))
                    reading.pythonSessions += 1
                    continue
                }
                if anyBanner.match(line) != nil {
                    flushUnpaired()
                    session = nil
                    reading.nativeSessions += line.contains("(native)") ? 1 : 0
                    continue
                }
            }
            guard let current = session else { continue }
            if line.hasPrefix(heardPrefix) {
                flushUnpaired()
                heard = String(line.dropFirst(heardPrefix.count))
            } else if line.hasPrefix(replyPrefix), let said = heard {
                heard = nil
                if let why = skipReason(said) {
                    reading.skipped[why, default: 0] += 1
                    continue
                }
                var reply = String(line.dropFirst(replyPrefix.count))
                if reply.hasSuffix(actingSuffix) { reply.removeLast(actingSuffix.count) }
                add([(.user, Py.strip(said)), (.jarvis, Py.strip(reply))], source: .log, date: current.date,
                    at: current.start, to: &reading.groups)
            }
        }
        flushUnpaired()
        return reading
    }

    // MARK: - The state files

    /// history.json's turns (`HistoryLog`'s reading: "user" and "assistant" dicts with string
    /// content), dated `date` (the file's local modification date: the turns carry none). A user
    /// turn that is empty, one word or garbled is left out with the reply that follows it.
    public static func readHistory(_ raw: JSONValue?, date: String, at t: Double,
                                   skipped: inout [Skip: Int]) -> [Group] {
        var messages: [(MemoryRole, String)] = []
        var droppingReply = false
        for turn in HistoryLog.load(raw).turns {
            guard case .string(let role)? = turn["role"], case .string(let content)? = turn["content"] else { continue }
            if role == "user" {
                if let why = skipReason(content) {
                    skipped[why, default: 0] += 1
                    droppingReply = true
                    continue
                }
                droppingReply = false
                messages.append((.user, Py.strip(content)))
            } else if !droppingReply, !messages.isEmpty {
                messages.append((.jarvis, Py.strip(content)))
            }
        }
        var groups: [Group] = []
        add(messages, source: .history, date: date, at: t, to: &groups)
        return groups
    }

    /// knowledge.json's "queue": what the user last asked about (kb_note_topic keeps their
    /// words, lowercased), dated `date` (the file's modification date). Empty, one-word and
    /// garbled items are left out.
    public static func readKnowledgeQueue(_ raw: JSONValue?, date: String, at t: Double,
                                          skipped: inout [Skip: Int]) -> [Group] {
        guard case .object(let kb)? = raw, case .array(let queue)? = kb["queue"] else { return [] }
        var messages: [(MemoryRole, String)] = []
        for case .string(let item) in queue {
            if let why = skipReason(item) {
                skipped[why, default: 0] += 1
            } else {
                messages.append((.user, Py.strip(item)))
            }
        }
        var groups: [Group] = []
        add(messages, source: .knowledge, date: date, at: t, to: &groups)
        return groups
    }

    /// corrections.json's pairs, as the user put them right: `You misheard me: I said "<meant>",
    /// not "<heard>".`, each dated by its "added" stamp (else `fallbackDate`).
    public static func readCorrections(_ raw: JSONValue?, timeZone: TimeZone, fallbackDate: String,
                                       fallbackTime: Double) -> [Group] {
        guard case .array(let pairs)? = raw else { return [] }
        var groups: [Group] = []
        for case .object(let p) in pairs {
            guard case .string(let heard)? = p["heard"], case .string(let meant)? = p["meant"],
                  !Py.strip(heard).isEmpty, !Py.strip(meant).isEmpty else { continue }
            let t = p["added"]?.pyFloat
            let date = t.map { PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: $0), timeZone: timeZone) }
                ?? fallbackDate
            let line = "You misheard me: I said \"\(Py.strip(meant))\", not \"\(Py.strip(heard))\"."
            add([(.user, line)], source: .corrections, date: date, at: t ?? fallbackTime, to: &groups)
        }
        return groups
    }

    // MARK: - What is left out

    /// Why a heard line (or a remembered user message) is left out; nil when it is kept.
    /// Garbled: a replacement character (the log was written with errors="replace"), a line
    /// that is only a bracketed annotation ("[BLANK_AUDIO]", "(music)", "*sighs*", "♪ … ♪"), or
    /// one whose non-space characters are under half letters and digits.
    public static func skipReason(_ heard: String) -> Skip? {
        let t = Py.strip(heard)
        if t.isEmpty { return .empty }
        let scalars = Array(t.unicodeScalars)
        if scalars.contains("\u{FFFD}") { return .garbled }
        if let first = scalars.first, let last = scalars.last, opening.contains(first), closing.contains(last) {
            return .garbled
        }
        let visible = scalars.filter { !$0.properties.isWhitespace }
        let wordy = visible.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        if !visible.contains(where: { $0.properties.isAlphabetic }) || wordy.count * 2 < visible.count {
            return .garbled
        }
        let words = t.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }
        return words.count < 2 ? .oneWord : nil
    }

    private static let opening: Set<Unicode.Scalar> = ["[", "(", "*", "♪", "♫"]
    private static let closing: Set<Unicode.Scalar> = ["]", ")", "*", "♪", "♫"]

    // MARK: - Helpers

    /// Appends `messages` to the last group when it is the same source and date, else as a new group.
    private static func add(_ messages: [(MemoryRole, String)], source: Source, date: String, at t: Double,
                            to groups: inout [Group]) {
        let entries = messages.filter { !$0.1.isEmpty }.map {
            ArchiveEntry(timestamp: t, date: date, channel: "voice", role: $0.0, text: $0.1)
        }
        guard !entries.isEmpty else { return }
        if let last = groups.last, last.source == source, last.date == date {
            groups[groups.count - 1].entries += entries
        } else {
            groups.append(Group(source: source, date: date, entries: entries))
        }
    }

    /// The banner's local time as epoch seconds.
    private static func startTime(_ date: String, _ h: String?, _ m: String?, _ s: String?,
                                  timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let ymd = date.split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3 else { return 0 }
        let parts = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: Int(h ?? "") ?? 0,
                                   minute: Int(m ?? "") ?? 0, second: Int(s ?? "") ?? 0)
        return calendar.date(from: parts)?.timeIntervalSince1970 ?? 0
    }

    private static func compile(_ pattern: String) -> PyRegex {
        do { return try PyRegex(pattern) } catch { preconditionFailure("PythonEraMemory: \(error)") }
    }
}

// MARK: - Batches

public extension PythonEraMemory {
    /// One batch for P2's compile: messages from one source and one day whose whole transcript
    /// fits `FactExtraction.transcriptLimit`, so the compile leaves none of them out.
    struct Batch: Sendable, Equatable {
        public let source: Source
        public let date: String
        public let entries: [ArchiveEntry]

        /// The facts it gives are tagged with this: `python:<YYYY-MM-DD>`.
        public var factSource: String { "python:" + date }
    }

    /// The groups cut into batches, oldest date first (a stable order, so a rerun makes the
    /// same batches from the same files). A user message stays with the reply after it.
    static func batches(_ groups: [Group], limit: Int = FactExtraction.transcriptLimit) -> [Batch] {
        let ordered = groups.enumerated().sorted { a, b in
            a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset
        }.map(\.element)
        var out: [Batch] = []
        for group in ordered {
            var units: [[ArchiveEntry]] = []          // a user message and the replies after it
            for e in group.entries {
                if e.role == .user || units.isEmpty { units.append([e]) } else { units[units.count - 1].append(e) }
            }
            var current: [ArchiveEntry] = []
            for unit in units {
                let candidate = current + unit
                if !current.isEmpty, FactExtraction.transcript(candidate, limit: limit).omitted > 0 {
                    out.append(Batch(source: group.source, date: group.date, entries: current))
                    current = unit
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty { out.append(Batch(source: group.source, date: group.date, entries: current)) }
        }
        return out
    }
}
