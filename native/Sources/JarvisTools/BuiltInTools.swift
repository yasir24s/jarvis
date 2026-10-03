import Foundation
import JarvisCore

/// The tool bodies that exist so far (B4: `get_time`; D-50: `personality_note` and
/// `personality_rewrite`; M5 T5.5: `get_battery`, `get_cpu_usage`, `get_wifi_status`,
/// `run_diagnostics`; T5.6: `read_clipboard`; T5.7: `see_screen`, `take_screenshot`; T5.8:
/// `find_apps`; T5.10: `search_files`, `find_files`; T5.11: `read_file`; W1: `web_search`,
/// `get_weather`, `get_location`, `get_news`; F1: `set_reminder`, `set_alarm`), registered on a gateway in one call, so JarvisBrain and JarvisApp
/// never name a tool type. Every other catalog tool stays listed with no body, and the gateway
/// answers it with its unknown-tool text until M5 or M6 adds one.
public enum BuiltInTools {
    /// What the native memory tools (P4: `search_memory`, `forget_memory`, `correct_memory`;
    /// P6: `restore_memory`) need: the store they write through, and the search behind
    /// search_memory.
    public struct Memory: Sendable {
        public let store: MemoryStore
        public let search: any MemorySearching

        public init(store: MemoryStore, search: any MemorySearching) {
            self.store = store
            self.search = search
        }
    }

    /// W1 part 4: what web_search's deep mode needs: the WebKit reader (JarvisApp's) and where
    /// each page it reads is kept, with the query it was read for (the web memory).
    public struct Web: Sendable {
        public let reader: any PageReading
        public let keep: @Sendable (ReadPage, String) -> Void
        /// PB: the on-device model summarize_page and find_song_by_lyrics ask, as Python asked
        /// Ollama. Never a cloud model: the page and the snippet stay on the Mac.
        public let model: (any PersonaLLM)?

        public init(reader: any PageReading, keep: @escaping @Sendable (ReadPage, String) -> Void,
                    model: (any PersonaLLM)? = nil) {
            self.reader = reader
            self.keep = keep
            self.model = model
        }
    }

    /// Registers every implemented body on `gateway`. `clock` and `timeZone` stand in for what
    /// Python's `datetime.now()` reads; the app passes the system's, tests pin both. `core` owns
    /// the personality file the two personality tools write (through its StateStore). With
    /// `memory`, the four memory tools are registered too (NativeToolCatalog). With `web`,
    /// web_search has its deep mode (W1 part 4). With `alarms`, set_reminder and set_alarm write
    /// to JARVIS's alarms.json (F1). `quick` (PR2) is what the fast path's own tools read from the
    /// app: the running apps and the last reply.
    public static func register(on gateway: ToolGateway, core: CoreState, clock: any JarvisClock,
                                timeZone: TimeZone, memory: Memory? = nil, web: Web? = nil,
                                alarms: AlarmBook? = nil, quick: QuickPlatform = QuickPlatform()) async {
        var platform = ToolPlatform.live
        platform.quick = quick
        await register(on: gateway, core: core, clock: clock, timeZone: timeZone, platform: platform, memory: memory,
                       web: web, alarms: alarms)
    }

