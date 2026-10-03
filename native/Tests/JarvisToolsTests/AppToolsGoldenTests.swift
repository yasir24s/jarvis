import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// An on-device model stand-in: records each prompt and answers the same text (or throws).
final class FakeModel: PersonaLLM {
    let answer: String?
    private let asked = Mutex<[(system: String, user: String)]>([])

    init(_ answer: String?) { self.answer = answer }

    var prompts: [String] { asked.withLock { $0.map(\.user) } }
    var systems: [String] { asked.withLock { $0.map(\.system) } }

    struct Failed: Error {}

    func complete(system: String, user: String, timeout: Duration) async throws -> String {
        asked.withLock { $0.append((system, user)) }
        guard let answer else { throw Failed() }
        return answer
    }
}

/// PB: make_note, run_shortcut, list_shortcuts, summarize_page and find_song_by_lyrics against
/// Python's replies (tools/golden_pb_apps.py). Notes and the browsers are a recording osascript
/// fake, Shortcuts a recorded `shortcuts` run, the network W1's fake and the model FakeModel.
@Suite("PB app tools (golden)")
struct AppToolsGoldenTests {
    static func gateway(_ tools: [any ToolImpl]) async -> ToolGateway {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        for tool in tools { await gateway.register(tool) }
        return gateway
    }

    @Test(arguments: try M5Fixture.cases("pb_notes"))
    func notes(_ c: M5Fixture.Case) async throws {
        let scripts = ScriptedRunner((c.input["outputs"]?.arrayValue ?? []).compactMap(\.stringValue))
        let gateway = await Self.gateway([MakeNote(runner: scripts)])
        let result = await gateway.call("make_note", c.input.object("args") ?? JSONObject(),
                                        turn: TurnContext(channel: .voice), origin: .model(.claude))
        #expect(result.text == c.expected.string("text"), "\(c.name)")
        #expect(await scripts.scripts == (c.expected["scripts"]?.arrayValue ?? []).compactMap(\.stringValue), "\(c.name)")
    }

    @Test(arguments: try M5Fixture.cases("pb_shortcuts"))
    func shortcuts(_ c: M5Fixture.Case) async throws {
        let outputs = [c.input["list"], c.input["run"]].compactMap { $0?.objectValue }.map(SettingsToolsTests.output)
        let runner = FakeRunner(outputs.isEmpty ? [nil] : outputs)
        let cli = c.input["cli"] == .bool(true)
        let shortcuts = ShortcutsCLI(runner: runner, executable: { cli && $0 == "shortcuts" ? "/usr/bin/shortcuts" : nil })
        let gateway = await Self.gateway([RunShortcut(shortcuts: shortcuts), ListShortcuts(shortcuts: shortcuts)])
        let tool = try #require(c.input.string("tool"))
        let result = await gateway.call(tool, c.input.object("args") ?? JSONObject(), turn: TurnContext(channel: .voice),
                                        origin: .model(.claude))
        #expect(result.text == c.expected.string("text"), "\(c.name)")
        // Python runs `shortcuts` by name; native runs the path it found.
        let want = (c.expected["argv"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue) }
        #expect(runner.calls.map { [($0[0] as NSString).lastPathComponent] + $0.dropFirst() } == want, "\(c.name)")
        #expect(runner.calls.allSatisfy { $0[0] == "/usr/bin/shortcuts" })
    }

    /// Python's page pipeline (no WebKit reader here) and prompts; the model answers what
    /// Python's `_ask_model` was made to answer.
    @Test(arguments: try M5Fixture.cases("pb_browser"))
    func browser(_ c: M5Fixture.Case) async throws {
        let scripts = ScriptedRunner((c.input["outputs"]?.arrayValue ?? []).compactMap(\.stringValue))
        let web = WebToolsGoldenTests.FakeWeb(pages: c.input.object("pages") ?? JSONObject())
        let online = c.input["online"] == .bool(true)
        let front = c.input.string("front") ?? ""
        let model = FakeModel(c.input.string("model"))
        let gateway = await Self.gateway([
            SummarizePage(runner: scripts, web: web, online: { online }, frontApp: { front }, reader: nil, model: model),
            FindSongByLyrics(web: web, online: { online }, model: model),
        ])
        let tool = try #require(c.input.string("tool"))
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call(tool, c.input.object("args") ?? JSONObject(), turn: turn, origin: .model(.claude))
        #expect(result.text == c.expected.string("text"), "\(c.name)")
        #expect(await scripts.scripts == (c.expected["scripts"]?.arrayValue ?? []).compactMap(\.stringValue), "\(c.name)")
        #expect(model.prompts == (c.expected["prompts"]?.arrayValue ?? []).compactMap(\.stringValue), "\(c.name)")
        #expect(model.systems.allSatisfy { $0.isEmpty })
        let want = c.expected["requests"]?.arrayValue ?? []
        #expect(web.requests.count == want.count, "\(c.name): requests")
        for (got, w) in zip(web.requests, want) {
            #expect(got.objectValue?.string("url") == w.objectValue?.string("url"), "\(c.name)")
            #expect(got.objectValue?.string("user_agent") == w.objectValue?.string("user_agent"), "\(c.name)")
            #expect(got.objectValue?.double("timeout") == w.objectValue?.double("timeout"), "\(c.name)")
        }
        // Both read text from outside JARVIS, so the turn is tainted once either has answered.
        if result.record.outcome == .ran { #expect(await turn.tainted, "\(c.name)") }
    }
}
