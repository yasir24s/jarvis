import Foundation
import FoundationModels
import JarvisCore
import JarvisTools

// plan M02-M04 §3.8 "LocalToolset.select": which tools one on-device turn is offered. The
// whole catalog when it fits in 0.6 × contextSize. Else the tools that fit the turn: the pinned
// three, the tools the previous turn ran, then the rest by how close their name and description
// are to what the user said, as many as fit (`LocalToolRanker`). With no sentence vectors, CORE-21
// (decision D-7's fixed list, amended: it is now the fallback), with tools dropped from its tail
// until it fits. Whatever is offered goes through the gateway.

/// What the budget rule needs from the model. `SystemLanguageModel` in production; tests
/// inject their own counts and context sizes.
public protocol LocalTokenCounting: Sendable {
    var contextSize: Int { get async }
    /// True when the counts are the chars-per-token estimate rather than the model's tokenizer.
    var estimates: Bool { get async }
    func tokenCount(tools: [DynamicTool]) async throws -> Int
    func tokenCount(instructions: String) async throws -> Int
}

/// The counts for one selection, which `LocalToolset` logs and the live probe prints.
public struct LocalToolSelection: Sendable {
    public enum Tier: String, Sendable, Equatable {
        /// Every catalog tool fits.
        case all
        /// The pinned tools, the previous turn's, then the most relevant to this turn, as many as fit.
        case ranked = "relevance"
        /// No sentence vectors, and CORE-21 fits.
        case core21 = "CORE-21"
        /// No sentence vectors, and CORE-21 with tools dropped from its tail.
        case core21Trimmed = "CORE-21 trimmed"
    }

    public let tools: [DynamicTool]
    public let tier: Tier
    public let contextSize: Int
    /// The tool and instruction tokens allowed: 0.6 × contextSize.
    public let limit: Double
    public let instructionTokens: Int
    /// Token count of every catalog tool together.
    public let allToolTokens: Int
    /// Token count of the tools offered.
    public let selectedToolTokens: Int
    /// The names dropped: CORE-21's from the tail, in the order they were dropped, or, for
    /// `.ranked`, the pinned tools that did not fit (none unless the instructions leave no room).
    public let dropped: [String]
    public let estimated: Bool

    public var names: [String] { tools.map(\.name) }
}

public enum LocalToolset {
    /// Decision D-7's fixed list, amended: web_search and search_memory follow get_time, so they
    /// are the last tools dropped, and open_settings, list_shortcuts and get_wifi_status made
    /// room for them. It is the fallback for a turn with no sentence vectors. Order matters:
    /// tools are dropped from the tail.
    public static let core21 = [
        "get_time", "web_search", "search_memory", "get_battery", "get_cpu_usage", "set_volume",
        "set_brightness", "music_now_playing", "music_play", "music_control", "set_reminder",
        "set_alarm", "make_note", "get_calendar", "create_event", "find_apps", "system_control",
        "run_shortcut", "notify", "find_files", "run_command",
    ]

    /// Offered first on every turn that does not offer the whole catalog, in this order.
    public static let pinned = ["get_time", "web_search", "search_memory"]

    /// What a local turn can be offered: the Python catalog, then search_memory. P4 serves
    /// search_memory after the generated catalog (`NativeToolCatalog`), so `ToolCatalog.tools`
    /// alone has no such tool, and a name in `pinned` or `core21` that it lacks is left out.
    public static let catalog: [ToolSchema] = ToolCatalog.tools
        + NativeToolCatalog.memoryTools.filter { $0.name == "search_memory" }

    /// Tools plus instructions may use this share of `contextSize`.
    public static let budgetFraction = 0.6

    /// Chars per token for the estimate below macOS 26.4, where `tokenCount(for:)` does not
    /// exist. Measured by T3.6's live probe on macOS 27.2 with the real tokenizer: the tool
    /// definitions ran 2.26 chars per token for all 46 (10,835 chars, 4,790 tokens) and 2.07
    /// for the old CORE-22 (5,040 chars, 2,430 tokens; D-7 before it was amended), so tools use
    /// the lower figure and are never counted below either measurement. At 3.5, CORE-22 plus
    /// SYSTEM_PROMPT (1,440 + 1,017) was judged to fit 0.6 × 4096 = 2,457.6, though the
    /// tokenizer counts 2,430 for CORE-22 alone.
    public static let toolCharsPerToken = 2.07

