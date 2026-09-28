import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// m1_persona_llm.golden.json (M01 §2.2, §3.7-3.8, §6 T12): every step of every scenario runs
/// CoreState's consolidatePersonalityIfDue / distillPersonalityIfDue with a canned PersonaLLM,
/// over a Sandbox seeded with the case's starting personality.json and history.json. Each step
/// must equal what the real jarvis.py functions did with `ollama_post` faked: the request
/// strings handed to the model (system, user, timeout), or that no call was made; the
/// research_bump sequence; and both files' bytes afterwards. A step's `during` tool call runs
/// inside the fake's `complete`, re-entering the actor while it awaits the model, as Python's
/// tool thread would while the model thinks. Python raising out of personality_consolidate
/// (which proactive_loop catches) has no other effect, and the effects are what is compared.
@Suite("M1 persona LLM golden (jarvis.py personality_consolidate / personality_distill_async)")
struct M1PersonaLLMTests {
    static let suite = "m1_persona_llm"
    static let files = ["personality.json", "history.json"]

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) async throws {
        let r = try await Self.check(c)
        for m in r.hard { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        if let d = r.divergence {
            withKnownIssue(Comment(rawValue: d)) {
                for m in r.knownPython { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            }
        } else {
            for m in r.knownPython { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        }
    }

    /// M01 §5 A5: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() async throws {
        let cases = try Golden.cases(Self.suite)
        var passed = 0
        var diverged: [String: Int] = [:]
        for c in cases {
            let r = try await Self.check(c)
            if let d = r.divergence, !r.knownPython.isEmpty { diverged[d, default: 0] += 1 }
            if r.hard.isEmpty && (r.divergence == nil) == r.knownPython.isEmpty { passed += 1 }
        }
        let summary = diverged.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }
        print("\(Self.suite): \(passed)/\(cases.count)"
              + (summary.isEmpty ? "" : " (known divergences: \(summary.joined(separator: ", ")))"))
        #expect(passed == cases.count)
    }

    /// Native only (Python's single proactive loop never overlaps two consolidations): a
    /// second consolidation that starts while the first awaits the model commits, and the
    /// first then re-validates and drops its now-stale result. One commit, one bump.
    @Test func overlappingConsolidationCommitsOnce() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let notes = (0..<12).map { i in
            JSONValue.object(JSONObject([.init(key: "note", value: .string("Synthetic style note \(i) here")),
                                         .init(key: "added", value: .double(1_790_000_000 + Double(i)))]))
        }
        let p = JSONObject([.init(key: "core", value: .array([.string("Synthetic trait.")])),
                            .init(key: "learned", value: .array(notes))])
        try sb.write("personality.json", PyJSON.dumps(.object(p), indent: 1))
        var root = sb.root.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        let clock = ManualClock(1_790_582_400.5)
        let counter = RecordingCounter()
        let core = CoreState(store: try StateStore(root: root, lease: nil, clock: clock), clock: clock,
                             research: counter, frontApp: NoFrontApp())
        let llm = OverlappingLLM(core: core)
        await core.consolidatePersonalityIfDue(using: llm)
        #expect(llm.calls == 2)
        #expect(counter.bumps.map(\.description) == ["personality_consolidations+1"])
        let saved = try #require(PyJSON.loads(Data(try sb.read("personality.json").utf8)).objectValue)
        #expect(saved["learned"]?.arrayValue?.compactMap { $0.objectValue?.string("note") } == ["Inner reply wins here."])
    }

    static func check(_ c: GoldenCase) async throws -> PersonaGolden.Report {
        if c.name == "literals" {
            var hard: [String] = []
            if PersonaDistill.consolidateSystem != c.expected.string("consolidate_system") {
                hard.append("consolidateSystem differs from personality_consolidate's")
            }
            if PersonaDistill.distillSystem != c.expected.string("distill_system") {
                hard.append("distillSystem differs from personality_distill_async's")
            }
            return PersonaGolden.Report(hard: hard)
        }
        guard let before = c.input.object("files_before"), let steps = c.input.array("steps"),
              let expected = c.expected.array("steps"), steps.count == expected.count, !steps.isEmpty,
              let now0 = PersonaGolden.double(steps[0].objectValue?["now"]) else {
            return PersonaGolden.Report(hard: ["malformed scenario"])
        }
        let native = c.expected.object("native")
        var report = PersonaGolden.Report(divergence: native?.string("divergence"))
        let sb = try Sandbox()
        defer { sb.remove() }
        for f in files {
            guard let b64 = before.string(f) else { continue }
            guard let data = Data(base64Encoded: b64) else { return .init(hard: ["files_before[\(f)] is not base64"]) }
            try data.write(to: sb.root.appending(path: f, directoryHint: .notDirectory))
        }
        var root = sb.root.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        let clock = ManualClock(now0)
        let counter = RecordingCounter()
        let core = CoreState(store: try StateStore(root: root, lease: nil, clock: clock), clock: clock,
                             research: counter, frontApp: NoFrontApp())
        let llm = CannedLLM(core: core)
        for (k, (s, e)) in zip(steps, expected).enumerated() {
            guard let so = s.objectValue, let eo = e.objectValue, let op = so.string("op"),
                  let args = so.object("args"), let now = PersonaGolden.double(so["now"]),
                  let bumps = eo.array("bumps"), let filesAfter = eo.object("files_after"),
                  eo.has("llm_request") else {
                report.hard.append("step \(k): malformed")
                continue
            }
            let tag = "step \(k) \(op)"
            var out: [String] = []
            clock.set(now)
            counter.reset()
            llm.arm(reply: args.string("reply"), fail: args["fail"] == .bool(true), during: args.object("during"))
            switch op {
            case "consolidate": await core.consolidatePersonalityIfDue(using: llm)
            case "distill": await core.distillPersonalityIfDue(using: llm)
            default: report.hard.append("\(tag): unknown op"); continue
            }
            let requests = llm.requests
            if let m = compareRequest(requests, eo["llm_request"]) { out.append("\(tag): \(m)") }
            let want = bumps.map { b -> String in
                let a = b.arrayValue ?? []
                let n: Int64 = if case .int(let i)? = a.last { i } else { -1 }
                return "\(a.first?.stringValue ?? "?")+\(n)"
            }
            let have = counter.bumps.map(\.description)
            if have != want { out.append("\(tag): bumps \(have) != Python \(want)") }
            for f in files {
                let data = try? Data(contentsOf: sb.root.appending(path: f, directoryHint: .notDirectory))
                let got = data?.base64EncodedString()
                if got != filesAfter.string(f) {
                    let text = data.map { String(decoding: $0, as: UTF8.self) } ?? "<absent>"
                    out.append("\(tag): \(f) bytes differ; native wrote \(text.debugDescription.prefix(400))")
                }
                if native?["files_unchanged"] == .bool(true), got != before.string(f) {
                    report.hard.append("\(tag): native changed \(f) (the divergence says it must not)")
                }
            }
            if native != nil {
                if native?["no_request"] == .bool(true), !requests.isEmpty {
                    report.hard.append("\(tag): native called the model (the divergence says it must not)")
                }
                if !counter.bumps.isEmpty { report.hard.append("\(tag): native bumped \(counter.bumps)") }
                report.knownPython += out
            } else {
                report.hard += out
            }
        }
        return report
    }

    /// Python's recorded `{system, user, timeout}` (or null: no call) against native's calls.
    static func compareRequest(_ got: [CannedLLM.Request], _ want: JSONValue?) -> String? {
        guard case .object(let w)? = want else {
            return got.isEmpty ? nil : "native called the model \(got.count)×; Python made no call"
        }
        guard got.count == 1, let r = got.first else {
            return "native called the model \(got.count)×; Python called it once"
        }
        var diffs: [String] = []
        if r.system != w.string("system") { diffs.append("system \(r.system.debugDescription.prefix(300))") }
        if r.user != w.string("user") {
            diffs.append("user \(r.user.debugDescription.prefix(600)) != Python "
                         + "\((w.string("user") ?? "nil").debugDescription.prefix(600))")
        }
        if r.timeout != .seconds(w.int("timeout") ?? -1) { diffs.append("timeout \(r.timeout)") }
        return diffs.isEmpty ? nil : "request differs: " + diffs.joined(separator: "; ")
    }
}

