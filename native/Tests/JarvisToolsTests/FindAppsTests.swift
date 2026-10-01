import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// T5.8: find_apps against m5_apps (G7). The bundles the REAL `_enrich_app_index` read are
/// rebuilt in a temporary folder from the fixture's Info.plist bytes, and the canned mdfind
/// listing is replayed through a fake runner; nothing lists or reads the real /Applications.
@Suite("FindAppsTests")
struct FindAppsTests {
    static let suite = "m5_apps"

    /// One fixture set rebuilt on disk: its listing, index and enrichment, as Python saw them.
    struct Set {
        let mdfind: String
        let index: [AppEntry]
        let meta: [String: [String]]?
    }

    /// Writes every set's bundles under `root` (standing in for ${JARVIS_HOME}).
    static func build(_ root: URL) throws -> [String: Set] {
        let token = "${JARVIS_HOME}"
        let base = root.path(percentEncoded: false).hasSuffix("/") ? String(root.path(percentEncoded: false).dropLast())
            : root.path(percentEncoded: false)
        func local(_ s: String) -> String { s.replacingOccurrences(of: token, with: base) }
        var sets: [String: Set] = [:]
        for c in try M5Fixture.cases(Self.suite) where c.name.hasPrefix("setup/") {
            for bundle in try #require(c.input["bundles"]?.arrayValue) {
                let b = try #require(bundle.objectValue)
                let path = local(try #require(b.string("path")))
                let contents = URL(fileURLWithPath: path).appending(path: "Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                if let hex = b.string("plist_hex") {
                    let bytes = try #require(ClipboardToolTests.bytes(hex: hex))
                    try bytes.write(to: contents.appending(path: "Info.plist"))
                }
            }
            let index = try #require(c.expected["index"]?.arrayValue).map { row in
                let r = (row.arrayValue ?? []).compactMap(\.stringValue)
                return AppEntry(low: r[0], name: r[1], path: local(r[2]))
            }
            var meta: [String: [String]]?
            if let m = c.expected.object("meta") {
                meta = Dictionary(uniqueKeysWithValues: m.members.map { ($0.key, ($0.value.arrayValue ?? []).compactMap(\.stringValue)) })
            }
            sets[String(c.name.dropFirst("setup/".count))] = Set(mdfind: local(try #require(c.input.string("mdfind"))),
                                                                 index: index, meta: meta)
        }
        return sets
    }

