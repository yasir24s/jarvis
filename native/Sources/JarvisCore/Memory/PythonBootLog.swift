import Foundation

// Batch C part 1: the boot log check. Python JARVIS's launchd job sent stdout to
// logs/jarvis.boot.log as well as log() to logs/jarvis.log, and the boot log has heard lines the
// main log lacks. This compares the two and keeps the boot log's exchanges that are not already in
// jarvis.log, for P6's import path (`PythonImport.importBootLog`). Counts only in every report.

public extension PythonEraMemory {
    static let bootLogFile = "logs/jarvis.boot.log"

    /// What the comparison found. `groups` holds only the boot log's new exchanges.
    struct BootLogCheck: Sendable, Equatable {
        public var bootHeard = 0          // "[Heard]   " lines in the boot log
        public var logHeard = 0           // and in jarvis.log
        public var extraHeard = 0         // boot-log heard lines with no copy left in jarvis.log
        public var bootExchanges = 0      // heard lines the boot log pairs with a reply (readLog's rules)
        public var duplicates = 0         // of those, ones jarvis.log already has
        public var newExchanges = 0       // the rest, for the import
        public var skipped: [Skip: Int] = [:]
        public var groups: [Group] = []

        public init() {}

        /// One line, counts only.
        public var summary: String {
            let skips = Skip.allCases.compactMap { why in skipped[why].map { "\($0) \(why.rawValue)" } }
            return "boot log: \(bootHeard) heard line(s), jarvis.log: \(logHeard); \(extraHeard) only in the boot log; "
                + "\(bootExchanges) answered exchange(s) in the boot log, \(duplicates) already in jarvis.log, "
                + "\(newExchanges) new" + (skips.isEmpty ? "" : "; skipped: " + skips.joined(separator: ", "))
        }
    }

    /// Compares the two logs' texts.
    static func checkBootLog(boot: String, log: String, timeZone: TimeZone) -> BootLogCheck {
        var check = BootLogCheck()
        func heardLines(_ text: String) -> [Substring: Int] {
            var counts: [Substring: Int] = [:]
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
                if line.hasPrefix(heardPrefix) { counts[line, default: 0] += 1 }
            }
            return counts
        }
        let bootLines = heardLines(boot), logLines = heardLines(log)
        check.bootHeard = bootLines.values.reduce(0, +)
        check.logHeard = logLines.values.reduce(0, +)
        check.extraHeard = bootLines.reduce(0) { $0 + max(0, $1.value - (logLines[$1.key] ?? 0)) }

        var known: [String: Int] = [:]
        for group in readLog(log, timeZone: timeZone).groups {
            for key in exchanges(group).map(\.key) { known[key, default: 0] += 1 }
        }
        let reading = readLog(boot, timeZone: timeZone)
        check.skipped = reading.skipped
        for group in reading.groups {
            var kept: [ArchiveEntry] = []
            for exchange in exchanges(group) {
                check.bootExchanges += 1
                if let n = known[exchange.key], n > 0 {
                    known[exchange.key] = n - 1
                    check.duplicates += 1
                } else {
                    check.newExchanges += 1
                    kept += exchange.entries
                }
            }
            if !kept.isEmpty { check.groups.append(Group(source: group.source, date: group.date, entries: kept)) }
        }
        return check
    }

    /// A group's exchanges: each user message with the reply after it (a reply may be missing
    /// when it was empty), keyed by date, what was heard and what was said.
    private static func exchanges(_ group: Group) -> [(key: String, entries: [ArchiveEntry])] {
        var out: [(key: String, entries: [ArchiveEntry])] = []
        var i = 0
        let e = group.entries
        while i < e.count {
            guard e[i].role == .user else { i += 1; continue }
            let reply = i + 1 < e.count && e[i + 1].role == .jarvis ? e[i + 1] : nil
            let entries = reply.map { [e[i], $0] } ?? [e[i]]
            out.append((group.date + "\u{1F}" + e[i].text + "\u{1F}" + (reply?.text ?? ""), entries))
            i += entries.count
        }
        return out
    }
}
