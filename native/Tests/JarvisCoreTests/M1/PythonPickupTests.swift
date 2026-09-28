import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// M01 §5 A9, §6 T13: the cross-implementation proof that Python picks up native's files.
// Each m1_pickup case (tools/golden_m1_pickup.py) is a CoreState session in a Sandbox:
//   1. native reads the files jarvis.py wrote (`files_before`) and must get Python's own
//      readings (`python_before`): personality/emotion/profile/kb context and _history_load;
//   2. a CoreState runs the case's steps (turns, tools, a consolidation and a distill with
//      canned replies, the history save) and so writes every state file itself;
//   3. those files are copied to a second Sandbox with native's readings of them, and
//      `golden.py readback <that dir> m1_pickup` runs through Process with the framework
//      Python. Python copies the files into its own sandbox (it never reads the repo's state and
//      never writes the handover dir), reads them with its own loaders, and must reproduce
//      every reading byte for byte (exit 0, "readback m1_pickup: OK").

private let pickupPython = "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3"
private let requestName = "m1_pickup_request.json"
private let stateFiles: [StateFile] = [.personality, .emotions, .profile, .knowledge, .history]

/// native/tools/golden.py, from this file's location in the tree.
private func goldenScript(_ file: String = #filePath) -> URL {
    URL(filePath: file).deletingLastPathComponent()   // M1
        .deletingLastPathComponent()                   // JarvisCoreTests
        .deletingLastPathComponent()                   // Tests
        .deletingLastPathComponent()                   // native
        .appending(path: "tools/golden.py")
}

@Suite("M1 cross-implementation: Python picks up native's state files (A9)")
struct M1PythonPickupTests {
    static let suite = "m1_pickup"

    @Test(arguments: try Golden.cases(suite))
    func pythonPicksUpNativeFiles(_ c: GoldenCase) async throws {
        let before = try #require(c.input.object("files_before"))
        let steps = try #require(c.input.array("steps"))
        let readAt = try #require(PersonaGolden.double(c.input["read_at"]))
        let nowEnd = try #require(PersonaGolden.double(c.input["now_end"]))
        let pythonBefore = try #require(c.expected.object("python_before"))

        // 1. Native reads Python's bytes.
        let first = try Sandbox()
        defer { first.remove() }
        try seed(first, before)
        let firstStore = try StateStore(root: root(first), lease: nil, clock: ManualClock(readAt))
        let mine = try readings(firstStore, history: HistoryLog.load(firstStore.load(.history)), now: readAt)
        for (key, value) in mine {
            let want = pythonBefore.string(key)?.replacingOccurrences(of: PersonaGolden.homeToken,
                                                                     with: root(first), options: .literal)
            #expect(value == want, "\(c.name): native's \(key) of Python's files differs")
        }

        // 2. A CoreState session writes every state file.
        let sb = try Sandbox()
        defer { sb.remove() }
        try seed(sb, before)
        let clock = ManualClock(readAt)
        let store = try StateStore(root: root(sb), lease: nil, clock: clock)
        let core = CoreState(store: store, clock: clock, research: RecordingCounter(), frontApp: EmptyFrontApp())
        for s in steps {
            let o = try #require(s.objectValue)
            let args = o.object("args") ?? JSONObject([])
            clock.set(try #require(PersonaGolden.double(o["now"])))
            switch o.string("op") {
            case "turn": _ = try await core.beginTurn(args.string("text") ?? "", online: args["online"] == .bool(true))
            case "assistant": await core.recordAssistant(args.string("text") ?? "")
            case "note_tool": _ = try await core.personalityNoteTool(args.string("note") ?? "")
            case "kb_remember": try await core.kbRemember(topic: args.string("topic") ?? "", summary: args.string("summary") ?? "")
            case "emotion_event": try await core.emotionEvent(args.string("name") ?? "")
            case "set_tone": try await core.setTone(args.string("desc") ?? "")
            case "consolidate": await core.consolidatePersonalityIfDue(using: FixedReplyLLM(reply: args.string("reply") ?? ""))
            case "distill": await core.distillPersonalityIfDue(using: FixedReplyLLM(reply: args.string("reply") ?? ""))
            case "save_history": await core.saveHistory()
            default: Issue.record("\(c.name): unknown op \(o.string("op") ?? "nil")")
            }
        }
        for f in stateFiles {
            #expect(FileManager.default.fileExists(atPath: store.path(f)), "\(c.name): native wrote no \(f.rawValue)")
        }
        let personality = try #require(store.load(.personality)?.objectValue)
        if c.name == "python_seeded" {                   // 12 notes: the consolidation committed
            #expect(personality.has("consolidated_at"), "\(c.name): the consolidation did not commit")
        }

        // 3. Hand the files over, take native's readings of them, and let Python read them.
        let handover = try Sandbox()
        defer { handover.remove() }
        for f in stateFiles {
            try FileManager.default.copyItem(atPath: store.path(f),
                                             toPath: handover.root.appending(path: f.rawValue).path(percentEncoded: false))
        }
        let native = try readings(store, history: await core.history, now: nowEnd)
        let request: [String: Any] = [
            "now": ["repr": PyFloat.repr(nowEnd), "bits": String(nowEnd.bitPattern, radix: 16).leftPadded(16)],
            "personality_file": store.path(.personality),
            "swift": native,
        ]
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            .write(to: handover.root.appending(path: requestName))
        let (status, output) = try runReadback(handover.root)
        let lines = output.split(separator: "\n").filter { $0.hasPrefix("readback ") }
        #expect(status == 0 && lines.last == "readback \(Self.suite): OK",
                "\(c.name): Python's readings of native's files differ:\n\(lines.joined(separator: "\n"))")
        print("\(Self.suite) \(c.name): python pickup \(status == 0 ? "OK" : "FAILED") (\(native.count) readings)")
    }

