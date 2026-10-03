import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// PA batch A: the fast path's routing, timers, alarm list and cancel, and the system quick
/// commands, against Python's own output (tools/golden_quick.py), then the dispatch rules Python
/// has no oracle for (the confirmations). Nothing here plays a sound or runs a command: the runner,
/// the web and the voice are fakes.
@Suite("PA quick commands")
struct QuickCommandsTests {
    static let zone = TimeZone(identifier: "Europe/London")!

    /// Canned output per argv, every run recorded.
    final class Runner: StdinCommandRunning {
        let outputs: [[String]: String]
        private let recorded = Mutex<[[String]]>([])
        init(_ outputs: [[String]: String] = [:]) { self.outputs = outputs }
        var calls: [[String]] { recorded.withLock { $0 } }
        func run(_ argv: [String], timeout: Double) async -> ProcessOutput? {
            await run(argv, input: Data(), timeout: timeout)
        }
        func run(_ argv: [String], input: Data, timeout: Double) async -> ProcessOutput? {
            recorded.withLock { $0.append(argv + (input.isEmpty ? [] : [String(decoding: input, as: UTF8.self)])) }
            guard let out = outputs[argv] else { return ProcessOutput.launchFailed(2) }
            return ProcessOutput(stdout: Data(out.utf8), stderr: Data(), status: 0, timedOut: false, truncated: false)
        }
    }

    final class Web: WebFetching {
        let body: Data?
        private let recorded = Mutex<[String]>([])
        init(_ body: Data?) { self.body = body }
        var urls: [String] { recorded.withLock { $0 } }
        func get(_ url: String, headers: [(String, String)], timeout: Double) async throws -> Data {
            recorded.withLock { $0.append(url) }
            guard let body else { throw WebFetchError.transport("unreachable") }
            return body
        }
    }

    final class Owner: ConfirmAuthenticator {
        let answer: Bool
        private let asked = Mutex<[String]>([])
        init(_ answer: Bool) { self.answer = answer }
        var reasons: [String] { asked.withLock { $0 } }
        func authenticate(reason: String) async -> Bool {
            asked.withLock { $0.append(reason) }
            return answer
        }
    }

    final class Count: Sendable {
        private let n = Mutex(0)
        func add() { n.withLock { $0 += 1 } }
        var value: Int { n.withLock { $0 } }
    }

    static func commands(_ sandbox: ToolCoreSandbox, gate: ConfirmationGate = ConfirmationGate(),
                         timers: QuickTimers? = nil, hooks: QuickCommands.Hooks = .init(),
                         runner: Runner = Runner(), web: Web = Web(nil), online: Bool = false) -> QuickCommands {
        QuickCommands(router: FastPathRouter(), core: sandbox.core, confirmations: gate, timers: timers,
                      alarms: AlarmBook(store: sandbox.store, timeZone: zone), timeZone: zone, hooks: hooks,
                      runner: runner, web: web, online: { online }, log: { _ in })
    }

