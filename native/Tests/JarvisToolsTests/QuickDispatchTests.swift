import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// PR2: the fast-path branches batch A left to the brain, carried through the gateway, and
/// the helpers with no catalog tool against Python (tools/golden_quick.py, quick_helpers).
/// Every machine-facing part is a fake: nothing opens, quits, plays or changes a setting.
@Suite("PR2 fast-path dispatch", .timeLimit(.minutes(1)))
struct QuickDispatchTests {
    static let zone = TimeZone(identifier: "Europe/London")!

    final class Apps: RunningAppsControlling {
        let apps: [RunningApp]
        private let quit = Mutex<[String]>([])
        init(_ apps: [RunningApp]) { self.apps = apps }
        var terminated: [String] { quit.withLock { $0 } }
        func runningApps() async -> [RunningApp] { apps }
        func terminate(_ app: RunningApp) async -> Bool {
            quit.withLock { $0.append(app.name) }
            return true
        }
    }

    /// A gateway with every body registered over fakes, and the fast path on it.
    struct Rig {
        let sandbox: ToolCoreSandbox
        let gate = ConfirmationGate()
        let gateway: ToolGateway
        let opener = FakeStdinRunner()
        let volume = FakeVolume()
        let settings = FakeSettingsOpener()
        let apps: Apps
        let commands: QuickCommands

        init(index: String = "/Applications/Safari.app\n", running: [RunningApp] = [],
             browser: String = "Safari", backend: (@Sendable () async -> String)? = nil) async throws {
            sandbox = try ToolCoreSandbox()
            gateway = ToolGateway(confirmationGate: gate, log: { _ in })
            apps = Apps(running)
            var platform = ToolPlatform.fake(apps: AppIndex(runner: FakeRunner(stdout: index), loadPlist: { _ in nil }),
                                             browser: StubBrowser(name: browser))
            platform.opener = opener
            platform.volume = volume
            platform.settingsOpener = settings
            platform.quick = QuickPlatform(runningApps: apps)
            await BuiltInTools.register(on: gateway, core: sandbox.core, clock: ManualClock(1790582400),
                                        timeZone: QuickDispatchTests.zone, platform: platform,
                                        alarms: AlarmBook(store: sandbox.store, timeZone: QuickDispatchTests.zone))
            commands = QuickCommands(router: FastPathRouter(), core: sandbox.core, confirmations: gate, timers: nil,
                                     alarms: nil, timeZone: QuickDispatchTests.zone,
                                     hooks: .init(backendReport: backend), runner: QuickCommandsTests.Runner(),
                                     web: QuickCommandsTests.Web(nil), online: { false }, log: { _ in },
                                     tools: gateway, browser: StubBrowser(name: browser))
        }

        func say(_ text: String, channel: Channel = .voice, pasted: Bool = false) async -> String? {
            await commands.route(text, turn: TurnContext(channel: channel, startTainted: pasted))
        }

        /// What the tool itself answers on a fresh turn.
        func direct(_ name: String, _ args: JSONObject = JSONObject()) async -> String {
            await gateway.call(name, args, turn: TurnContext(channel: .voice), origin: .fastPath).text
        }
    }

    /// Polls `condition` until it holds or `seconds` pass (well past any action under test).
    static func eventually(seconds: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    static func args(_ pairs: [(String, JSONValue)]) -> JSONObject {
        JSONObject(pairs.map { JSONObject.Member(key: $0.0, value: $0.1) })
    }

    // MARK: helpers answer with the tool's own reply

    @Test func helperBranchesSayWhatTheirToolSays() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        let table: [(String, String, JSONObject)] = [
            ("what time is it", "get_time", JSONObject()),
            ("battery level", "get_battery", JSONObject()),
            ("run diagnostics", "run_diagnostics", JSONObject()),
            ("what's the weather in paris", "get_weather", Self.args([("location", .string("paris"))])),
            ("where am i", "get_location", JSONObject()),
            ("news", "get_news", JSONObject()),
            ("list my shortcuts", "list_shortcuts", JSONObject()),
            ("run shortcut morning routine", "run_shortcut", Self.args([("name", .string("morning routine"))])),
            ("what browsers do i have", "find_apps", Self.args([("query", .string("browsers"))])),
            ("recent files", "find_files", Self.args([("query", .string("")), ("recent", .bool(true))])),
        ]
        for (phrase, tool, args) in table {
            let expected = await rig.direct(tool, args)
            #expect(await rig.say(phrase) == expected, "\(phrase)")
        }
    }

