import Foundation
import FoundationModels
import JarvisCore
import JarvisTools

// od/guided-generation: the tool choice made with guided generation before the free-form
// reply. The model picks one of the turn's offered tools or "none" from an enum built from
// their names, then fills that tool's arguments under the tool's own schema. The call goes
// through the tool's DynamicTool, so the gateway's taint, guards and confirmations apply as
// they do to a free-form call. Only the choice and the arguments are constrained: the reply
// is still written by the model, free-form, and checked by ReplyCheck.

/// A session for guided generation only. It is given no tools, so a constrained response
/// never runs one; its transcript keeps the request, each choice and each result, so a later
/// choice sees what the earlier calls returned.
public protocol LocalGuidedSession: Sendable {
    func respond(to prompt: String, schema: GenerationSchema, options: GenerationOptions) async throws
        -> GeneratedContent
}

public enum GuidedTools {
    /// The defaults key (in the app's suite). Unset means on; `false` turns the step off with no
    /// rebuild, and the turn goes back to free-form tool calling.
    public static let defaultsKey = "onDeviceGuidedTools"
    /// Choices per turn, so "find Priya then text her" can take two.
    public static let maxSteps = 3
    /// The choice that answers without a tool.
    public static let none = "none"
    /// A tool result is cut to this many characters in the next choice's prompt.
    static let resultChars = 600
    /// An offered tool's description is cut to this many characters in the choice prompt.
    static let descriptionChars = 110

    /// The planner session's instructions. Short: it only picks and fills.
    public static let instructions = """
        You choose the tool a voice assistant should use for the user's request. Pick a tool \
        whenever the request asks for an action or for information a tool provides. Pick none \
        for chat, compliments, opinions or general knowledge, and for a request to delete, wipe \
        or format things wholesale.
        """