/// A PersonaLLM that records each request and returns the step's canned reply, or throws
/// (Python's ollama_post raising). Its `during` tool call is made from inside `complete`,
/// while CoreState is suspended at the await, exactly where Python's other threads run.
final class CannedLLM: PersonaLLM {
    struct Request: Sendable {
        let system: String
        let user: String
        let timeout: Duration
    }

    struct Failure: Error {}

    private struct State {
        var reply: String?
        var fail = false
        var during: JSONObject?
        var requests: [Request] = []
    }

    private let core: CoreState
    private let state = Mutex(State())

    init(core: CoreState) {
        self.core = core
    }

    /// Sets the next step's behaviour and clears the recorded requests.
    func arm(reply: String?, fail: Bool, during: JSONObject?) {
        state.withLock { $0 = State(reply: reply, fail: fail, during: during) }
    }

    var requests: [Request] { state.withLock { $0.requests } }

    func complete(system: String, user: String, timeout: Duration) async throws -> String {
        let (reply, fail, during) = state.withLock { s in
            s.requests.append(Request(system: system, user: user, timeout: timeout))
            return (s.reply, s.fail, s.during)
        }
        if let during {
            switch during.string("op") {
            case "rewrite_tool": _ = await core.personalityRewriteTool(during.string("core") ?? "")
            case "note_tool": _ = try? await core.personalityNoteTool(during.string("note") ?? "")
            case "forget": await core.personalityFactoryReset()
            default: throw Failure()
            }
        }
        if fail { throw Failure() }
        return reply ?? ""                                       // `content or ""`
    }
}

/// The first `complete` starts a second consolidation on the same actor (re-entering it at
/// the await) and only answers after that one has committed.
private final class OverlappingLLM: PersonaLLM {
    private let core: CoreState
    private let count = Mutex(0)

    init(core: CoreState) {
        self.core = core
    }

    var calls: Int { count.withLock { $0 } }

    func complete(system: String, user: String, timeout: Duration) async throws -> String {
        let n = count.withLock { c in c += 1; return c }
        if n == 1 {
            await core.consolidatePersonalityIfDue(using: self)
            return "Outer reply is stale by now."
        }
        return "Inner reply wins here."
    }
}

private struct NoFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "" }
}
