import Foundation
import JarvisCore

/// `personality_note` (plan decision D-50: exempt from D-44, with `personality_rewrite`).
/// Python's `execute_tool` returns `personality_note_tool(args.get("note", ""))`, and
/// `CoreState.personalityNoteTool` is that function: "Note too short to keep." under 8
/// characters after `strip()`, otherwise `personality_learn` and "Noted, and remembered — my
/// personality file is updated." A missing or non-string `note` counts as "", as the gateway
/// reads `run_command`'s argument. An executor (TaintPolicy), so a tainted turn never reaches it.
struct PersonalityNote: ToolImpl {
    static let name = "personality_note"
    static let schema = BuiltInTools.catalogSchema(named: name)

    let core: CoreState

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(try await core.personalityNoteTool(args["note"]?.stringValue ?? ""))
    }
}
