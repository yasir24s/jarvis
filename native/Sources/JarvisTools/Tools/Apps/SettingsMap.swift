import CoreServices
import Foundation
import JarvisCore

protocol SettingsOpening: Sendable { func open(_ url: URL) async }
struct LiveSettingsOpener: SettingsOpening {
    func open(_ url: URL) async { _ = LSOpenCFURLRef(url as CFURL, nil) }
}

struct OpenSettings: ToolImpl {
    static let name = "open_settings"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let opener: any SettingsOpening
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let pane = try PyArgs.stringOrEmpty(args, "pane", method: "lower")
        let result = SettingsMap.resolve(pane)
        if let url = URL(string: result.url) { await opener.open(url) }
        return .text(result.reply)
    }
}

enum SettingsMap {
    // Python insertion order matters for ambiguous substring matches.
    static let panes: [(String, String)] = [
        ("wifi", "com.apple.wifi-settings-extension"),
        ("wi-fi", "com.apple.wifi-settings-extension"),
        ("network", "com.apple.Network-Settings.extension"),
        ("bluetooth", "com.apple.BluetoothSettings"),
        ("sound", "com.apple.Sound-Settings.extension"),
        ("notifications", "com.apple.Notifications-Settings.extension"),
        ("displays", "com.apple.Displays-Settings.extension"),
        ("display", "com.apple.Displays-Settings.extension"),
        ("battery", "com.apple.Battery-Settings.extension"),
        ("wallpaper", "com.apple.Wallpaper-Settings.extension"),
        ("screen saver", "com.apple.ScreenSaver-Settings.extension"),
        ("accessibility", "com.apple.Accessibility-Settings.extension"),
        ("privacy", "com.apple.settings.PrivacySecurity.extension"),
        ("security", "com.apple.settings.PrivacySecurity.extension"),
        ("privacy and security", "com.apple.settings.PrivacySecurity.extension"),
        ("keyboard", "com.apple.Keyboard-Settings.extension"),
        ("mouse", "com.apple.Mouse-Settings.extension"),
        ("trackpad", "com.apple.Trackpad-Settings.extension"),
        ("general", "com.apple.systempreferences.GeneralSettings"),
        ("software update", "com.apple.Software-Update-Settings.extension"),
        ("storage", "com.apple.settings.Storage"),
        ("users", "com.apple.Users-Groups-Settings.extension"),
        ("users and groups", "com.apple.Users-Groups-Settings.extension"),
        ("date and time", "com.apple.Date-Time-Settings.extension"),
        ("language", "com.apple.Localization-Settings.extension"),
        ("desktop and dock", "com.apple.Desktop-Settings.extension"),
        ("dock", "com.apple.Desktop-Settings.extension"),
        ("focus", "com.apple.Focus-Settings.extension"),
        ("screen time", "com.apple.Screen-Time-Settings.extension"),
        ("apple id", "com.apple.systempreferences.AppleIDSettings"),
        ("wallet", "com.apple.WalletSettingsExtension"),
        ("siri", "com.apple.Siri-Settings.extension"),
        ("spotlight", "com.apple.Spotlight-Settings.extension"),
        ("control center", "com.apple.ControlCenter-Settings.extension"),
        ("sharing", "com.apple.Sharing-Settings.extension"),
        ("printers", "com.apple.Print-Scan-Settings.extension"),
        ("printers and scanners", "com.apple.Print-Scan-Settings.extension"),
        ("vpn", "com.apple.Network-Settings.extension"),
    ]
    static let privacy: [(String, String)] = [
        ("microphone", "Privacy_Microphone"),
        ("camera", "Privacy_Camera"),
        ("screen recording", "Privacy_ScreenCapture"),
        ("accessibility", "Privacy_Accessibility"),
        ("full disk access", "Privacy_AllFiles"),
        ("automation", "Privacy_Automation"),
        ("location", "Privacy_LocationServices"),
        ("files and folders", "Privacy_FilesAndFolders"),
        ("input monitoring", "Privacy_ListenEvent"),
    ]
    private static let normalize = try! PyRegex(#"^(the|my)\s+|\s+(settings?|preferences?|pane|panel|page)$"#)
    static func resolve(_ raw: String) -> (url: String, reply: String) {
        let pane = Py.strip(normalize.sub(Py.strip(Py.lower(raw)), literal: ""))
        let root = "x-apple.systempreferences:"
        if pane.isEmpty { return (root, "Opening System Settings, sir.") }
        // Dict lookups and `in` compare code points, so Py.eq and Py.contains, not == and contains.
        if let match = privacy.first(where: { Py.eq($0.0, pane) }) {
            return (root + "com.apple.preference.security?" + match.1, "Opening \(pane) privacy settings, sir.")
        }
        if let match = panes.first(where: { Py.eq($0.0, pane) })
            ?? panes.first(where: { Py.contains($0.0, pane) || Py.contains(pane, $0.0) }) {
            return (root + match.1, "Opening \(match.0) settings, sir.")
        }
        return (root, "I couldn't find a \(raw) pane, sir, so I've opened System Settings.")
    }
}
