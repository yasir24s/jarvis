import Foundation

// One line of `memory/archive.jsonl` (D-51, P2): every message, typed or spoken, from the user
// or JARVIS. The archive is append-only and native-only; Python's rolling history.json is
// untouched. Text is never logged anywhere: callers log counts.

/// Who said an archived message.
public enum MemoryRole: String, Sendable, CaseIterable {
    case user
    case jarvis
}

/// `{"timestamp": <epoch s>, "date": "YYYY-MM-DD", "channel": "voice"|"text", "role":
/// "user"|"jarvis", "text": "..."}`, compact, in that key order, non-ASCII kept. JSON escapes
/// every newline in the text, so one message is always one line.
public struct ArchiveEntry: Sendable, Equatable {
    public var timestamp: Double
    public var date: String          // the local calendar date of `timestamp`
    public var channel: String       // `Channel.rawValue` (JarvisTools): "voice" or "text";
                                     // "voice (Python)" in archive-python.jsonl (P6b)
    public var role: MemoryRole
    public var text: String

    public init(timestamp: Double, date: String, channel: String, role: MemoryRole, text: String) {
        self.timestamp = timestamp
        self.date = date
        self.channel = channel
        self.role = role
        self.text = text
    }

    /// Stamps `text` with `timestamp` and its local date in `timeZone`.
    public init(timestamp: Double, timeZone: TimeZone, channel: String, role: MemoryRole,
                text: String) {
        let date = PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: timestamp),
                                   timeZone: timeZone)
        self.init(timestamp: timestamp, date: date, channel: channel, role: role, text: text)
    }

    /// The archive line, without its trailing newline.
    public var line: String {
        let object = JSONObject([
            .init(key: "timestamp", value: .double(timestamp)),
            .init(key: "date", value: .string(date)),
            .init(key: "channel", value: .string(channel)),
            .init(key: "role", value: .string(role.rawValue)),
            .init(key: "text", value: .string(text)),
        ])
        return PyJSON.dumps(.object(object), ensureASCII: false)
    }

    /// Parses one archive line; nil for anything else (a torn or foreign line is skipped).
    public init?(line: Data) {
        guard let value = try? PyJSON.loads(line), let o = value.objectValue,
              let timestamp = o["timestamp"]?.pyFloat,
              let date = o["date"]?.stringValue,
              let channel = o["channel"]?.stringValue,
              let role = o["role"]?.stringValue.flatMap(MemoryRole.init(rawValue:)),
              let text = o["text"]?.stringValue
        else { return nil }
        self.init(timestamp: timestamp, date: date, channel: channel, role: role, text: text)
    }
}