    @Test func aReminderGoesToSetReminderWithPythonsSplit() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        let reply = try #require(await rig.say("remind me to call mum in 10 minutes"))
        #expect(reply.hasPrefix("Reminder set for"))
        #expect(rig.sandbox.store.load(.alarms) != nil)
    }

    @Test func whichModelIsTheBackendReport() async throws {
        let rig = try await Rig(backend: { "The last request was handled by Claude, through Claude Code, sir." })
        defer { rig.sandbox.remove() }
        #expect(await rig.say("which model are you using") == "The last request was handled by Claude, through Claude Code, sir.")
        let none = try await Rig()
        defer { none.sandbox.remove() }
        #expect(await none.say("which model are you using") == nil)
    }

    @Test func screenAndClipboardHelpStillReachTheBrain() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        for phrase in ["what's on my screen", "explain my screen", "what's on my clipboard"] {
            #expect(await rig.say(phrase) == nil, "\(phrase)")
        }
    }

    // MARK: tuples say the line at once and act beside it

    @Test func volumeSpeaksPythonsLineAndSetsTheLevel() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        #expect(await rig.say("set volume to 150") == "Setting volume to 100, sir.")
        #expect(await Self.eventually { rig.volume.levels == [100] })
        #expect(await rig.say("mute") == "Muting, sir.")
        #expect(await Self.eventually { rig.volume.levels == [100, 0] })
    }

    @Test func settingsPanesOpenThroughOpenSettings() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        #expect(await rig.say("open bluetooth settings") == "Opening settings, sir.")
        #expect(await Self.eventually { await rig.settings.urls.count == 1 })
        #expect(await rig.say("open settings") == "Opening System Settings, sir.")
        #expect(await Self.eventually { await rig.settings.urls.count == 2 })
    }

    @Test func searchesOpenTheEncodedURL() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        #expect(await rig.say("google swift concurrency") == "Googling swift concurrency, sir.")
        #expect(await rig.say("search for lofi beats on youtube") == "Searching YouTube for lofi beats, sir.")
        let want = [["/usr/bin/open", "https://www.google.com/search?q=swift%20concurrency"],
                    ["/usr/bin/open", "https://www.youtube.com/results?search_query=lofi%20beats"]]
        #expect(await Self.eventually { Set(await rig.opener.calls.map(\.argv)) == Set(want) })
    }

    @Test func togglesRunSystemControl() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        #expect(await rig.say("turn on dark mode") == "Turning on dark mode, sir.")
        #expect(await rig.say("enable dock autohide") == "Done, sir.")
    }

    // MARK: the internal tools

    @Test func openingAnAppLaunchesItByName() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        #expect(await rig.say("open safari") == "Opening Safari, sir.")
        #expect(await rig.say("open flurbo") == "I couldn't find an app called flurbo, sir.")
        #expect(await rig.opener.calls.map(\.argv) == [["/usr/bin/open", "-a", "Safari"]])
    }

    @Test func quittingARunningAppTerminatesItAndAnythingElseGoesToTheBrain() async throws {
        let rig = try await Rig(running: [RunningApp(name: "Safari", regular: true, pid: 1)])
        defer { rig.sandbox.remove() }
        #expect(await rig.say("quit safari") == "Closed Safari, sir.")
        #expect(await rig.say("close the deal") == nil)
        #expect(rig.apps.terminated == ["Safari"])
    }

    @Test func theDefaultBrowserIsReadAndSaid() async throws {
        let named = try await Rig(browser: "Arc")
        defer { named.sandbox.remove() }
        #expect(await named.say("what's my default browser") == "Your default browser is Arc, sir.")
        let none = try await Rig(browser: "")
        defer { none.sandbox.remove() }
        #expect(await none.say("which browser is my default") == "I couldn't determine your default browser, sir.")
    }

    @Test func aModelCannotCallTheFastPathsOwnTools() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        for origin in [ToolOrigin.model(.claude), .model(.local), .ui] {
            let result = await rig.gateway.call(QuickOpenURL.name, Self.args([("url", .string("https://example.com"))]),
                                                turn: TurnContext(channel: .text), origin: origin)
            #expect(result.text == GuardStrings.unknownTool(QuickOpenURL.name))
        }
        #expect(await rig.opener.calls.isEmpty)
        #expect(await rig.gateway.toolList().contains { $0.name.hasPrefix("quick_") } == false)
    }

    @Test func aPastedTypeCommandIsRefusedByTheTaintGuard() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        #expect(await rig.say("type hello world", channel: .text, pasted: true) == TaintPolicy.blockedTextLocal)
    }

    @Test func withoutAGatewayTheNewBranchesGoToTheBrain() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let commands = QuickCommandsTests.commands(sandbox)
        for phrase in ["open safari", "volume 50", "what time is it", "google cats", "quit safari"] {
            #expect(await commands.route(phrase, turn: TurnContext(channel: .voice)) == nil, "\(phrase)")
        }
    }

    // MARK: quick_helpers (Python's own output)

    static func catalog(_ input: JSONObject) -> AppCatalog {
        let defaultIndex: [[String]] = [["safari", "Safari", "/Applications/Safari.app"],
                                        ["google chrome", "Google Chrome", "/Applications/Google Chrome.app"],
                                        ["music", "Music", "/System/Applications/Music.app"],
                                        ["xcode", "Xcode", "/Applications/Xcode.app"],
                                        ["calculator", "Calculator", "/System/Applications/Calculator.app"],
                                        ["visual studio code", "Visual Studio Code",
                                         "/Applications/Visual Studio Code.app"]]
        let defaultMeta: [String: [String]] = ["safari": ["browser"], "google chrome": ["browser"], "music": ["music"],
                                               "xcode": ["code"], "calculator": ["utility"],
                                               "visual studio code": ["code", "editor"]]
        let index = input["index"]?.arrayValue.map { $0.map { ($0.arrayValue ?? []).compactMap(\.stringValue) } }
            ?? defaultIndex
        var meta = defaultMeta
        if let given = input["meta"]?.objectValue {
            meta = Dictionary(given.members.map { ($0.key, ($0.value.arrayValue ?? []).compactMap(\.stringValue)) },
                              uniquingKeysWith: { a, _ in a })
        }
        let lows = Set(index.map { $0[0] })
        return AppCatalog(entries: index.map { AppEntry(low: $0[0], name: $0[1], path: $0[2]) },
                          meta: meta.filter { lows.contains($0.key) })
    }

    /// Python's argv, with the commands native runs by absolute path.
    static func calls(_ expected: JSONObject) -> [[String]] {
        (expected["calls"]?.arrayValue ?? []).map { call in
            let parts = (call.arrayValue ?? []).map(QuickCommandsTests.text)
            guard let head = parts.first else { return parts }
            switch head {
            case "open", "mdfind": return ["/usr/bin/" + head] + parts.dropFirst()
            default: return parts
            }
        }
    }

    final class StubTool: Sendable {
        let calls = Mutex<[[String]]>([])
    }

    @Test(arguments: try M5Fixture.cases("quick_helpers"))
    func helpersMatchPython(_ c: M5Fixture.Case) async throws {
        let e = c.expected
        let fn = try #require(c.input.string("fn"))
        let ctx = ToolRunContext(toolName: "test", origin: .fastPath, turn: TurnContext(channel: .voice))
        switch fn {
        case "open":
            let exists = (c.input["exists"]?.arrayValue ?? []).compactMap(\.stringValue)
            let catalog = Self.catalog(c.input)
            let (text, action) = await QuickOpenApp.resolve(
                try #require(c.input.string("name")), catalog: { catalog },
                defaultBrowser: { c.input.string("default_browser") ?? "" }, appExists: { exists.contains($0) })
            #expect(text == e.string("text"))
            #expect((action.map { [["/usr/bin/open"] + $0] } ?? []) == Self.calls(e))
        case "path", "reveal":
            let exists = (c.input["exists"]?.arrayValue ?? []).compactMap(\.stringValue)
            let mdfind = c.input.string("mdfind")
            let spotlight = FakeRunner(mdfind.map {
                [ProcessOutput(stdout: Data($0.utf8), stderr: Data(), status: 0, timedOut: false, truncated: false)]
            } ?? [ProcessOutput.launchFailed(2)])
            let opener = FakeStdinRunner()
            let tool = QuickOpenPath(spotlight: spotlight, runner: opener, home: "/nonexistent/home",
                                     userHome: { _ in nil }, exists: { exists.contains($0) })
            let path = try #require(c.input.string("path"))
            var args = Self.args([("path", .string(path))])
            if fn == "reveal" { args = Self.args([("path", .string(path)), ("reveal", .bool(true))]) }
            guard case .text(let text) = try await tool.run(args, ctx) else { Issue.record("gated"); return }
            // Python raises when mdfind cannot run at all; native says it found nothing (DEV row).
            #expect(text == (e.string("text") ?? "I couldn't find \(path), sir."))
            let ran = spotlight.calls + (await opener.calls.map(\.argv))
            #expect(ran == Self.calls(e))
        case "quit":
            let running = (c.input["apps"]?.arrayValue).map { list in
                list.compactMap(\.objectValue).map {
                    RunningApp(name: $0.string("name") ?? "", regular: $0["policy"] == .int(0), pid: 0)
                }
            } ?? [RunningApp(name: "Finder", regular: true, pid: 1), RunningApp(name: "Safari", regular: true, pid: 2),
                  RunningApp(name: "Google Chrome", regular: true, pid: 3), RunningApp(name: "Music", regular: true, pid: 4),
                  RunningApp(name: "Dock", regular: false, pid: 5), RunningApp(name: "JARVIS", regular: true, pid: 6)]
            let apps = Apps(running)
            let catalog = Self.catalog(c.input)
            guard case .text(let text) = try await QuickQuitApp(apps: apps, catalog: { catalog }).run(
                Self.args([("name", .string(try #require(c.input.string("name"))))]), ctx) else { return }
            #expect(text == (e.string("text") ?? ""))
            #expect(apps.terminated.map { ["terminate", $0] } == Self.calls(e))
        case "briefing":
            let online = c.input["online"]?.pyTruthy ?? false
            let log = StubTool()
            let gateway = ToolGateway(log: { _ in })
            let calendar = c.input.string("calendar") ?? ""
            let news = c.input.string("news") ?? "Top headlines. One ... Two ... Three."
            await gateway.register(Stub<TimeName>(log: log, reply: "It's 9:00 AM, sir.", record: ["get_time", "time"]))
            await gateway.register(Stub<WeatherName>(log: log, reply: "It's 14 degrees and cloudy in London, sir.",
                                                     record: ["get_weather", ""]))
            await gateway.register(Stub<CalendarName>(log: log, reply: calendar, record: ["get_calendar"]))
            await gateway.register(Stub<NewsName>(log: log, reply: news, record: ["get_news"]))
            let sandbox = try ToolCoreSandbox()
            defer { sandbox.remove() }
            let commands = QuickCommands(router: FastPathRouter(), core: sandbox.core, confirmations: ConfirmationGate(),
                                         timers: nil, alarms: nil, timeZone: Self.zone, hooks: .init(),
                                         runner: QuickCommandsTests.Runner(), web: QuickCommandsTests.Web(nil),
                                         online: { online }, log: { _ in }, tools: gateway, browser: StubBrowser())
            #expect(await commands.route("brief me", turn: TurnContext(channel: .voice)) == e.string("text"))
            #expect(log.calls.withLock { $0 } == Self.calls(e))
        case "browser":
            let sandbox = try ToolCoreSandbox()
            defer { sandbox.remove() }
            let commands = QuickCommands(router: FastPathRouter(), core: sandbox.core, confirmations: ConfirmationGate(),
                                         timers: nil, alarms: nil, timeZone: Self.zone, hooks: .init(),
                                         runner: QuickCommandsTests.Runner(), web: QuickCommandsTests.Web(nil),
                                         online: { false }, log: { _ in }, tools: ToolGateway(log: { _ in }),
                                         browser: StubBrowser(name: c.input.string("default_browser") ?? ""))
            #expect(await commands.route("what's my default browser", turn: TurnContext(channel: .voice))
                    == e.string("text"))
        default:
            Issue.record("unknown case \(fn)")
        }
    }

    @Test func theAppTablesMatchPython() throws {
        let tables = try #require(try M5Fixture.cases("quick_router").first { $0.name == "tables" }).expected
        func dict(_ key: String) -> [String: String] {
            Dictionary((tables[key]?.objectValue?.members ?? []).map { ($0.key, $0.value.stringValue ?? "") },
                       uniquingKeysWith: { a, _ in a })
        }
        #expect(dict("APP_ALIASES") == QuickTables.aliases)
        #expect(dict("WEBSITES") == QuickTables.websites)
    }
}

protocol StubName { static var name: String { get } }
enum TimeName: StubName { static let name = "get_time" }
enum WeatherName: StubName { static let name = "get_weather" }
enum CalendarName: StubName { static let name = "get_calendar" }
enum NewsName: StubName { static let name = "get_news" }

/// A canned tool body that notes each call (the news count, when given, as Python's argument).
struct Stub<N: StubName>: ToolImpl {
    static var name: String { N.name }
    static var schema: ToolSchema { ToolSchema(name: N.name) }
    let log: QuickDispatchTests.StubTool
    let reply: String
    let record: [String]

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        var call = record
        if case .int(let n)? = args["count"] { call.append(String(n)) }
        log.calls.withLock { $0.append(call) }
        return .text(reply)
    }
}
