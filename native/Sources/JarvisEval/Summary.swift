import Foundation

/// The scorecard over a run's results.
public struct EvalSummary: Codable, Sendable, Equatable {
    public struct ToolRow: Codable, Sendable, Equatable {
        public var tool: String
        public var cases: Int
        public var correct: Int
        public var offered: Int
        public var offeredOf: Int
    }

    public struct Category: Codable, Sendable, Equatable {
        public var category: String
        public var count: Int
        public var examples: [String]
    }

    public var cases: Int
    public var passed: Int
    public var toolCorrect: Int
    /// Cases that expected a tool and reported their offer.
    public var recallCases: Int
    public var recallHits: Int
    public var argsCases: Int
    public var argsCorrect: Int
    public var falseDone: Int
    /// The stricter count: the reply claims an action and the turn called no tool at all.
    public var claimedNoTool: Int
    /// Cases whose reply must not claim an action, and how many claimed one anyway.
    public var noClaimCases: Int
    public var noClaimViolations: Int
    public var p50LatencyMs: Double
    public var p95LatencyMs: Double
    public var meanToolsOffered: Double?
    public var meanBudgetUsed: Double?
    public var perTool: [ToolRow]
    public var perKind: [ToolRow]
    public var failures: [Category]

    public var toolAccuracy: Double { ratio(toolCorrect, cases) }
    public var rankerRecall: Double { ratio(recallHits, recallCases) }
    public var argAccuracy: Double { ratio(argsCorrect, argsCases) }
    public var falseDoneRate: Double { ratio(falseDone, cases) }

    public init(_ results: [EvalCaseResult], examplesPerCategory: Int = 3, cases: [EvalCase] = []) {
        let byID = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.cases = results.count
        passed = results.filter(\.pass).count
        toolCorrect = results.filter(\.toolCorrect).count
        let recall = results.compactMap(\.expectedOffered)
        recallCases = recall.count
        recallHits = recall.filter { $0 }.count
        let args = results.compactMap(\.argsCorrect)
        argsCases = args.count
        argsCorrect = args.filter { $0 }.count
        falseDone = results.filter(\.falseDone).count
        claimedNoTool = results.filter { $0.claimsAction && $0.calls.isEmpty }.count
        let forbidding = results.filter { r in
            byID[r.id].map(\.forbidsClaim) ?? (r.expected == EvalCase.noTool)
        }
        noClaimCases = forbidding.count
        noClaimViolations = forbidding.filter(\.claimsAction).count
        let latencies = results.map(\.latencyMs).sorted()
        p50LatencyMs = Self.percentile(latencies, 0.50)
        p95LatencyMs = Self.percentile(latencies, 0.95)
        let offered = results.compactMap(\.toolsOffered)
        meanToolsOffered = offered.isEmpty ? nil : Double(offered.reduce(0, +)) / Double(offered.count)
        let budgets = results.compactMap(\.budgetUsed)
        meanBudgetUsed = budgets.isEmpty ? nil : Double(budgets.reduce(0, +)) / Double(budgets.count)
        perTool = Self.rows(results, key: \.expected)
        perKind = Self.rows(results, key: \.kind)
        var categories: [String: [String]] = [:]
        for r in results { if let f = r.failure { categories[f.rawValue, default: []].append(r.id) } }
        failures = categories.map { Category(category: $0.key, count: $0.value.count,
                                             examples: Array($0.value.prefix(examplesPerCategory))) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.category < $1.category }
    }

    static func rows(_ results: [EvalCaseResult], key: KeyPath<EvalCaseResult, String>) -> [ToolRow] {
        Dictionary(grouping: results, by: { $0[keyPath: key] }).map { name, group in
            let recall = group.compactMap(\.expectedOffered)
            return ToolRow(tool: name, cases: group.count, correct: group.filter(\.toolCorrect).count,
                           offered: recall.filter { $0 }.count, offeredOf: recall.count)
        }.sorted { $0.tool < $1.tool }
    }

    /// Nearest-rank percentile of sorted values; 0 for none.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }

    static func pct(_ x: Double) -> String { String(format: "%5.1f%%", x * 100) }

    /// The table the runner prints.
    public func table() -> String {
        var lines: [String] = []
        lines.append("OD-EVAL scorecard: \(cases) cases, \(passed) passed (\(Self.pct(ratio(passed, cases))))")
        lines.append("")
        lines.append("  tool accuracy      \(Self.pct(toolAccuracy))  (\(toolCorrect)/\(cases))")
        lines.append("  ranker recall      \(Self.pct(rankerRecall))  (\(recallHits)/\(recallCases) expected tool offered)")
        lines.append("  argument accuracy  \(Self.pct(argAccuracy))  (\(argsCorrect)/\(argsCases))")
        lines.append("  false Done rate    \(Self.pct(falseDoneRate))  (\(falseDone)/\(cases) claimed an action, no action tool ran)")
        lines.append("    of which no tool  \(claimedNoTool)/\(cases) called no tool at all")
        lines.append("  no-claim breaches  \(noClaimViolations)/\(noClaimCases) cases that must not claim an action")
        lines.append(String(format: "  latency            p50 %.0f ms, p95 %.0f ms", p50LatencyMs, p95LatencyMs))
        if let meanToolsOffered { lines.append(String(format: "  tools offered      %.1f on average", meanToolsOffered)) }
        if let meanBudgetUsed { lines.append(String(format: "  prompt tokens      %.0f on average (instructions + tools)", meanBudgetUsed)) }
        lines.append("")
        lines.append("  failure categories")
        if failures.isEmpty { lines.append("    (none)") }
        for f in failures {
            lines.append("    \(f.category.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%4d", f.count))  e.g. \(f.examples.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("  by kind                 cases  tool-correct  offered")
        for r in perKind { lines.append(row(r)) }
        lines.append("")
        lines.append("  by expected tool        cases  tool-correct  offered")
        for r in perTool { lines.append(row(r)) }
        return lines.joined(separator: "\n") + "\n"
    }

    func row(_ r: ToolRow) -> String {
        let offered = r.offeredOf == 0 ? "-" : "\(r.offered)/\(r.offeredOf)"
        return "    \(r.tool.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%4d", r.cases))  "
            + "\(String(format: "%3d", r.correct)) \(Self.pct(ratio(r.correct, r.cases)))  \(offered)"
    }
}
