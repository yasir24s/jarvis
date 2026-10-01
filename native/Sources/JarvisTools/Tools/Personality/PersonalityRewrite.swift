import Foundation
import JarvisCore

/// `personality_rewrite` (plan decision D-50: exempt from D-44, with `personality_note`).
/// Python's `execute_tool` returns `personality_rewrite_tool(args.get("core", ""))`, and
/// `CoreState.personalityRewriteTool` is that function: 3 to 12 trait lines replace "core"
/// (learned notes survive), anything else is "Rewrite rejected — give me 3 to 12 trait lines,
/// one per line." A missing or non-string `core` counts as "". The seed's identity line stays
/// line 1, with its Tone and Humour lines when no new line covers them
/// (`PersonalityLogic.guardedCore`, DEV-P5-01). An executor (TaintPolicy), so a tainted turn
/// never reaches it.
struct PersonalityRewrite: ToolImpl {
    static let name = "personality_rewrite"
    static let schema = BuiltInTools.catalogSchema(named: name)

    let core: CoreState

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(await core.personalityRewriteTool(args["core"]?.stringValue ?? ""))
    }
}