    /// A timer list on `clock` whose loop never wakes by itself (the tests call takeDue).
    static func idleTimers(_ clock: ManualClock) -> QuickTimers {
        QuickTimers(clock: clock, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
    }

    // MARK: quick_router

    @Test func routerTablesMatchPython() throws {
        let tables = try #require(try M5Fixture.cases("quick_router").first { $0.name == "tables" }).expected
        let kinds = (tables["ALL_KINDS"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(Set(kinds) == AppKinds.allKinds)
        #expect((tables["TWEAKS"]?.arrayValue ?? []).compactMap(\.stringValue) == FastPathRouter.tweakNames)
        let branches = Set((tables["BRANCHES"]?.arrayValue ?? []).compactMap(\.stringValue))
        #expect(FastPathRouter.carried.isSubset(of: branches))
    }

    @Test(arguments: try M5Fixture.cases("quick_router").filter { $0.name != "tables" })
    func routerMatchesPython(_ c: M5Fixture.Case) throws {
        let running = ["safari", "music", "xcode", "all my browsers"]
        let router = FastPathRouter(quitWouldHandle: { name in running.contains { Py.eq($0, name) } })
        let text = try #require(c.input.string("text"))
        let e = c.expected
        #expect(Py.eq(FastPathRouter.normalise(text), try #require(e.string("t"))))
        let match = router.route(text)
        if let id = e.string("deviation") {
            // An approved deviation: Python's launcher took it; natively the named branch does.
            #expect(e.string("branch") == "open.app")
            let play = FastPathCommand.media(announcement: "Playing, sir.", command: "play")
            let native: [String: (id: String, branch: String, command: FastPathCommand)] = [
                "start a timer for 5 minutes": ("DEV-M7-01", "timer.set", .setTimer(300)),
                "start a timer for 90 seconds": ("DEV-M7-01", "timer.set", .setTimer(90)),
                "start timer for 2 hours": ("DEV-M7-01", "timer.set", .setTimer(7200)),
                "start music": ("DEV-M7-02", "media.play", play),
                "start the music": ("DEV-M7-02", "media.play", play),
            ]
            let want = try #require(native[text], "no native verdict for \(text)")
            #expect(want.id == id)
            #expect(match.branch == want.branch && match.command == want.command)
            return
        }
        let branch = try #require(e.string("branch"))
        #expect(match.branch == branch)
        guard branch != "defer", !Self.leftToTheBrain.contains(branch) else {
            #expect(match.command == nil)
            return
        }
        let command = try #require(match.command)
        let call = command.goldenCall
        switch e.string("kind") ?? "" {
        case "say":
            if command == .defaultBrowser {
                // The suite cans the default browser as Safari (QuickCommands' test answers it).
                #expect(e.string("reply") == "Your default browser is Safari, sir.")
            } else {
                #expect(command == .presence)
                #expect(e.string("reply") == QuickReplies.presence)
            }
        case "act":
            let action = try #require(e.object("action"))
            #expect(action.string("fn") == call.fn)
            #expect((action["args"]?.arrayValue ?? []).map(Self.text) == call.args)
            // The empty-trash line is Python's; native asks first (DEV row).
            #expect(e.string("reply") == command.announcement)
        case "helper":
            let helper = try #require(e.object("helper"))
            #expect(helper.string("fn") == call.fn)
            #expect((helper["args"]?.arrayValue ?? []).map(Self.text) == call.args)
        default:
            Issue.record("a carried branch deferred: \(c)")
        }
    }

    static func text(_ v: JSONValue) -> String {
        if let s = v.stringValue { return s }
        if case .int(let i) = v { return String(i) }
        if case .bool(let b) = v { return b ? "True" : "False" }
        return "\(v)"
    }

    /// PR2: the branches whose Python helper is a model call (OCR or the clipboard, then
    /// `_ask_model`); the router names them and the brain answers.
    static let leftToTheBrain: Set<String> = ["screen.exact", "screen.fuzzy", "clipboard.help"]

    @Test func everyCarriedBranchIsInTheCorpus() throws {
        let hit = Set(try M5Fixture.cases("quick_router").compactMap { $0.expected.string("branch") })
        #expect(FastPathRouter.carried.subtracting(hit).isEmpty)
    }

    /// PR2: every one of Python's branches is carried except the three left to the brain.
    @Test func everyBranchButTheModelHelpersIsCarried() throws {
        let tables = try #require(try M5Fixture.cases("quick_router").first { $0.name == "tables" }).expected
        let branches = Set((tables["BRANCHES"]?.arrayValue ?? []).compactMap(\.stringValue))
        #expect(branches.subtracting(FastPathRouter.carried).subtracting(["defer"]) == Self.leftToTheBrain)
    }

    // MARK: quick_timers

    @Test(arguments: try M5Fixture.cases("quick_timers"))
    func timersMatchPython(_ c: M5Fixture.Case) throws {
        let epoch = try #require(c.input.double("epoch"))
        let clock = ManualClock(epoch)
        let timers = Self.idleTimers(clock)
        defer { timers.stop() }
        var out: [JSONValue] = []
        for step in c.input["steps"]?.arrayValue ?? [] {
            let s = try #require(step.objectValue)
            if let at = s.double("at") { clock.set(at) }
            switch s.string("op") {
            case "set": out.append(.string(timers.set(seconds: Int(try #require(s.int("secs"))))))
            case "status": out.append(.string(timers.status()))
            case "cancel": out.append(.string(timers.cancel()))
            case "fire": out.append(.array(timers.takeDue(at: clock.now()).map(JSONValue.string)))
            default: Issue.record("unknown op in \(c)")
            }
        }
        #expect(out == c.expected["out"]?.arrayValue)
    }

    /// The loop compares ends with the wall clock after each sleep: a timer whose end passed while
    /// the Mac slept (the wall clock jumps, the sleeps do not) is spoken at the next check.
    @Test(.timeLimit(.minutes(1))) func aTimerThatEndedDuringSleepIsSpokenOnWaking() async throws {
        let clock = ManualClock(1_000)
        let (lines, sink) = AsyncStream<String>.makeStream()
        let timers = QuickTimers(clock: clock, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) },
                                 announce: { sink.yield($0) })
        defer { timers.stop() }
        #expect(timers.set(seconds: 300) == "Timer set for 5 minutes, sir.")
        clock.set(1_000 + 8 * 3600)                           // the lid was shut overnight
        var heard: String?
        for await line in lines { heard = line; break }
        #expect(heard == "Sir, your timer is complete.")
        #expect(timers.count == 0)
    }

    // MARK: quick_alarms

    @Test(arguments: try M5Fixture.cases("quick_alarms"))
    func alarmsMatchPython(_ c: M5Fixture.Case) throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let path = sandbox.store.path(.alarms)
        if let text = c.input.string("file") { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        let (count, parsed) = book.alarms()
        #expect(QuickReplies.alarmList(count: count, parsed: parsed, timeZone: Self.zone) == c.expected.string("list"))
        #expect(QuickReplies.alarmsCancelled(book.cancelAlarms()) == c.expected.string("cancel"))
        let after = try? String(contentsOfFile: path, encoding: .utf8)
        if let want = c.expected.string("after") {
            let have = try #require(after)
            // The same JSON value (Python's separators differ only in spacing here).
            #expect((try? PyJSON.loads(Data(have.utf8))) ?? .string(have) == (try? PyJSON.loads(Data(want.utf8))) ?? .string(want))
        } else {
            #expect(after == nil)
        }
    }

    /// Native only: the reminders F1 writes into the same file are neither listed nor cancelled.
    @Test func remindersSurviveCancellingAlarms() throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        let when = Date(timeIntervalSince1970: 1_790_600_000)
        #expect(book.add(at: when, label: "call the dentist", kind: .reminder))
        #expect(book.add(at: when, label: "", kind: .alarm))
        #expect(book.alarms().count == 1)
        #expect(QuickReplies.alarmsCancelled(book.cancelAlarms()) == "Alarm cancelled, sir.")
        #expect(book.entries().map(\.kind) == [.reminder])
        #expect(QuickReplies.alarmsCancelled(book.cancelAlarms()) == QuickReplies.noAlarms)
    }

    // MARK: quick_system

    @Test(arguments: try M5Fixture.cases("quick_system"))
    func systemRepliesMatchPython(_ c: M5Fixture.Case) async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let inp = c.input
        let want = c.expected.string("text")
        let calls = (c.expected["calls"]?.arrayValue ?? []).compactMap { $0.arrayValue?.map(Self.text) }
        switch inp.string("fn") {
        case "ip":
            var outputs: [[String]: String] = [:]
            for iface in ["en0", "en1"] {
                if let out = inp.string(iface) { outputs[["/usr/sbin/ipconfig", "getifaddr", iface]] = out }
            }
            let body: Data? = inp.object("public").map { Data(PyJSON.dumps(.object($0)).utf8) }
            let runner = Runner(outputs), web = Web(body)
            let commands = Self.commands(sandbox, runner: runner, web: web, online: inp["online"] == .bool(true))
            #expect(await commands.ipReport() == want)
            let ran = runner.calls.map { [URL(fileURLWithPath: $0[0]).lastPathComponent] + $0.dropFirst() }
                + web.urls.map { ["GET", $0] }
            #expect(ran == calls)
        case "bt":
            var outputs: [[String]: String] = [:]
            if let out = inp.string("ioreg") { outputs[["/usr/sbin/ioreg", "-r", "-l", "-k", "BatteryPercentLeft"]] = out }
            let commands = Self.commands(sandbox, runner: Runner(outputs))
            #expect(await commands.perform(.btBattery, turn: TurnContext(channel: .voice)) == want)
        case "quit_all":
            var terminated: [[String]] = []
            let apps = inp["apps"]?.arrayValue?.compactMap(\.objectValue)
            let reply = QuickReplies.quitAll(apps: apps?.map { (name: $0.string("name") ?? "", policy: Int($0.int("policy") ?? -1)) }) { i in
                terminated.append(["terminate", apps?[i].string("name") ?? ""])
                return apps?[i]["terminates"] != .bool(false)
            }
            #expect(reply == want)
            #expect(terminated == calls)
        case "trash":
            #expect(QuickReplies.emptyTrash(osascript: inp.string("osascript") ?? "") == want)
            #expect(calls == [["osascript", QuickReplies.emptyTrashScript]])
        case "lock", "sleep":
            let runner = Runner([["/usr/bin/pmset", "displaysleepnow"]: "", ["/usr/bin/pmset", "sleepnow"]: ""])
            let commands = Self.commands(sandbox, hooks: .init(afterGoodnight: {}), runner: runner)
            let lock = inp.string("fn") == "lock"
            let spoken = await commands.perform(lock ? .lockScreen : .sleepMac, turn: TurnContext(channel: .voice))
            #expect(spoken == (lock ? QuickReplies.locking : QuickReplies.goodnight))
            if lock { #expect(want == QuickReplies.locked) } else { #expect(want == nil) }
            for _ in 0..<500 where runner.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(runner.calls.map { [URL(fileURLWithPath: $0[0]).lastPathComponent] + $0.dropFirst() } == calls)
        case "media":
            #expect(calls == [["osascript", QuickReplies.mediaScript(inp.string("cmd") ?? "")]])
        case "forget_voice":
            #expect(want == QuickReplies.voiceCleared)
        default:
            Issue.record("unknown fn in \(c)")
        }
    }

    // MARK: dispatch (native: no oracle)

    @Test func phrasesNotCarriedGoToTheBrain() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let commands = Self.commands(sandbox, timers: Self.idleTimers(ManualClock(0)))
        for text in ["tell me a joke", "open safari", "open a timer", "volume up",
                     "quit safari", "what time is it", "hello!", "what\u{2019}s my ip"] {
            #expect(await commands.route(text, turn: TurnContext(channel: .voice)) == nil, "\(text)")
        }
    }

    @Test func timersAndPresenceAnswerAtOnce() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let clock = ManualClock(0)
        let timers = Self.idleTimers(clock)
        defer { timers.stop() }
        let commands = Self.commands(sandbox, timers: timers)
        let turn = TurnContext(channel: .voice)
        #expect(await commands.route("Hello.", turn: turn) == "At your service, sir.")
        #expect(await commands.route("set a timer for 90 seconds", turn: turn) == "Timer set for 1 minute 30 seconds, sir.")
        clock.set(30)
        #expect(await commands.route("how long left?", turn: turn) == "1 minute left, sir.")
        #expect(await commands.route("cancel the timer", turn: turn) == "Timer cancelled, sir.")
    }

    @Test func correctionsAreTaughtAndForgottenByVoice() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let commands = Self.commands(sandbox)
        let turn = TurnContext(channel: .voice)
        #expect(await commands.route("I said Jarvis not Travis", turn: turn)
            == "Got it, sir — I'll read 'travis' as 'jarvis' from now on.")
        #expect(try await sandbox.core.applyCorrections("hello travis") == "hello jarvis")
        #expect(await commands.route("forget the correction for travis", turn: turn)
            == "Forgotten the correction for 'travis', sir.")
        #expect(try await sandbox.core.applyCorrections("hello travis") == "hello travis")
    }

    @Test(arguments: [true, false])
    func forgettingTheVoiceWaitsForTheOwner(_ approved: Bool) async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gate = ConfirmationGate()
        let forgot = Count()
        let commands = Self.commands(sandbox, gate: gate, hooks: .init(forgetVoice: {
            forgot.add()
            return QuickReplies.voiceCleared
        }))
        let turn = TurnContext(channel: .voice)
        let prompt = await commands.route("forget my voice", turn: turn)
        #expect(prompt == "That will forget your voice, so I'll respond to anyone, sir — say 'confirm' to proceed.")
        #expect(forgot.value == 0)
        #expect(await gate.pending?.desc == QuickReplies.forgetVoiceDesc)
        let owner = Owner(approved)
        let result = await gate.consume("confirm", via: .voice(confirming: .ownerCheck(owner)), runIn: turn)
        #expect(owner.reasons == [QuickReplies.forgetVoiceDesc])
        #expect(result == .handled(approved ? QuickReplies.voiceCleared : VoiceConfirmation.notConfirmed))
        #expect(forgot.value == (approved ? 1 : 0))
    }

    @Test func emptyingTheTrashWaitsForTheOwner() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gate = ConfirmationGate()
        let runner = Runner([["/usr/bin/osascript", "-"]: ""])
        let commands = Self.commands(sandbox, gate: gate, runner: runner)
        let turn = TurnContext(channel: .text)
        #expect(await commands.route("empty the trash", turn: turn)
            == "That will empty the Trash for good, sir — say 'confirm' to proceed.")
        #expect(runner.calls.isEmpty)
        let result = await gate.consume("yes", via: .text(authenticator: Owner(true)), runIn: turn)
        #expect(result == .handled(QuickReplies.trashEmptied))
        #expect(runner.calls == [["/usr/bin/osascript", "-", QuickReplies.emptyTrashScript]])
    }

    @Test func withoutAVoiceForgetMyVoiceGoesToTheBrain() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gate = ConfirmationGate()
        let commands = Self.commands(sandbox, gate: gate)
        #expect(await commands.route("forget my voice", turn: TurnContext(channel: .voice)) == nil)
        #expect(await gate.pending == nil)
    }

    @Test func mediaSpeaksAndRunsTheScript() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let runner = Runner([["/usr/bin/osascript", "-"]: "ok"])
        let commands = Self.commands(sandbox, runner: runner)
        #expect(await commands.route("skip", turn: TurnContext(channel: .voice)) == "Next track, sir.")
        for _ in 0..<500 where runner.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(runner.calls == [["/usr/bin/osascript", "-", QuickReplies.mediaScript("next track")]])
    }

    @Test func quitAllUsesTheAppsHook() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let commands = Self.commands(sandbox, hooks: .init(quitAllApps: { "Closed 2 apps, sir." }))
        #expect(await commands.route("quit everything", turn: TurnContext(channel: .voice)) == "Closed 2 apps, sir.")
    }
}
