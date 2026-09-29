import Foundation
import FoundationModels
import JarvisCore
import JarvisTools
import Synchronization

// plan M02-M04 §3.8: one catalog tool as a FoundationModels `Tool`. The on-device model can
// reach a tool body only through `call`, and `call` only through `ToolGateway.call`, so the
// local brain gets the same guards, taint rules and turn records as the Claude path.

/// Counts one turn's local tool calls (plan §3.8: more than 10 in one turn ends it with
/// "I got stuck working through that, sir."). Python bounds 5 rounds of calls; FoundationModels
/// exposes no round count, so native counts calls. The eleventh call is refused before it
/// reaches the gateway, and its error ends the model's response.
public final class LocalCallBudget: Sendable {
    public static let limit = 10

    /// What the eleventh call throws.
    public struct LimitExceeded: Error, Equatable, CustomStringConvertible {
        public var description: String { "more than \(LocalCallBudget.limit) tool calls in one turn" }
    }

    private let count = Mutex(0)

    public init() {}

    /// Calls so far this turn, refused ones included.
    public var calls: Int { count.withLock { $0 } }

    /// True once a call has been refused.
    public var exceeded: Bool { calls > Self.limit }

    /// Counts one call; throws if it is over the limit.
    func take() throws(LimitExceeded) {
        let n = count.withLock { value -> Int in
            value += 1
            return value
        }
        if n > Self.limit { throw LimitExceeded() }
    }
}

/// `Arguments = GeneratedContent`, `Output = String`. `call` parses the generated arguments
/// into an ordered `JSONObject` (anything but a JSON object becomes `{}`, as the MCP path
/// treats non-object arguments) and returns the gateway's text, error or not, to the model.
public struct DynamicTool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = String

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    public let turn: TurnContext
    /// The catalog's parameters JSON, kept for the chars ÷ 3.5 estimate.
    let parametersJSON: String
    private let gateway: ToolGateway
    private let budget: LocalCallBudget

    public init(schema: ToolSchema, gateway: ToolGateway, turn: TurnContext,
                budget: LocalCallBudget) throws {
        name = schema.name
        description = schema.description
        parameters = try SchemaBridge.generationSchema(for: schema)
        parametersJSON = schema.parametersJSON
        self.turn = turn
        self.gateway = gateway
        self.budget = budget
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        try budget.take()
        let args = (try? PyJSON.loads(Data(arguments.jsonString.utf8)))?.objectValue ?? JSONObject()
        return await gateway.call(name, args, turn: turn, origin: .model(.local)).text
    }

    /// Code points in the name, description and parameters JSON (Python `len`).
    var estimateChars: Int {
        name.unicodeScalars.count + description.unicodeScalars.count + parametersJSON.unicodeScalars.count
    }
}
