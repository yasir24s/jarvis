import Foundation
import JarvisCore
import JarvisTools
import Synchronization

/// Every call that reached a fake tool body, in order, with its arguments.
public final class ToolRecorder: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let args: [String: String]
    }

    private let entries = Mutex<[Entry]>([])

    public init() {}

    func record(_ name: String, _ args: JSONObject) {
        let flat = Self.flatten(args)
        entries.withLock { $0.append(Entry(name: name, args: flat)) }
    }

    public var calls: [Entry] { entries.withLock { $0 } }

    /// Arguments as strings: strings as they are, numbers and booleans as JSON writes them,
    /// arrays and objects as compact JSON.
    public static func flatten(_ args: JSONObject) -> [String: String] {
        var out: [String: String] = [:]
        for m in args.members {
            switch m.value {
            case .string(let s): out[m.key] = s
            case .null: out[m.key] = "null"
            default: out[m.key] = PyJSON.dumps(m.value, ensureASCII: false)
            }
        }
        return out
    }

    /// Pairs the gateway's records (every call, blocked ones too) with the recorded arguments:
    /// a call that reached a body takes the next recorded entry of its name.
    public func merge(_ records: [ToolRunRecord]) -> [EvalToolCall] {
        var pending = calls
        return records.map { record in
            var args: [String: String]?
            if let i = pending.firstIndex(where: { $0.name == record.name }),
               [.ran, .gated, .failed].contains(record.outcome) {
                args = pending.remove(at: i).args
            }
            return EvalToolCall(name: record.name, args: args, outcome: Self.describe(record.outcome))
        }
    }

    static func describe(_ outcome: ToolRunRecord.Outcome) -> String {
        switch outcome {
        case .ran: "ran"
        case .blockedTaint: "blockedTaint"
        case .blockedGuard: "blockedGuard"
        case .gated: "gated"
        case .failed: "failed"
        case .unknown: "unknown"
        }
    }
}

/// A fake body for any catalog tool. It records the call and answers with a canned, plausible
/// result; nothing real happens (no message, no playback, no file write). The tools that ask
/// for confirmation in JARVIS ask here too, so the gateway stashes the action (which only
/// returns text) and the model sees the same "say 'confirm'" reply.
///
/// `ToolGateway.register` keys a body by its type's static `name`, so one type serves every tool
/// by reading the name from a task-local while it is registered (`registerAll`).
public struct RecordingTool: ToolImpl {
    @TaskLocal static var registering = ToolSchema(name: "")

    public static var name: String { registering.name }
    public static var schema: ToolSchema { registering }

    let toolName: String
    let recorder: ToolRecorder

    public func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        recorder.record(toolName, args)
        if let desc = FakeOutputs.confirmation(toolName, args) {
            return .needsConfirmation(desc: desc, action: { "Done." })
        }
        return .text(FakeOutputs.text(toolName, args))
    }

    /// Registers a recording fake for every schema on `gateway`.
    public static func registerAll(_ schemas: [ToolSchema], on gateway: ToolGateway, recorder: ToolRecorder) async {
        for schema in schemas {
            await $registering.withValue(schema) {
                await gateway.register(RecordingTool(toolName: schema.name, recorder: recorder))
            }
        }
    }
}

/// The canned results. Made-up data only.
public enum FakeOutputs {
    /// The confirmation prompt a tool that asks first gives, or nil for one that runs at once.
    public static func confirmation(_ name: String, _ args: JSONObject) -> String? {
        let s = { (key: String) in args[key]?.stringValue ?? "" }
        switch name {
        case "send_message": return "Send to \(s("recipient")): \"\(s("text"))\""
        case "send_email": return "Email \(s("to")): \"\(s("subject"))\""
        case "create_event": return "Add \"\(s("title"))\" to your calendar \(s("when"))"
        case "delete_file" where args["permanent"]?.pyTruthy == true:
            return "Permanently delete \(s("path"))"
        default: return nil
        }
    }