    /// The same registration over `platform`, the machine-facing readers, so tests register
    /// every body over fakes.
    static func register(on gateway: ToolGateway, core: CoreState, clock: any JarvisClock,
                         timeZone: TimeZone, platform: ToolPlatform, memory: Memory? = nil, web: Web? = nil,
                         alarms: AlarmBook? = nil) async {
        await gateway.register(GetTime(clock: clock, timeZone: timeZone))
        await gateway.register(PersonalityNote(core: core))
        await gateway.register(PersonalityRewrite(core: core))
        // Every M5 body goes through the reply cap (ReplyCap): Python has none, and only a reply
        // that echoes a huge argument can reach it.
        await gateway.register(Capped(GetBattery(probe: platform.system)))
        await gateway.register(Capped(GetCPUUsage(probe: platform.system)))
        await gateway.register(Capped(GetWiFiStatus(probe: platform.system)))
        await gateway.register(Capped(RunDiagnostics(probe: platform.system, clock: clock)))
        await gateway.register(Capped(ReadClipboard(clipboard: platform.clipboard)))
        await gateway.register(Capped(SeeScreen(capturer: platform.screen, recognizer: platform.recognizer)))
        await gateway.register(Capped(TakeScreenshot(capturer: platform.screen, clock: clock, timeZone: timeZone,
                                                     home: platform.home)))
        await gateway.register(Capped(FindApps(index: platform.apps, browser: platform.browser)))
        let spotlight = Spotlight(runner: platform.spotlightRunner, home: platform.home)
        await gateway.register(Capped(SearchFiles(spotlight: spotlight)))
        await gateway.register(Capped(FindFiles(spotlight: spotlight)))
        await gateway.register(Capped(ReadFile(home: platform.home, userHome: platform.userHome,
                                               recognizer: platform.recognizer)))
        await gateway.register(Capped(RunCommand(runner: platform.commandRunner)))
        await gateway.register(Capped(RunAppleScript(runner: platform.scriptRunner)))
        await gateway.register(Capped(WriteFile(session: platform.files)))
        await gateway.register(Capped(MoveFile(session: platform.files)))
        await gateway.register(Capped(DeleteFile(session: platform.files)))
        await gateway.register(Capped(SetVolume(volume: platform.volume)))
        await gateway.register(Capped(SetBrightness(keyboard: platform.keyboard, runner: platform.actionRunner,
                                                    cli: platform.brightnessCLI)))
        await gateway.register(Capped(Notify(notifications: platform.notifications, runner: platform.scriptRunner)))
        await gateway.register(Capped(TypeText(keyboard: platform.keyboard)))
        await gateway.register(Capped(OpenSettings(opener: platform.settingsOpener)))
        await gateway.register(Capped(SystemControl(runner: platform.actionRunner, scriptRunner: platform.scriptRunner,
                                                    executable: platform.executable)))
        // W1 part 1: Python's four web tools, over the platform's GET and is_online.
        await gateway.register(Capped(WebSearch(core: core, web: platform.web, online: platform.online,
                                                log: platform.webLog, deep: web)))
        await gateway.register(Capped(GetWeather(web: platform.web, online: platform.online)))
        await gateway.register(Capped(GetLocation(web: platform.web, online: platform.online)))
        await gateway.register(Capped(GetNews(web: platform.web, online: platform.online, feed: platform.newsFeed,
                                              log: platform.webLog)))
        // PB: Python's four music tools (osascript, as Python; YouTube through the platform's GET).
        await gateway.register(Capped(MusicNowPlaying(runner: platform.scriptRunner)))
        await gateway.register(Capped(MusicSearch(runner: platform.scriptRunner, pause: platform.pause)))
        await gateway.register(Capped(MusicControl(runner: platform.scriptRunner)))
        await gateway.register(Capped(MusicPlay(runner: platform.scriptRunner, web: platform.web, online: platform.online,
                                                opener: platform.urlOpener, log: platform.webLog)))
        // PB: Python's personal-data tools. Messages, contacts and the calendar tag the turn as
        // personal (DataSourceMap); sending and creating events wait for the confirmation gate.
        let scripts = AppleScriptRunner(runner: platform.scriptRunner)
        let contacts = ContactLookup(contacts: platform.contacts, scripts: scripts)
        await gateway.register(Capped(GetMessages(messages: platform.messages)))
        await gateway.register(Capped(FindContact(lookup: contacts)))
        await gateway.register(Capped(SendMessage(lookup: contacts, log: platform.webLog)))
        await gateway.register(Capped(SendEmail(lookup: contacts, log: platform.webLog)))
        await gateway.register(Capped(GetCalendar(calendar: platform.calendar, scripts: scripts, clock: clock,
                                                  timeZone: timeZone, pause: platform.pause)))
        await gateway.register(Capped(CreateEvent(calendar: platform.calendar, scripts: scripts, clock: clock,
                                                  timeZone: timeZone, pause: platform.pause)))
        // PB: Notes, Shortcuts, the front browser page and lyrics.
        await gateway.register(Capped(MakeNote(runner: platform.scriptRunner)))
        let shortcuts = ShortcutsCLI(runner: platform.actionRunner, executable: platform.executable)
        await gateway.register(Capped(RunShortcut(shortcuts: shortcuts, log: platform.webLog)))
        await gateway.register(Capped(ListShortcuts(shortcuts: shortcuts)))
        await gateway.register(Capped(SummarizePage(runner: platform.scriptRunner, web: platform.web,
                                                    online: platform.online, frontApp: platform.frontApp,
                                                    reader: web?.reader, model: web?.model,
                                                    log: platform.webLog)))
        await gateway.register(Capped(FindSongByLyrics(web: platform.web, online: platform.online, model: web?.model,
                                                       log: platform.webLog)))
        if let memory {
            await gateway.register(Capped(SearchMemory(memory: memory.store, search: memory.search)))
            await gateway.register(Capped(ForgetMemory(memory: memory.store)))
            await gateway.register(Capped(CorrectMemory(memory: memory.store, clock: clock)))
            await gateway.register(Capped(RestoreMemory(memory: memory.store)))
        }
        if let alarms {
            await gateway.register(Capped(SetReminder(book: alarms, clock: clock, timeZone: timeZone)))
            await gateway.register(Capped(SetAlarm(book: alarms, clock: clock, timeZone: timeZone)))
        }
        // PR2: the fast path's own helpers, never offered to a model (FastPathOnly).
        await gateway.register(FastPathOnly(QuickOpenApp(index: platform.apps, browser: platform.browser,
                                                         runner: platform.opener, appExists: platform.appExists)))
        await gateway.register(FastPathOnly(QuickOpenPath(spotlight: platform.spotlightRunner, runner: platform.opener,
                                                          home: platform.home, userHome: platform.userHome,
                                                          exists: platform.pathExists)))
        await gateway.register(FastPathOnly(QuickOpenURL(runner: platform.opener)))
        await gateway.register(FastPathOnly(QuickQuitApp(apps: platform.quick.runningApps, catalog: { [apps = platform.apps] in await apps.catalog() })))
    }

