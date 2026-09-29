import Foundation

public enum Channel: String, Sendable, Equatable {
    case voice
    case text
}

public enum DataSource: String, Sendable, CaseIterable {
    case messages, calendar, reminders, contacts, email, notes, files, clipboard, screen
    case location, web, news, music, system, shortcuts, personality, alarms, apps, settings
}

public enum DataSourceMap {
    public static let toolNames: [String] = [
        "run_command", "run_applescript", "get_battery", "get_time", "get_cpu_usage",
        "get_wifi_status", "set_volume", "music_now_playing", "music_search", "music_play",
        "music_control", "web_search", "search_files", "read_file", "delete_file", "move_file",
        "write_file", "get_weather", "get_location", "set_reminder", "get_messages", "get_calendar",
        "see_screen", "read_clipboard", "make_note", "set_alarm", "find_song_by_lyrics", "notify",
        "send_message", "send_email", "find_contact", "create_event", "get_news", "run_diagnostics",
        "set_brightness", "type_text", "take_screenshot", "run_shortcut", "list_shortcuts",
        "summarize_page", "find_apps", "find_files", "open_settings", "system_control",
        "personality_note", "personality_rewrite"
    ]

    public static let allTools = Set(toolNames)

    private static let table: [String: Set<DataSource>] = [
        "get_messages": [.messages, .contacts], "send_message": [.messages, .contacts],
        "send_email": [.email, .contacts], "find_contact": [.contacts],
        "get_calendar": [.calendar], "create_event": [.calendar], "set_reminder": [.reminders],
        "set_alarm": [.alarms], "make_note": [.notes],
        "read_file": [.files], "search_files": [.files], "find_files": [.files],
        "delete_file": [.files], "move_file": [.files], "write_file": [.files],
        "read_clipboard": [.clipboard], "see_screen": [.screen], "take_screenshot": [.screen],
        "summarize_page": [.screen, .web], "web_search": [.web],
        "get_weather": [.location, .web], "get_location": [.location], "get_news": [.news, .web],
        "music_now_playing": [.music], "music_search": [.music], "music_play": [.music],
        "music_control": [.music], "find_song_by_lyrics": [.music],
        "run_command": [.system], "run_applescript": [.system], "get_battery": [.system],
        "get_time": [.system], "get_cpu_usage": [.system], "get_wifi_status": [.system],
        "set_volume": [.system], "notify": [.system], "run_diagnostics": [.system],
        "set_brightness": [.system], "type_text": [.system],
        "run_shortcut": [.shortcuts], "list_shortcuts": [.shortcuts], "find_apps": [.apps],
        "open_settings": [.settings], "system_control": [.settings],
        "personality_note": [.personality], "personality_rewrite": [.personality]
    ]

    public static func sources(for tool: String) -> Set<DataSource> {
        table[tool] ?? []
    }
}

public struct ToolRunRecord: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case ran
        case blockedTaint
        case blockedGuard
        case gated
        case failed
        case unknown
    }

    public let name: String
    public let origin: ToolOrigin
    public let outcome: Outcome

    public init(name: String, origin: ToolOrigin, outcome: Outcome) {
        self.name = name
        self.origin = origin
        self.outcome = outcome
    }
}

public struct TurnSummary: Sendable {
    public let turnID: UUID
    public let channel: Channel
    public let tainted: Bool
    public let taintedBy: [String]
    public let dataSources: Set<DataSource>
    public let toolRuns: [ToolRunRecord]
    public let startedPasteTainted: Bool
}

private actor TurnFIFO {
    private var tail: Task<Void, Never>?

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let predecessor = tail
        let task = Task<T, Never> {
            if let predecessor { await predecessor.value }
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

public actor TurnContext {
    public let turnID: UUID
    public let channel: Channel
    public let startedPasteTainted: Bool

    private var open = true
    private var isTainted: Bool
    private var taintSources: [String] = []
    private var touchedSources: Set<DataSource> = []
    private var records: [ToolRunRecord] = []
    private let fifo = TurnFIFO()

    public init(channel: Channel, startTainted: Bool = false) {
        self.turnID = UUID()
        self.channel = channel
        self.startedPasteTainted = startTainted
        self.isTainted = startTainted
        if startTainted { self.taintSources = ["paste"] }
    }

    public var isOpen: Bool { open }
    public var tainted: Bool { isTainted }

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await fifo.enqueue(operation)
    }

    public func markTainted(by tool: String) {
        isTainted = true
        if !taintSources.contains(tool) { taintSources.append(tool) }
    }

    public func recordSources(for tool: String) {
        touchedSources.formUnion(DataSourceMap.sources(for: tool))
    }

    public func record(_ record: ToolRunRecord) {
        records.append(record)
    }

    public func close() {
        open = false
    }

    public func summary() -> TurnSummary {
        TurnSummary(turnID: turnID, channel: channel, tainted: isTainted,
                    taintedBy: taintSources, dataSources: touchedSources,
                    toolRuns: records, startedPasteTainted: startedPasteTainted)
    }
}
