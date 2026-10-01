import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// T5.6: read_clipboard against m5_clipboard, what the REAL `execute_tool("read_clipboard")`
/// returned for canned pbpaste bytes. The fake pasteboard hands the Swift side the same bytes;
/// no test reads the live pasteboard.
@Suite("ClipboardToolTests")
struct ClipboardToolTests {
    static let suite = "m5_clipboard"

    static func bytes(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    static func data(_ c: M5Fixture.Case) throws -> Data? {
        guard let hex = c.input.string("pbpaste_hex") else { return nil }
        return try #require(bytes(hex: hex))
    }

    @Test func fixtureHoldsEveryCase() throws {
        let cases = try M5Fixture.cases(Self.suite)
        #expect(cases.count == 24)
        #expect(cases.filter { $0.input["pbpaste_hex"] == .null }.map(\.name) == ["clipboard/no_plain_text"])
    }

    @Test func goldenCasesThroughTheReply() throws {
        for c in try M5Fixture.cases(Self.suite) {
            let want = try #require(c.expected.string("text"))
            let got = ReadClipboard.reply(try Self.data(c))
            #expect(Py.eq(got, want), "\(c): \(Py.len(got)) vs \(Py.len(want)) code points")
        }
    }

    /// Through the gateway: the reply, then the turn is tainted, so an executor that follows
    /// on the same turn is refused (TaintPolicy.untrusted, as Python's UNTRUSTED_TOOLS).
    @Test func goldenCasesThroughTheGatewayTaintTheTurn() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        for c in try M5Fixture.cases(Self.suite) {
            let clipboard = FakeClipboard(try Self.data(c))
            let gateway = await M5Fixture.gateway(.fake(clipboard: clipboard), sandbox: sandbox)
            let turn = TurnContext(channel: .voice)
            let result = await gateway.call("read_clipboard", JSONObject(), turn: turn, origin: .model(.claude))
            #expect(Py.eq(result.text, try #require(c.expected.string("text"))), "\(c)")
            #expect(!result.isError, "\(c)")
            #expect(result.record.outcome == .ran, "\(c)")
            #expect(clipboard.reads == 1, "\(c)")
            #expect(await turn.tainted, "\(c): read_clipboard must taint the turn")
        }
        let gateway = await M5Fixture.gateway(.fake(clipboard: FakeClipboard(Data("rm -rf ~".utf8))), sandbox: sandbox)
        let turn = TurnContext(channel: .voice)
        _ = await gateway.call("read_clipboard", JSONObject(), turn: turn, origin: .model(.claude))
        let blocked = await gateway.call("run_command", JSONObject([.init(key: "command", value: .string("ls"))]),
                                         turn: turn, origin: .model(.claude))
        #expect(blocked.record.outcome == .blockedTaint)
        #expect(blocked.text == TaintPolicy.blockedTextClaude)
    }

    /// The reply is bounded however big the pasteboard is (the MCP limit is 4 MiB).
    @Test func replyIsCappedForAHugePasteboard() {
        let huge = Data(repeating: UInt8(ascii: "z"), count: 8 << 20)
        let reply = ReadClipboard.reply(huge)
        #expect(Py.len(reply) == 3500)
        #expect(reply.utf8.count <= 1 << 20)
    }

    @Test func universalNewlines() {
        #expect(PyText.universalNewlines("a\r\nb\rc\n\rd\r\r\n") == "a\nb\nc\n\nd\n\n")
        #expect(PyText.universalNewlines("no breaks") == "no breaks")
        #expect(PyText.decode(Data([0x61, 0xff])) == nil)
        #expect(PyText.decode(Data("x\r\ny".utf8)) == "x\ny")
    }

    /// The live reader's 5 s bound, exercised on a stand-in that never returns in time.
    @Test func liveReaderGivesUpAtItsTimeout() async {
        let clock = SuspendingClock()
        let start = clock.now
        let value = await LivePasteboard.firstOf(timeout: 0.2) {
            Thread.sleep(forTimeInterval: 2)
            return Data("late".utf8)
        }
        #expect(value == nil)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func registeredSchemaIsTheCatalogEntry() async throws {
        let catalog = try #require(ToolCatalog.tools.first { $0.name == "read_clipboard" })
        #expect(ReadClipboard.schema == catalog)
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        #expect(await gateway.toolList().first { $0.name == "read_clipboard" } == catalog)
    }
}
