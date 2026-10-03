import Foundation
import JarvisCore

/// PA batch A: jarvis.py's fast path (`fast_path` and `handle_one`'s handling of its result,
/// 5582-5596) for the commands this port carries. A command Python answered with a tuple speaks
/// its announcement while the action starts; one it answered with a helper's text says that
/// text. Every other phrase, and every branch not carried yet, goes to the brain (nil).
///
/// Destructive commands do not run at once, unlike Python: forgetting the voice and emptying
/// the Trash are stashed in the confirmation gate the coordinator consumes, so they pass the
/// same owner check (Touch ID or the password) as every other confirmation, spoken or typed.
public struct QuickCommands: Sendable {
    /// What the app supplies: the parts that need AppKit, the voice or the speech queue.
    public struct Hooks: Sendable {
        /// Deletes the voiceprint and returns `forget_voice()`'s reply; nil when there is no voice.
        public var forgetVoice: (@Sendable () async -> String)?
        /// Asks the running apps to quit (`QuickReplies.quitAll`) and returns the reply.
        public var quitAllApps: (@Sendable () async -> String)?
        /// Returns once "Goodnight, sir." has had time to be heard (Python sleeps 1.2 s).
        public var afterGoodnight: @Sendable () async -> Void
        /// PR2: `_backend_report()` (BackendReporter.report); nil sends "which model" to the brain.
        public var backendReport: (@Sendable () async -> String)?

        public init(forgetVoice: (@Sendable () async -> String)? = nil,
                    quitAllApps: (@Sendable () async -> String)? = nil,
                    backendReport: (@Sendable () async -> String)? = nil,
                    afterGoodnight: @escaping @Sendable () async -> Void = {
                        try? await Task.sleep(for: .milliseconds(1200))
                    }) {
            self.forgetVoice = forgetVoice
            self.quitAllApps = quitAllApps
            self.backendReport = backendReport
            self.afterGoodnight = afterGoodnight
        }
    }

    let router: FastPathRouter
    let core: CoreState
    let confirmations: ConfirmationGate
    let timers: QuickTimers?
    let alarms: AlarmBook?
    let timeZone: TimeZone
    let hooks: Hooks
    let runner: any StdinCommandRunning
    let web: any WebFetching
    let online: @Sendable () async -> Bool
    let log: @Sendable (String) -> Void
    /// PR2: the gateway the carried helpers run through (`origin: .fastPath`), so they pass the
    /// same guards, taint rules and confirmations as a model's call. Nil: only the batch A
    /// commands answer and every other branch goes to the brain.
    let tools: ToolGateway?
    let browser: any DefaultBrowserLookup

