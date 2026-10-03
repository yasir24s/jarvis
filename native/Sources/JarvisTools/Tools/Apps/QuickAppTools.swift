import Foundation
import JarvisCore

// PR2: the fast path's own helpers that no catalog tool covers, as internal gateway tools.
// Only the fast path may call them (FastPathOnly): they are never offered to a model, and a
// model that names one is told it is unknown, as for any other name.

/// A fast-path-only tool body: any other origin gets Python's "Unknown tool" reply.
struct FastPathOnly<Tool: ToolImpl>: ToolImpl {
    static var name: String { Tool.name }
    static var schema: ToolSchema { Tool.schema }
    let tool: Tool

    init(_ tool: Tool) { self.tool = tool }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard ctx.origin == .fastPath else { return .text(GuardStrings.unknownTool(Self.name)) }
        return try await tool.run(args, ctx)
    }
}

/// jarvis.py's macOS `APP_ALIASES` and `WEBSITES` (the tables the open and quit helpers read).
enum QuickTables {
    static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome",
        "vscode": "Visual Studio Code", "vs code": "Visual Studio Code", "code": "Visual Studio Code",
        "settings": "System Settings", "system settings": "System Settings",
        "system preferences": "System Settings", "preferences": "System Settings",
        "zoom": "zoom.us", "app store": "App Store", "calc": "Calculator",
        "vlc": "VLC", "word": "Microsoft Word", "excel": "Microsoft Excel",
    ]
    static let websites: [String: String] = [
        "youtube": "https://youtube.com", "google": "https://google.com",
        "gmail": "https://mail.google.com", "github": "https://github.com",
        "twitter": "https://twitter.com", "x": "https://x.com", "reddit": "https://reddit.com",
        "netflix": "https://netflix.com", "chatgpt": "https://chat.openai.com",
        "maps": "https://maps.google.com", "amazon": "https://amazon.com",
    ]

    /// `subprocess.Popen(["open", *args])`: started, not awaited for its result.
    static func open(_ args: [String], runner: any CommandRunning) async {
        _ = await runner.run(["/usr/bin/open"] + args, timeout: 10)
    }

    /// `_app_exists(app)` without AppKit: `fullPathForApplication` finds an app by name in the
    /// standard folders, which is where this looks (the index already covered the rest).
    static func liveAppExists(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                "/Applications/Utilities", home + "/Applications"]
            .contains { FileManager.default.fileExists(atPath: "\($0)/\(name).app") }
    }

    /// The top Spotlight hit for a name that is not a path: `mdfind "kMDItemDisplayName ==
    /// '*{p}*'cd"` and its first line that is not blank, as is (Python does not strip it).
    static func spotlightHit(_ p: String, runner: any CommandRunning) async -> String {
        guard let out = await runner.run(["/usr/bin/mdfind", "kMDItemDisplayName == '*\(p)*'cd"], timeout: 12),
              out.completed, let text = PyText.decode(out.stdout) else { return "" }
        return Py.splitlines(text).first { !Py.strip($0).isEmpty } ?? ""
    }
}

/// `_resolve_open(name)` (the "open X" branch), as one action: what to say, and the launch or
/// URL it starts. `args.name` is the matched name, already stripped.
struct QuickOpenApp: ToolImpl {
    static let name = "quick_open_app"
    static let schema = ToolSchema(name: name)
    let index: AppIndex
    let browser: any DefaultBrowserLookup
    let runner: any CommandRunning
    let appExists: @Sendable (String) -> Bool

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let name = args["name"]?.stringValue ?? ""
        let (reply, action) = await Self.resolve(name, catalog: { await index.catalog() },
                                                 defaultBrowser: { await browser.defaultBrowserName() },
                                                 appExists: appExists)
        if let action { await QuickTables.open(action, runner: runner) }
        return .text(reply)
    }

    /// The announcement and `open`'s arguments (nil where Python's action is None).
    static func resolve(_ name: String, catalog: () async -> AppCatalog, defaultBrowser: () async -> String,
                        appExists: (String) -> Bool) async -> (String, [String]?) {
        let key = Py.rstrip(Py.strip(Py.lower(name)), "?.!")
        if let url = QuickTables.websites[key] { return ("Opening \(name), sir.", [url]) }
        if let kind = AppKinds.kindWord(key) {
            var app = kind == "browser" ? await defaultBrowser() : ""
            if app.isEmpty { app = AppKinds.apps(ofKind: kind, await catalog()).first ?? "" }
            if !app.isEmpty { return ("Opening \(app), sir.", ["-a", app]) }
            return ("I don't see a \(kind) app installed, sir.", nil)
        }
        var app = QuickTables.aliases[key] ?? ""
        if app.isEmpty {
            let entries = await catalog().entries
            if let exact = entries.first(where: { Py.eq($0.low, key) }) {
                app = exact.name
            } else if let fuzzy = entries.first(where: { Py.eq(key, $0.low) || Py.contains($0.low, key)
                                                        || Py.contains(key, $0.low) }) {
                app = fuzzy.name
            }
        }
        if !app.isEmpty || appExists(name) {
            let target = app.isEmpty ? name : app
            return ("Opening \(target), sir.", ["-a", target])
        }
        if Py.contains(key, ".") || key.hasPrefix("http") {
            let url = key.hasPrefix("http") ? key : "https://" + key.replacingOccurrences(of: " ", with: "")
            return ("Opening \(name), sir.", [url])
        }
        return ("I couldn't find an app called \(name), sir.", nil)
    }
}