    /// SYSTEM_PROMPT measured 3.77 chars per token (3,633 chars, 963 tokens), so 3.5 counts
    /// instructions a little high, which errs toward fewer tools.
    public static let instructionCharsPerToken = 3.5

    /// The turn's tools for `model`, measured with its tokenizer where the OS has one.
    /// The instructions are the full system prompt the session gets. `request` and `ranker`
    /// choose the tools by relevance when `tools` do not all fit; no ranker offers CORE-21.
    public static func select(model: SystemLanguageModel, instructions: String,
                              request: LocalToolRequest = LocalToolRequest(), ranker: LocalToolRanker? = nil,
                              gateway: ToolGateway, turn: TurnContext, budget: LocalCallBudget,
                              tools: [ToolSchema] = LocalToolset.catalog,
                              log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) })
        async -> LocalToolSelection {
        let all = dynamicTools(tools, gateway: gateway, turn: turn, budget: budget, log: log)
        return await select(from: all, instructions: instructions, counter: SystemTokenCounter(model: model),
                            request: request, ranker: ranker, log: log)
    }

    /// Every schema that bridges, in catalog order. One that does not is left out and logged;
    /// `LocalSchemaBridgeTests` shows that no catalog schema does that.
    public static func dynamicTools(_ schemas: [ToolSchema], gateway: ToolGateway, turn: TurnContext,
                                    budget: LocalCallBudget,
                                    log: @Sendable (String) -> Void) -> [DynamicTool] {
        schemas.compactMap { schema in
            do {
                return try DynamicTool(schema: schema, gateway: gateway, turn: turn, budget: budget)
            } catch {
                log("Local model: tool \(schema.name) left out: \(error)")
                return nil
            }
        }
    }

    /// The budget rule over `all` (the catalog's tools, in catalog order). When they do not all
    /// fit, `ranker` orders them for `request` and the longest prefix that fits is offered;
    /// with no ranker, or no sentence vector for the request, it is CORE-21, trimmed from its tail.
    public static func select(from all: [DynamicTool], instructions: String, counter: some LocalTokenCounting,
                              request: LocalToolRequest = LocalToolRequest(), ranker: LocalToolRanker? = nil,
                              log: @Sendable (String) -> Void) async -> LocalToolSelection {
        let contextSize = await counter.contextSize
        let estimated = await counter.estimates
        let limit = budgetFraction * Double(contextSize)
        let instructionTokens = await count(log: log) { try await counter.tokenCount(instructions: instructions) }
            ?? estimate(instructions: instructions)
        func toolTokens(_ tools: [DynamicTool]) async -> Int {
            await count(log: log) { try await counter.tokenCount(tools: tools) } ?? estimate(tools: tools)
        }
        func fits(_ tokens: Int) -> Bool { Double(tokens + instructionTokens) <= limit }

        let allTokens = await toolTokens(all)
        var tier = LocalToolSelection.Tier.all
        var chosen = all
        var chosenTokens = allTokens
        var dropped: [String] = []
        if !fits(allTokens), let ordered = ranker?.order(all, for: request) {
            tier = .ranked
            // The longest prefix of `ordered` that fits. A tool only adds tokens, so bisect:
            // about six counts for 47 tools, where one at a time would be a dozen. `all` does
            // not fit, so the answer is at most one short of it.
            var low = 0
            var high = ordered.count - 1
            chosenTokens = 0
            while low < high {
                let mid = (low + high + 1) / 2
                let tokens = await toolTokens(Array(ordered[..<mid]))
                if fits(tokens) {
                    low = mid
                    chosenTokens = tokens
                } else {
                    high = mid - 1
                }
            }
            chosen = Array(ordered[..<low])
            dropped = pinned.filter { name in
                ordered.contains { $0.name == name } && !chosen.contains { $0.name == name }
            }
        } else if !fits(allTokens) {
            tier = .core21
            chosen = core21.compactMap { name in all.first { $0.name == name } }
            chosenTokens = await toolTokens(chosen)
            while !fits(chosenTokens), let last = chosen.popLast() {
                tier = .core21Trimmed
                dropped.append(last.name)
                chosenTokens = await toolTokens(chosen)
            }
        }
        let selection = LocalToolSelection(tools: chosen, tier: tier, contextSize: contextSize, limit: limit,
                                           instructionTokens: instructionTokens, allToolTokens: allTokens,
                                           selectedToolTokens: chosenTokens, dropped: dropped,
                                           estimated: estimated)
        log(summary(selection, catalogCount: all.count))
        return selection
    }

    /// The log line for a selection, e.g. "Local model: contextSize 4096, limit 2457.6;
    /// instructions 1500 tokens; 47 tools 4200 tokens; offering relevance: 9 tools, 900 tokens".
    /// It never carries what the user said, nor which tools that ranked. The only names it can
    /// carry are CORE-21's fixed tail and any pinned tool that did not fit.
    public static func summary(_ s: LocalToolSelection, catalogCount: Int) -> String {
        var line = "Local model: contextSize \(s.contextSize), limit \(s.limit)"
        line += "; instructions \(s.instructionTokens) tokens; \(catalogCount) tools \(s.allToolTokens) tokens"
        line += "; offering \(s.tier.rawValue): \(s.tools.count) tools, \(s.selectedToolTokens) tokens"
        if !s.dropped.isEmpty { line += "; dropped \(s.dropped.joined(separator: ", "))" }
        if s.estimated { line += " (\(estimateNote))" }
        return line
    }

    /// How estimated counts are labelled in the log.
    static var estimateNote: String {
        "estimated: tools chars/\(toolCharsPerToken), instructions chars/\(instructionCharsPerToken)"
    }

    /// Python-style `len()` (code points) ÷ `instructionCharsPerToken`, rounded up.
    public static func estimate(instructions: String) -> Int {
        estimate(chars: instructions.unicodeScalars.count, perToken: instructionCharsPerToken)
    }

    /// Each tool's name, description and parameters JSON, ÷ `toolCharsPerToken`, rounded up.
    public static func estimate(tools: [DynamicTool]) -> Int {
        estimate(chars: tools.reduce(0) { $0 + $1.estimateChars }, perToken: toolCharsPerToken)
    }

    static func estimate(chars: Int, perToken: Double) -> Int {
        Int((Double(chars) / perToken).rounded(.up))
    }

    /// A count, or nil (logged) if the tokenizer failed, so the caller falls back to the estimate.
    private static func count(log: @Sendable (String) -> Void,
                              _ body: () async throws -> Int) async -> Int? {
        do {
            return try await body()
        } catch {
            log("Local model: token count failed, using the estimate (\(estimateNote)): \(error)")
            return nil
        }
    }
}

/// `SystemLanguageModel` as a `LocalTokenCounting`. `contextSize` is back-deployed and reads
/// 4096 before macOS 27; `tokenCount(for:)` needs macOS 26.4, and below it the estimate stands in.
struct SystemTokenCounter: LocalTokenCounting {
    let model: SystemLanguageModel

    var contextSize: Int { model.contextSize }

    var estimates: Bool {
        if #available(macOS 26.4, *) { return false }
        return true
    }

    func tokenCount(tools: [DynamicTool]) async throws -> Int {
        if #available(macOS 26.4, *) {
            return try await model.tokenCount(for: tools.map { $0 as any Tool })
        }
        return LocalToolset.estimate(tools: tools)
    }

    func tokenCount(instructions: String) async throws -> Int {
        if #available(macOS 26.4, *) {
            return try await model.tokenCount(for: Instructions(instructions))
        }
        return LocalToolset.estimate(instructions: instructions)
    }
}
