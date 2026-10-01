import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// P6, DEV-P6-01 (proposed): his persona is compiled in. The prompt's core is the seed's 8 lines
/// (`PersonalityLogic.seedCore`, which `PersonaGuardTests.theGuardsLinesAreJarvisPysSeedLines`
/// proves are jarvis.py's `_PERSONALITY_SEED`), then each of personality.json's core lines that is
/// not one of them, then the learned notes as before. Python shows the file's core alone, so a
/// rewritten or hand-edited file could swap J.A.R.V.I.S. for anyone.
@Suite("P6 the persona is a compiled-in base layer")
struct PersonaBaseTests {
    static func store(_ sb: Sandbox) throws -> StateStore {
        try StateStore(root: sb.root.path(percentEncoded: false), lease: nil)
    }

    static let seedSentence = " PERSONALITY — " + PersonalityLogic.seedCore.joined(separator: " ")

    @Test func theBaseLayerIsTheSeedThenTheFilesOtherLines() {
        #expect(PersonalityLogic.promptCore([]) == PersonalityLogic.seedCore)
        #expect(PersonalityLogic.promptCore(PersonalityLogic.seedCore) == PersonalityLogic.seedCore)
        let added = "Gardening: knows the user's roses by name."
        // A seed line the file repeats, reorders or keeps after a guarded rewrite appears once.
        let file = [added, PersonalityLogic.seedCore[3], PersonalityLogic.identityLine, "Pace: unhurried."]
        #expect(PersonalityLogic.promptCore(file) == PersonalityLogic.seedCore + [added, "Pace: unhurried."])
        // A near copy of a seed line is the user's own line and is kept.
        let edited = PersonalityLogic.identityLine.replacingOccurrences(of: "dryly", with: "warmly")
        #expect(PersonalityLogic.promptCore([edited]) == PersonalityLogic.seedCore + [edited])
    }

    /// No file, unreadable bytes, an empty core or a file that is not an object: the seed, as
    /// Python's personality_load gives.
    @Test(arguments: [nil, "{\"core\": [\"half", "", "[1, 2, 3]", "{\"core\": [], \"learned\": []}"] as [String?])
    func aMissingOrUnreadableFileKeepsHisCharacter(_ bytes: String?) throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        if let bytes { try sb.write("personality.json", bytes) }
        let context = try PersonalityLogic.context(store: try Self.store(sb))
        #expect(context.hasPrefix(Self.seedSentence + " Your personality lives in "))
    }

    /// A core written straight to the file (a Python-era `personality_rewrite`, or a hand edit)
    /// cannot remove him: the seed comes first and the file's lines follow.
    @Test func aRewrittenFileKeepsHisCharacter() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let generic = ["Helpful: answers every question clearly.", "Friendly: warm and approachable.",
                       "Concise: keeps replies short."]
        let file = JSONObject([.init(key: "core", value: .array(generic.map { .string($0) })),
                               .init(key: "learned", value: .array([]))])
        try sb.write("personality.json", PyJSON.dumps(.object(file), indent: 1))
        let context = try PersonalityLogic.context(store: try Self.store(sb))
        #expect(context.hasPrefix(Self.seedSentence + " " + generic.joined(separator: " ") + " Your personality"))
        // The file is read, not rewritten.
        #expect(try sb.read("personality.json") == PyJSON.dumps(.object(file), indent: 1))
    }

    /// The whole turn prompt, through CoreState: a generic core on disk still gives his 8 lines.
    @Test func theTurnPromptKeepsHisCharacter() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let file = JSONObject([.init(key: "core", value: .array([.string("Generic: a plain assistant.")])),
                               .init(key: "learned", value: .array([]))])
        try sb.write("personality.json", PyJSON.dumps(.object(file), indent: 1))
        let core = CoreState(store: try Self.store(sb), clock: ManualClock(1_000), research: RecordingCounter(),
                             frontApp: FixedFrontApp())
        let prompt = try await core.beginTurn("What's on today?", online: true)
        #expect(prompt.system.contains(Self.seedSentence + " Generic: a plain assistant. Your personality lives in "))
        #expect(prompt.claudeSystem.contains(Self.seedSentence))
    }

    /// When the file's core is the seed (true of this install today), the context is Python's
    /// byte for byte: the golden `context_seed` case is jarvis.py's personality_context() with
    /// the seed, and the file here is the seed as Python writes it.
    @Test func theSeedFileIsPythonsByteForByte() throws {
        let cases = try Golden.cases(M1PersonalityTests.suite)
        let seedCase = try #require(cases.first { $0.name == "context_seed" })
        let step = try #require(seedCase.expected.array("steps")?.first?.objectValue)
        let python = try #require(step.object("result")?.string("value"))
        let sb = try Sandbox()
        defer { sb.remove() }
        try sb.write("personality.json", PyJSON.dumps(.object(PersonalityLogic.seed()), indent: 1))
        let store = try Self.store(sb)
        var root = sb.root.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        let want = python.replacingOccurrences(of: PersonaGolden.homeToken, with: root, options: .literal)
        #expect(Array(try PersonalityLogic.context(store: store).utf8) == Array(want.utf8))
    }

    /// Outside the DEV-P6-01 cases (and the earlier deviations' own), every golden case equals
    /// Python's verdict with no adjustment: the base layer changes only cores that are not the seed.
    @Test func everyOtherGoldenCaseIsPythonsUnadjusted() async throws {
        let known = M1PersonalityTests.noteCutCases.union(M1PersonalityTests.personaGuardCases)
            .union(M1PersonalityTests.personaBaseCases)
        var checked = 0
        for c in try Golden.cases(M1PersonalityTests.suite) where !known.contains(c.name) {
            for m in try M1PersonalityTests.check(c, baseLayer: false) { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            checked += 1
        }
        let promptKnown = M1PromptGoldenTests.personaGuardCases.union(M1PromptGoldenTests.personaBaseCases)
        for c in try Golden.cases(M1PromptGoldenTests.suite) where !promptKnown.contains(c.name) && c.name != "system_prompt" {
            for m in try await M1PromptGoldenTests.scenario(c, baseLayer: false) {
                Issue.record(Comment(rawValue: "\(c.name): \(m)"))
            }
            checked += 1
        }
        #expect(checked >= 100)
    }

    /// The adjustment itself: Python's sentence for a non-seed core gains the seed in front, and
    /// a seed or missing core is left alone.
    @Test func theGoldenAdjustmentOnlyAddsTheSeed() throws {
        let tail = " Your personality lives in X and is YOURS to author."
        let custom = ["Synthetic trait: calm.", "Synthetic trait: brisk."]
        let file = JSONObject([.init(key: "core", value: .array(custom.map { .string($0) }))])
        let bytes = Data(PyJSON.dumps(.object(file), indent: 1).utf8)
        let python = " PERSONALITY — " + custom.joined(separator: " ") + tail
        #expect(PersonaBaseGolden.contextValue(python, pythonFile: bytes)
            == Self.seedSentence + " " + custom.joined(separator: " ") + tail)
        #expect(PersonaBaseGolden.contextValue(Self.seedSentence + tail, pythonFile: nil) == Self.seedSentence + tail)
        let seedBytes = Data(PyJSON.dumps(.object(PersonalityLogic.seed()), indent: 1).utf8)
        #expect(PersonaBaseGolden.contextValue(Self.seedSentence + tail, pythonFile: seedBytes) == Self.seedSentence + tail)
        #expect(PersonaBaseGolden.prompt("A." + python, pythonFile: bytes)
            == "A." + Self.seedSentence + " " + custom.joined(separator: " ") + tail)
    }
}

