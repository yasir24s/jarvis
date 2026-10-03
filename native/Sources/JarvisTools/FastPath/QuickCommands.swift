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

        public init(forgetVoice: (@Sendable () async -> String)? = nil,
                    quitAllApps: (@Sendable () async -> String)? = nil,
                    afterGoodnight: @escaping @Sendable () async -> Void = {
                        try? await Task.sleep(for: .milliseconds(1200))
                    }) {
            self.forgetVoice = forgetVoice
            self.quitAllApps = quitAllApps
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

    public init(core: CoreState, confirmations: ConfirmationGate, timers: QuickTimers?, alarms: AlarmBook?,
                timeZone: TimeZone = .autoupdatingCurrent, hooks: Hooks,
                online: @escaping @Sendable () async -> Bool,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .tools) }) {
        self.init(router: FastPathRouter(), core: core, confirmations: confirmations, timers: timers,
                  alarms: alarms, timeZone: timeZone, hooks: hooks, runner: BoundedRunner(), web: LiveWebFetch(),
                  online: online, log: log)
    }

    init(router: FastPathRouter, core: CoreState, confirmations: ConfirmationGate, timers: QuickTimers?,
         alarms: AlarmBook?, timeZone: TimeZone, hooks: Hooks, runner: any StdinCommandRunning,
         web: any WebFetching, online: @escaping @Sendable () async -> Bool,
         log: @escaping @Sendable (String) -> Void) {
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
    }

    /// The reply for `text`, or nil for the brain. Actions that Python ran beside the spoken
    /// announcement are started here and not awaited.
    public func route(_ text: String, turn: TurnContext) async -> String? {
        let match = router.route(text)
        guard let command = match.command, let reply = await perform(command, turn: turn) else { return nil }
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
        }
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