/// `_open_path(path)` and `_reveal_in_finder(path)`: a path, or else the top Spotlight hit,
/// opened (or shown in Finder with `open -R`).
struct QuickOpenPath: ToolImpl {
    static let name = "quick_open_path"
    static let schema = ToolSchema(name: name)
    let spotlight: any CommandRunning
    let runner: any CommandRunning
    let home: String
    let userHome: @Sendable (String) -> String?
    let exists: @Sendable (String) -> Bool

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let path = args["path"]?.stringValue ?? ""
        let reveal = args["reveal"]?.pyTruthy ?? false
        let expand = ReadFile(home: home, userHome: userHome, recognizer: VisionTextRecognizer())
        var p = expand.expanduser(Py.strip(path)) ?? Py.strip(path)
        if !reveal, p.isEmpty { return .text("Which file, sir?") }
        if !exists(p) {
            p = await QuickTables.spotlightHit(p, runner: spotlight)
            if p.isEmpty { return .text("I couldn't find \(path), sir.") }
        }
        await QuickTables.open(reveal ? ["-R", p] : [p], runner: runner)
        let base = SpotlightQuery.basename(p)
        return .text(reveal ? "Showing \(base) in Finder, sir." : "Opening \(base), sir.")
    }

    static let liveExists: @Sendable (String) -> Bool = { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
}

/// `_open_url(url)`: the Google and YouTube searches.
struct QuickOpenURL: ToolImpl {
    static let name = "quick_open_url"
    static let schema = ToolSchema(name: name)
    let runner: any CommandRunning

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let url = args["url"]?.stringValue ?? ""
        guard url.hasPrefix("https://") else { return .text("") }
        await QuickTables.open([url], runner: runner)
        return .text("")
    }
}

/// `_quit_app(name)`: a kind ("all my browsers") quits every regular running app of that kind
/// but JARVIS (`_quit_kind`); any other name quits the first regular running app whose
/// lowercased name is the name (after "the"/"my" and the aliases) or contains it. "" where
/// Python returns None, so the fast path hands the phrase to the brain.
struct QuickQuitApp: ToolImpl {
    static let name = "quick_quit_app"
    static let schema = ToolSchema(name: name)
    static let leading = try! PyRegex(#"^(the|my)\s+"#)
    static let all = try! PyRegex(#"^all\s+"#)
    let apps: any RunningAppsControlling
    /// The app index (`APP_META`), read for a kind only.
    let catalog: @Sendable () async -> AppCatalog

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        var n = Self.leading.sub(Py.strip(Py.lower(args["name"]?.stringValue ?? "")), literal: "")
        if let kind = AppKinds.kindWord(Self.all.sub(n, literal: "")) { return .text(await quitKind(kind)) }
        n = Py.lower(QuickTables.aliases[n] ?? n)
        guard !n.isEmpty else { return .text("") }
        for app in await apps.runningApps() where app.regular {
            let low = Py.lower(app.name)
            if Py.eq(low, n) || Py.contains(low, n) {
                _ = await apps.terminate(app)
                return .text("Closed \(app.name), sir.")
            }
        }
        return .text("")
    }
}

extension QuickQuitApp {
    /// `_quit_kind(kind)`: the regular running apps, but none named like JARVIS, whose kinds
    /// (`_app_kinds`) include `kind` and which agree to terminate.
    func quitKind(_ kind: String) async -> String {
        let catalog = await self.catalog()
        var closed: [String] = []
        for app in await apps.runningApps() where app.regular {
            let low = Py.lower(app.name)
            if Py.contains(low, "jarvis") { continue }
            if AppKinds.appKinds(low, catalog).contains(kind), await apps.terminate(app) { closed.append(app.name) }
        }
        return closed.isEmpty ? "No \(kind) apps are running, sir." : "Closed \(closed.joined(separator: ", ")), sir."
    }
}
