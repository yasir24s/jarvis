import Foundation
import JarvisCore

/// `--od-replay`: the user's past requests through the same faked on-device pipeline, reported
/// as aggregate counts only. The request and reply text never reach the report unless
/// `includeText` is set; without it the report holds numbers and tool names, nothing else.
public enum Replay {
    /// The user's requests in an archive, in order: `path` is one archive file
    /// (`memory/archive.jsonl` format, `ArchiveEntry`), or a state root or memory folder, whose
    /// archives are read in `MemoryStore.searchedArchives` order. Superseded turns, torn lines and
    /// JARVIS's own lines are skipped, as `MemoryStore.archivedMessages()` skips them.
    public static func requests(fromArchive path: URL) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false), isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let files: [URL]
        if isDirectory.boolValue {
            files = MemoryStore.searchedArchives.flatMap { file -> [URL] in
                let name = (file.rawValue as NSString).lastPathComponent
                return [path.appending(path: file.rawValue), path.appending(path: name)]
            }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        } else {
            files = [path]
        }
        return try files.flatMap { try requests(inArchiveData: Data(contentsOf: $0)) }
    }

    /// The user lines of one archive file's bytes.
    public static func requests(inArchiveData data: Data) -> [String] {
        let lines = data.split(separator: 0x0A)
        let superseded = ArchiveSupersede.superseded(in: lines.lazy.map { Data($0) })
        return lines.compactMap { line -> String? in
            guard let entry = ArchiveEntry(line: Data(line)), entry.role == .user else { return nil }
            if let turn = entry.turn, superseded.contains(turn) { return nil }
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// A word in the request that names what JARVIS should do, and the tools that do it.
    public struct Keyword: Sendable {
        public let label: String
        public let pattern: String
        public let tools: Set<String>
    }

    static let music: Set<String> = ["music_play", "music_search", "music_control", "music_now_playing",
                                     "find_song_by_lyrics", "run_applescript"]
    public static let keywords: [Keyword] = [
        Keyword(label: "song", pattern: #"(?i)\bsongs?\b"#, tools: music),
        Keyword(label: "play", pattern: #"(?i)\bplay\b"#, tools: music.union(["run_shortcut"])),
        Keyword(label: "remind", pattern: #"(?i)\bremind(er|ers)?\b"#, tools: ["set_reminder"]),
        Keyword(label: "calendar", pattern: #"(?i)\bcalendar\b"#, tools: ["get_calendar", "create_event"]),
        Keyword(label: "message", pattern: #"(?i)\bmessages?\b"#, tools: ["send_message", "get_messages", "find_contact"]),
        Keyword(label: "text", pattern: #"(?i)^\s*(please\s+)?text\b|\btext\s+(my\s+)?[A-Z]?[a-z]+\s+(that|saying|to say)\b"#,
                tools: ["send_message", "get_messages", "find_contact"]),
        Keyword(label: "timer", pattern: #"(?i)\btimers?\b"#, tools: ["set_alarm", "set_reminder"]),
        Keyword(label: "weather", pattern: #"(?i)\bweather\b"#, tools: ["get_weather"]),
        Keyword(label: "find/call <name>", pattern: #"\b(?:[Ff]ind|[Cc]all|[Rr]ing)\s+(?:[A-Z][a-z]+|(?i:mum|mom|dad))\b"#,
                tools: ["find_contact", "send_message"]),
    ]

    /// The labels of the keywords `text` contains.
    public static func keywordHits(_ text: String) -> [Keyword] {
        keywords.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }
    }

    /// The report. Counts only, unless `samples` (only with `includeText`).
    public struct Report: Codable, Sendable, Equatable {
        public struct KeywordRow: Codable, Sendable, Equatable {
            public var keyword: String
            public var requests: Int
            /// The model called none of the keyword's tools (another tool, or none at all).
            public var missed: Int
            public var missedNoTool: Int
        }

        public struct Sample: Codable, Sendable, Equatable {
            public var reason: String
            public var request: String
            public var reply: String
            public var tools: [String]
        }

        public var requests: Int = 0
        /// A tool ran or was attempted.
        public var withToolCall: Int = 0
        /// The reply claims an action and the turn called no tool at all.
        public var claimedActionNoTool: Int = 0
        /// The reply claims an action and no action tool ran (a read-only tool may have):
        /// "Done, sir." after get_battery counts here, and so does one after a gated send.
        public var claimedActionNoActionTool: Int = 0
        /// `claimedActionNoTool` over `requests`.
        public var claimedActionNoToolShare: Double = 0
        public var timeouts: Int = 0
        public var emptyReplies: Int = 0
        public var stuck: Int = 0
        public var modelErrors: Int = 0
        public var keywordRequests: Int = 0
        public var keywordMisses: Int = 0
        public var byKeyword: [KeywordRow] = []
        /// How often each tool was the turn's first call (tool names only).
        public var firstTool: [String: Int] = [:]
        public var p50LatencyMs: Double = 0
        public var p95LatencyMs: Double = 0
        public var includesText = false
        public var samples: [Sample]?
    }

    public static func run(_ requests: [String], brain: some EvalBrain, includeText: Bool = false,
                           progress: (Int) -> Void = { _ in }) async -> Report {
        var report = Report()
        report.includesText = includeText
        var samples: [Report.Sample] = []
        var latencies: [Double] = []
        var rows: [String: Report.KeywordRow] = [:]
        for (index, text) in requests.enumerated() {
            let o = await brain.observe(EvalCase(id: "replay-\(index)", request: text, tool: EvalCase.noTool,
                                                 kind: "replay"))
            report.requests += 1
            latencies.append(o.latencyMs)
            let names = o.calls.map(\.name)
            if let first = names.first { report.firstTool[first, default: 0] += 1 }
            if !names.isEmpty { report.withToolCall += 1 }
            var reasons: [String] = []
            switch o.ending {
            case .timeout: report.timeouts += 1; reasons.append("timeout")
            case .empty: report.emptyReplies += 1; reasons.append("empty")
            case .stuck: report.stuck += 1; reasons.append("stuck")
            case .failed: report.modelErrors += 1; reasons.append("error")
            case .reply: break
            }
            if o.ending == .reply, o.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.emptyReplies += 1
                reasons.append("empty")
            }
            let ranAction = o.calls.contains { $0.outcome == "ran" && EvalScorer.actionTools.contains($0.name) }
            if ClaimDetector.claimsAction(o.reply) && !ranAction {
                report.claimedActionNoActionTool += 1
                if names.isEmpty {
                    report.claimedActionNoTool += 1
                    reasons.append("claimed-no-tool")
                } else {
                    reasons.append("claimed-no-action-tool")
                }
            }
            let hits = keywordHits(text)
            if !hits.isEmpty { report.keywordRequests += 1 }
            var missedAny = false
            for k in hits {
                var row = rows[k.label] ?? Report.KeywordRow(keyword: k.label, requests: 0, missed: 0, missedNoTool: 0)
                row.requests += 1
                if !names.contains(where: k.tools.contains) {
                    row.missed += 1
                    if names.isEmpty { row.missedNoTool += 1 }
                    missedAny = true
                }
                rows[k.label] = row
            }
            if missedAny {
                report.keywordMisses += 1
                reasons.append("keyword-miss")
            }
            if includeText && !reasons.isEmpty {
                samples.append(Report.Sample(reason: reasons.joined(separator: ","), request: text, reply: o.reply,
                                             tools: names))
            }
            progress(index + 1)
        }
        latencies.sort()
        report.p50LatencyMs = EvalSummary.percentile(latencies, 0.5)
        report.p95LatencyMs = EvalSummary.percentile(latencies, 0.95)
        report.claimedActionNoToolShare = report.requests == 0 ? 0
            : Double(report.claimedActionNoTool) / Double(report.requests)
        report.byKeyword = rows.values.sorted { $0.keyword < $1.keyword }
        report.samples = includeText ? samples : nil
        return report
    }

    /// The report as pretty JSON, keys sorted.
    public static func encode(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
