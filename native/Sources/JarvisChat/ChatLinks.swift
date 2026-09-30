import Foundation

/// Which links in a reply open when clicked (plan §3.12 `MarkdownText`; review item): only
/// http and https. A reply is model output and can hold any URL, so every other scheme (file,
/// javascript, an app's own scheme) is ignored, and logged by its scheme alone: the rest of the
/// URL may hold a path or a token.
public enum ChatLinks {
    public static let openableSchemes: Set<String> = ["http", "https"]

    /// Whether `url` may open. When it may not, `log` gets one line naming its scheme.
    public static func opens(_ url: URL, log: (String) -> Void) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if openableSchemes.contains(scheme) { return true }
        log(scheme.isEmpty ? "chat: a link with no scheme was not opened"
                           : "chat: a \(scheme): link was not opened (only http and https open)")
        return false
    }
}
