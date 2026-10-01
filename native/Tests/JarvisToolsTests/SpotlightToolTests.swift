import Darwin
import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// T5.10: search_files and find_files against m5_spotlight (G8), what the REAL `execute_tool`
/// returned over canned mdfind output. mdfind is a fake runner; the `recent` cases recreate the
/// fixture's files in a temporary home with Python's exact st_mtime_ns, so the newest-first
/// sort reads real `stat` results. Nothing queries the real Spotlight index.
@Suite("SpotlightToolTests")
struct SpotlightToolTests {
    static let suite = "m5_spotlight"
    static let token = "${JARVIS_HOME}"

    @Test func fixtureHoldsEveryCase() throws {
        let cases = try M5Fixture.cases(Self.suite)
        #expect(cases.count == 49)
        #expect(cases.filter { $0.input["files"]?.arrayValue?.isEmpty == false }.count == 6)
    }

    @Test func goldenCasesThroughTheGateway() async throws {
        for c in try M5Fixture.cases(Self.suite) {
            let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-spot-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let home = root.path(percentEncoded: false).hasSuffix("/") ? String(root.path(percentEncoded: false).dropLast())
                : root.path(percentEncoded: false)
            func local(_ s: String) -> String { s.replacingOccurrences(of: Self.token, with: home) }
            for file in c.input["files"]?.arrayValue ?? [] {
                let pair = try #require(file.arrayValue)
                let rel = try #require(pair.first?.stringValue)
                guard case .int(let ns)? = pair.last else { Issue.record("\(c): mtime"); continue }
                let url = root.appending(path: rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(rel.utf8).write(to: url)
                var times = [timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000)),
                             timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))]
                #expect(utimensat(AT_FDCWD, url.path(percentEncoded: false), &times, 0) == 0, "\(c)")
            }
            var stdout = Data(local(c.input.string("stdout") ?? "").utf8)
            if let hex = c.input.string("stdout_hex") { stdout = try #require(ClipboardToolTests.bytes(hex: hex)) }
            let timedOut = c.input["timeout"] == .bool(true)
            let runner = FakeRunner([ProcessOutput(stdout: timedOut ? Data() : stdout, stderr: Data(),
                                                   status: timedOut ? -9 : 0, timedOut: timedOut, truncated: false)])
            let sandbox = try ToolCoreSandbox()
            defer { sandbox.remove() }
            let gateway = await M5Fixture.gateway(.fake(home: home, spotlightRunner: runner), sandbox: sandbox)
            let tool = try #require(c.input.string("tool"))
            let turn = TurnContext(channel: .voice)
            let result = await gateway.call(tool, try #require(c.input.object("args")), turn: turn, origin: .model(.claude))
            #expect(result.text == local(try #require(c.expected.string("text"))), "\(c)")
            #expect(await turn.tainted == false, "\(c)")
            let argv = (c.expected["argv"]?.arrayValue ?? []).compactMap(\.stringValue).map(local)
            if argv.isEmpty {
                #expect(runner.calls.isEmpty, "\(c): Python raised before running mdfind")
            } else {
                #expect(runner.calls == [["/usr/bin/mdfind"] + argv.dropFirst()], "\(c)")
            }
        }
    }

    /// CPython's UnicodeDecodeError text for the shapes the fixture does not reach.
    @Test func decodeErrorText() {
        #expect(PyText.decodeError(Data("fine ✓".utf8)) == nil)
        #expect(PyText.decodeError(Data([0x80])) == "'utf-8' codec can't decode byte 0x80 in position 0: invalid start byte")
        #expect(PyText.decodeError(Data([0xF0, 0x9F, 0x28])) == "'utf-8' codec can't decode bytes in position 0-1: invalid continuation byte")
    }

    /// A runaway listing past the cap: the cut-off last line is dropped, never decoded.
    @Test func truncatedListingDropsItsPartialLine() async throws {
        var bytes = Data("/Volumes/Work/a.txt\n/Volumes/Work/b.txt\n/Volumes/Work/caf".utf8)
        bytes.append(0xC3)                                    // the cap cut "é" in half
        let runner = FakeRunner([ProcessOutput(stdout: bytes, stderr: Data(), status: -9, timedOut: false, truncated: true)])
        let spotlight = Spotlight(runner: runner, home: "/nonexistent")
        let text = try await spotlight.search(query: "x", kind: nil, recent: false)
        #expect(text == "Found 2: a.txt, b.txt.\n/Volumes/Work/a.txt\n/Volumes/Work/b.txt")
    }

    /// Python's subprocess raises OSError for an argv past ARG_MAX: "[Errno 7] Argument list too
    /// long: 'mdfind'" (the same wording Python printed for /usr/bin/true with a 3 MiB argument).
    @Test func oversizedQueryReportsPythonsOSError() async throws {
        let spotlight = Spotlight(runner: FakeRunner([.launchFailed(E2BIG)]), home: "/nonexistent")
        let text = try await spotlight.search(query: "x", kind: nil, recent: false)
        #expect(text == "Search error: [Errno 7] Argument list too long: 'mdfind'")
    }

    @Test func registeredSchemasAreTheCatalogEntries() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        let listed = await gateway.toolList()
        for schema in [SearchFiles.schema, FindFiles.schema] {
            let catalog = try #require(ToolCatalog.tools.first { $0.name == schema.name })
            #expect(schema == catalog)
            #expect(listed.first { $0.name == schema.name } == catalog)
        }
    }
}
