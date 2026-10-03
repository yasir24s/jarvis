import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// Batch C part 1: identify_song behind its feature check, with a scripted matcher. Nothing here
/// opens the microphone or reaches Shazam.
@Suite("Batch C identify_song", .timeLimit(.minutes(1)))
struct IdentifySongTests {
    final class Matcher: SongMatching, @unchecked Sendable {
        let answer: SongMatch
        private(set) var calls = 0
        private let lock = NSLock()
        init(_ answer: SongMatch) { self.answer = answer }
        func identify(seconds: Int) async -> SongMatch {
            lock.withLock { calls += 1 }
            return answer
        }
    }

    static func call(_ tool: IdentifySong) async -> ToolCallResult {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        await gateway.register(tool)
        return await gateway.call(IdentifySong.name, JSONObject([]), turn: TurnContext(channel: .voice),
                                  origin: .model(.claude))
    }

    @Test("without the ShazamKit build it says what is missing and never listens")
    func gated() async {
        let matcher = Matcher(.match(title: "Invented Song", artist: "The Inventions"))
        let result = await Self.call(IdentifySong(feature: ShazamFeature(isAvailable: false), matcher: matcher))
        #expect(result.text == IdentifySong.unavailable)
        #expect(matcher.calls == 0)
    }

    @Test("the replies follow Python's AudD lines", arguments: [
        (SongMatch.match(title: "Invented Song", artist: "The Inventions"), "That's Invented Song by The Inventions, sir."),
        (SongMatch.match(title: "Invented Song", artist: ""), "That's Invented Song by an unknown artist, sir."),
        (SongMatch.noMatch, IdentifySong.noMatch),
        (SongMatch.failed, IdentifySong.failed),
        (SongMatch.notEntitled, IdentifySong.unavailable),
    ])
    func replies(_ answer: SongMatch, _ reply: String) async {
        let result = await Self.call(IdentifySong(feature: ShazamFeature(isAvailable: true), matcher: Matcher(answer)))
        #expect(result.text == reply)
    }

    @Test("the feature check reads the build's marker; the test runner has none")
    func feature() {
        #expect(!ShazamFeature.live().isAvailable)
    }
}
