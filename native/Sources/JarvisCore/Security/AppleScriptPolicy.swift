import Foundation

public enum AppleScriptPolicy {
    public static let denyPatterns: [String] = [
        #"do\s+shell\s+script|administrator\s+privileges|system\s+events"#
    ]
    private static let deny = try! PyRegex(denyPatterns[0], ignoreCase: true)

    public static func isDangerous(_ s: String?) -> Bool {
        deny.search(s ?? "") != nil
    }

    public static func escape(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
