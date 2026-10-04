import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools

/// od/phase2 item 3: the ranker on its own, without the model. For each fixture case that
/// expects a tool, whether an acceptable tool is among the first `top` that `LocalToolRanker`
/// orders for the request, as a turn with no previous turn would be. Seconds, not the 40
/// minutes a scorecard run takes, so the tool cap can be measured before the model sees it.
public enum RankerRecall {
    public struct Miss: Sendable, Equatable {
        public let id: String
        public let expected: String
        /// Where the first acceptable tool came, 1-based; nil when the ranker gave no order.
        public let rank: Int?
    }

    public struct Report: Sendable {
        public let top: Int
        public let cases: Int
        public let found: Int
        public let misses: [Miss]
        public var recall: Double { cases == 0 ? 0 : Double(found) / Double(cases) }
    }

    /// The catalog's tools as a local turn builds them, on a gateway that is never called.
    public static func catalogTools() -> [DynamicTool] {
        LocalToolset.dynamicTools(LocalToolset.catalog, gateway: ToolGateway(log: { _ in }),
                                  turn: TurnContext(channel: .text), budget: LocalCallBudget(), log: { _ in })
    }

    /// With the production sentence embedding and the whole catalog.
    public static func run(_ cases: [EvalCase], top: [Int]) -> [Report] {
        run(cases, ranker: LocalToolRanker(embedding: SystemSentenceEmbedding()), tools: catalogTools(), top: top)
    }

    public static func run(_ cases: [EvalCase], ranker: LocalToolRanker, tools: [DynamicTool],
                           top: [Int]) -> [Report] {
        var ranks: [(EvalCase, Int?)] = []
        for c in cases where c.expectsTool {
            let order = ranker.order(tools, for: LocalToolRequest(text: c.request))
            let rank = order.flatMap { $0.firstIndex { c.acceptable.contains($0.name) } }.map { $0 + 1 }
            ranks.append((c, rank))
        }
        return top.map { k in
            let misses = ranks.filter { ($0.1 ?? Int.max) > k }
                .map { Miss(id: $0.0.id, expected: $0.0.tool, rank: $0.1) }
            return Report(top: k, cases: ranks.count, found: ranks.count - misses.count, misses: misses)
        }
    }

    /// How many fixture requests the fast path answers without the model (the scorecard sends
    /// every case to the model, so it does not see these): Python's carried branches, and the
    /// native ones. Each id with its branch, for the native ones.
    public static func fastPath(_ cases: [EvalCase]) -> (python: Int, native: [(id: String, branch: String)],
                                                         tools: [(id: String, tool: String)]) {
        let router = FastPathRouter()
        var python = 0
        var native: [(String, String)] = []
        var tools: [(String, String)] = []
        for c in cases {
            let m = router.route(c.request)
            guard let command = m.command else { continue }
            if FastPathRouter.native.contains(m.branch) { native.append((c.id, m.branch)) } else { python += 1 }
            tools.append((c.id, tool(for: command) ?? "other"))
        }
        return (python, native, tools)
    }

    /// The catalog tool a fast-path command runs, as QuickCommands dispatches it; nil for the
    /// helpers with no single catalog tool.
    public static func tool(for command: FastPathCommand) -> String? {
        switch command {
        case .systemInfo(let kind):
            switch kind {
            case "time": "get_time"
            case "wifi": "get_wifi_status"
            case "cpu": "get_cpu_usage"
            default: "get_battery"
            }
        case .setVolume, .nudgeVolume: "set_volume"
        case .media: "music_control"
        case .nowPlaying: "music_now_playing"
        case .playQuery: "music_play"
        case .reminder: "set_reminder"
        case .setAlarm, .setTimer: "set_alarm"
        case .makeNote: "make_note"
        case .weather: "get_weather"
        case .location: "get_location"
        case .news: "get_news"
        case .calendar: "get_calendar"
        case .messages: "get_messages"
        case .sendMessage: "send_message"
        case .setBrightness, .nudgeBrightness: "set_brightness"
        case .screenshot: "take_screenshot"
        case .findContact: "find_contact"
        case .runShortcut: "run_shortcut"
        case .listShortcuts: "list_shortcuts"
        case .openSettings: "open_settings"
        case .diagnostics: "run_diagnostics"
        case .findApps: "find_apps"
        case .typeText: "type_text"
        case .songByLyrics: "find_song_by_lyrics"
        case .summarizePage: "summarize_page"
        case .toggleSystem: "system_control"
        default: nil
        }
    }
}
