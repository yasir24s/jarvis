import CoreGraphics
import Foundation
import JarvisCore

// PR2 item 2: the five fast-path helpers that had no tool, so the brain improvised them with
// run_command or run_applescript. Fast-path-only (FastPathOnly), never offered to a model.

/// `_copy_last_reply()`: the last reply, stripped, to the clipboard with `pbcopy`.
struct QuickCopyLastReply: ToolImpl {
    static let name = "quick_copy_last_reply"
    static let schema = ToolSchema(name: name)
    let lastReply: LastReply
    let runner: any StdinCommandRunning

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let text = Py.strip(lastReply.value)
        if text.isEmpty { return .text("I haven't said anything worth copying yet, sir.") }
        // `_set_clipboard`: True unless pbcopy could not be run (the exception Python catches).
        guard let out = await runner.run(["/usr/bin/pbcopy"], input: Data(text.utf8), timeout: 5),
              out.launchErrno == nil, !out.timedOut else {
            return .text("I couldn't write to the clipboard, sir.")
        }
        return .text("Copied to your clipboard, sir.")
    }
}

/// `_set_default_browser(name)`: the first indexed app whose name is the name or contains it
/// and is a browser (or is exactly the name), made the default for http. macOS asks the user
/// to confirm, which is why the reply says so.
struct QuickSetDefaultBrowser: ToolImpl {
    static let name = "quick_set_default_browser"
    static let schema = ToolSchema(name: name)
    let catalog: @Sendable () async -> AppCatalog
    let setter: any DefaultBrowserSetting

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let name = args["name"]?.stringValue ?? ""
        let key = Py.strip(Py.lower(name))
        let catalog = await self.catalog()
        let found = catalog.entries.first { entry in
            (Py.eq(entry.low, key) || Py.contains(entry.low, key))
                && (AppKinds.appKinds(entry.low, catalog).contains("browser") || Py.eq(key, entry.low))
        }
        guard let app = found else { return .text("I couldn't find a browser called \(name), sir.") }
        if app.path.isEmpty { return .text("I couldn't locate \(app.name) on disk, sir.") }
        guard await setter.setDefaultBrowser(appPath: app.path) else {
            return .text("macOS wouldn't let me switch it directly, sir — set \(app.name) "
                         + "as default in System Settings, Desktop and Dock.")
        }
        return .text("Setting \(app.name) as your default browser, sir — please confirm the system prompt.")
    }
}

/// `_nudge_volume(delta)`: Python's own osascript line, relative to the current level.
struct QuickNudgeVolume: ToolImpl {
    static let name = "quick_nudge_volume"
    static let schema = ToolSchema(name: name)
    let runner: any StdinCommandRunning

    static func script(_ delta: Int) -> String {
        "set volume output volume ((output volume of (get volume settings)) + (\(delta)))"
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard case .int(let delta)? = args["delta"] else { return .text("") }
        _ = await runner.run(["/usr/bin/osascript", "-e", Self.script(Int(delta))], timeout: 5)
        return .text("")
    }
}

/// `_nudge_brightness(steps)`: brightness-up (144) or brightness-down (145) key taps, as many
/// as the steps. Python sends them through System Events; native posts them as set_brightness
/// does (CGEvent), so the same Accessibility grant covers both.
struct QuickNudgeBrightness: ToolImpl {
    static let name = "quick_nudge_brightness"
    static let schema = ToolSchema(name: name)
    static let denied = "I need Accessibility permission to change brightness, sir."
    let keyboard: any KeyboardPosting

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard case .int(let steps)? = args["steps"] else { return .text("") }
        guard keyboard.permitted() else { return .text(Self.denied) }
        let key: CGKeyCode = steps > 0 ? 144 : 145
        for _ in 0..<abs(Int(steps)) { guard keyboard.key(key) else { return .text(Self.denied) } }
        return .text("Done, sir.")
    }
}
