import Darwin
import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// T5.11: read_file against m5_read_file (G9's read half), what the REAL `execute_tool` returned
/// for a tree it built in its sandbox home. The tree is rebuilt byte for byte in a temporary
/// home; `~name` lookups go to a stub, never the real passwd database, and nothing reads ~/jarvis.
@Suite("ReadFileToolTests")
struct ReadFileToolTests {
    static let suite = "m5_read_file"
    static let token = "${JARVIS_HOME}"

    /// The fixture's tree under a fresh temporary home, which `body` gets as a path.
    static func withTree(_ body: (String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = String(root.path(percentEncoded: false).trimmingSuffix("/"))
        let setup = try #require(try M5Fixture.cases(Self.suite).first { $0.name == "tree" })
        for node in try #require(setup.input["tree"]?.arrayValue) {
            let n = try #require(node.arrayValue)
            let rel = try #require(n[0].stringValue), kind = try #require(n[1].stringValue)
            let path = home + "/" + rel
            let payload = n[2].stringValue ?? ""
            switch kind {
            case "file":
                let bytes = try #require(ClipboardToolTests.bytes(hex: payload))
                try bytes.write(to: URL(fileURLWithPath: path))
            case "dir":
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            default:
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: payload)
            }
        }
        let locked = (setup.input["locked"]?.arrayValue ?? []).compactMap(\.stringValue).map { home + "/" + $0 }
        for path in locked { #expect(chmod(path, 0) == 0) }
        defer {
            for path in locked { _ = chmod(path, 0o600) }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(home)
    }

    static func localize(_ value: JSONValue, _ home: String) -> JSONValue {
        if case .string(let s) = value { return .string(s.replacingOccurrences(of: token, with: home)) }
        return value
    }

    @Test func fixtureHoldsEveryCase() throws {
        let cases = try M5Fixture.cases(Self.suite)
        #expect(cases.count == 52)
        #expect(cases.filter { $0.name.hasPrefix("read/") }.count == 51)
    }

    /// Every case through the gateway: Python's exact text, and the turn tainted afterwards,
    /// whatever the outcome (read_file is in TaintPolicy.untrusted, as in UNTRUSTED_TOOLS).
    @Test func goldenCasesThroughTheGatewayTaintTheTurn() async throws {
        try await Self.withTree { home in
            let sandbox = try ToolCoreSandbox()
            defer { sandbox.remove() }
            let gateway = await M5Fixture.gateway(.fake(home: home), sandbox: sandbox)
            for c in try M5Fixture.cases(Self.suite) where c.name.hasPrefix("read/") {
                let raw = try #require(c.input.object("args"))
                let args = JSONObject(raw.members.map { .init(key: $0.key, value: Self.localize($0.value, home)) })
                let want = try #require(c.expected.string("text")).replacingOccurrences(of: Self.token, with: home)
                let turn = TurnContext(channel: .voice)
                let result = await gateway.call("read_file", args, turn: turn, origin: .model(.claude))
                #expect(Py.eq(result.text, want), "\(c): \(result.text.prefix(160))")
                #expect(!result.isError && result.record.outcome == .ran, "\(c)")
                #expect(await turn.tainted, "\(c): read_file must taint the turn")
            }
        }
    }

    @Test func executorAfterReadFileIsBlocked() async throws {
        try await Self.withTree { home in
            let sandbox = try ToolCoreSandbox()
            defer { sandbox.remove() }
            let gateway = await M5Fixture.gateway(.fake(home: home), sandbox: sandbox)
            let turn = TurnContext(channel: .voice)
            _ = await gateway.call("read_file", JSONObject([.init(key: "path", value: .string("~/hello.txt"))]),
                                   turn: turn, origin: .model(.claude))
            let blocked = await gateway.call("run_command", JSONObject([.init(key: "command", value: .string("ls"))]),
                                             turn: turn, origin: .model(.claude))
            #expect(blocked.record.outcome == .blockedTaint)
        }
    }

    /// `~name` uses the passwd home with its trailing "/" dropped; no such user leaves the path.
    @Test func expanduserForOtherUsers() {
        let tool = ReadFile(home: "/Volumes/Homes/me/", userHome: { $0 == "alice" ? "/Volumes/Homes/alice/" : nil })
        #expect(tool.expanduser("~alice/notes.txt") == "/Volumes/Homes/alice/notes.txt")
        #expect(tool.expanduser("~alice") == "/Volumes/Homes/alice")
        #expect(tool.expanduser("~bob/x") == "~bob/x")
        #expect(tool.expanduser("~") == "/Volumes/Homes/me")
        #expect(tool.expanduser("~/") == "/Volumes/Homes/me/")
        #expect(ReadFile(home: "/", userHome: { _ in nil }).expanduser("~") == "/")
        #expect(tool.expanduser("a~/b") == "a~/b")
        #expect(tool.expanduser("~a\u{0}b/x") == nil)
    }

    /// Feeding the decoder one byte at a time gives what one feed gives, for every split.
    @Test func decoderIsIndependentOfChunking() {
        var bytes = Data("a\r\nb\r".utf8)
        bytes.append(contentsOf: [0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80, 0xE2, 0x28, 0xFF, 0xED, 0xA0, 0x80, 0x0A, 0x0D])
        bytes.append(contentsOf: Data("\nz".utf8))
        bytes.append(contentsOf: [0xF0, 0x9F])
        var whole = IgnoringUTF8Decoder(limit: 4000)
        whole.feed(ArraySlice(bytes))
        whole.finish()
        #expect(whole.text == "a\nb\n€😀(\n\nz")
        for split in 0...bytes.count {
            var parts = IgnoringUTF8Decoder(limit: 4000)
            parts.feed(ArraySlice(bytes.prefix(split)))
            parts.feed(ArraySlice(bytes.dropFirst(split)))
            parts.finish()
            #expect(parts.text == whole.text, "split at \(split)")
        }
        var bytewise = IgnoringUTF8Decoder(limit: 4000)
        for b in bytes { bytewise.feed([b][...]) }
        bytewise.finish()
        #expect(bytewise.text == whole.text)
        var limited = IgnoringUTF8Decoder(limit: 3)
        limited.feed(ArraySlice(bytes))
        #expect(limited.full && limited.text == "a\nb")
    }

    /// The reply cap: an error that echoes a huge path twice stays under 1 MiB.
    @Test func hugePathEchoIsCapped() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        let path = "/nonexistent/" + String(repeating: "\u{01}", count: 900_000)
        let result = await gateway.call("read_file", JSONObject([.init(key: "path", value: .string(path))]),
                                        turn: TurnContext(channel: .text), origin: .model(.local))
        #expect(result.text.hasPrefix("Could not read /nonexistent/"))
        #expect(result.text.utf8.count <= ReplyCap.bytes)
        #expect(result.text.unicodeScalars.count <= ReplyCap.scalars)
        let uncapped = ReadFile.contents(of: path)
        #expect(uncapped.utf8.count > 4 << 20, "without the cap this reply would pass the MCP limit")
        #expect(ReplyCap.apply("short") == "short")
        #expect(ReplyCap.apply(String(repeating: "😀", count: 300_000)).unicodeScalars.count == 262_144)
    }

    @Test func registeredSchemaIsTheCatalogEntry() async throws {
        let catalog = try #require(ToolCatalog.tools.first { $0.name == "read_file" })
        #expect(ReadFile.schema == catalog)
        #expect(Capped<ReadFile>.schema == catalog && Capped<ReadFile>.name == "read_file")
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        #expect(await gateway.toolList().first { $0.name == "read_file" } == catalog)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> Substring {
        hasSuffix(suffix) ? dropLast(suffix.count) : self[...]
    }
}
