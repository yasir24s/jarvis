import Foundation
import JarvisCore

/// `get_time` (plan: M05-M06 tools, A-SYS-2). Python's `execute_tool` returns
/// `_get_system_info("time")`, which is `datetime.now().strftime("It is %I:%M %p on %A, %B %d.")`:
/// the hour and the day zero-padded, the names from the C locale. `PyTime.strftime` renders
/// exactly that (never `DateFormatter`), and the clock and time zone are injected so tests pin
/// the instant. The arguments are ignored, as in Python. Not an executor, so it runs on a
/// tainted turn too.
struct GetTime: ToolImpl {
    static let name = "get_time"
    static let schema = BuiltInTools.catalogSchema(named: name)
    /// `_get_system_info`'s format for "time" in jarvis.py.
    static let format = "It is %I:%M %p on %A, %B %d."

    let clock: any JarvisClock
    let timeZone: TimeZone

    /// The tool's text at the clock's current instant.
    func text() -> String {
        PyTime.strftime(Self.format, Date(timeIntervalSince1970: clock.now()), timeZone: timeZone)
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(text())
    }
}