    /// The generated `ToolCatalog` entry for `name`, so no body carries a hand-written schema.
    static func catalogSchema(named name: String) -> ToolSchema {
        ToolCatalog.tools.first { $0.name == name } ?? ToolSchema(name: name)
    }
}

/// What the M5 tool bodies read from the machine, behind protocols. `live` is the app's; tests
/// build one from fakes, so no test reads the real battery, pasteboard, screen or network.
struct ToolPlatform: Sendable {
    var system: any SystemProbing
    var clipboard: any ClipboardReading
    var screen: any ScreenCapturing
    var recognizer: any TextRecognizing
    /// `$HOME`, as Python's `os.path.expanduser` reads it.
    var home: String
    /// Built on the first find_apps, then kept for the process, as Python's APP_INDEX.
    var apps: AppIndex
    var browser: any DefaultBrowserLookup
    /// mdfind for search_files and find_files.
    var spotlightRunner: any CommandRunning
    /// `pwd.getpwnam(name).pw_dir`, for read_file's `~name` paths.
    var userHome: @Sendable (String) -> String? = ReadFile.passwdHome
    /// run_command's `/bin/sh` and run_applescript's osascript, with the agent PATH.
    var commandRunner: any CommandRunning = BoundedRunner(environment: BoundedRunner.agentEnvironment())
    var scriptRunner: any StdinCommandRunning = BoundedRunner(environment: BoundedRunner.agentEnvironment())
    /// write_file, move_file and delete_file, with `_written_this_session` kept per process.
    var files: FileMutationSession = .live
    /// The fixed internal commands (the brightness CLI, later networksetup, blueutil,
    /// defaults, killall and shortcuts), with the agent PATH. Never model text.
    var actionRunner: any CommandRunning = BoundedRunner(environment: BoundedRunner.agentEnvironment())
    /// CoreAudio's default output device.
    var volume: any VolumeSetting = LiveVolume()
    /// CGEvent keyboard posts, for type_text and set_brightness's key-tap fallback.
    var keyboard: any KeyboardPosting = LiveKeyboard()
    /// UserNotifications when JARVIS is authorised; notify falls back to osascript otherwise.
    var notifications: any NotificationPosting = LiveNotification()
    /// `_brightness_cli()`: the Homebrew `brightness` command, when installed.
    var brightnessCLI: @Sendable () -> String? = SetBrightness.liveCLI
    /// LaunchServices, for open_settings's `x-apple.systempreferences:` URLs (no AppKit here).
    var settingsOpener: any SettingsOpening = LiveSettingsOpener()
    /// `shutil.which` over the agent PATH, for blueutil and shortcuts.
    var executable: @Sendable (String) -> String? = SystemControl.liveExecutable
    /// W1 part 1: the web tools' GET and Python's is_online. Until the app gives them the
    /// network, a platform has none and reads as offline, so no fake platform reaches it.
    var web: any WebFetching = NoWebFetch()
    var online: @Sendable () async -> Bool = { false }
    /// get_news's feed: `JARVIS_NEWS_FEED`, else BBC News.
    var newsFeed: String = GetNews.defaultFeed
    /// The web tools' log (error kinds only, never a query or a URL).
    var webLog: @Sendable (String) -> Void = { _ in }
    /// PB: music_play's `open URL`. Until the app gives it LaunchServices, nothing is opened.
    var urlOpener: any SettingsOpening = NoURLOpener()
    /// PB: `time.sleep`, for `_ensure_app_running`'s wait. Tests pass none.
    var pause: @Sendable (Double) async -> Void = { _ in }
    /// PB: Messages' chat.db, the address book and EventKit. A platform has none of them until
    /// the app gives it the real ones, so no fake platform reads personal data.
    var messages: any MessagesReading = NoMessages()
    var contacts: any ContactsReading = NoContacts()
    var calendar: any CalendarStoring = NoCalendar()
    /// PB: `_front_app()`, for summarize_page's browser order.
    var frontApp: @Sendable () async -> String = { "" }
    /// PR2: the fast path's own tools. `open` (apps, files, URLs) runs on `opener`, which
    /// runs nothing until the app's live platform; the running apps and the last reply come
    /// from the app (QuickPlatform).
    var opener: any StdinCommandRunning = NoCommands()
    var appExists: @Sendable (String) -> Bool = { _ in false }
    var pathExists: @Sendable (String) -> Bool = { _ in false }
    var quick: QuickPlatform = QuickPlatform()

