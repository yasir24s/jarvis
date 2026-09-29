import Foundation

public enum Affirmation {
    private static let pattern = try! PyRegex(#"^\s*(confirm(ed)?|yes|yeah|yep|do it( now)?|go ahead|proceed|go for it|affirmative|please do|that'?s right)\b"#, ignoreCase: true)

    public static func matches(_ s: String?) -> Bool {
        pattern.match(s ?? "") != nil
    }
}
