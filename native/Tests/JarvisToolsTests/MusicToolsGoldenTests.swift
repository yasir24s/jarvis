import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// An osascript stand-in that answers each script with the next canned output ("" once they run
/// out), as the golden suites' fake `_run_applescript` does, and records every script it was given.
actor ScriptedRunner: StdinCommandRunning {
    private var outputs: [String]
    private(set) var scripts: [String] = []

    init(_ outputs: [String]) { self.outputs = outputs }

    func run(_ argv: [String], timeout: Double) async -> ProcessOutput? {
        await run(argv, input: Data(), timeout: timeout)
    }

    func run(_ argv: [String], input: Data, timeout: Double) async -> ProcessOutput? {
        precondition(argv == ["/usr/bin/osascript", "-"])
        scripts.append(String(decoding: input, as: UTF8.self))
        let out = outputs.isEmpty ? "" : outputs.removeFirst()
        // osascript ends its result with a newline, so "" is a blank line, not an empty stdout.
        return ProcessOutput(stdout: Data((out + "\n").utf8), stderr: Data(), status: 0, timedOut: false, truncated: false)
    }
}

/// Records each URL a tool opens; opens nothing.
final class RecordingOpener: SettingsOpening {
    private let urls = Mutex<[String]>([])
    var opened: [String] { urls.withLock { $0 } }
    func open(_ url: URL) async { urls.withLock { $0.append(url.absoluteString) } }
}

/// PB: the four music tools against Python's replies, scripts, opened URLs and requests
/// (tools/golden_pb_music.py). Nothing reaches Music, the network or LaunchServices.
@Suite("PB music tools (golden)")
struct MusicToolsGoldenTests {
    @Test func fixtureHoldsEveryTool() throws {
        let cases = try M5Fixture.cases("pb_music")
        let tools = Set(cases.compactMap { $0.input.string("tool") })
        #expect(tools == ["music_now_playing", "music_search", "music_control", "music_play"])
        #expect(cases.count == 86)
    }

    @Test(arguments: try M5Fixture.cases("pb_music"))
    func golden(_ c: M5Fixture.Case) async throws {
        let outputs = (c.input["outputs"]?.arrayValue ?? []).compactMap(\.stringValue)
        let scripts = ScriptedRunner(outputs)
        let opener = RecordingOpener()
        let web = WebToolsGoldenTests.FakeWeb(pages: c.input.object("pages") ?? JSONObject())
        let online: Bool = if case .bool(let b)? = c.input["online"] { b } else { true }
        var platform = ToolPlatform.fake()
        platform.scriptRunner = scripts
        platform.web = web
        platform.online = { online }
        platform.urlOpener = opener
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(platform, sandbox: sandbox)
        let tool = try #require(c.input.string("tool"))
        let result = await gateway.call(tool, c.input.object("args") ?? JSONObject(), turn: TurnContext(channel: .voice),
                                        origin: .model(.claude))
        #expect(result.text == c.expected.string("text"), "\(c.name)")
        #expect(await scripts.scripts == (c.expected["scripts"]?.arrayValue ?? []).compactMap(\.stringValue), "\(c.name)")
        #expect(opener.opened == (c.expected["opened"]?.arrayValue ?? []).compactMap(\.stringValue), "\(c.name)")
        let want = c.expected["requests"]?.arrayValue ?? []
        #expect(web.requests.count == want.count, "\(c.name): requests")
        for (got, w) in zip(web.requests, want) {
            #expect(got.objectValue?.string("url") == w.objectValue?.string("url"), "\(c.name)")
            #expect(got.objectValue?.string("user_agent") == w.objectValue?.string("user_agent"), "\(c.name)")
            #expect(got.objectValue?.double("timeout") == w.objectValue?.double("timeout"), "\(c.name)")
        }
    }

    /// No music tool is an executor or reads untrusted text; each tags the turn with music.
    @Test func musicToolsAreNotGuardedAndTagMusic() {
        for tool in ["music_now_playing", "music_search", "music_play", "music_control"] {
            #expect(!TaintPolicy.executors.contains(tool) && !TaintPolicy.untrusted.contains(tool))
            #expect(DataSourceMap.sources(for: tool) == [.music])
        }
    }
}