    /// Greedy and short: a choice is one enum value.
    static let choiceOptions = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24)
    /// Greedy: arguments are copied from the request, not invented.
    static let argumentOptions = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200)

    /// The setting: on unless `defaultsKey` is stored as false.
    public static func enabled(in defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The app's setting, read on each turn. `.standard` is the app's own domain inside the app;
    /// `UserDefaults(suiteName:)` with the app's bundle ID returns nil, so it is never used here.
    public static func enabledSetting(in defaults: UserDefaults = .standard) -> Bool {
        enabled(in: defaults)
    }

    /// One tool the guided step ran.
    public struct Step: Sendable, Equatable {
        public let name: String
        public let arguments: String
        public let result: String
        public let outcome: ToolRunRecord.Outcome
    }

    /// What the guided step did. `steps` empty and `fellBack` true: it errored before any call,
    /// so the turn runs free-form as before. `steps` empty and `fellBack` false: it chose none.
    /// `cancelled`: the turn was stopped; it ends, and nothing falls back.
    public struct Result: Sendable, Equatable {
        public var steps: [Step] = []
        public var fellBack = false
        public var cancelled = false
    }

    /// `{"tool": <one of names, or none>}`.
    static func choiceSchema(_ names: [String]) throws -> GenerationSchema {
        let choice = DynamicGenerationSchema(name: "ToolName", description: "a tool name, or none",
                                             anyOf: names + [none])
        let root = DynamicGenerationSchema(name: "ToolChoice", properties: [
            .init(name: "tool", description: "the tool to use next, or none", schema: choice),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// The first choice's prompt: the request, the previous one for "her" and "it", and the
    /// offered tools with a short description each.
    static func firstPrompt(request: LocalToolRequest, tools: [DynamicTool]) -> String {
        var lines: [String] = []
        if let previous = request.previousText, !previous.isEmpty {
            lines.append("Previous request: \(previous)")
        }
        lines.append("Request: \(request.text)")
        lines.append("Tools:")
        // "none" is listed as an option with its cases: without it the eval's greetings, thanks
        // and jokes (none-01..06) each ran a tool.
        lines.append("- \(none): no tool, for greetings, thanks, jokes, chat, opinions, general knowledge or maths")
        for tool in tools {
            lines.append("- \(tool.name): \(short(tool.description, descriptionChars))")
        }
        lines.append("Which tool does the request need first? Answer none if it needs no tool.")
        return lines.joined(separator: "\n")
    }

    /// The prompt after a call: its result, and the question of what comes next.
    static func nextPrompt(after step: Step) -> String {
        "\(step.name) returned: \(short(step.result, resultChars))\n"
            + "Does the request still need another tool? Answer none if it is done."
    }

    static func argumentPrompt(_ name: String) -> String {
        "Fill in the arguments for \(name) from the request and any results above. Keep the user's "
            + "own words, with each pronoun replaced by what it refers to."
    }

    /// The final reply's prompt when the guided step ran tools: the request, then each result,
    /// so the model writes the reply from them without running them again.
    public static func replyPrompt(user: String, steps: [Step]) -> String {
        guard !steps.isEmpty else { return user }
        let results = steps.map { "\($0.name): \(short($0.result, resultChars))" }
        return user + "\n\n(Tools already run for this request, with their results:\n"
            + results.joined(separator: "\n") + ")"
    }

    /// Up to `maxSteps` choices. Each chosen tool runs through its DynamicTool (the gateway,
    /// the call budget). The chain stops at none, at a name not offered, at the same call twice,
    /// at a call that did not run (gated, blocked or failed: Swift's reply covers it), or when
    /// the budget is spent. An error before the first call falls back; one after keeps the
    /// calls made, so free-form never runs them again. Cancellation never falls back.
    public static func run(session: any LocalGuidedSession, request: LocalToolRequest, tools: [DynamicTool],
                           budget: LocalCallBudget, log: @Sendable (String) -> Void) async -> Result {
        var result = Result()
        guard !tools.isEmpty else { return result }
        // get_time last: listed first, it was chosen first for most requests in the eval
        // (none-01..05, send_message-03, personality_rewrite-01). Moving all three pinned tools
        // last sent memory questions to see_screen (search_memory-01..03).
        let tools = ordered(tools)
        let schema: GenerationSchema
        do {
            schema = try choiceSchema(tools.map(\.name))
        } catch {
            log("Local model: guided tool choice unavailable (\(error)), free-form tool calling")
            result.fellBack = true
            return result
        }
        var seen = Set<String>()
        var prompt = firstPrompt(request: request, tools: tools)
        do {
            for _ in 0..<maxSteps {
                try Task.checkCancellation()
                let choice = try await session.respond(to: prompt, schema: schema, options: choiceOptions)
                let name = try choice.value(String.self, forProperty: "tool")
                guard name != none, let tool = tools.first(where: { $0.name == name }) else { break }
                let arguments = try await session.respond(to: argumentPrompt(name), schema: tool.parameters,
                                                          options: argumentOptions)
                // A Stop between choosing and calling never runs the tool.
                try Task.checkCancellation()
                let key = name + "\u{0}" + arguments.jsonString
                guard seen.insert(key).inserted, budget.calls < LocalCallBudget.limit else { break }
                let text = try await tool.call(arguments: arguments)
                let outcome = budget.results.last?.outcome ?? .unknown
                let step = Step(name: name, arguments: arguments.jsonString, result: text, outcome: outcome)
                result.steps.append(step)
                guard outcome == .ran else { break }
                prompt = nextPrompt(after: step)
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                result.cancelled = true
            } else if result.steps.isEmpty {
                log("Local model: guided tool choice failed (\(LocalBrain.describe(error))), free-form tool calling")
                result.fellBack = true
            } else {
                log("Local model: guided tool choice stopped (\(LocalBrain.describe(error))) "
                    + "after \(result.steps.count) call(s)")
            }
        }
        return result
    }

    /// The tool listed last in the choice.
    static let listedLast = "get_time"

    /// `tools` with `listedLast` moved to the end, the rest in their own order.
    static func ordered(_ tools: [DynamicTool]) -> [DynamicTool] {
        tools.filter { $0.name != listedLast } + tools.filter { $0.name == listedLast }
    }

    static func short(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}

/// A tools-less `LanguageModelSession` behind `LocalGuidedSession`.
struct FoundationGuidedSession: LocalGuidedSession {
    let session: LanguageModelSession

    func respond(to prompt: String, schema: GenerationSchema, options: GenerationOptions) async throws
        -> GeneratedContent {
        try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true, options: options).content
    }
}
