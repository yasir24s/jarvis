import Foundation
import JarvisCore
import JarvisChat
import Testing

/// Live updates (U1), the hand-over: resume.json as the old process writes it and the new one
/// reads it, and the chat's rows, draft and scroll going through it. No app or window runs.
@Suite("U1 save and resume", .timeLimit(.minutes(1)))
@MainActor
struct ResumeTests {
    static let built = BuildID(commit: "aaa1111", dirty: false, built: "2026-10-01T20:00:00Z")
    static let staged = BuildID(commit: "bbb2222", dirty: true, built: "2026-10-01T21:00:00Z")

    static func state(chat: ResumeChat = ResumeChat(rows: [], draft: "", draftPasted: false,
                                                    scroll: .init(atBottom: true, topIndex: nil))) -> ResumeState {
        ResumeState(from: built, to: staged, written: 1_000_000, chat: chat,
                    window: .init(open: true, frame: [100, 200, 640, 480]))
    }

    @Test("resume.json is written 0600 through a temp file, and reads back the same")
    func writeAndRead() throws {
        let fake = try UpdateScriptTests.FakeDist()
        defer { fake.remove() }
        let run = fake.root.appending(path: "run", directoryHint: .isDirectory)
        let url = run.appending(path: ResumeState.fileName)
        let state = Self.state()
        try state.write(to: url)
        #expect(ResumeState.read(url) == state)
        let fm = FileManager.default
        let mode = try #require(try fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        let folderMode = try #require(try fm.attributesOfItem(atPath: run.path(percentEncoded: false))[.posixPermissions] as? Int)
        #expect(folderMode == 0o700)
        #expect(try fm.contentsOfDirectory(atPath: run.path(percentEncoded: false)) == [ResumeState.fileName])
        // A second write replaces the first, still 0600.
        var next = state
        next.chat.draft = "half a thought"
        try next.write(to: url)
        #expect(ResumeState.read(url)?.chat.draft == "half a thought")
        #expect(try fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int == 0o600)
        // The build ids are both in the file.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("aaa1111") && text.contains("bbb2222"))
        try Data("not json".utf8).write(to: url)
        #expect(ResumeState.read(url) == nil)
    }

    @Test("the chat's rows, draft with its paste flag, and scroll go through the hand-over")
    func chatRoundTrip() throws {
        let old = ChatViewModel(minimumGap: .zero)
        old.restore(ResumeChat(rows: [
            .init(role: "user", text: "what time is it", retracted: false),
            .init(role: "assistant", text: "It is **three**, sir.", retracted: false),
            .init(role: "assistant", text: "a retracted reply", retracted: true),
            .init(role: "system", text: "Cancelled.", retracted: false),
        ], draft: "", draftPasted: false, scroll: .init(atBottom: true, topIndex: nil)))
        old.draft.text = "pasted text"
        old.notePaste()
        old.scrollTop = old.messages[1].id
        old.scrolledToBottom = false

        let saved = old.resumeSnapshot()
        #expect(saved.rows.map(\.role) == ["user", "assistant", "assistant", "system"])
        #expect(saved.rows[2].retracted)
        #expect(saved.draft == "pasted text" && saved.draftPasted)
        #expect(saved.scroll == ResumeChat.Scroll(atBottom: false, topIndex: 1))

        // Through the file, as the new build reads it.
        let fake = try UpdateScriptTests.FakeDist()
        defer { fake.remove() }
        let url = fake.root.appending(path: "run/resume.json")
        try Self.state(chat: saved).write(to: url)
        let back = try #require(ResumeState.read(url))

        let new = ChatViewModel(minimumGap: .zero)
        new.restore(back.chat)
        #expect(new.messages.map(\.text) == old.messages.map(\.text))
        #expect(new.messages.map(\.role) == [.user, .assistant, .assistant, .system])
        #expect(new.messages.allSatisfy { $0.phase == .finished })
        #expect(new.messages.map(\.retracted) == [false, false, true, false])
        #expect(new.messages[1].rendersMarkdown && !new.messages[2].rendersMarkdown)
        // The draft keeps its paste flag: pasted text stays external content (X-8).
        #expect(new.draft.text == "pasted text")
        #expect(new.draft.input?.pasted == true)
        // The scroll is handed to the view once: the second row at the top.
        #expect(new.takeScrollRequest() == ChatScrollRequest(row: new.messages[1].id, atBottom: false))
        #expect(new.takeScrollRequest() == nil)
    }

