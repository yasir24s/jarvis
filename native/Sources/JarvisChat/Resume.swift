import Foundation
import JarvisCore

// Live updates (U1), the hand-over. Before the swap the old process writes resume.json in its
// run folder (0600): the chat as the user sees it, the composer's draft, the scroll position,
// the chat window, and both build ids. The new build is opened with `--resume <path>`, puts
// all of it back, deletes the file and logs how long the swap took. After 30 s of healthy
// running it writes update-health.json beside it, which the update helper waits for.

/// What a live update carries from the old process to the new one.
public struct ResumeState: Codable, Sendable, Equatable {
    /// The chat window: whether it was open, and its frame in screen coordinates
    /// (x, y, width, height, AppKit's bottom-left origin).
    public struct Window: Codable, Sendable, Equatable {
        public var open: Bool
        public var frame: [Double]?

        public init(open: Bool, frame: [Double]?) {
            self.open = open
            self.frame = frame
        }
    }

    public static let fileName = "resume.json"
    public static let healthFileName = "update-health.json"

    /// The running build and the staged one it hands over to; nil when unknown.
    public var from: BuildID?
    public var to: BuildID?
    /// When the old process wrote this, unix time: the swap's duration is measured from it.
    public var written: Double
    public var chat: ResumeChat
    public var window: Window

    public init(from: BuildID?, to: BuildID?, written: Double, chat: ResumeChat, window: Window) {
        self.from = from
        self.to = to
        self.written = written
        self.chat = chat
        self.window = window
    }

    /// Writes `url` with mode 0600 from the first byte: a temp file beside it, then a rename.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.writePrivately(try encoder.encode(self), to: url)
    }

    /// The state in `url`; nil when it is missing or does not parse.
    public static func read(_ url: URL) -> ResumeState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeState.self, from: data)
    }

    /// `data` at `url`, 0600, via `<url>.tmp` and rename(2); the folder is made 0700 if missing.
    public static func writePrivately(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = folder.appending(path: url.lastPathComponent + ".tmp")
        let path = temp.path(percentEncoded: false)
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) }
        let wrote = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += n
            }
            return true
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard wrote, synced, rename(path, url.path(percentEncoded: false)) == 0 else {
            unlink(path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
    }
}

/// The chat part of a hand-over: the rows, the draft with its paste flag, and the scroll.
public struct ResumeChat: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        /// "user", "assistant" or "system".
        public var role: String
        public var text: String
        public var retracted: Bool

        public init(role: String, text: String, retracted: Bool) {
            self.role = role
            self.text = text
            self.retracted = retracted
        }
    }

    /// Where the transcript was scrolled: at the bottom (following new rows), or with the row
    /// `topIndex` at the top.
    public struct Scroll: Codable, Sendable, Equatable {
        public var atBottom: Bool
        public var topIndex: Int?

        public init(atBottom: Bool, topIndex: Int?) {
            self.atBottom = atBottom
            self.topIndex = topIndex
        }
    }

    public var rows: [Row]
    public var draft: String
    /// The draft came by paste or drop (X-8): it stays external content after the swap.
    public var draftPasted: Bool
    public var scroll: Scroll

    public init(rows: [Row], draft: String, draftPasted: Bool, scroll: Scroll) {
        self.rows = rows
        self.draft = draft
        self.draftPasted = draftPasted
        self.scroll = scroll
    }
}

/// The new build's side of the hand-over.
public enum ResumeLaunch {
    public static let flag = "--resume"
    /// How long a resumed build waits for the old process to let go of .jarvis.lock.
    public static let lockWait: Duration = .seconds(15)
    /// How long the resumed build runs healthily before it writes update-health.json.
    public static let healthyAfter: Duration = .seconds(30)

    /// The path after `--resume`, nil when the flag is absent or has no path after it.
    public static func path(arguments: [String]) -> URL? {
        guard let i = arguments.dropFirst().firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        let path = arguments[i + 1]
        guard !path.isEmpty, !path.hasPrefix("--") else { return nil }
        return URL(filePath: path, directoryHint: .notDirectory)
    }

    /// Calls `attempt` until it returns a value or `timeout` has passed, `every` apart, on the
    /// caller's actor.
    public static func retry<T>(timeout: Duration, every: Duration,
                                sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                                clock: ContinuousClock = .continuous,
                                isolation: isolated (any Actor)? = #isolation,
                                _ attempt: () -> T?) async -> T? {
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let value = attempt() { return value }
            guard clock.now < deadline else { return nil }
            await sleep(every)
        }
    }

    /// "update: resumed from <old> to <new> in <n> s", the line the new build logs.
    public static func resumedLine(_ state: ResumeState, now: Double, running: BuildID?) -> String {
        let seconds = max(0, now - state.written)
        return "update: resumed from \(state.from?.label ?? "an unknown build") to "
            + "\(running?.label ?? "an unknown build") in \(String(format: "%.1f", seconds)) s"
    }

    /// The health report's content: this process and its build.
    public static func healthReport(pid: Int32, build: BuildID?, at time: Double) -> Data {
        let object: [String: Any] = ["pid": Int(pid), "build": build?.label ?? "unknown", "at": time]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

extension ChatViewModel {
    /// The chat as a live update hands it over: every row, the draft and the scroll.
    public func resumeSnapshot() -> ResumeChat {
        let rows = messages.map { message -> ResumeChat.Row in
            let role: String = switch message.role {
            case .user: "user"
            case .assistant: "assistant"
            case .system: "system"
            }
            return ResumeChat.Row(role: role, text: message.text, retracted: message.retracted)
        }
        let top = scrollTop.flatMap { id in messages.firstIndex(where: { $0.id == id }) }
        return ResumeChat(rows: rows, draft: draft.text, draftPasted: draft.pasted,
                          scroll: ResumeChat.Scroll(atBottom: scrolledToBottom || top == nil, topIndex: top))
    }

    /// Puts a handed-over chat back: the rows (finished), the draft with its paste flag, and
    /// the scroll position for the chat view to apply. Only before anything else is shown.
    public func restore(_ chat: ResumeChat) {
        guard messages.isEmpty else { return }
        let restored = chat.rows.map { row -> ChatMessage in
            let role: ChatMessage.Role = switch row.role {
            case "user": .user
            case "system": .system
            default: .assistant
            }
            return ChatMessage(role: role, text: row.text, phase: .finished, retracted: row.retracted)
        }
        replaceMessages(restored)
        var draft = ComposerDraft(text: chat.draft)
        if chat.draftPasted { draft.notePaste() }
        self.draft = draft
        if chat.scroll.atBottom || restored.isEmpty {
            requestScroll(ChatScrollRequest(row: restored.last?.id, atBottom: true))
        } else {
            let index = min(max(chat.scroll.topIndex ?? 0, 0), restored.count - 1)
            requestScroll(ChatScrollRequest(row: restored[index].id, atBottom: false))
        }
    }
}

/// A scroll position for the chat view to apply once: a row at the top, or the bottom.
public struct ChatScrollRequest: Sendable, Equatable {
    public var row: UUID?
    public var atBottom: Bool

    public init(row: UUID?, atBottom: Bool) {
        self.row = row
        self.atBottom = atBottom
    }
}