    public static func text(_ name: String, _ args: JSONObject) -> String {
        let s = { (key: String) in args[key]?.stringValue ?? "" }
        switch name {
        case "get_time": return "Saturday, 4 October 2026, 14:05"
        case "get_battery": return "Battery: 76%, not charging"
        case "get_cpu_usage": return "CPU load: 12%"
        case "get_wifi_status": return "Wi-Fi: connected to ExampleNet"
        case "set_volume": return "Volume set to \(args["level"].map { PyJSON.dumps($0) } ?? "50")."
        case "set_brightness": return "Brightness set to \(args["level"].map { PyJSON.dumps($0) } ?? "50")."
        case "music_now_playing": return "Now playing: Example Song by The Examples, from Example Album."
        case "music_search": return "Found 3 tracks for '\(s("query"))': Example One, Example Two, Example Three."
        case "music_play": return "Playing \(s("query"))."
        case "music_control": return "Music: \(s("action").isEmpty ? "volume changed" : s("action"))."
        case "web_search":
            return "1. \(s("query")) - Example News (https://example.com/a): A short made-up summary.\n"
                + "2. More on \(s("query")) (https://example.com/b): Another made-up summary."
        case "search_files", "find_files":
            return "Found 2 files: ~/Documents/example-report.pdf, ~/Desktop/example-notes.txt"
        case "read_file": return "Contents of \(s("path")): Example text, nothing important."
        case "delete_file": return "Moved \(s("path")) to the Trash."
        case "move_file": return "Moved \(s("src")) to \(s("dst"))."
        case "write_file": return "Wrote \(s("path"))."
        case "get_weather": return "\(s("location").isEmpty ? "Exampleton" : s("location")): 14°C, light rain, wind 12 mph."
        case "get_location": return "You appear to be in Exampleton, Example County."
        case "set_reminder": return "Reminder set: \(s("text")) \(s("when"))."
        case "set_alarm": return "Alarm set for \(s("when"))."
        case "get_messages": return "Priya (07700 900123): Running ten minutes late.\nMum: Call me when you're free."
        case "get_calendar": return "Today: 10:00 Team stand-up; 15:00 Dentist."
        case "see_screen": return "Screen text: Example Editor - untitled.txt - Line 1"
        case "read_clipboard": return "Clipboard: https://example.com/recipe"
        case "make_note": return "Note saved."
        case "find_song_by_lyrics": return "That sounds like Example Song by The Examples."
        case "notify": return "Notification shown."
        case "find_contact": return "\(s("name")): 07700 900456, \(s("name").lowercased().replacingOccurrences(of: " ", with: "."))@example.com"
        case "get_news": return "Top headlines: 1. Example headline one. 2. Example headline two."
        case "run_diagnostics": return "CPU 12%, memory 61% used, disk 220 GB free, battery 76%, uptime 3 days."
        case "type_text": return "Typed."
        case "take_screenshot": return "Screenshot saved to the Desktop."
        case "run_shortcut": return "Ran shortcut \(s("name"))."
        case "list_shortcuts": return "Shortcuts: Lights On, Lights Off, Movie Time, Good Morning."
        case "summarize_page": return "The page is a made-up recipe for lemon drizzle cake."
        case "find_apps": return "Browsers: Safari, Example Browser."
        case "open_settings": return "Opened \(s("pane").isEmpty ? "System Settings" : s("pane"))."
        case "system_control": return "\(s("feature")) turned \(args["enable"]?.pyTruthy == true ? "on" : "off")."
        case "run_command": return "Ran: \(s("command"))"
        case "run_applescript": return "Script ran."
        case "personality_note": return "Noted in my personality file."
        case "personality_rewrite": return "Personality core rewritten."
        case "search_memory": return "Notes: [n1] The user's sister is called Priya. [n2] The user likes lemon drizzle cake."
        case "forget_memory": return "Forgot 1 note: n1."
        case "correct_memory": return "Corrected note n1."
        case "restore_memory": return "Restored 1 note: n1."
        default: return "OK."
        }
    }
}
