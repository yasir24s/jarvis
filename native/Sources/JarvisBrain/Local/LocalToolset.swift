import Foundation
import FoundationModels
import JarvisCore
import JarvisTools

// plan M02-M04 §3.8 "LocalToolset.select": which tools one on-device turn is offered. The
// whole catalog when it fits in 0.6 × contextSize, else CORE-22 (decision D-7), else CORE-22
// with tools dropped from its tail until it fits. Whatever is offered goes through the gateway.

/// What the budget rule needs from the model. `SystemLanguageModel` in production; tests
/// inject their own counts and context sizes.
public protocol LocalTokenCounting: Sendable {
    var contextSize: Int { get async }
    /// True when the counts are the chars ÷ 3.5 estimate rather than the model's tokenizer.
    var estimates: Bool { get async }
    func tokenCount(tools: [DynamicTool]) async throws -> Int
    func tokenCount(instructions: String) async throws -> Int
}

/// The counts for one selection, which `LocalToolset` logs and the live probe prints.
public struct LocalToolSelection: Sendable {
    public enum Tier: String, Sendable, Equatable {
        /// Every catalog tool fits.
        case all
        /// CORE-22 fits.
        case core22 = "CORE-22"
        /// CORE-22 with tools dropped from its tail.
        case core22Trimmed = "CORE-22 trimmed"
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
    /// CORE-22 names dropped from the tail, in the order they were dropped.
    public let dropped: [String]
    public let estimated: Bool

    public var names: [String] { tools.map(\.name) }
}

public enum LocalToolset {
    /// Decision D-7. Order matters: tools are dropped from the tail.
    public static let core22 = [
        "get_time", "get_battery", "get_cpu_usage", "get_wifi_status", "set_volume",
        "set_brightness", "music_now_playing", "music_play", "music_control", "set_reminder",
        "set_alarm", "make_note", "get_calendar", "create_event", "find_apps", "open_settings",
        "system_control", "run_shortcut", "list_shortcuts", "notify", "find_files", "run_command",
    ]

    /// Tools plus instructions may use this share of `contextSize`.
    public static let budgetFraction = 0.6

    /// The rough token estimate below macOS 26.4, where `tokenCount(for:)` does not exist.
    public static let charsPerToken = 3.5

    /// The turn's tools for `model`, measured with its tokenizer where the OS has one.
    /// The instructions are the full system prompt the session gets.
    public static func select(model: SystemLanguageModel, instructions: String, gateway: ToolGateway,
                              turn: TurnContext, budget: LocalCallBudget,
                              tools: [ToolSchema] = ToolCatalog.tools,
                              log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) })
        async -> LocalToolSelection {
        let all = dynamicTools(tools, gateway: gateway, turn: turn, budget: budget, log: log)
        return await select(from: all, instructions: instructions, counter: SystemTokenCounter(model: model),
                            log: log)
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

    /// The budget rule over `all` (the catalog's tools, in catalog order).
    public static func select(from all: [DynamicTool], instructions: String, counter: some LocalTokenCounting,
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
        if !fits(allTokens) {
            tier = .core22
            chosen = core22.compactMap { name in all.first { $0.name == name } }
            chosenTokens = await toolTokens(chosen)
            while !fits(chosenTokens), let last = chosen.popLast() {
                tier = .core22Trimmed
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
    /// instructions 1500 tokens; 46 tools 4200 tokens; offering CORE-22: 22 tools, 1900 tokens".
    public static func summary(_ s: LocalToolSelection, catalogCount: Int) -> String {
        var line = "Local model: contextSize \(s.contextSize), limit \(s.limit)"
        line += "; instructions \(s.instructionTokens) tokens; \(catalogCount) tools \(s.allToolTokens) tokens"
        line += "; offering \(s.tier.rawValue): \(s.tools.count) tools, \(s.selectedToolTokens) tokens"
        if !s.dropped.isEmpty { line += "; dropped \(s.dropped.joined(separator: ", "))" }
        if s.estimated { line += " (chars/\(charsPerToken) estimate)" }
        return line
    }

    /// Python-style `len()` (code points) ÷ 3.5, rounded up.
    public static func estimate(instructions: String) -> Int {
        estimate(chars: instructions.unicodeScalars.count)
    }

    /// Each tool's name, description and parameters JSON, ÷ 3.5, rounded up.
    public static func estimate(tools: [DynamicTool]) -> Int {
        estimate(chars: tools.reduce(0) { $0 + $1.estimateChars })
    }

    static func estimate(chars: Int) -> Int {
        Int((Double(chars) / charsPerToken).rounded(.up))
    }

    /// A count, or nil (logged) if the tokenizer failed, so the caller falls back to the estimate.
    private static func count(log: @Sendable (String) -> Void,
                              _ body: () async throws -> Int) async -> Int? {
        do {
            return try await body()
        } catch {
            log("Local model: token count failed, using the chars/\(charsPerToken) estimate: \(error)")
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