    @Test("a chat at the bottom resumes at the bottom, and a restore never overwrites rows")
    func scrollAtBottomAndNoOverwrite() {
        let model = ChatViewModel(minimumGap: .zero)
        model.restore(ResumeChat(rows: [.init(role: "user", text: "one", retracted: false),
                                        .init(role: "assistant", text: "two", retracted: false)],
                                 draft: "typed", draftPasted: false, scroll: .init(atBottom: true, topIndex: 0)))
        #expect(model.takeScrollRequest() == ChatScrollRequest(row: model.messages.last?.id, atBottom: true))
        #expect(model.draft.input?.pasted == false)
        model.restore(ResumeChat(rows: [.init(role: "user", text: "other", retracted: false)],
                                 draft: "", draftPasted: false, scroll: .init(atBottom: true, topIndex: nil)))
        #expect(model.messages.map(\.text) == ["one", "two"])
        // A top row past the end is clamped to the last row.
        let clamped = ChatViewModel(minimumGap: .zero)
        clamped.restore(ResumeChat(rows: [.init(role: "user", text: "only", retracted: false)],
                                   draft: "", draftPasted: false, scroll: .init(atBottom: false, topIndex: 9)))
        #expect(clamped.takeScrollRequest() == ChatScrollRequest(row: clamped.messages[0].id, atBottom: false))
    }

    @Test("--resume takes the path after it; the window opens after an update only if it was open")
    func launchArguments() {
        #expect(ResumeLaunch.path(arguments: ["JARVIS", "--resume", "/tmp/x/resume.json"])?.path(percentEncoded: false)
                == "/tmp/x/resume.json")
        #expect(ResumeLaunch.path(arguments: ["JARVIS"]) == nil)
        #expect(ResumeLaunch.path(arguments: ["JARVIS", "--resume"]) == nil)
        #expect(ResumeLaunch.path(arguments: ["JARVIS", "--resume", "--background"]) == nil)
        #expect(ResumeLaunch.path(arguments: ["--resume", "/tmp/x"]) == nil, "never the executable's own name")
        var closed = Self.state()
        closed.window.open = false
        #expect(!ChatLaunch.opensWindow(arguments: ["JARVIS", "--resume", "/tmp/x"], resume: closed))
        #expect(ChatLaunch.opensWindow(arguments: ["JARVIS", "--resume", "/tmp/x", "--background"], resume: Self.state()))
        #expect(ChatLaunch.opensWindow(arguments: ["JARVIS"], resume: nil))
        #expect(!ChatLaunch.opensWindow(arguments: ["JARVIS", "--background"], resume: nil))
    }

    @Test("the lock wait gives up after its timeout, and returns the lock once it is free")
    func lockRetry() async {
        let none: Int? = await ResumeLaunch.retry(timeout: .milliseconds(60), every: .milliseconds(5)) { nil }
        #expect(none == nil)
        var tries = 0
        let third = await ResumeLaunch.retry(timeout: .seconds(10), every: .milliseconds(1)) { () -> Int? in
            tries += 1
            return tries == 3 ? 42 : nil
        }
        #expect(third == 42 && tries == 3)
        #expect(ResumeLaunch.lockWait == .seconds(15))
    }

    @Test("the resumed line names both builds and the time the swap took")
    func resumedLine() {
        #expect(ResumeLaunch.resumedLine(Self.state(), now: 1_000_004.3, running: Self.staged)
                == "update: resumed from aaa1111 2026-10-01T20:00:00Z to bbb2222+dirty 2026-10-01T21:00:00Z in 4.3 s")
        var unknown = Self.state()
        unknown.from = nil
        #expect(ResumeLaunch.resumedLine(unknown, now: 999_990, running: nil)
                == "update: resumed from an unknown build to an unknown build in 0.0 s")
    }
}