    static func withSets(_ body: ([String: Set]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(try build(root))
    }

    @Test func fixtureHoldsEveryCase() throws {
        let cases = try M5Fixture.cases(Self.suite)
        #expect(cases.count == 168)
        #expect(cases.filter { $0.name.hasPrefix("find/") }.count == 116)
    }

    /// build_app_index's line rules and _enrich_app_index over the same Info.plist bytes.
    @Test func indexAndEnrichmentMatchPython() async throws {
        try await Self.withSets { sets in
            #expect(sets.keys.sorted() == ["crash", "crash_list", "crash_none", "main"])
            for (name, set) in sets {
                #expect(AppKinds.index(fromMdfind: set.mdfind) == set.index, "\(name)")
                #expect(AppKinds.enrich(set.index, load: PlistValue.load) == set.meta, "\(name)")
            }
            // A string URL-type entry, a plist with no root object and an array root each make
            // the real enrichment raise, so nothing is enriched.
            for name in ["crash", "crash_none", "crash_list"] {
                #expect(sets[name]?.meta == nil, "\(name)")
            }
        }
    }

    @Test func kindWordAndNameKindsMatchPython() throws {
        for c in try M5Fixture.cases(Self.suite) {
            if c.name.hasPrefix("kind_word/") {
                #expect(AppKinds.kindWord(c.input.string("text")) == c.expected.string("kind"), "\(c)")
            } else if c.name.hasPrefix("name_kinds/") {
                let kinds = (c.expected["kinds"]?.arrayValue ?? []).compactMap(\.stringValue)
                let name = c.input.string("name") ?? ""
                #expect(AppKinds.pySorted(Array(AppKinds.nameKinds(Py.lower(name)))) == kinds, "\(c)")
            }
        }
    }

    /// Every _find_apps reply, with the kinds in "(...)" sorted (Python's are in set order).
    @Test func findAppsMatchesPython() async throws {
        try await Self.withSets { sets in
            for c in try M5Fixture.cases(Self.suite) where c.name.hasPrefix("find/") {
                let setName = try #require(c.input.string("set"))
                let set = sets[setName]
                var catalog = AppCatalog(entries: set?.index ?? [], meta: [:])
                if c.input["enriched"] == .bool(true) { catalog.meta = set?.meta ?? [:] }
                let browser = c.input.string("default_browser") ?? ""
                let text = await AppKinds.findApps(try #require(c.input.string("query")), catalog,
                                                   defaultBrowser: { browser })
                #expect(text == c.expected.string("canonical"), "\(c)")
            }
        }
    }

    /// The tool end to end: the fake mdfind listing, the rebuilt bundles, one index build for
    /// many calls, and execute_tool's argument handling.
    @Test func findAppsThroughTheGateway() async throws {
        try await Self.withSets { sets in
            let main = try #require(sets["main"])
            let runner = FakeRunner(stdout: main.mdfind)
            let platform = ToolPlatform.fake(apps: AppIndex(runner: runner), browser: StubBrowser(name: "Safari"))
            let sandbox = try ToolCoreSandbox()
            defer { sandbox.remove() }
            let gateway = await M5Fixture.gateway(platform, sandbox: sandbox)
            let wanted = try M5Fixture.cases(Self.suite).filter { $0.name.hasPrefix("find/main/enriched/Safari/") }
            #expect(wanted.count == 28)
            for c in wanted {
                let args = JSONObject([.init(key: "query", value: .string(try #require(c.input.string("query"))))])
                let turn = TurnContext(channel: .voice)
                let result = await gateway.call("find_apps", args, turn: turn, origin: .model(.claude))
                #expect(result.text == c.expected.string("canonical"), "\(c)")
                #expect(!result.isError && result.record.outcome == .ran, "\(c)")
                #expect(await turn.tainted == false, "\(c)")
            }
            #expect(runner.calls == [AppIndex.query], "one mdfind for every call")
        }
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        for c in try M5Fixture.cases(Self.suite) where c.name.hasPrefix("args/") {
            let args = try #require(c.input.object("args"))
            let result = await gateway.call("find_apps", args, turn: TurnContext(channel: .text), origin: .model(.local))
            #expect(result.text == c.expected.string("text"), "\(c)")
        }
    }

    /// A listing that fails answers from an empty index and is tried again on the next call.
    @Test func failedListingIsRetried() async throws {
        let ok = ProcessOutput(stdout: Data("/Applications/Arc.app\n".utf8), stderr: Data(), status: 0,
                               timedOut: false, truncated: false)
        let late = ProcessOutput(stdout: Data(), stderr: Data(), status: -9, timedOut: true, truncated: false)
        let runner = FakeRunner([nil, late, ok])
        let index = AppIndex(runner: runner, loadPlist: { _ in nil })
        #expect(await index.catalog() == AppCatalog())
        #expect(await index.catalog() == AppCatalog())
        let built = await index.catalog()
        #expect(built.entries == [AppEntry(low: "arc", name: "Arc", path: "/Applications/Arc.app")])
        #expect(built.meta == ["arc": ["browser"]])
        #expect(await index.catalog() == built)
        #expect(runner.calls.count == 3)
    }

    @Test func registeredSchemaIsTheCatalogEntry() async throws {
        let catalog = try #require(ToolCatalog.tools.first { $0.name == "find_apps" })
        #expect(FindApps.schema == catalog)
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        #expect(await gateway.toolList().first { $0.name == "find_apps" } == catalog)
    }
}
