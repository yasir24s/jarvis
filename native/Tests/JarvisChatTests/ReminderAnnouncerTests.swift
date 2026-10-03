import Foundation
@testable import JarvisChat
import Testing

/// F1: a due reminder is spoken at once when JARVIS is idle, and after the reply when a turn is
/// running. The "voice" is a recorded list: nothing plays.
@MainActor
@Suite("ReminderAnnouncerTests")
struct ReminderAnnouncerTests {
    @Test func idleSpeaksAtOnce() {
        var spoken: [String] = []
        let announcer = ReminderAnnouncer(isBusy: { false }, speak: { spoken.append($0) }, post: { _ in })
        announcer.announce("Sir, you asked me to remind you: stretch.")
        #expect(spoken == ["Sir, you asked me to remind you: stretch."])
        #expect(announcer.heldCount == 0)
    }

    @Test func midReplyItWaitsForTheReplyThenSpeaksInOrder() async {
        var busy = true
        var spoken: [String] = []
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let announcer = ReminderAnnouncer(isBusy: { busy }, speak: { spoken.append($0); continuation.yield() },
                                          post: { _ in }, sleep: { _ in await Task.yield() })
        announcer.announce("first")
        announcer.announce("second")
        #expect(spoken.isEmpty)
        #expect(announcer.heldCount == 2)
        await Task.yield()
        #expect(spoken.isEmpty)   // still busy: still held
        busy = false
        var it = stream.makeAsyncIterator()
        _ = await it.next()
        _ = await it.next()
        #expect(spoken == ["first", "second"])
        #expect(announcer.heldCount == 0)
    }

    @Test func withNoVoiceTheLineIsPostedInTheChat() {
        var posted: [String] = []
        let announcer = ReminderAnnouncer(isBusy: { false }, speak: nil, post: { posted.append($0) })
        announcer.announce("Alarm, sir. It's time.")
        #expect(posted == ["Alarm, sir. It's time."])
    }
}
