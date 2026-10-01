import Darwin
import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// G9's write, delete and move cases (golden suite m5_file_mutations, recorded from the real
/// Python bodies) replayed through the gateway on real temp trees: the in-home tree, which is
/// the session's home, under ~/Library/Caches/jarvis-golden/<uuid>, and the outside tree under
/// $SHARED/jarvis-golden/<uuid> (G9: the Shared folder of the local Users directory). Only the
/// trasher is faked, as the suite fakes
/// _to_trash, and gated actions are confirmed and run, as the suite runs _pending_action.
@Suite("FileMutationsTests")
struct FileMutationsTests {
    static let suite = "m5_file_mutations"

    @Test func fixtureHoldsEveryCase() throws {
        let cases = try M5Fixture.cases(Self.suite)
        #expect(cases.count == 28)
        let tools = Dictionary(grouping: cases) { $0.input.string("tool") ?? "" }.mapValues(\.count)
        #expect(tools == ["write_file": 6, "delete_file": 10, "move_file": 12])
        #expect(cases.filter { $0.expected.string("deviation") != nil }.map(\.name) == ["move/trailing_slash"])
        #expect(cases.filter { $0.input["exdev"] == .bool(true) }.count == 3)
    }

    @Test func goldenCasesOnTempTrees() async throws {
        for c in try M5Fixture.cases(Self.suite) {
            let trees = try GoldenTrees()
            defer { trees.remove() }
            try trees.build(c.input["setup"]?.arrayValue ?? [])
            let files = SandboxedFiles(roots: trees.roots, trashOK: c.input["trash_ok"] == .bool(true),
                                       crossDevice: c.input["exdev"] == .bool(true))
            let session = FileMutationSession(files: files, home: trees.home, cwd: trees.home)
            let gate = ConfirmationGate()
            let gateway = ToolGateway(confirmationGate: gate, log: { _ in })
            await gateway.register(WriteFile(session: session))
            await gateway.register(MoveFile(session: session))
            await gateway.register(DeleteFile(session: session))
            let tool = try #require(c.input.string("tool"))
            let args = trees.resolve(try #require(c.input.object("args")))
            let turn = TurnContext(channel: .voice)

            let first = await gateway.call(tool, args, turn: turn, origin: .ui)
            var text = first.text
            var desc: String?
            if first.record.outcome == .gated {
                desc = await gate.pending?.desc
                guard case .handled(let ran) = await gate.consume("confirm", via: .voice, runIn: turn) else {
                    Issue.record("\(c.name): the gated action did not run")
                    continue
                }
                text = ran
            }
            let deviation = c.expected.string("deviation") != nil
            #expect(desc.map(trees.tokens) == c.expected.string(deviation ? "native_gate" : "gate"), "\(c.name)")
            #expect(trees.tokens(text) == c.expected.string(deviation ? "native_text" : "text"), "\(c.name)")
            if deviation {
                // DEV-M5-04 (proposed): native names the folder; Python's basename of "dir/" is "".
                withKnownIssue("DEV-M5-04: Python's reply names the trailing-slash paths as \"\"") {
                    #expect(desc.map(trees.tokens) == c.expected.string("gate"))
                    #expect(trees.tokens(text) == c.expected.string("text"))
                }
            }
            if let again = c.expected.string("repeat") {
                // _written_this_session: the confirmed write makes the same overwrite instant.
                let second = await gateway.call(tool, args, turn: turn, origin: .ui)
                #expect(second.record.outcome == .ran, "\(c.name)")
                #expect(trees.tokens(second.text) == again, "\(c.name)")
            }
            let tree = try #require(c.expected["tree"]?.objectValue)
            #expect(try trees.listing() == Dictionary(uniqueKeysWithValues: tree.keys.map { ($0, tree[$0]!) }), "\(c.name)")
        }
    }

    /// The three bodies are registered with their generated catalog entries (m3_tool_schemas).
    @Test func registeredSchemasAreTheCatalogEntries() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let listed = await M5Fixture.gateway(.fake(), sandbox: sandbox).toolList()
        for (name, schema) in [(WriteFile.name, WriteFile.schema), (MoveFile.name, MoveFile.schema),
                               (DeleteFile.name, DeleteFile.schema)] {
            let catalog = try #require(ToolCatalog.tools.first { $0.name == name })
            #expect(schema == catalog)
            #expect(listed.first { $0.name == name } == catalog)
        }
    }

    @Test func treesLiveUnderTheG9RootsAndAreRemoved() throws {
        let trees = try GoldenTrees()
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        #expect(trees.home.hasPrefix(caches.path(percentEncoded: false)))
        #expect(PathPolicy.inHome(trees.home + "/a", home: trees.home, cwd: "/"))
        #expect(!PathPolicy.inHome(trees.outside + "/a", home: trees.home, cwd: "/"))
        trees.remove()
        #expect(!FileManager.default.fileExists(atPath: trees.homeRoot))
        #expect(!FileManager.default.fileExists(atPath: trees.outsideRoot))
    }

