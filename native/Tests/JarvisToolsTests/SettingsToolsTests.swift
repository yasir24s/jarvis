import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

@Suite("SettingsToolsTests")
struct SettingsToolsTests {
    @Test func everyPaneMatchesPython() async throws {
        for c in try M5Fixture.cases("m5_open_settings") {
            let opener = FakeSettingsOpener()
            let gateway = ToolGateway(log: { _ in })
            await gateway.register(OpenSettings(opener: opener))
            let result = await gateway.call("open_settings", c.input,
                turn: TurnContext(channel: .voice), origin: .ui)
            #expect(result.text == c.expected.string("text"), "\(c)")
            #expect(await opener.urls == [try #require(c.expected.string("url"))])
        }
    }

    @Test func fixturesHoldEveryCase() throws {
        #expect(try M5Fixture.cases("m5_open_settings").count == 55)
        let controls = try M5Fixture.cases("m5_system_control").map(\.name)
        #expect(controls.count == 64)
        #expect(controls.filter { $0.hasPrefix("dnd/") }.count == 14)
    }

    /// The DND branch against Python's real _run_shortcut, _match_shortcut and _shortcuts_all:
    /// each case replays the recorded `shortcuts list` and `shortcuts run` results.
    @Test func doNotDisturbRunsTheShortcutAsPythonDoes() async throws {
        for c in try M5Fixture.cases("m5_system_control") where c.name.hasPrefix("dnd/") {
            let outputs = [c.input["list"], c.input["run"]].compactMap { $0?.objectValue }.map(Self.output)
            let runner = FakeRunner(outputs.isEmpty ? [nil] : outputs)
            let cli = c.input["cli"] == .bool(true)
            let scripts = FakeStdinRunner()
            let gateway = ToolGateway(log: { _ in })
            await gateway.register(SystemControl(runner: runner, scriptRunner: scripts,
                executable: { cli && $0 == "shortcuts" ? "/usr/bin/shortcuts" : nil }))
            let result = await gateway.call("system_control", JSONObject([.init(key: "feature", value: .string("dnd"))]),
                turn: TurnContext(channel: .voice), origin: .ui)
            #expect(result.text == c.expected.string("text"), "\(c.name)")
            // Python runs `shortcuts` by name; native runs the path it found.
            let want = (c.expected["argv"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue) }
            #expect(runner.calls.map { [($0[0] as NSString).lastPathComponent] + $0.dropFirst() } == want, "\(c.name)")
            #expect(runner.calls.allSatisfy { $0[0] == "/usr/bin/shortcuts" })
            #expect(await scripts.calls.isEmpty)
        }
    }

    static func output(_ spec: JSONObject) -> ProcessOutput? {
        if case .int(let code)? = spec["errno"] { return .launchFailed(Int32(code)) }
        let hex = { (key: String) in
            let chars = Array(spec.string(key) ?? "")
            return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
        }
        return ProcessOutput(stdout: hex("stdout_hex"), stderr: hex("stderr_hex"),
                             status: Int32(spec.int("status") ?? 0), timedOut: spec["timeout"] == .bool(true),
                             truncated: false)
    }

    @Test func controlsMatchPython() async throws {
        for c in try M5Fixture.cases("m5_system_control") where !c.name.hasPrefix("dnd/") {
            let feature = try #require(c.input.string("feature"))
            let isDND = feature == "dnd"
            let shortcutExists = c.input.string("shortcut") == "Done, sir."
            let output = isDND ? (shortcutExists ? "Toggle Do Not Disturb\n" : "") : c.input.string("ports") ?? ""
            let runner = FakeRunner(stdout: output)
            let scriptOutput = c.input.string("script_output") ?? ""
            let scripts = FakeStdinRunner(output: ProcessOutput(stdout: Data(scriptOutput.utf8), stderr: Data(),
                                       status: 0, timedOut: false, truncated: false))
            let bt = c.input["bt"] == .bool(true)
            let gateway = ToolGateway(log: { _ in })
            await gateway.register(SystemControl(runner: runner, scriptRunner: scripts,
                executable: { $0 == "shortcuts" ? "/usr/bin/shortcuts" : bt ? "/fake/blueutil" : nil }))
            let result = await gateway.call("system_control", c.input,
                turn: TurnContext(channel: .voice), origin: .ui)
            #expect(result.text == c.expected.string("text"), "\(c)")
            let expectedScripts = c.expected["scripts"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(await scripts.calls.map { String(decoding: $0.input, as: UTF8.self) } == expectedScripts)
            if !isDND {
                let expected = c.expected["argv"]?.arrayValue?.compactMap(\.arrayValue).map { $0.compactMap(\.stringValue) } ?? []
                let normalized = runner.calls.map { argv in [argv[0].hasPrefix("/fake/") ? argv[0] : (argv[0] as NSString).lastPathComponent] + argv.dropFirst() }
                #expect(normalized == expected, "\(c)")
            } else {
                #expect(runner.calls == (shortcutExists ? [["/usr/bin/shortcuts", "list"], ["/usr/bin/shortcuts", "run", "Toggle Do Not Disturb"]] : [["/usr/bin/shortcuts", "list"]]))
            }
        }
    }

    /// All eleven tools that act are registered over the platform with their generated catalog
    /// entries (m3_tool_schemas), so none answers "Unknown tool" any more.
    @Test func everyM5ActionToolIsRegisteredWithItsCatalogEntry() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let listed = await M5Fixture.gateway(.fake(), sandbox: sandbox).toolList()
        let names = ["run_command", "run_applescript", "write_file", "move_file", "delete_file", "set_volume",
                     "set_brightness", "notify", "type_text", "open_settings", "system_control"]
        for name in names {
            let catalog = try #require(ToolCatalog.tools.first { $0.name == name })
            #expect(listed.first { $0.name == name } == catalog, "\(name)")
        }
        #expect(OpenSettings.schema == ToolCatalog.tools.first { $0.name == "open_settings" })
        #expect(SystemControl.schema == ToolCatalog.tools.first { $0.name == "system_control" })
    }

    /// shutil.which over the agent PATH: macOS's own sh and shortcuts, nothing for a made-up name.
    @Test func liveExecutableSearchesTheAgentPath() {
        #expect(SystemControl.liveExecutable("sh") == "/bin/sh")
        #expect(SystemControl.liveExecutable("shortcuts") == "/usr/bin/shortcuts")
        #expect(SystemControl.liveExecutable("jarvis-no-such-tool-\(UUID().uuidString)") == nil)
        #expect(SystemControl.liveExecutable("") == nil)   // a directory, not a command
    }

    @Test func shortcutMatchingUsesStableShortestThenOverlap() {
        #expect(SystemControl.matchShortcut(["Other", "Toggle Do Not Disturb"]) == "Toggle Do Not Disturb")
        #expect(SystemControl.matchShortcut(["do not disturb extended", "do not disturb"]) == "do not disturb")
        #expect(SystemControl.matchShortcut(["disturb toggle", "toggle other"]) == "disturb toggle")
        #expect(SystemControl.matchShortcut(["unrelated"]) == nil)
    }
}

actor FakeSettingsOpener: SettingsOpening {
    var urls: [String] = []
    func open(_ url: URL) async { urls.append(url.absoluteString) }
}
