import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_history_app.golden.json (M01 §2.6, §2.7, §3.7, §6 T10): AppContextLogic against the real
/// _front_app / app_context (driven by an injected AppKit stand-in), FeedbackLogic against
/// track_feedback under the frozen clock (the research_bump and emotion_event calls it makes,
/// in order; RecordingCounter here), and HistoryLog against _history_load, process_command's
/// history statements, _history_save's bytes (StateStore, compact) and
/// _claude_history_preamble. The "constants" case compares the regex, window, threshold,
/// exclusions and slice bounds with jarvis.py's.
///
/// Where a hand-edited turn's truthy non-string content makes _claude_history_preamble raise,
/// native must throw StateShapeError(.history). No divergences are registered.
@Suite("M1 history + app context + feedback golden (jarvis.py _history_* / app_context / track_feedback)")
struct M1HistoryAppFeedbackTests {
    static let suite = "m1_history_app"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) async throws {
        CorrHistGolden.record(c, try await Self.check(c))
    }

    /// M01 §5 A5: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() async throws {
        var reports: [String: CorrHistGolden.Report] = [:]
        for c in try Golden.cases(Self.suite) { reports[c.name] = try await Self.check(c) }
        try CorrHistGolden.summarise(Self.suite) { reports[$0.name] ?? CorrHistGolden.Report(hard: ["not run"]) }
    }

    static func check(_ c: GoldenCase) async throws -> CorrHistGolden.Report {
        switch c.input.string("kind") {
        case "constants": return CorrHistGolden.Report(hard: constants(c.expected))
        case "app": return try await app(c)
        case "feedback": return try feedback(c)
        case "history": return try history(c)
        default: return CorrHistGolden.Report(hard: ["unknown case kind \(c.input["kind"] ?? .null)"])
        }
    }

    // MARK: - App context

    struct StubFrontApp: FrontAppProviding {
        let name: String
        func frontmostAppName() async -> String { name }
    }

    static func app(_ c: GoldenCase) async throws -> CorrHistGolden.Report {
        var r = CorrHistGolden.Report()
        let mode = try #require(c.input.string("mode"))
        let wantName = try #require(c.expected.string("front_app"))
        let name: String
        switch mode {
        case "name":
            let localized = try #require(c.input.string("name"))
            name = AppContextLogic.frontAppName(appPresent: true, localizedName: localized)
        case "nil_name": name = AppContextLogic.frontAppName(appPresent: true, localizedName: nil)
        case "no_app": name = AppContextLogic.frontAppName(appPresent: false, localizedName: nil)
        case "raises": name = ""          // FrontAppProviding's contract: "" when unknown
        default: return CorrHistGolden.Report(hard: ["unknown app mode \(mode)"])
        }
        if !Py.eq(name, wantName) { r.hard.append("front app name \(name.debugDescription), Python \(wantName.debugDescription)") }
        let want = try #require(c.expected.string("context"))
        let got = AppContextLogic.context(frontApp: name)
        if !Py.eq(got, want) { r.hard.append("context \(got.debugDescription), Python \(want.debugDescription)") }
        let viaProvider = await AppContextLogic.context(from: StubFrontApp(name: wantName))
        if !Py.eq(viaProvider, want) { r.hard.append("context(from:) \(viaProvider.debugDescription)") }
        return r
    }

    // MARK: - Feedback

    static func feedback(_ c: GoldenCase) throws -> CorrHistGolden.Report {
        var r = CorrHistGolden.Report()
        let initial = try #require(c.input.object("initial"))
        var last = FeedbackLogic.LastCommand(text: try #require(initial.string("text")),
                                             at: try #require(initial.double("at")))
        let clock = ManualClock(try #require(c.clock.double("epoch")))
        let counter = RecordingCounter()
        let steps = try #require(c.input.array("steps")), want = try #require(c.expected.array("steps"))
        try #require(steps.count == want.count)
        for (k, (sv, wv)) in zip(steps, want).enumerated() {
            let st = try #require(sv.objectValue), w = try #require(wv.objectValue)
            let text = try #require(st.string("text"))
            clock.set(try #require(st.double("at")))
            counter.reset()
            let out = FeedbackLogic.track(text, last: last, now: clock.now())
            if let key = out.counter { counter.bump(key, by: 1) }            // research_bump first…
            var effects: [JSONValue] = counter.bumps.map { .array([.string("bump"), .string($0.key), .int(Int64($0.n))]) }
            if let event = out.emotionEvent {                                  // …then emotion_event
                effects.append(.array([.string("emotion"), .string(event), .double(1.0)]))
            }
            last = out.last
            let at = "step \(k) \(text.debugDescription) at \(st["at"] ?? .null)"
            if .array(effects) != w["effects"] { r.hard.append("\(at): effects \(effects), Python \(w["effects"] ?? .null)") }
            let lastJSON: JSONValue = .object(JSONObject([.init(key: "text", value: .string(last.text)),
                                                          .init(key: "at", value: .double(last.at))]))
            if lastJSON != w["last"] { r.hard.append("\(at): _LAST_CMD \(lastJSON), Python \(w["last"] ?? .null)") }
            let expectedSignal: FeedbackLogic.Signal = out.counter == nil ? .none
                : out.counter == FeedbackLogic.negativeCounter ? .negative : .rephrase
            if out.signal != expectedSignal { r.hard.append("\(at): signal \(out.signal) disagrees with its counter") }
        }
        return r
    }

    // MARK: - History

    static func history(_ c: GoldenCase) throws -> CorrHistGolden.Report {
        var r = CorrHistGolden.Report()
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: sb.root.path(percentEncoded: false), lease: nil)
        let path = store.path(.history)
        try CorrHistGolden.put(c.input["initial"], at: path)
        var log = HistoryLog()
        let ops = try #require(c.input.array("ops")), want = try #require(c.expected.array("steps"))
        try #require(ops.count == want.count)
        for (k, (ov, wv)) in zip(ops, want).enumerated() {
            let o = try #require(ov.arrayValue), w = try #require(wv.objectValue)
            let op = try #require(o.first?.stringValue), arg = o.count > 1 ? o[1].stringValue : nil
            let at = "step \(k) \(op) \(arg?.debugDescription ?? "")"
            switch op {
            case "load": log = HistoryLog.load(store.load(.history))
            case "user": log.appendUser(try #require(arg))
            case "assistant": log.appendAssistant(try #require(arg))
            case "pop": log.popTrailingUser()
            case "save": _ = store.save(.history, log.serialized())
            case "preamble":
                let got: String?, thrown: StateShapeError?
                do { got = try log.claudePreamble(); thrown = nil } catch { got = nil; thrown = error }
                if let raised = w.string("raises") {
                    if thrown?.file != .history {
                        r.hard.append("\(at): Python raises \(raised); native gave \(got?.debugDescription ?? "nil") without StateShapeError(.history)")
                    }
                } else if got.map({ JSONValue.string($0) }) != w["result"] {
                    r.hard.append("\(at): preamble \(got?.debugDescription ?? "threw \(thrown.map { "\($0)" } ?? "")"), Python \(w["result"] ?? .null)")
                }
            default: r.hard.append("\(at): unknown op")
            }
            let turns: JSONValue = .array(log.turns.map { .object($0) })
            if turns != w["turns"] { r.hard.append("\(at): turns \(turns), Python \(w["turns"] ?? .null)") }
            if op == "save", let m = CorrHistGolden.fileMismatch(path, w["file"]) { r.hard.append("\(at): history.json \(m)") }
        }
        return r
    }

    // MARK: - Literals

    static func constants(_ e: JSONObject) -> [String] {
        var out: [String] = []
        let p = e.object("feedback_pattern")
        if p?.string("pattern").map({ Py.eq($0, FeedbackLogic.negativePattern) }) != true {
            out.append("_FEEDBACK_NEG_RE differs: \(p?["pattern"] ?? .null)")
        }
        if p?["ignorecase"] != .bool(true) || p?["other_flags"] != .int(0) { out.append("_FEEDBACK_NEG_RE flags differ") }
        out += CorrHistGolden.compares(e.object("feedback_compares"), [
            "now - _LAST_CMD['at'] < 30": FeedbackLogic.window,
            "difflib.SequenceMatcher(None, text, _LAST_CMD['text']).ratio() > 0.65": FeedbackLogic.threshold,
        ])
        let initial = FeedbackLogic.LastCommand()
        if e["last_cmd_initial"] != .object(JSONObject([.init(key: "text", value: .string(initial.text)),
                                                         .init(key: "at", value: .double(initial.at))])) {
            out.append("_LAST_CMD initial \(e["last_cmd_initial"] ?? .null)")
        }
        if e["app_exclusions"] != .array([.array(AppContextLogic.excluded.map { .string($0) })]) {
            out.append("app_context exclusions \(e["app_exclusions"] ?? .null)")
        }
        let h = e.object("history")
        let trim: JSONValue = .array([.int(Int64(-HistoryLog.cap)), .null])
        for key in ["process_command_slices", "load_slices", "save_slices"] {
            let s = h?.object(key)
            if s?.count != 1 || s?.members.first?.value != trim { out.append("\(key) \(h?[key] ?? .null) (cap \(HistoryLog.cap))") }
        }
        if h?["load_roles"] != .array([.array(HistoryLog.roles.map { .string($0) })]) { out.append("_history_load roles \(h?["load_roles"] ?? .null)") }
        if h?["preamble_slices"] != .object(JSONObject([.init(key: "_history[-7:-1]", value: .array([.int(-7), .int(-1)]))])) {
            out.append("_claude_history_preamble slice \(h?["preamble_slices"] ?? .null)")
        }
        return out
    }
}
