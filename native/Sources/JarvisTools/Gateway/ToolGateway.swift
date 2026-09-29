import Foundation
import JarvisCore

public actor ToolGateway {
    public static let shared = ToolGateway()

    private struct Handler: Sendable {
        let schema: ToolSchema
        let run: @Sendable (JSONObject, ToolRunContext) async throws -> ToolOutcome
    }

    private var handlers: [String: Handler] = [:]
    private let confirmationGate: ConfirmationGate
    private let log: @Sendable (String) -> Void
    private let research: (any ResearchCounting)?

    public init(confirmationGate: ConfirmationGate = .shared,
                log: @escaping @Sendable (String) -> Void = {
                    JarvisLog.log($0, category: .tools)
                },
                research: (any ResearchCounting)? = nil) {
        self.confirmationGate = confirmationGate
        self.log = log
        self.research = research
    }

    /// Registers an implementation for later milestones. Registration is deliberately an
    /// actor operation; callers still execute only through `call`.
    public func register(_ tool: any ToolImpl) {
        handlers[type(of: tool).name] = Handler(schema: type(of: tool).schema) { args, ctx in
            try await tool.run(args, ctx)
        }
    }

    public func register(_ tool: any JarvisTool, schema: ToolSchema) {
        handlers[type(of: tool).name] = Handler(schema: schema) { args, ctx in
            .text(try await tool.run(args, ctx))
        }
    }

    public func toolList() -> [ToolSchema] {
        DataSourceMap.toolNames.map { name in
            handlers[name]?.schema ?? ToolSchema(name: name)
        }
    }

    public func call(_ name: String, _ args: JSONObject, turn: TurnContext,
                     origin: ToolOrigin) async -> ToolCallResult {
        await turn.enqueue { [self] in
            await self.execute(name, args, turn: turn, origin: origin)
        }
    }

    private func execute(_ name: String, _ args: JSONObject, turn: TurnContext,
                         origin: ToolOrigin) async -> ToolCallResult {
        guard await turn.isOpen else {
            return await result("Turn closed.", name: name, origin: origin, outcome: .failed,
                                error: true, turn: turn)
        }

        // A catalog tool is known even before a later milestone registers its body. This
        // distinction keeps M3's taint and static guards active while the M5/M6 bodies land.
        guard DataSourceMap.allTools.contains(name) || handlers[name] != nil else {
            return await result(GuardStrings.unknownTool(name), name: name, origin: origin,
                                outcome: .unknown, error: false, turn: turn)
        }
        if TaintPolicy.executors.contains(name), await turn.tainted {
            log("BLOCKED \(name) after untrusted-content ingestion (injection guard)")
            research?.bump("taint_block", by: 1)
            let text: String
            let isError: Bool
            if case .model(.claude) = origin {
                text = TaintPolicy.blockedTextClaude
                isError = true
            } else {
                text = TaintPolicy.blockedTextLocal
                isError = false
            }
            return await result(text, name: name, origin: origin, outcome: .blockedTaint,
                                error: isError, turn: turn)
        }

        var verified: VerifiedShellCommand?
        if name == "run_command" {
            let command = args["command"]?.stringValue ?? ""
            let tier = PyShellRisk.classify(command)
            let verdict = ShellVerdict(tier: tier, pythonTier: tier,
                                       reasons: tier == .ok ? [] : ["python:\(tier.rawValue)"],
                                       isSudo: PyShellRisk.containsSudo(command))
            switch tier {
            case .block:
                log("BLOCKED command: \(String(command.prefix(120)))")
                let text = PyShellRisk.containsSudo(command) ? GuardStrings.sudoNotAllowed : GuardStrings.systemDamaging
                return await result(text, name: name, origin: origin, outcome: .blockedGuard,
                                    error: false, turn: turn)
            case .confirm:
                await turn.recordSources(for: name)
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                let desc = "That will run: \(String(trimmed.prefix(100)))"
                let gateway = self
                await confirmationGate.stash(desc: desc, action: {
                    await gateway.runConfirmed(name: name, args: args, turn: turn, origin: .confirmation,
                                               verified: VerifiedShellCommand(line: command, verdict: verdict))
                }, turn: turn)
                return await result(GuardStrings.gatePrompt(desc), name: name, origin: origin,
                                    outcome: .gated, error: false, turn: turn)
            case .ok:
                verified = VerifiedShellCommand(line: command, verdict: verdict)
            }
        } else if name == "run_applescript",
                  AppleScriptPolicy.isDangerous(args["script"]?.stringValue) {
            log("BLOCKED dangerous AppleScript from LLM")
            return await result(GuardStrings.appleScriptRefused, name: name, origin: origin,
                                outcome: .blockedGuard, error: false, turn: turn)
        }

        guard let handler = handlers[name] else {
            return await result(GuardStrings.unknownTool(name), name: name, origin: origin,
                                outcome: .unknown, error: false, turn: turn)
        }

        await turn.recordSources(for: name)
        do {
            let context = ToolRunContext(toolName: name, origin: origin, turn: turn,
                                         verifiedShellCommand: verified)
            let outcome = try await handler.run(args, context)
            switch outcome {
            case .text(let text):
                if TaintPolicy.untrusted.contains(name) { await turn.markTainted(by: name) }
                return await result(text, name: name, origin: origin, outcome: .ran,
                                    error: false, turn: turn)
            case .needsConfirmation(let desc, let action):
                await confirmationGate.stash(desc: desc, action: action, turn: turn)
                return await result(GuardStrings.gatePrompt(desc), name: name, origin: origin,
                                    outcome: .gated, error: false, turn: turn)
            }
        } catch {
            return await result(GuardStrings.toolError(String(describing: error)), name: name,
                                origin: origin, outcome: .failed, error: false, turn: turn)
        }
    }

    private func runConfirmed(name: String, args: JSONObject, turn: TurnContext,
                              origin: ToolOrigin, verified: VerifiedShellCommand) async -> String {
        guard let handler = handlers[name] else { return GuardStrings.unknownTool(name) }
        do {
            let context = ToolRunContext(toolName: name, origin: origin, turn: turn,
                                         verifiedShellCommand: verified)
            let outcome = try await handler.run(args, context)
            switch outcome {
            case .text(let text): return text
            case .needsConfirmation:
                return GuardStrings.confirmFailed("confirmation requested twice")
            }
        } catch {
            return GuardStrings.confirmFailed(String(describing: error))
        }
    }

    private func result(_ text: String, name: String, origin: ToolOrigin,
                        outcome: ToolRunRecord.Outcome, error: Bool,
                        turn: TurnContext) async -> ToolCallResult {
        let record = ToolRunRecord(name: name, origin: origin, outcome: outcome)
        await turn.record(record)
        return ToolCallResult(text: text, isError: error, record: record)
    }
}
