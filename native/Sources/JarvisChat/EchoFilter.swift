import Foundation
import JarvisCore

/// Live fix 4: a defensive echo filter for voice transcripts. In the first live session the
/// user said "Do I have any reminders set" while JARVIS's "…, sir." was still playing, and the
/// transcript came back "Do I have any reminders, sir?". A transcript that ends in ", sir",
/// heard within `window` seconds of a line of his that ended in "sir", loses that ending.
public enum EchoFilter {
    /// How recently he must have spoken, in seconds.
    public static let window: Double = 2

    private static let trailingSir = try! PyRegex(#"^(.*\S)\s*,\s*sir\s*([?.!]*)\s*$"#, ignoreCase: true, dotAll: true)
    private static let endsInSir = try! PyRegex(#"\bsir\s*[?.!]*\s*$"#, ignoreCase: true)

    /// `transcript` without the echoed ", sir", or nil when it is left as it was. `spokeAt` is
    /// when his last line ended (now, while it plays); `lastLine` is that line's text.
    public static func strip(_ transcript: String, lastLine: String?, spokeAt: Double?, now: Double) -> String? {
        guard let lastLine, let spokeAt, now - spokeAt <= window, now >= spokeAt - window,
              endsInSir.search(lastLine) != nil,
              let m = trailingSir.match(transcript), let body = m.groups[1] else { return nil }
        return body + (m.groups[2] ?? "")
    }
}