    @Test func pathsOutsideTheTreesAreNeverTouched() throws {
        let trees = try GoldenTrees()
        defer { trees.remove() }
        let files = SandboxedFiles(roots: trees.roots, trashOK: true, crossDevice: false)
        withKnownIssue("the sandbox records any mutation outside the temp trees") {
            #expect(throws: FileMutationError.self) { try files.write(trees.homeRoot + "-elsewhere/a.txt", content: "x") }
        }
        #expect(!FileManager.default.fileExists(atPath: trees.homeRoot + "-elsewhere"))
    }
}

/// G9's two roots, removed afterwards. Python's suite lists them as "h/…" and "o/…".
struct GoldenTrees {
    let homeRoot: String
    let outsideRoot: String
    var home: String { homeRoot + "/h" }
    var outside: String { outsideRoot + "/o" }
    var roots: [String] { [homeRoot, outsideRoot] }

    struct NoRoot: Error {}

    init() throws {
        let id = UUID().uuidString
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let users = FileManager.default.urls(for: .userDirectory, in: .localDomainMask).first else { throw NoRoot() }
        homeRoot = caches.appending(path: "jarvis-golden").appending(path: id).path(percentEncoded: false)
        outsideRoot = users.appending(path: "Shared").appending(path: "jarvis-golden").appending(path: id)
            .path(percentEncoded: false)
        for dir in [home, outside] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    /// Removes this instance's two UUID folders only. The shared jarvis-golden parents stay:
    /// removing one when it looked empty raced another test creating its own folder in it.
    func remove() {
        for root in roots {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    /// The suite's setup rows: `["h/dir/", null]`, `["h/a.txt", "text"]`, `["h/link", {"link": "dir"}]`.
    func build(_ rows: [JSONValue]) throws {
        for row in rows {
            guard let pair = row.arrayValue, pair.count == 2, let rel = pair[0].stringValue else { throw NoRoot() }
            let path = self.path(rel)
            if rel.hasSuffix("/") {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            if let link = pair[1].objectValue?.string("link") {
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: link)
            } else {
                try Data((pair[1].stringValue ?? "").utf8).write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func path(_ rel: String) -> String {
        let trimmed = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
        if trimmed.hasPrefix("h/") { return home + "/" + trimmed.dropFirst(2) }
        return outside + "/" + trimmed.dropFirst(2)
    }

    /// The suite's "@HOME@" and "@OUTSIDE@" tokens, in and out.
    func resolve(_ args: JSONObject) -> JSONObject {
        JSONObject(args.keys.map { key in
            let value = args[key]!
            guard let s = value.stringValue else { return .init(key: key, value: value) }
            return .init(key: key, value: .string(s.replacingOccurrences(of: "@HOME@", with: home)
                .replacingOccurrences(of: "@OUTSIDE@", with: outside)))
        })
    }

    func tokens(_ text: String) -> String {
        text.replacingOccurrences(of: home, with: "@HOME@").replacingOccurrences(of: outside, with: "@OUTSIDE@")
    }

    /// The tree as the suite records it: "x/" → null, a link → {"link": target}, a file → hex.
    func listing() throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        func walk(_ dir: String, _ rel: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
                let path = dir + "/" + name, key = rel + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                    out[key] = .object(JSONObject([.init(key: "link", value: .string(target))]))
                case S_IFDIR:
                    out[key + "/"] = .null
                    try walk(path, key)
                default:
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                    out[key] = .string(bytes.map { String(format: "%02x", $0) }.joined())
                }
            }
        }
        try walk(home, "h")
        try walk(outside, "o")
        return out
    }
}

/// The live file operations confined to the temp trees: any mutation outside them is
/// recorded as an issue and refused. The trasher is faked as the Python suite fakes it (the
/// item is removed when trashing "succeeds"), and the two system paths the suite reports as
/// existing are reported the same way, never touched.
struct SandboxedFiles: FileMutating {
    let roots: [String]
    let trashOK: Bool
    let live: LiveFileMutations

    init(roots: [String], trashOK: Bool, crossDevice: Bool) {
        self.roots = roots
        self.trashOK = trashOK
        var live = LiveFileMutations()
        if crossDevice { live.rename = { _, _ in errno = EXDEV; return -1 } }
        self.live = live
    }

    func exists(_ p: String) -> Bool { p == "/etc/hosts" || p == "/private/tmp/x" || live.exists(p) }
    func isDir(_ p: String) -> Bool { live.isDir(p) }
    func trash(_ p: String) -> Bool {
        guard inside(p) else { Issue.record("trash outside the temp trees: \(p)"); return false }
        if trashOK { try? FileManager.default.removeItem(atPath: p) }
        return trashOK
    }
    func hardDelete(_ p: String) throws { try guarded(p); try live.hardDelete(p) }
    func write(_ p: String, content: String) throws { try guarded(p); try live.write(p, content: content) }
    func move(_ s: String, _ d: String) throws { try guarded(s); try guarded(d); try live.move(s, d) }

    private func inside(_ p: String) -> Bool { roots.contains { p.hasPrefix($0 + "/") } }
    private func guarded(_ p: String) throws {
        guard inside(p) else {
            Issue.record("mutation outside the temp trees: \(p)")
            throw FileMutationError(description: "outside the temp trees")
        }
    }
}
