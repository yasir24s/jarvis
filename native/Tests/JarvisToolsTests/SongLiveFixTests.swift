import Foundation
import JarvisCore
@testable import JarvisTools
import ShazamKit
import Testing

/// Live fixes A, C and D, with a scripted matcher: nothing here opens the microphone or reaches
/// Shazam. A: "what song iss this" (a typo) reaches the song fast path. C: with nothing playing
/// in Music, that fast path listens with identify_song. D: identify_song tries once more after
/// a failure (not after a no-match), and a no-match reads apart from a failure.
@Suite("Song questions and identify_song (live fixes A, C, D)", .timeLimit(.minutes(1)))
struct SongLiveFixTests {
    final class Matcher: SongMatching, @unchecked Sendable {
        private var answers: [SongMatch]
        private(set) var calls = 0
        private let lock = NSLock()
        init(_ answers: [SongMatch]) { self.answers = answers }
        func identify(seconds: Int) async -> SongMatch {
            lock.withLock {
                calls += 1
                return answers.count > 1 ? answers.removeFirst() : answers[0]
            }
        }
    }

    static func identify(_ matcher: Matcher) async -> String {
        await IdentifySongTests.call(IdentifySong(feature: ShazamFeature(isAvailable: true), matcher: matcher)).text
    }

    @Test func aFailureIsTriedOnceMore() async {
        let recovered = Matcher([.failed, .match(title: "Invented Song", artist: "The Inventions")])
        #expect(await Self.identify(recovered) == "That's Invented Song by The Inventions, sir.")
        #expect(recovered.calls == 2)

        let twice = Matcher([.failed, .failed])
        #expect(await Self.identify(twice) == IdentifySong.failed)
        #expect(twice.calls == 2)
    }

    @Test func aNoMatchIsNotRetriedAndReadsApartFromAFailure() async {
        let none = Matcher([.noMatch])
        #expect(await Self.identify(none) == "I couldn't make out a song, sir.")
        #expect(none.calls == 1)
        #expect(IdentifySong.noMatch != IdentifySong.failed)
    }

    @Test func theFirstHalfSecondOfInputIsNotUsed() {
        #expect(!LiveShazam.pastWarmUp(framesBefore: 0, sampleRate: 48_000))
        #expect(!LiveShazam.pastWarmUp(framesBefore: 23_999, sampleRate: 48_000))
        #expect(LiveShazam.pastWarmUp(framesBefore: 24_000, sampleRate: 48_000))
    }

    @Test func errorsAreClassifiedAndDescribed() {
        let server = NSError(domain: SHErrorDomain, code: 202, userInfo: [NSLocalizedDescriptionKey: "Match attempt failed"])
        #expect(LiveShazam.classify(server) == .failed)
        #expect(LiveShazam.describe(server) == "\(SHErrorDomain) 202: Match attempt failed")
        let refused = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing entitlement"])
        #expect(LiveShazam.classify(refused) == .notEntitled)
    }

    @Test(arguments: ["what song iss this", "what song is this", "whats this song", "what's this song",
                      "what's playing here", "what sonf is this", "What song is this?", "whats this somg"])
    func songQuestionsReachTheSongFastPath(_ text: String) {
        #expect(FastPathRouter().route(text).branch == "media.now_playing")
    }

    @Test(arguments: ["what's on my screen", "what time is it", "what song goes la la la", "what is this",
                      "play this song", "who is playing", "what\u{2019}s playing", "what song is that one"])
    func otherQuestionsDoNot(_ text: String) {
        #expect(FastPathRouter().route(text).branch != "media.now_playing")
    }

    @Test func nothingPlayingInMusicListensForTheSong() async throws {
        let rig = try await QuickDispatchTests.Rig(scriptOutput: "nothing")   // Music's script: nothing playing
        defer { rig.sandbox.remove() }
        // Without identify_song (or without the ShazamKit build) the answer is Python's.
        #expect(await rig.say("what song is this") == "Nothing is playing, sir.")
        await rig.gateway.register(IdentifySong(feature: ShazamFeature(isAvailable: false), matcher: Matcher([.noMatch])))
        #expect(await rig.say("what song is this") == "Nothing is playing, sir.")
        let matcher = Matcher([.match(title: "Invented Song", artist: "The Inventions")])
        await rig.gateway.register(IdentifySong(feature: ShazamFeature(isAvailable: true), matcher: matcher))
        #expect(await rig.say("what song iss this") == "That's Invented Song by The Inventions, sir.")
        #expect(matcher.calls == 1)
    }
}