    static var live: ToolPlatform {
        var platform = ToolPlatform(system: LiveSystemProbe(), clipboard: LivePasteboard(), screen: LiveScreenCapture(),
                                    recognizer: VisionTextRecognizer(),
                                    home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
                                    apps: AppIndex(runner: BoundedRunner()), browser: LiveDefaultBrowser(),
                                    spotlightRunner: BoundedRunner(cap: Spotlight.cap))
        platform.web = LiveWebFetch()
        platform.online = { await Net.isOnline() }
        platform.newsFeed = GetNews.feed(ProcessInfo.processInfo.environment)
        platform.webLog = { JarvisLog.log($0, category: .tools) }
        platform.urlOpener = LiveSettingsOpener()
        platform.pause = { try? await Task.sleep(for: .seconds($0)) }
        platform.messages = LiveMessages(home: platform.home)
        platform.contacts = LiveContacts()
        platform.calendar = LiveCalendar.shared
        platform.frontApp = { SummarizePage.liveFrontApp() }
        platform.opener = BoundedRunner(environment: BoundedRunner.agentEnvironment())
        platform.appExists = { QuickTables.liveAppExists($0) }
        platform.pathExists = QuickOpenPath.liveExists
        return platform
    }
}

/// The bound on every M5 reply (the brief: no tool returns more than about 1 MiB). The MCP
/// server reads request lines of up to 1 MiB and drops a connection with 4 MiB of replies
/// queued, so a reply that echoes an argument (read_file's error text repeats the path twice,
/// once as a repr) could pass that. At most 1 MiB of UTF-8 and 256 Ki code points (JSON
/// escaping widens a code point to 12 bytes at most, so 3 MiB), cut on a code point. Python
/// has no cap; every reply its own caps allow is far below this.
enum ReplyCap {
    static let bytes = 1 << 20
    static let scalars = 1 << 18

    static func apply(_ text: String) -> String {
        if text.utf8.count <= bytes && text.unicodeScalars.count <= scalars { return text }
        var out = String.UnicodeScalarView()
        var size = 0
        for (i, u) in text.unicodeScalars.enumerated() {
            let width = String(u).utf8.count
            guard i < scalars, size + width <= bytes else { break }
            out.append(u)
            size += width
        }
        return String(out)
    }
}

/// A tool body with its text reply passed through `ReplyCap`.
struct Capped<Tool: ToolImpl>: ToolImpl {
    static var name: String { Tool.name }
    static var schema: ToolSchema { Tool.schema }
    let tool: Tool

    init(_ tool: Tool) { self.tool = tool }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let outcome = try await tool.run(args, ctx)
        if case .text(let text) = outcome { return .text(ReplyCap.apply(text)) }
        return outcome
    }
}
