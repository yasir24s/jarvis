import Foundation

/// One tool call the model made in a turn: its name, its arguments flattened to strings (nil
/// when the call never reached a tool body, e.g. the injection guard stopped it), and the
/// gateway's outcome (ran, gated, blockedTaint, blockedGuard, failed, unknown).
public struct EvalToolCall: Codable, Sendable, Equatable {
    public var name: String
    public var args: [String: String]?
    public var outcome: String

    public init(name: String, args: [String: String]?, outcome: String) {
        self.name = name
        self.args = args
        self.outcome = outcome
    }
}

/// How the turn ended: LocalOutcome's four endings, and the harness's own timeout.
public enum EvalEnding: String, Codable, Sendable {
    case reply, empty, stuck, failed, timeout
}

/// The tools a turn was offered and the token budget they were chosen under
/// (`LocalToolSelection`). Nil fields mean the brain did not report them.
public struct EvalOffer: Codable, Sendable, Equatable {
    public var tools: [String]
    public var tier: String?
    public var instructionTokens: Int?
    public var toolTokens: Int?
    public var limit: Double?
    public var contextSize: Int?
    public var estimated: Bool?

    public init(tools: [String], tier: String? = nil, instructionTokens: Int? = nil, toolTokens: Int? = nil,
                limit: Double? = nil, contextSize: Int? = nil, estimated: Bool? = nil) {
        self.tools = tools
        self.tier = tier
        self.instructionTokens = instructionTokens
        self.toolTokens = toolTokens
        self.limit = limit
        self.contextSize = contextSize
        self.estimated = estimated
    }

    /// Instructions plus offered tools: what the prompt spent before the user's words.
    public var budgetUsed: Int? {
        guard let instructionTokens, let toolTokens else { return nil }
        return instructionTokens + toolTokens
    }
}

/// What one turn did, as a brain reports it to the scorer.
public struct EvalObservation: Sendable, Equatable {
    public var calls: [EvalToolCall]
    public var reply: String
    public var ending: EvalEnding
    public var latencyMs: Double
    public var offer: EvalOffer?

    public init(calls: [EvalToolCall], reply: String, ending: EvalEnding, latencyMs: Double, offer: EvalOffer?) {
        self.calls = calls
        self.reply = reply
        self.ending = ending
        self.latencyMs = latencyMs
        self.offer = offer
    }
}

/// Runs one case. The on-device runner is the real one; tests pass a fake.
public protocol EvalBrain: Sendable {
    func observe(_ evalCase: EvalCase) async -> EvalObservation
}

/// Why a case failed, the first that applies, in this order.
public enum FailureCategory: String, Codable, Sendable, CaseIterable {
    case timeout
    case modelError = "model_error"
    case stuck
    case emptyReply = "empty_reply"
    /// The right tool was never offered: L2's ranker or the budget left it out.
    case rankerMiss = "ranker_miss"
    /// Offered, but the model answered without calling it and claimed the action anyway.
    case claimedWithoutTool = "claimed_without_tool"
    /// Offered, but the model answered without calling any tool.
    case noToolCall = "no_tool_call"
    /// The model called tools, none of them an acceptable one.
    case wrongTool = "wrong_tool"
    /// No tool was wanted and the model called one.
    case unneededTool = "unneeded_tool"
    case wrongArgs = "wrong_args"
    /// The reply claims an action it must not (nothing ran, it waits for confirmation, or it
    /// was blocked).
    case falseClaim = "false_claim"
    case missingMention = "missing_mention"
}

/// One scored case: a line of the per-case JSONL.
public struct EvalCaseResult: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var request: String
    public var expected: String
    /// The first tool called, or "none".
    public var chosen: String
    public var calls: [EvalToolCall]
    public var reply: String
    public var ending: EvalEnding
    public var latencyMs: Double
    public var toolsOffered: Int?
    public var offered: [String]?
    public var budgetUsed: Int?
    public var budgetLimit: Double?
    /// Whether an acceptable tool was among those offered; nil when no tool was expected or the
    /// brain did not report its offer.
    public var expectedOffered: Bool?
    public var toolCorrect: Bool
    /// Nil when the case names no arguments or the expected tool was not called with any.
    public var argsCorrect: Bool?
    public var claimsAction: Bool
    /// The reply claims an action and no action tool ran this turn.
    public var falseDone: Bool
    public var mentionCorrect: Bool
    public var failure: FailureCategory?
    public var pass: Bool { failure == nil }
}

