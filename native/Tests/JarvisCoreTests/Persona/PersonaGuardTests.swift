import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// P5, DEV-P5-01 (proposed): `personality_rewrite` may change his traits but not his identity.
/// The seed's Persona line is always line 1 of a rewritten core, with the seed's Tone and Humour
/// lines when no rewrite line is about his humour, tone or "sir" butler manner. Python stores the
/// rewrite as it is; its verdict for the golden rewrites is a known issue in M1PersonalityTests,
/// and these tests assert native's side.
@Suite("P5 personality rewrite keeps his identity")
struct PersonaGuardTests {
    /// Six lines of a generic assistant, the shape of the rewrite that replaced his persona.
    static let generic = """
        Helpful: answers every question clearly and completely
        Friendly: warm, approachable and encouraging
        Concise: keeps replies short and to the point
        Accurate: checks facts before answering
        Proactive: suggests useful next steps
        Respectful: polite and professional at all times
        """

    static func store(_ sb: Sandbox) throws -> StateStore {
        try StateStore(root: sb.root.path(percentEncoded: false), lease: nil)
    }

    static func core(_ store: StateStore) -> [String]? {
        guard case .object(let p)? = store.load(.personality) else { return nil }
        return p.array("core")?.compactMap(\.stringValue)
    }

    /// The seed as jarvis.py has it: the golden "literals" case holds `_PERSONALITY_SEED` dumped by
    /// Python (golden.py --check keeps it fresh).
    @Test func theGuardsLinesAreJarvisPysSeedLines() throws {
        let cases = try Golden.cases("m1_personality")
        let literals = try #require(cases.first { $0.name == "literals" })
        let json = try #require(literals.expected.string("seed_json"))
        guard case .object(let seed) = try PyJSON.loads(Data(json.utf8)) else {
            Issue.record("seed_json is not an object")
            return
        }
        let seedLines = seed.array("core")?.compactMap(\.stringValue)
        let python = try #require(seedLines)
        #expect(python.count == 8)
        #expect(PersonalityLogic.seedCore == python)
        #expect(PersonalityLogic.identityLine == python[0])
        #expect(PersonalityLogic.toneAndHumourLines == Array(python[1...2]))
        #expect(PersonalityLogic.identityLine.hasPrefix("Persona: J.A.R.V.I.S. from the Marvel films"))
        #expect(PersonalityLogic.toneAndHumourLines[0].hasPrefix("Tone:"))
        #expect(PersonalityLogic.toneAndHumourLines[1].hasPrefix("Humour:"))
    }