    public init(core: CoreState, confirmations: ConfirmationGate, timers: QuickTimers?, alarms: AlarmBook?,
                timeZone: TimeZone = .autoupdatingCurrent, hooks: Hooks, tools: ToolGateway? = nil,
                online: @escaping @Sendable () async -> Bool,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .tools) }) {
        self.init(router: FastPathRouter(), core: core, confirmations: confirmations, timers: timers,
                  alarms: alarms, timeZone: timeZone, hooks: hooks, runner: BoundedRunner(), web: LiveWebFetch(),
                  online: online, log: log, tools: tools, browser: LiveDefaultBrowser())
    }

    init(router: FastPathRouter, core: CoreState, confirmations: ConfirmationGate, timers: QuickTimers?,
         alarms: AlarmBook?, timeZone: TimeZone, hooks: Hooks, runner: any StdinCommandRunning,
         web: any WebFetching, online: @escaping @Sendable () async -> Bool,
         log: @escaping @Sendable (String) -> Void, tools: ToolGateway? = nil,
         browser: any DefaultBrowserLookup = LiveDefaultBrowser()) {
        self.router = router
        self.core = core
        self.confirmations = confirmations
        self.timers = timers
        self.alarms = alarms
        self.timeZone = timeZone
        self.hooks = hooks
        self.runner = runner
        self.web = web
        self.online = online
        self.log = log
        self.tools = tools
        self.browser = browser
    }

    /// The reply for `text`, or nil for the brain. Actions that Python ran beside the spoken
    /// announcement are started here and not awaited.
    public func route(_ text: String, turn: TurnContext) async -> String? {
        let match = router.route(text)
        guard FastPathRouter.carried.contains(match.branch), let command = match.command,
              let reply = await perform(command, turn: turn) else { return nil }
        log("fast path: \(match.branch)")      // the branch only: never the user's words
        return reply
    }

    func perform(_ command: FastPathCommand, turn: TurnContext) async -> String? {
        switch command {
        case .forgetCorrection(let t):
            return await core.forgetCorrection(t)
        case .learnCorrection(let t):
            return await core.learnCorrection(t)
        case .media(let announcement, let cmd):
            let runner = self.runner, log = self.log
            Task.detached {
                let out = await AppleScriptRunner(runner: runner).run(QuickReplies.mediaScript(cmd))
                if !Py.eq(out, "ok") { log("fast path: media \(cmd) -> \(Py.prefix(out, 200))") }
            }
            return announcement
        case .presence:
            return QuickReplies.presence
        case .forgetVoice:
            guard let forget = hooks.forgetVoice else { return nil }
            await confirmations.stash(desc: QuickReplies.forgetVoiceDesc, action: { await forget() }, turn: turn)
            return GuardStrings.gatePrompt(QuickReplies.forgetVoiceDesc)
        case .setTimer(let secs):
            return timers?.set(seconds: secs)
        case .cancelTimers:
            return timers?.cancel()
        case .timerStatus:
            return timers?.status()
        case .cancelAlarms:
            guard let alarms else { return nil }
            return QuickReplies.alarmsCancelled(alarms.cancelAlarms())
        case .listAlarms:
            guard let alarms else { return nil }
            let (count, parsed) = alarms.alarms()
            return QuickReplies.alarmList(count: count, parsed: parsed, timeZone: timeZone)
        case .lockScreen:
            let runner = self.runner
            Task.detached { _ = await runner.run(["/usr/bin/pmset", "displaysleepnow"], timeout: 5) }
            return QuickReplies.locking
        case .emptyTrash:
            let runner = self.runner
            await confirmations.stash(desc: QuickReplies.emptyTrashDesc, action: {
                QuickReplies.emptyTrash(osascript: await AppleScriptRunner(runner: runner).run(QuickReplies.emptyTrashScript))
            }, turn: turn)
            return GuardStrings.gatePrompt(QuickReplies.emptyTrashDesc)
        case .quitAllApps:
            guard let quit = hooks.quitAllApps else { return nil }
            return await quit()
        case .sleepMac:
            let runner = self.runner, wait = hooks.afterGoodnight
            Task.detached {
                await wait()
                _ = await runner.run(["/usr/bin/pmset", "sleepnow"], timeout: 10)
            }
            return QuickReplies.goodnight
        case .ipReport:
            return await ipReport()
        case .btBattery:
            let out = await runner.run(["/usr/sbin/ioreg", "-r", "-l", "-k", "BatteryPercentLeft"], timeout: 8)
            let text = out.flatMap { $0.completed ? String(decoding: $0.stdout, as: UTF8.self) : nil } ?? ""
            return QuickReplies.bluetoothBattery(ioreg: text)
        // PR2: Python's helper replies, through the tool that is that helper.
        case .diagnostics: return await tool("run_diagnostics", turn: turn)
        case .runShortcut(let name): return await tool("run_shortcut", ["name": .string(name)], turn: turn)
        case .openPath(let path): return await tool(QuickOpenPath.name, ["path": .string(path)], turn: turn)
        case .reveal(let path):
            return await tool(QuickOpenPath.name, ["path": .string(path), "reveal": .bool(true)], turn: turn)
        case .resolveOpen(let name): return await tool(QuickOpenApp.name, ["name": .string(name)], turn: turn)
        case .nowPlaying: return await tool("music_now_playing", turn: turn)
        case .playQuery(let q): return await tool("music_play", ["query": .string(q)], turn: turn)
        case .location: return await tool("get_location", turn: turn)
        case .weather(let city): return await tool("get_weather", ["location": .string(city)], turn: turn)
        case .reminder(let task, let when):
            return await tool("set_reminder", ["text": .string(task), "when": .string(when)], turn: turn)
        case .setAlarm(let when): return await tool("set_alarm", ["when": .string(when)], turn: turn)
        case .songByLyrics(let lyrics): return await tool("find_song_by_lyrics", ["lyrics": .string(lyrics)], turn: turn)
        case .messages: return await tool("get_messages", turn: turn)
        case .calendar: return await tool("get_calendar", turn: turn)
        case .briefing: return await briefing(turn: turn)
        case .makeNote(let text): return await tool("make_note", ["text": .string(text)], turn: turn)
        case .systemInfo(let kind): return await tool(kind == "time" ? "get_time" : "get_battery", turn: turn)
        case .backendReport: return await hooks.backendReport?()
        case .news: return await tool("get_news", turn: turn)
        case .screenshot: return await tool("take_screenshot", turn: turn)
        case .sendMessage(let recipient, let text):
            return await tool("send_message", ["recipient": .string(recipient), "text": .string(text)], turn: turn)
        case .typeText(let text): return await tool("type_text", ["text": .string(text)], turn: turn)
        case .summarizePage: return await tool("summarize_page", turn: turn)
        case .listShortcuts: return await tool("list_shortcuts", turn: turn)
        case .findApps(let kind): return await tool("find_apps", ["query": .string(kind)], turn: turn)
        case .recentFiles: return await tool("find_files", ["query": .string(""), "recent": .bool(true)], turn: turn)
        case .quitApp(let name):
            // "" is Python's None: nothing by that name is running, so the brain gets the phrase.
            guard let reply = await tool(QuickQuitApp.name, ["name": .string(name)], turn: turn), !reply.isEmpty else {
                return nil
            }
            return reply
        case .defaultBrowser:
            let db = await browser.defaultBrowserName()
            return db.isEmpty ? "I couldn't determine your default browser, sir." : "Your default browser is \(db), sir."
        // Python's tuples: the line is spoken while the action runs.
        case .openSettings(let spoken, let pane):
            return act(spoken, "open_settings", pane.map { ["pane": .string($0)] } ?? [:], turn: turn)
        case .setVolume(let spoken, let level): return act(spoken, "set_volume", ["level": .int(Int64(level))], turn: turn)
        case .setBrightness(let spoken, let level):
            return act(spoken, "set_brightness", ["level": .int(Int64(level))], turn: turn)
        case .toggleSystem(let spoken, let feature, let on):
            return act(spoken, "system_control", ["feature": .string(feature), "enable": .bool(on)], turn: turn)
        case .macosTweak(let thing, let on):
            // `_macos_tweak(thing, on)` is system_control's own fall-through for a name that is
            // not one of the system toggles, which the router has already ruled out.
            return act("Done, sir.", "system_control", ["feature": .string(thing), "enable": .bool(on)], turn: turn)
        case .openURL(let spoken, let url): return act(spoken, QuickOpenURL.name, ["url": .string(url)], turn: turn)
        case .nudgeVolume(let spoken, let delta):
            return act(spoken, QuickNudgeVolume.name, ["delta": .int(Int64(delta))], turn: turn)
        case .nudgeBrightness(let spoken, let steps):
            return act(spoken, QuickNudgeBrightness.name, ["steps": .int(Int64(steps))], turn: turn)
        case .copyLastReply: return await tool(QuickCopyLastReply.name, turn: turn)
        case .setDefaultBrowser(let name):
            return await tool(QuickSetDefaultBrowser.name, ["name": .string(name)], turn: turn)
        }
    }

    /// A helper's reply: the tool's text, run on this turn. Nil (the brain) without a gateway
    /// or where the tool has no body (set_reminder without the alarms book).
    func tool(_ name: String, _ args: [String: JSONValue] = [:], turn: TurnContext) async -> String? {
        guard let tools else { return nil }
        let object = JSONObject(args.sorted { $0.key < $1.key }.map { JSONObject.Member(key: $0.key, value: $0.value) })
        let result = await tools.call(name, object, turn: turn, origin: .fastPath)
        return result.record.outcome == .unknown ? nil : result.text
    }

    /// `(announcement, action)`: the line at once, the action in the background. The turn ends
    /// as soon as the line is said, so the action runs on a turn of its own, begun as this one
    /// was (same channel, and tainted if this one began with a paste), and is never awaited, as
    /// Python's thread is not. None of these tools asks for a confirmation.
    func act(_ announcement: String, _ name: String, _ args: [String: JSONValue], turn: TurnContext) -> String? {
        guard let tools else { return nil }
        let object = JSONObject(args.sorted { $0.key < $1.key }.map { JSONObject.Member(key: $0.key, value: $0.value) })
        let channel = turn.channel, pasted = turn.startedPasteTainted, log = self.log
        Task.detached {
            let own = TurnContext(channel: channel, startTainted: pasted)
            let result = await tools.call(name, object, turn: own, origin: .fastPath)
            await own.close()
            if result.record.outcome != .ran { log("fast path: \(name) did not run") }
        }
        return announcement
    }

    /// `_briefing()`: the time, the weather when online, today's calendar unless it could not be
    /// read, and three headlines when online and fetched.
    func briefing(turn: TurnContext) async -> String? {
        guard let time = await tool("get_time", turn: turn) else { return nil }
        var parts = [time]
        if await online(), let weather = await tool("get_weather", turn: turn) { parts.append(weather) }
        if let cal = await tool("get_calendar", turn: turn), !cal.isEmpty, !cal.hasPrefix("I can't") {
            parts.append(cal)
        }
        if await online(), let news = await tool("get_news", ["count": .int(3)], turn: turn),
           news.hasPrefix("Top headlines") {
            parts.append(news)
        }
        return parts.joined(separator: " ")
    }

    /// `_ip_report()`'s readings: `ipconfig getifaddr` en0 then en1, then ipwho.is when online.
    func ipReport() async -> String {
        var local = ""
        for iface in ["en0", "en1"] {
            if let out = await runner.run(["/usr/sbin/ipconfig", "getifaddr", iface], timeout: 5), out.completed {
                let text = Py.strip(String(decoding: out.stdout, as: UTF8.self))
                if !text.isEmpty {
                    local = text
                    break
                }
            }
        }
        var publicIP = ""
        if await online() {
            if let body = try? await web.get("https://ipwho.is/", headers: [("User-Agent", "JARVIS/1.0 (personal assistant)")],
                                             timeout: 8),
               case .object(let o)? = try? PyJSON.loads(body), let ip = o["ip"]?.stringValue {
                publicIP = ip
            }
        }
        return QuickReplies.ipReport(local: local, publicIP: publicIP)
    }
}
