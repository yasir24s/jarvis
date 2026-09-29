import Foundation
import JarvisCore

/// The tool bodies that exist so far (B4: `get_time`), registered on a gateway in one call, so
/// JarvisBrain and JarvisApp never name a tool type. Every other catalog tool stays listed with
/// no body, and the gateway answers it with its unknown-tool text until M5 or M6 adds one.
public enum BuiltInTools {
    /// Registers every implemented body on `gateway`. `clock` and `timeZone` stand in for what
    /// Python's `datetime.now()` reads; the app passes the system's, tests pin both.
    public static func register(on gateway: ToolGateway, clock: any JarvisClock, timeZone: TimeZone) async {
        await gateway.register(GetTime(clock: clock, timeZone: timeZone))
    }

    /// The generated `ToolCatalog` entry for `name`, so no body carries a hand-written schema.
    static func catalogSchema(named name: String) -> ToolSchema {
        ToolCatalog.tools.first { $0.name == name } ?? ToolSchema(name: name)
    }
}
