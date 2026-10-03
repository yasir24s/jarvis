import Foundation
import JarvisCore

struct SystemControl: ToolImpl {
    static let name = "system_control"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let runner: any CommandRunning
    let scriptRunner: any StdinCommandRunning
    let executable: @Sendable (String) -> String?

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let raw = try PyArgs.stringOrEmpty(args, "feature", method: "lower")
        let name = Py.strip(Py.lower(raw))
        let on = args["enable"]?.pyTruthy ?? true
        switch name {
        case "wifi", "wi-fi", "wireless":
            let output = try ActionProcess.require(await runner.run(["/usr/sbin/networksetup", "-listallhardwareports"], timeout: 8),
                                                   argv: ["networksetup", "-listallhardwareports"], timeout: 8)
            if let error = PyText.decodeError(output.stdout) ?? PyText.decodeError(output.stderr) { throw PyError(description: error) }
            let ports = PyText.decode(output.stdout) ?? ""
            let interface = Self.wifi.search(ports)?.groups[1] ?? "en0"
            let argv = ["/usr/sbin/networksetup", "-setairportpower", interface, on ? "on" : "off"]
            _ = try ActionProcess.require(await runner.run(argv, timeout: 8),
                                           argv: ["networksetup"] + argv.dropFirst(), timeout: 8)
            return .text("Wi-Fi \(on ? "on" : "off"), sir.")
        case "bluetooth", "bt":
            guard let cli = executable("blueutil") else {
                return .text("I need the blueutil tool to toggle Bluetooth, sir — install it with brew install blueutil.")
            }
            let argv = [cli, "-p", on ? "1" : "0"]
            _ = try ActionProcess.require(await runner.run(argv, timeout: 8), argv: argv, timeout: 8)
            return .text("Bluetooth \(on ? "on" : "off"), sir.")
        case "do not disturb", "dnd", "focus":
            return .text(await doNotDisturb())
        case "dark mode", "dark", "light mode":
            return .text(await dark(name == "light mode" ? !on : on))
        default:
            let key = Self.leadingThe.sub(name, literal: "")
            // Python's first entry is dark mode, even for an empty substring.
            if Py.eq(key, "dark mode") || (!Self.tweaks.contains(where: { Py.eq($0.name, key) }) &&
                                           (Py.contains("dark mode", key) || Py.contains(key, "dark mode"))) {
                return .text(await dark(on))
            }
            guard let tweak = Self.tweaks.first(where: { Py.eq($0.name, key) })
                ?? Self.tweaks.first(where: { Py.contains($0.name, key) || Py.contains(key, $0.name) }) else {
                return .text("I don't have a hidden toggle for \(name), sir.")
            }
            let argv = ["/usr/bin/defaults", "write", tweak.domain == "NSGlobalDomain" ? "-g" : tweak.domain,
                        tweak.key, "-bool", on ? tweak.on : tweak.off]
            guard let result = await runner.run(argv, timeout: 8), result.completed, result.status == 0 else {
                return .text("I couldn't change \(tweak.name), sir.")
            }
            if let restart = tweak.restart {
                guard let result = await runner.run(["/usr/bin/killall", restart], timeout: 8), result.completed else {
                    return .text("I couldn't change \(tweak.name), sir.")
                }
            }
            let capital = tweak.name.prefix(1).uppercased() + tweak.name.dropFirst()
            return .text("\(capital) \(on ? "enabled" : "disabled"), sir.")
        }
    }

    private func dark(_ on: Bool) async -> String {
        let reply = await AppleScriptRunner(runner: scriptRunner).run(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on ? "true" : "false")")
        return Py.contains(Py.lower(reply), "error") ? "I couldn't change the appearance, sir."
            : "Dark mode \(on ? "on" : "off"), sir."
    }

    /// `_toggle_system`'s DND branch: `_run_shortcut("toggle do not disturb")`, with Python's
    /// guide in place of any reply that says "couldn't find".
    private func doNotDisturb() async -> String {
        let reply = await runShortcut("toggle do not disturb")
        return Py.contains(reply, "couldn't find")
            ? "I can toggle Do Not Disturb if you make a Shortcut named 'toggle do not disturb', sir." : reply
    }

    /// `_run_shortcut(name)`, for this internal call only (the run_shortcut tool is M6).
    private func runShortcut(_ wanted: String) async -> String {
        guard let cli = executable("shortcuts"), let match = Self.matchShortcut(await shortcuts(cli)) else {
            return "I couldn't find a shortcut matching \(wanted), sir."
        }
        guard let result = await runner.run([cli, "run", match], timeout: 60) else {
            return "Shortcut error: command could not be started"
        }
        if result.timedOut { return "The \(match) shortcut is taking a while, sir — it may still be running." }
        if let code = result.launchErrno {
            return "Shortcut error: [Errno \(code)] \(String(cString: strerror(code))): 'shortcuts'"
        }
        // text=True decodes both streams before the exit status is looked at.
        if let error = PyText.decodeError(result.stdout) ?? PyText.decodeError(result.stderr) {
            return "Shortcut error: \(error)"
        }
        return result.status == 0 ? "Done, sir." : "The \(match) shortcut failed, sir."
    }

    /// `_shortcuts_all`: the stripped, non-empty lines of `shortcuts list`, or none when the
    /// run fails in any way (Python logs the exception and returns []).
    private func shortcuts(_ cli: String) async -> [String] {
        guard let list = await runner.run([cli, "list"], timeout: 10), list.completed,
              PyText.decodeError(list.stderr) == nil, let text = PyText.decode(list.stdout) else { return [] }
        return Py.splitlines(text).map { Py.strip($0) }.filter { !$0.isEmpty }
    }

    /// `_match_shortcut("toggle do not disturb")`: exact, then the shortest substring match,
    /// then the best token overlap of at least one half. Compared by code points, as Python.
    static func matchShortcut(_ names: [String]) -> String? {
        let wanted = "toggle do not disturb"
        if let exact = names.first(where: { Py.eq(Py.lower($0), wanted) }) { return exact }
        let substrings = names.filter { Py.contains(Py.lower($0), wanted) || Py.contains(wanted, Py.lower($0)) }
        if let shortest = substrings.min(by: { $0.unicodeScalars.count < $1.unicodeScalars.count }) { return shortest }
        let tokens = Set(Py.split(wanted).map { Array($0.unicodeScalars) })
        var best: String?, score = 0.0
        for name in names {
            let words = Set(Py.split(Py.lower(name)).map { Array($0.unicodeScalars) })
            let overlap = Double(tokens.intersection(words).count) / Double(max(1, tokens.union(words).count))
            if overlap > score { score = overlap; best = name }
        }
        return score >= 0.5 ? best : nil
    }

    /// `shutil.which(name)` over the agent PATH (plan §3.4, so the blueutil lookup finds what
    /// Python finds): the first entry holding an executable that is not a directory.
    static func liveExecutable(_ name: String) -> String? {
        BoundedRunner.agentPATH.split(separator: ":").map { String($0) + "/" + name }.first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory) && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: $0)
        }
    }
    private static let wifi = try! PyRegex(#"Wi-Fi\n.*?Device:\s*(\w+)"#)
    private static let leadingThe = try! PyRegex(#"^(the)\s+"#)
    private struct Tweak: Sendable {
        let name: String, domain: String, key: String, on: String, off: String
        let restart: String?
    }
    /// The tweaks' names in table order (the fast path's toggle branch matches against them).
    static var tweakNames: [String] { tweaks.map(\.name) }
    private static let tweaks: [Tweak] = [
        Tweak(name: "hidden files", domain: "com.apple.finder", key: "AppleShowAllFiles", on: "true", off: "false", restart: "Finder"),
        Tweak(name: "show hidden files", domain: "com.apple.finder", key: "AppleShowAllFiles", on: "true", off: "false", restart: "Finder"),
        Tweak(name: "file extensions", domain: "NSGlobalDomain", key: "AppleShowAllExtensions", on: "true", off: "false", restart: "Finder"),
        Tweak(name: "dock autohide", domain: "com.apple.dock", key: "autohide", on: "true", off: "false", restart: "Dock"),
        Tweak(name: "auto hide the dock", domain: "com.apple.dock", key: "autohide", on: "true", off: "false", restart: "Dock"),
        Tweak(name: "dock magnification", domain: "com.apple.dock", key: "magnification", on: "true", off: "false", restart: "Dock"),
        Tweak(name: "path bar", domain: "com.apple.finder", key: "ShowPathbar", on: "true", off: "false", restart: "Finder"),
        Tweak(name: "status bar", domain: "com.apple.finder", key: "ShowStatusBar", on: "true", off: "false", restart: "Finder"),
        Tweak(name: "desktop icons", domain: "com.apple.finder", key: "CreateDesktop", on: "true", off: "false", restart: "Finder"),
        Tweak(name: "screenshot shadow", domain: "com.apple.screencapture", key: "disable-shadow", on: "true", off: "false", restart: "SystemUIServer"),
        Tweak(name: "spring loading", domain: "NSGlobalDomain", key: "com.apple.springing.enabled", on: "true", off: "false", restart: "Finder"),
        Tweak(name: "key repeat", domain: "NSGlobalDomain", key: "ApplePressAndHoldEnabled", on: "false", off: "true", restart: nil),
        Tweak(name: "natural scrolling", domain: "NSGlobalDomain", key: "com.apple.swipescrolldirection", on: "true", off: "false", restart: nil),
    ]
}
