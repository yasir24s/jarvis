import Foundation
import JarvisCore

/// Tool arguments use JarvisCore's insertion-ordered JSON object so the gateway and
/// JarvisBrain share one byte-exact representation.
public typealias ToolArgs = JSONObject

public struct ToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String = "", parametersJSON: String = #"{"type":"object","properties":{}}"#) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public enum BackendKind: String, Sendable, Equatable {
    case claude
    case local
}

public enum ToolOrigin: Sendable, Equatable {
    case model(BackendKind)
    case fastPath
    case confirmation
    case ui
}

public struct VerifiedShellCommand: Sendable, Equatable {
    public let line: String
    public let verdict: ShellVerdict

    internal init(line: String, verdict: ShellVerdict) {
        self.line = line
        self.verdict = verdict
    }
}

public struct ToolRunContext: Sendable {
    public let toolName: String
    public let origin: ToolOrigin
    public let turn: TurnContext
    public let verifiedShellCommand: VerifiedShellCommand?

    internal init(toolName: String, origin: ToolOrigin, turn: TurnContext,
                  verifiedShellCommand: VerifiedShellCommand? = nil) {
        self.toolName = toolName
        self.origin = origin
        self.turn = turn
        self.verifiedShellCommand = verifiedShellCommand
    }
}

public typealias ToolContext = ToolRunContext

/// M2's internal implementation contract. Later milestones register their internal tool
/// bodies through this contract; model, MCP and UI callers never receive it directly.
public protocol ToolImpl: Sendable {
    static var name: String { get }
    static var schema: ToolSchema { get }
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome
}

/// Compatibility contract for the M5 tool bodies described by the native plan.
public protocol JarvisTool: Sendable {
    static var name: String { get }
    func run(_ args: ToolArgs, _ ctx: ToolContext) async throws -> String
}

public enum ToolOutcome: Sendable {
    case text(String)
    case needsConfirmation(desc: String, action: @Sendable () async throws -> String)
}

public struct ToolCallResult: Sendable {
    public let text: String
    public let isError: Bool
    public let record: ToolRunRecord

    public init(text: String, isError: Bool, record: ToolRunRecord) {
        self.text = text
        self.isError = isError
        self.record = record
    }
}