    private func root(_ sb: Sandbox) -> String {
        var r = sb.root.path(percentEncoded: false)
        while r.hasSuffix("/") { r.removeLast() }
        return r
    }

    private func seed(_ sb: Sandbox, _ before: JSONObject) throws {
        for m in before.members {
            guard let b64 = m.value.stringValue else { continue }
            let data = try #require(Data(base64Encoded: b64), "files_before[\(m.key)] is not base64")
            try data.write(to: sb.root.appending(path: m.key, directoryHint: .notDirectory))
        }
    }

    /// The A9 readings, in golden_m1_pickup.py's order (emotion_context saves emotions.json).
    private func readings(_ store: StateStore, history: HistoryLog, now: Double) throws -> [String: String] {
        var r: [String: String] = [:]
        r["personality_context"] = try PersonalityLogic.context(store: store)
        r["emotion_context"] = try EmotionLogic.context(store: store, now: now)
        r["emotions_after"] = (try? Data(contentsOf: URL(filePath: store.path(.emotions))))?.base64EncodedString() ?? ""
        r["profile_context"] = try ProfileLogic.context(store: store)
        r["kb_context"] = try KnowledgeLogic.context(store: store)
        r["history_load"] = PyJSON.dumps(history.serialized())
        return r
    }

    private func runReadback(_ dir: URL) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(filePath: pickupPython)
        p.arguments = [goldenScript().path(percentEncoded: false), "readback", dir.path(percentEncoded: false), Self.suite]
        var env = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "en_US.UTF-8"]
        for k in ["HOME", "TMPDIR"] { if let v = ProcessInfo.processInfo.environment[k] { env[k] = v } }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }
}

private struct FixedReplyLLM: PersonaLLM {
    let reply: String
    func complete(system: String, user: String, timeout: Duration) async throws -> String { reply }
}

private struct EmptyFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "" }
}

private extension String {
    func leftPadded(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}