/// DEV-P6-01 in the golden suites: native must equal Python with Python's core made native's
/// (`PersonalityLogic.promptCore`), where Python's core is the one its personality_load read,
/// the step's personality.json afterwards (context and the turn's head never change the core
/// after reading it).
enum PersonaBaseGolden {
    /// What Python's `" ".join(core)` joined, when personality_load returns the file: a dict with
    /// a truthy core, read as a list of str, a str's code points or a dict's keys. Nil when Python
    /// gives the seed or would raise.
    static func pythonCore(_ file: Data?) -> [String]? {
        guard let file, case .object(let p)? = try? PyJSON.loads(file), let core = p["core"], core.pyTruthy else {
            return nil
        }
        switch core {
        case .array(let a):
            let lines = a.compactMap(\.stringValue)
            return lines.count == a.count ? lines : nil
        case .string(let s): return s.unicodeScalars.map { String($0) }
        case .object(let o): return o.keys
        default: return nil
        }
    }

    /// Python's personality_context() value with its leading core sentence made native's.
    static func contextValue(_ python: String, pythonFile: Data?) -> String {
        guard let core = pythonCore(pythonFile) else { return python }
        let old = Array((" PERSONALITY — " + core.joined(separator: " ")).unicodeScalars)
        let scalars = Array(python.unicodeScalars)
        guard scalars.starts(with: old) else { return python }
        var out = String.UnicodeScalarView(" PERSONALITY — ".unicodeScalars)
        out.append(contentsOf: PersonalityLogic.promptCore(core).joined(separator: " ").unicodeScalars)
        out.append(contentsOf: scalars[old.count...])
        return String(out)
    }

    /// Python's captured system prompt with its PERSONALITY sentence's core made native's.
    static func prompt(_ python: String, pythonFile: Data?) -> String {
        guard let core = pythonCore(pythonFile) else { return python }
        return python.replacingOccurrences(
            of: "PERSONALITY — " + core.joined(separator: " "),
            with: "PERSONALITY — " + PersonalityLogic.promptCore(core).joined(separator: " "),
            options: .literal)
    }

    /// `PersonaGolden.run`'s adjustment: a `context` step's value, with Python's file afterwards.
    static func adjust(_ op: String, _ result: JSONObject, _ filesAfter: JSONObject) -> JSONObject {
        guard op == "context", let python = result.string("value") else { return result }
        var r = result
        let file = filesAfter.string("personality.json").flatMap { Data(base64Encoded: $0) }
        r["value"] = .string(contextValue(python, pythonFile: file))
        return r
    }
}

private struct FixedFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "Finder" }
}
