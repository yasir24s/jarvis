import Foundation

// P6b part 5: the task journal, `memory/journal.jsonl`. One line for every tool call the gateway
// handles: when, which tool, what came of it, a short summary of what it was given and the start
// of its reply. What looks like a secret is masked first (P3's `Redactor`), and the reply of a
// tool that reads (a file, the screen, the clipboard, a web page: `TaintPolicy.untrusted`) is
// never kept. Append-only and native-only, like the archive; nothing here logs the text.

/// `{"timestamp": <epoch s>, "date": "YYYY-MM-DD", "time": "HH:MM", "tool": "...", "outcome":
/// "ran"|"gated"|"blocked"|"failed", "args": "...", "reply": "..." or null}`, compact, in that key
/// order, non-ASCII kept, one call per line.
public struct JournalEntry: Sendable, Equatable {
    /// What came of the call.
    public enum Outcome: String, Sendable, CaseIterable {
        case ran
        case gated          // waiting for the user to confirm
        case blocked        // refused by a guard or the injection guard
        case failed         // it threw, or no such tool
    }

    /// The longest argument summary kept, in characters.
    public static let argsLimit = 160
    /// Each argument's value is cut to this many characters within it.
    public static let valueLimit = 80
    /// The longest reply excerpt kept, in characters.
    public static let replyLimit = 200
    /// What is redacted is first cut to this many characters, so a long argument or reply costs
    /// little; anything past it is cut anyway.
    static let redactWindow = 2000

    public var timestamp: Double
    public var date: String          // the local calendar date of `timestamp`
    public var time: String          // its local time, "HH:MM"
    public var tool: String
    public var outcome: Outcome
    public var args: String
    public var reply: String?        // nil when the tool read content, which is never kept

    public init(timestamp: Double, date: String, time: String, tool: String, outcome: Outcome, args: String,
                reply: String?) {
        self.timestamp = timestamp
        self.date = date
        self.time = time
        self.tool = tool
        self.outcome = outcome
        self.args = args
        self.reply = reply
    }

    /// A call stamped `timestamp` in `timeZone`, its arguments summarised and its reply cut, both
    /// redacted (`summary`, `excerpt`); `reply` nil keeps none.
    public init(timestamp: Double, timeZone: TimeZone, tool: String, outcome: Outcome, args: JSONObject,
                reply: String?) {
        let at = Date(timeIntervalSince1970: timestamp)
        self.init(timestamp: timestamp, date: PyTime.strftime("%Y-%m-%d", at, timeZone: timeZone),
                  time: PyTime.strftime("%H:%M", at, timeZone: timeZone), tool: tool, outcome: outcome,
                  args: Self.summary(args), reply: reply.map(Self.excerpt))
    }

    /// "key: value" for each argument in order, joined by "; ": a string as it is, anything else
    /// as compact JSON; each value redacted, put on one line and cut to `valueLimit`, and the whole
    /// cut to `argsLimit`. A cut ends with "...".
    public static func summary(_ args: JSONObject) -> String {
        let parts = args.members.map { m -> String in
            let value: String
            if case .string(let s) = m.value { value = s } else { value = PyJSON.dumps(m.value, ensureASCII: false) }
            return "\(m.key): \(clean(value, limit: valueLimit))"
        }
        return cut(parts.joined(separator: "; "), limit: argsLimit)
    }

    /// The reply redacted, on one line and cut to `replyLimit`.
    public static func excerpt(_ reply: String) -> String {
        clean(reply, limit: replyLimit)
    }

    private static func clean(_ text: String, limit: Int) -> String {
        let masked = Redactor.redacted(Py.prefix(text, redactWindow))
        return cut(Py.strip(masked.split(whereSeparator: \.isNewline).joined(separator: " ")), limit: limit)
    }

    private static func cut(_ s: String, limit: Int) -> String {
        Py.len(s) <= limit ? s : Py.prefix(s, limit - 3) + "..."
    }

    /// The journal line, without its trailing newline.
    public var line: String {
        let object = JSONObject([
            .init(key: "timestamp", value: .double(timestamp)),
            .init(key: "date", value: .string(date)),
            .init(key: "time", value: .string(time)),
            .init(key: "tool", value: .string(tool)),
            .init(key: "outcome", value: .string(outcome.rawValue)),
            .init(key: "args", value: .string(args)),
            .init(key: "reply", value: reply.map { .string($0) } ?? .null),
        ])
        return PyJSON.dumps(.object(object), ensureASCII: false)
    }

    /// Parses one journal line; nil for anything else (a torn or foreign line is skipped).
    public init?(line: Data) {
        guard let value = try? PyJSON.loads(line), let o = value.objectValue,
              let timestamp = o["timestamp"]?.pyFloat,
              let date = o["date"]?.stringValue,
              let time = o["time"]?.stringValue,
              let tool = o["tool"]?.stringValue,
              let outcome = o["outcome"]?.stringValue.flatMap(Outcome.init(rawValue:)),
              let args = o["args"]?.stringValue,
              let reply = o["reply"]
        else { return nil }
        let text: String?
        switch reply {
        case .string(let s): text = s
        case .null: text = nil
        default: return nil
        }
        self.init(timestamp: timestamp, date: date, time: time, tool: tool, outcome: outcome, args: args, reply: text)
    }
}
