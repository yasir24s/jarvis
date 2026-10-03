import Foundation
import JarvisCore

/// The replies of the quick commands' helpers, from the readings the app takes. Each is
/// jarvis.py's text over the same input, proven by the quick_alarms and quick_system goldens.
public enum QuickReplies {
    public static let presence = "At your service, sir."
    public static let locking = "Locking, sir."
    public static let locked = "Locked, sir."
    public static let goodnight = "Goodnight, sir."
    public static let trashEmptied = "Trash emptied, sir."
    public static let trashFailed = "I couldn't empty the trash, sir."
    public static let noAlarms = "You have no alarms set, sir."
    public static let voiceCleared = "Voice recognition cleared, sir. I'll respond to any voice now."
    public static let nothingToClose = "There's nothing to close, sir."
    public static let closeTrouble = "I had trouble closing everything, sir."
    public static let noIP = "I couldn't determine your IP address, sir."
    public static let noBluetooth = "I don't see any Bluetooth audio devices with battery levels, sir."
    public static let noBluetoothLevels = "I don't see battery levels for your Bluetooth devices, sir."
    /// The confirmations PA batch A asks for (native only: Python ran both at once).
    public static let forgetVoiceDesc = "That will forget your voice, so I'll respond to anyone"
    public static let emptyTrashDesc = "That will empty the Trash for good"

    // MARK: alarms

    /// `_list_alarms()` over `AlarmBook.alarms()`.
    public static func alarmList(count: Int, parsed: [AlarmEntry], timeZone: TimeZone) -> String {
        if count == 0 { return noAlarms }
        let bits = parsed.map { e -> String in
            var s = clock(e.time, timeZone)
            switch e.repeats {
            case "daily": s += " every day"
            case "weekdays": s += " on weekdays"
            default: break
            }
            if !e.label.isEmpty { s += " for \(e.label)" }
            return s
        }
        return "Your alarms: " + bits.joined(separator: ", ") + ", sir."
    }

    /// `_cancel_alarms()`'s reply, given how many alarms it removed.
    public static func alarmsCancelled(_ count: Int) -> String {
        if count == 0 { return noAlarms }
        return count <= 1 ? "Alarm cancelled, sir." : "All \(count) alarms cancelled, sir."
    }

    /// `dt.strftime("%I:%M %p").lstrip("0")` in the C locale.
    static func clock(_ date: Date, _ timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let text = String(format: "%02d:%02d ", twelve, minute) + (hour < 12 ? "AM" : "PM")
        return Py.lstrip(text, "0")
    }

    // MARK: system

    /// `_ip_report()`: `local` is the first non-blank `ipconfig getifaddr` of en0 and en1,
    /// stripped; `publicIP` is ipwho.is's "ip" ("" when offline or it failed).
    public static func ipReport(local: String, publicIP: String) -> String {
        if local.isEmpty && publicIP.isEmpty { return noIP }
        var bits: [String] = []
        if !local.isEmpty { bits.append("local IP \(local)") }
        if !publicIP.isEmpty { bits.append("public IP \(publicIP)") }
        return "Your " + bits.joined(separator: " and ") + ", sir."
    }

    private static let product = try! PyRegex(#""Product" = "([^"]+)""#)
    private static let levels: [(key: PyRegex, label: String)] = [
        (try! PyRegex(#""BatteryPercentLeft" = (\d+)"#), "left"),
        (try! PyRegex(#""BatteryPercentRight" = (\d+)"#), "right"),
        (try! PyRegex(#""BatteryPercentCase" = (\d+)"#), "case"),
    ]

    /// `_bt_battery()` over `ioreg -r -l -k BatteryPercentLeft`'s output ("" when it failed).
    public static func bluetoothBattery(ioreg out: String) -> String {
        if Py.strip(out).isEmpty { return noBluetooth }
        let name = product.search(out)?.groups[1] ?? "Your headphones"
        var bits: [String] = []
        for level in levels {
            if let m = level.key.search(out), let value = m.groups[1] { bits.append("\(level.label) \(value) percent") }
        }
        if bits.isEmpty { return noBluetoothLevels }
        return "\(name): " + bits.joined(separator: ", ") + ", sir."
    }

    /// `_quit_all_apps()`: every regular app (activation policy 0) whose name holds neither
    /// "finder" nor "jarvis" is asked to quit, in order; `terminate(i)` asks app `i` and says
    /// whether it agreed. Nil `apps` is the workspace failing.
    public static func quitAll(apps: [(name: String, policy: Int)]?, terminate: (Int) -> Bool) -> String {
        guard let apps else { return closeTrouble }
        var closed = 0
        for (i, app) in apps.enumerated() where app.policy == 0 {
            let low = Py.lower(app.name)
            if Py.contains(low, "finder") || Py.contains(low, "jarvis") { continue }
            if terminate(i) { closed += 1 }
        }
        if closed == 0 { return nothingToClose }
        return "Closed \(closed) app\(closed != 1 ? "s" : ""), sir."
    }

    /// `_empty_trash()` from osascript's text.
    public static func emptyTrash(osascript out: String) -> String {
        Py.contains(Py.lower(out), "error") ? trashFailed : trashEmptied
    }

    public static let emptyTrashScript = #"tell application "Finder" to empty trash"#

    /// `_media(cmd)`'s AppleScript.
    public static func mediaScript(_ cmd: String) -> String {
        "if application \"Spotify\" is running then\n"
            + "  tell application \"Spotify\" to \(cmd)\n"
            + "else\n"
            + "  tell application \"Music\"\n"
            + "    if it is not running then launch\n"
            + "    \(cmd)\n"
            + "  end tell\n"
            + "end if\nreturn \"ok\""
    }
}
