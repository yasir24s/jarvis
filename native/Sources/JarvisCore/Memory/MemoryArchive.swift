import Foundation

// One line of `memory/archive.jsonl` (D-51, P2): every message, typed or spoken, from the user
// or JARVIS. The archive is append-only and native-only; Python's rolling history.json is
// untouched. Text is never logged anywhere: callers log counts. UI1 part 5 adds the turn's id to
// each message and a supersede line for the turns an edit replaced.

/// Who said an archived message.
public enum MemoryRole: String, Sendable, CaseIterable {
    case user
    case jarvis
}

/// `{"timestamp": <epoch s>, "date": "YYYY-MM-DD", "channel": "voice"|"text", "role":
/// "user"|"jarvis", "text": "..."}`, compact, in that key order, non-ASCII kept. JSON escapes
/// every newline in the text, so one message is always one line. UI1 part 5: a message from a
/// turn also carries `"turn": "<uuid>"`, last, so an edit can supersede the turn (a line
/// without it reads as before).
public struct ArchiveEntry: Sendable, Equatable {
    public var timestamp: Double
    public var date: String          // the local calendar date of `timestamp`
    public var channel: String       // `Channel.rawValue` (JarvisTools): "voice" or "text";
                                     // "voice (Python)" in archive-python.jsonl (P6b)
    public var role: MemoryRole
    public var text: String
    /// UI1 part 5: the turn the message belongs to, nil on lines from before UI1 and on the
    /// Python-era archive.
    public var turn: String?

    public init(timestamp: Double, date: String, channel: String, role: MemoryRole, text: String,
                turn: String? = nil) {
        self.timestamp = timestamp
        self.date = date
        self.channel = channel
        self.role = role
        self.text = text
        self.turn = turn
    }

    /// Stamps `text` with `timestamp` and its local date in `timeZone`.
    public init(timestamp: Double, timeZone: TimeZone, channel: String, role: MemoryRole,
                text: String, turn: String? = nil) {
        let date = PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: timestamp),
                                   timeZone: timeZone)
        self.init(timestamp: timestamp, date: date, channel: channel, role: role, text: text, turn: turn)
    }

    /// The archive line, without its trailing newline.
    public var line: String {
        var members: [JSONObject.Member] = [
            .init(key: "timestamp", value: .double(timestamp)),
            .init(key: "date", value: .string(date)),
            .init(key: "channel", value: .string(channel)),
            .init(key: "role", value: .string(role.rawValue)),
            .init(key: "text", value: .string(text)),
        ]
        if let turn { members.append(.init(key: "turn", value: .string(turn))) }
        return PyJSON.dumps(.object(JSONObject(members)), ensureASCII: false)
    }

    /// Parses one archive line; nil for anything else (a torn or foreign line is skipped, and
    /// so is a supersede line, which has no role or text).
    public init?(line: Data) {
        guard let value = try? PyJSON.loads(line), let o = value.objectValue,
              let timestamp = o["timestamp"]?.pyFloat,
              let date = o["date"]?.stringValue,
              let channel = o["channel"]?.stringValue,
              let role = o["role"]?.stringValue.flatMap(MemoryRole.init(rawValue:)),
              let text = o["text"]?.stringValue
        else { return nil }
        self.init(timestamp: timestamp, date: date, channel: channel, role: role, text: text,
                  turn: o["turn"]?.stringValue)
    }
}

/// UI1 part 5: an edit replaced these turns. One appended line, `{"timestamp": <epoch s>,
/// "date": "YYYY-MM-DD", "superseded": ["<uuid>", ...]}`: the archive stays append-only, and a
/// reader from before UI1 skips the line, as it skips any line that is not a message. The
/// compile (P2) and search_memory skip every message of a superseded turn.
public enum ArchiveSupersede {
    public static let key = "superseded"

    /// The line that supersedes `turns`, stamped `timestamp`, without its trailing newline.
    public static func line(turns: [String], timestamp: Double, timeZone: TimeZone) -> String {
        let date = PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: timestamp), timeZone: timeZone)
        let object = JSONObject([
            .init(key: "timestamp", value: .double(timestamp)),
            .init(key: "date", value: .string(date)),
            .init(key: key, value: .array(turns.map { .string($0) })),
        ])
        return PyJSON.dumps(.object(object), ensureASCII: false)
    }

    /// The turns a supersede line names; nil for any other line.
    public static func turns(line: Data) -> [String]? {
        guard let value = try? PyJSON.loads(line), let o = value.objectValue,
              case .array(let items)? = o[key] else { return nil }
        return items.compactMap(\.stringValue)
    }

    /// Every turn the supersede lines among `lines` name.
    public static func superseded<S: Sequence>(in lines: S) -> Set<String> where S.Element == Data {
        var out = Set<String>()
        for line in lines {
            // Only a line that names the key can be one; the rest are not parsed twice.
            guard line.range(of: Data(("\"" + key + "\"").utf8)) != nil, let turns = turns(line: line) else { continue }
            out.formUnion(turns)
        }
        return out
    }

    /// What `"turn": "<id>"` looks like inside an archive line, for finding a turn's lines
    /// without parsing them.
    public static func needle(turn: String) -> Data {
        let object = PyJSON.dumps(.object(JSONObject([.init(key: "turn", value: .string(turn))])), ensureASCII: false)
        return Data(object.dropFirst().dropLast().utf8)
    }
}
