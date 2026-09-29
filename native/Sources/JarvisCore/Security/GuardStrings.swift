import Foundation

public enum GuardStrings {
    public static let sudoNotAllowed = "That sudo command isn't on my allowed list, sir, so I won't run it."
    public static let systemDamaging = "I won't run that, sir — it's system-damaging, so I've blocked it."
    public static func gatePrompt(_ desc: String) -> String { "\(desc), sir — say 'confirm' to proceed." }
    public static func confirmFailed(_ error: String) -> String { "That failed, sir: \(error)" }
    public static let appleScriptRefused = "I won't run that script, sir — it could shell out or automate unsafely."
    public static func toolError(_ error: String) -> String { "Tool error: \(error)" }
    public static func unknownTool(_ name: String) -> String { "Unknown tool \(name)" }
}