public enum EvalScorer {
    /// Tools that change something. A reply that claims an action is a false "Done" unless one
    /// of these ran.
    public static let actionTools: Set<String> = [
        "run_command", "run_applescript", "set_volume", "music_play", "music_control", "delete_file",
        "move_file", "write_file", "set_reminder", "make_note", "set_alarm", "notify", "send_message",
        "send_email", "create_event", "set_brightness", "type_text", "take_screenshot", "run_shortcut",
        "open_settings", "system_control", "personality_note", "personality_rewrite", "forget_memory",
        "correct_memory", "restore_memory",
    ]

    public static func score(_ c: EvalCase, _ o: EvalObservation) -> EvalCaseResult {
        let acceptable = c.acceptable
        let names = o.calls.map(\.name)
        let toolCorrect = names.isEmpty ? !c.expectsTool : names.contains { acceptable.contains($0) }
        let expectedOffered: Bool? = c.expectsTool ? o.offer.map { !acceptable.isDisjoint(with: $0.tools) } : nil

        var argsCorrect: Bool?
        if let expected = c.args, !expected.isEmpty,
           let call = o.calls.first(where: { $0.name == c.tool && $0.args != nil }), let got = call.args {
            argsCorrect = expected.allSatisfy { key, want in matches(got[key], want) }
        }

        let claims = ClaimDetector.claimsAction(o.reply)
        let ranAction = o.calls.contains { $0.outcome == "ran" && actionTools.contains($0.name) }
        let falseDone = claims && !ranAction
        let mentionCorrect = (c.mustMention ?? []).allSatisfy { matches(o.reply, $0) }

        let failure: FailureCategory? = {
            switch o.ending {
            case .timeout: return .timeout
            case .failed: return .modelError
            case .stuck: return .stuck
            case .empty: return .emptyReply
            case .reply: break
            }
            if !toolCorrect {
                if c.expectsTool {
                    if expectedOffered == false { return .rankerMiss }
                    if names.isEmpty { return claims ? .claimedWithoutTool : .noToolCall }
                    return .wrongTool
                }
                return .unneededTool
            }
            if argsCorrect == false { return .wrongArgs }
            if falseDone || (claims && c.forbidsClaim) { return .falseClaim }
            if !mentionCorrect { return .missingMention }
            return nil
        }()

        return EvalCaseResult(
            id: c.id, kind: c.kind, request: c.request, expected: c.tool, chosen: names.first ?? EvalCase.noTool,
            calls: o.calls, reply: o.reply, ending: o.ending, latencyMs: o.latencyMs,
            toolsOffered: o.offer?.tools.count, offered: o.offer?.tools, budgetUsed: o.offer?.budgetUsed,
            budgetLimit: o.offer?.limit, expectedOffered: expectedOffered, toolCorrect: toolCorrect,
            argsCorrect: argsCorrect, claimsAction: claims, falseDone: falseDone, mentionCorrect: mentionCorrect,
            failure: failure)
    }

    /// Loose match: `value`, lower-cased with whitespace collapsed, contains one of the
    /// `|`-separated alternatives in `want`.
    public static func matches(_ value: String?, _ want: String) -> Bool {
        guard let value else { return false }
        let hay = fold(value)
        return want.split(separator: "|").contains { hay.contains(fold(String($0))) }
    }

    static func fold(_ s: String) -> String {
        ClaimDetector.normalise(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Runs every case through `brain`, one at a time, handing each result to `progress`.
    public static func run(_ cases: [EvalCase], brain: some EvalBrain,
                           progress: (EvalCaseResult) -> Void = { _ in }) async -> [EvalCaseResult] {
        var out: [EvalCaseResult] = []
        for c in cases {
            let result = score(c, await brain.observe(c))
            progress(result)
            out.append(result)
        }
        return out
    }
}
