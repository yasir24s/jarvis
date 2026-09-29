import Foundation
import JarvisCore

/// jarvis.py `_claude_history_preamble`: the last turns folded into Claude's system prompt.
/// M1 already ports it over `HistoryLog` as `claudePreamble()`, so the driver calls it through
/// here and the port has one implementation. Proven by golden suite m3_history_preamble.
public enum HistoryPreamble {
    /// Over `_history[-7:-1]`: "User: " / "You: " plus each stripped non-empty content, one per
    /// line, after "\n\nRecent conversation:\n"; "" when no line survives. Throws where Python
    /// raises (a truthy non-string content).
    public static func text(for history: HistoryLog) throws(StateShapeError) -> String {
        try history.claudePreamble()
    }
}
