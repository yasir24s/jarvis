import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// m1_prompt.golden.json (M01 §2.7, §2.9, §3.8, §5 A10): every scenario replays, through
/// `CoreState`, what the REAL process_command did in the sandboxed child (tools/golden_m1_prompt.py).
/// Per step, byte-equal: the captured system prompt (Claude's for online turns, the local
/// model's `messages[0]` for offline ones), the research_bump sequence of the turn's head (or
/// of the op), and all six state files on disk afterwards. A turn's tail is the one the real
/// backend took: record the reply and save, or (a brain error) pop the user turn and save.
/// After every step, `snapshotInputs()` and `whisperVocabularyInputs()` are checked against
/// len(_history), len(_corrections_load()) and _whisper_prompt().
/// The "system_prompt" case compares `SystemPrompt.base` with SYSTEM_PROMPT.
@Suite("M1 prompt golden (jarvis.py process_command head)")
struct M1PromptGoldenTests {
    static let suite = "m1_prompt"
    static let homeToken = "${JARVIS_HOME}"
    static let files = ["personality.json", "emotions.json", "profile.json", "knowledge.json",
                        "corrections.json", "history.json"]

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) async throws {
        for m in try await Self.check(c) { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
    }

    /// M01 §5 A5: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() async throws {
        let cases = try Golden.cases(Self.suite)
        var passed = 0
        for c in cases where try await Self.check(c).isEmpty { passed += 1 }
        print("\(Self.suite): \(passed)/\(cases.count)")
        #expect(passed == cases.count)
    }

    static func check(_ c: GoldenCase) async throws -> [String] {
        if c.name == "system_prompt" { return systemPrompt(c) }
        return try await scenario(c)
    }

    static func systemPrompt(_ c: GoldenCase) -> [String] {
        guard let sentinel = c.input.string("sentinel"), let real = c.expected.string("system_prompt"),
              let withSentinel = c.expected.string("with_sentinel") else { return ["malformed case"] }
        var out: [String] = []
        if let d = diff(SystemPrompt.base(changelogPath: sentinel), withSentinel) {
            out.append("base(sentinel): \(d)")
        }
        if let d = diff(SystemPrompt.base(changelogPath: homeToken + "/CHANGELOG.md"), real) {
            out.append("base(HERE/CHANGELOG.md): \(d)")
        }
        return out
    }

    static func scenario(_ c: GoldenCase) async throws -> [String] {
        guard let before = c.input.object("files_before"), let steps = c.input.array("steps"),
              let expected = c.expected.array("steps"), steps.count == expected.count, !steps.isEmpty,
              let now0 = PersonaGolden.double(steps[0].objectValue?["now"]) else {
            return ["malformed scenario"]
        }
        let sb = try Sandbox()
        defer { sb.remove() }
        var root = sb.root.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        for m in before.members {
            guard let b64 = m.value.stringValue else { continue }
            guard let data = Data(base64Encoded: b64) else { return ["files_before[\(m.key)] is not base64"] }
            try data.write(to: sb.root.appending(path: m.key, directoryHint: .notDirectory))
        }
        let clock = ManualClock(now0)
        let store = try StateStore(root: root, lease: nil, clock: clock)
        let counter = RecordingCounter()
        let front = FrontAppStub()
        var core = CoreState(store: store, clock: clock, research: counter, frontApp: front)
        var out: [String] = []

        for (k, (s, e)) in zip(steps, expected).enumerated() {
            guard let so = s.objectValue, let eo = e.objectValue, let op = so.string("op"),
                  let now = PersonaGolden.double(so["now"]), let bumps = eo.array("bumps"),
                  let filesAfter = eo.object("files_after") else {
                out.append("step \(k): malformed")
                continue
            }
            let tag = "step \(k) \(op)"
            clock.set(now)
            counter.reset()
            var result: JSONValue? = nil          // non-turn ops: the function's return value
            do {
                switch op {
                case "turn":
                    guard let app = eo.string("front_app"), case .bool(let online)? = so["online"],
                          let captured = eo.string("captured_system"), let reply = eo.string("reply") else {
                        out.append("\(tag): malformed turn")
                        continue
                    }
                    front.set(app)
                    var text = so.string("text") ?? ""
                    if let raw = so.string("raw") {
                        text = try await core.applyCorrections(raw)
                        if let d = diff(text, eo.string("text") ?? "<missing>") { out.append("\(tag): applied text \(d)") }
                    }
                    let prompt = try await core.beginTurn(text, online: online)
                    let want = captured.replacingOccurrences(of: homeToken, with: root, options: .literal)
                    if let d = diff(online ? prompt.claudeSystem : prompt.system, want) {
                        out.append("\(tag): \(online ? "claude" : "local") system prompt \(d)")
                    }
                    if so["fail"] == .bool(true) {
                        await core.popTrailingUserTurn()
                    } else {
                        await core.recordAssistant(reply)
                    }
                    await core.saveHistory()
                case "tone":
                    try await core.setTone(so.string("desc") ?? "")
                    result = .null
                case "learn":
                    result = .string(await core.learnCorrection(so.string("text") ?? ""))
                case "forget":
                    result = .string(await core.forgetCorrection(so.string("text") ?? ""))
                case "kb":
                    try await core.kbRemember(topic: so.string("topic") ?? "", summary: so.string("summary") ?? "")
                    result = .null
                case "note":
                    result = .string(try await core.personalityNoteTool(so.string("note") ?? ""))
                case "rewrite":
                    result = .string(await core.personalityRewriteTool(so.string("core") ?? ""))
                case "restart":                    // a new process: module state reset, history reloaded
                    core = CoreState(store: store, clock: clock, research: counter, frontApp: front)
                    result = .null
                default:
                    out.append("\(tag): unknown op")
                    continue
                }
            } catch {
                out.append("\(tag): native threw \(error)")
                continue
            }
            if let result {
                let want = eo["result"] ?? .string("<missing>")
                let same: Bool = switch (result, want) {
                case (.string(let a), .string(let b)): diff(a, b) == nil
                default: result == want
                }
                if !same { out.append("\(tag): result \(result) != Python \(want)") }
            }
            let wantBumps = bumps.map { b -> String in
                let a = b.arrayValue ?? []
                let n: Int64 = if case .int(let i)? = a.last { i } else { -1 }
                return "\(a.first?.stringValue ?? "?")+\(n)"
            }
            let haveBumps = counter.bumps.map(\.description)
            if haveBumps != wantBumps { out.append("\(tag): bumps \(haveBumps) != Python \(wantBumps)") }
            for f in files {
                guard filesAfter.has(f) else {
                    out.append("\(tag): fixture has no files_after[\(f)]")
                    continue
                }
                let data = try? Data(contentsOf: sb.root.appending(path: f, directoryHint: .notDirectory))
                let want = filesAfter[f]?.stringValue.flatMap { Data(base64Encoded: $0) }
                if data != want {
                    let text = data.map { String(decoding: $0, as: UTF8.self) } ?? "<absent>"
                    let pyText = want.map { String(decoding: $0, as: UTF8.self) } ?? "<absent>"
                    out.append("\(tag): \(f) bytes differ; native \(text.debugDescription.prefix(300)) "
                               + "Python \(pyText.debugDescription.prefix(300))")
                }
            }
            guard let ms = eo.object("module_state"), let base = c.expected.string("whisper_base"),
                  let wantWhisper = ms.string("whisper_prompt") else {
                out.append("\(tag): fixture has no module_state")
                continue
            }
            let snap = await core.snapshotInputs()
            if Int64(snap.historyTurns) != ms.int("history_len") || Int64(snap.correctionsCount) != ms.int("corrections_len") {
                out.append("\(tag): snapshotInputs \(snap) != Python len(_history) \(ms.int("history_len") ?? -1), "
                           + "len(_corrections_load()) \(ms.int("corrections_len") ?? -1)")
            }
            let vocab = await core.whisperVocabularyInputs()
            if let d = diff(whisperPrompt(base: base, name: vocab.name, meant: vocab.meant), wantWhisper) {
                out.append("\(tag): whisper prompt from whisperVocabularyInputs \(d)")
            }
        }
        return out
    }

    /// `_whisper_prompt`'s assembly (M9's), over CoreState's inputs: name first, then the
    /// meant words, de-duplicated in order (`dict.fromkeys`: code-point equality).
    static func whisperPrompt(base: String, name: String?, meant: [String]) -> String {
        var extra: [String] = []
        var seen = Set<[Unicode.Scalar]>()
        for w in (name.map { [$0] } ?? []) + meant where seen.insert(Array(w.unicodeScalars)).inserted {
            extra.append(w)
        }
        return extra.isEmpty ? base : base + " Also: " + extra.joined(separator: ", ") + "."
    }

    /// nil when the UTF-8 bytes are equal (Swift's `==` is canonical equivalence, too loose
    /// here); else where they first differ, with context from both sides.
    static func diff(_ got: String, _ want: String) -> String? {
        let a = Array(got.utf8), b = Array(want.utf8)
        if a == b { return nil }
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        func around(_ x: [UInt8]) -> String {
            let lo = max(0, i - 60), hi = min(x.count, i + 80)
            return String(decoding: x[lo..<hi], as: UTF8.self).debugDescription
        }
        return "differs at byte \(i) (native \(a.count) B, Python \(b.count) B): native …\(around(a))… "
            + "Python …\(around(b))…"
    }
}

/// The frontmost app `_front_app` returned in the Python run, injected per step.
private final class FrontAppStub: FrontAppProviding {
    private let name = Mutex("")

    func set(_ s: String) { name.withLock { $0 = s } }

    func frontmostAppName() async -> String { name.withLock { $0 } }
}