    @Test func aGenericRewriteKeepsHisIdentityToneAndHumour() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try Self.store(sb)
        try PersonalityLogic.learn("The user likes a dry joke", store: store, now: 1_000)
        #expect(PersonalityLogic.rewriteTool(Self.generic, store: store) == PersonalityLogic.rewriteDone)
        let lines = Self.generic.split(separator: "\n").map { String($0) + "." }
        #expect(Self.core(store) == [PersonalityLogic.identityLine] + PersonalityLogic.toneAndHumourLines + lines)
        // Learned notes survive, as in Python.
        guard case .object(let p)? = store.load(.personality) else {
            Issue.record("no personality.json")
            return
        }
        #expect(p.array("learned")?.count == 1)
    }

    @Test func theIdentityLineMovesToLine1Once() {
        let rewrite = ["Loyalty: steadfast.", PersonalityLogic.identityLine, "Humour: drier than ever."]
        #expect(PersonalityLogic.guardedCore(rewrite)
            == [PersonalityLogic.identityLine, "Loyalty: steadfast.", "Humour: drier than ever."])
        // Already first: unchanged.
        let first = [PersonalityLogic.identityLine, "Tone: warmer.", "Loyalty: steadfast."]
        #expect(PersonalityLogic.guardedCore(first) == first)
    }

    /// A rewrite that speaks of his humour, tone or butler manner keeps its own word on them.
    @Test(arguments: [
        "Tone: warmer, still precise.", "Humor: rarer, kinder.", "No jokes while the user works.",
        "Calls the user sir.", "A butler's discretion in all things.", "Sarcastic only when invited.",
        "Witty, but brief.", "Dry irony, sparingly.", "Deadpan delivery.",
    ])
    func aRewriteAboutHisMannerKeepsItsOwn(_ line: String) {
        let rewrite = ["Loyalty: steadfast.", line, "Crisis: calm."]
        #expect(PersonalityLogic.guardedCore(rewrite) == [PersonalityLogic.identityLine] + rewrite)
    }

    /// Words that only look like the manner words do not count: the seed's lines come back.
    @Test func lookalikeWordsDoNotCount() {
        let rewrite = ["Iron Man's assistant.", "Undertone of warmth.", "Desire to help.", "Witness to events."]
        #expect(PersonalityLogic.guardedCore(rewrite)
            == [PersonalityLogic.identityLine] + PersonalityLogic.toneAndHumourLines + rewrite)
    }

    @Test func theReplyTextAndTheLineRuleArePythons() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try Self.store(sb)
        // 2 and 13 lines are rejected and write nothing.
        #expect(PersonalityLogic.rewriteTool("one\ntwo", store: store) == PersonalityLogic.rewriteRejected)
        let thirteen = (1...13).map { "Trait \($0)" }.joined(separator: "\n")
        #expect(PersonalityLogic.rewriteTool(thirteen, store: store) == PersonalityLogic.rewriteRejected)
        #expect(store.load(.personality) == nil)
        // 12 lines are accepted; the guard's three lines come on top of them.
        let twelve = (1...12).map { "Trait \($0)" }.joined(separator: "\n")
        #expect(PersonalityLogic.rewriteTool(twelve, store: store) == PersonalityLogic.rewriteDone)
        #expect(Self.core(store)?.count == 15)
        #expect(Self.core(store)?.first == PersonalityLogic.identityLine)
    }

    @Test func resetYourPersonalityRestoresTheWholeSeed() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try Self.store(sb)
        _ = PersonalityLogic.rewriteTool(Self.generic, store: store)
        try PersonalityLogic.maybeLearn("Please reset your personality.", store: store, now: 2_000)
        #expect(store.load(.personality) == .object(PersonalityLogic.seed()))
        #expect(Self.core(store) == PersonalityLogic.seedCore)
    }

    /// The golden rewrites Python accepts: native writes Python's lines behind the seed's
    /// identity, Tone and Humour lines (none of the synthetic lines is about his manner), and
    /// replies as Python does.
    @Test(arguments: M1PersonalityTests.personaGuardCases.sorted())
    func theGoldenRewritesAreGuardedPythonLines(_ name: String) throws {
        let cases = try Golden.cases("m1_personality")
        let c = try #require(cases.first { $0.name == name })
        let step = try #require(c.input.array("steps")?.first?.objectValue)
        let want = try #require(c.expected.array("steps")?.first?.objectValue)
        #expect(step.string("op") == "rewrite_tool")
        let sb = try Sandbox()
        defer { sb.remove() }
        if let b64 = c.input.object("files_before")?.string("personality.json") {
            let before = try #require(Data(base64Encoded: b64))
            try before.write(to: sb.root.appending(path: "personality.json"))
        }
        let store = try Self.store(sb)
        let reply = PersonalityLogic.rewriteTool(step.object("args")?.string("core") ?? "", store: store)
        #expect(JSONValue.string(reply) == want.object("result")?["value"])
        let afterB64 = try #require(want.object("files_after")?.string("personality.json"))
        let after = try #require(Data(base64Encoded: afterB64))
        guard case .object(var python) = try PyJSON.loads(after) else {
            Issue.record("\(name): Python's file is not an object")
            return
        }
        let pythonLines = python.array("core")?.compactMap(\.stringValue)
        let pythonCore = try #require(pythonLines)
        let guarded = [PersonalityLogic.identityLine] + PersonalityLogic.toneAndHumourLines + pythonCore
        #expect(PersonalityLogic.guardedCore(pythonCore) == guarded)
        // Every other key is Python's.
        python["core"] = .array(guarded.map { .string($0) })
        #expect(store.load(.personality) == .object(python))
    }
}

/// DEV-P5-01 in the golden suites whose scenarios rewrite the core (m1_prompt, m1_persona_llm):
/// native must equal Python with the rewrite's lines guarded, and Python's own bytes and
/// prompts are its verdict, a known issue.
enum PersonaGuardGolden {
    /// Python's personality.json bytes, with the core guarded when it is the rewrite's lines.
    static func personalityBytes(_ python: Data?, rewritten: [String]?) -> Data? {
        guard let python, let rewritten, case .object(var p)? = try? PyJSON.loads(python),
              p.array("core")?.compactMap(\.stringValue) == rewritten else { return python }
        p["core"] = .array(PersonalityLogic.guardedCore(rewritten).map { .string($0) })
        return Data(PyJSON.dumps(.object(p), indent: 1).utf8)
    }

    /// Python's system prompt, with the rewritten core's PERSONALITY sentence guarded.
    static func prompt(_ python: String, rewritten: [String]?) -> String {
        guard let rewritten else { return python }
        return python.replacingOccurrences(
            of: "PERSONALITY — " + rewritten.joined(separator: " "),
            with: "PERSONALITY — " + PersonalityLogic.guardedCore(rewritten).joined(separator: " "),
            options: .literal)
    }
}
