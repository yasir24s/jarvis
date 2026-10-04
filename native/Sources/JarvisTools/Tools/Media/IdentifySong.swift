@preconcurrency import AVFAudio
import Foundation
import JarvisCore
import ShazamKit

/// Batch C part 1: `identify_song`, Python's "what song is this" (jarvis.py 4126-4173) through
/// Apple's ShazamKit instead of AudD. It listens to the room for a few seconds and matches the
/// signature against the Shazam catalogue.
///
/// ShazamKit answers only an app whose App ID has the ShazamKit service and which is signed with
/// that team's profile, so the tool sits behind a feature check (`ShazamFeature`): until the build
/// says it was signed that way, it says what is missing and never opens the microphone.
struct IdentifySong: ToolImpl {
    static let name = "identify_song"
    static let schema = ToolSchema(
        name: name,
        description: "Identify the song playing around the user (Shazam): listens through the microphone for about eight seconds, then names the song and artist. Use it when the user asks what song is playing.",
        parametersJSON: #"{"type": "object", "properties": {}, "required": []}"#)

    static let unavailable = "Song recognition isn't set up yet, sir. It needs my build signed with the "
        + "Apple Developer profile that has ShazamKit switched on; the steps are in the batch C report."
    /// Live fix D (DEV-LIVE-09): Python's AudD line was "I listened, but couldn't identify that
    /// song, sir."; a no-match now reads apart from a failure.
    static let noMatch = "I couldn't make out a song, sir."
    static let failed = "I had trouble identifying that, sir."

    let feature: ShazamFeature
    let matcher: any SongMatching

    init(feature: ShazamFeature = .live(), matcher: any SongMatching = LiveShazam()) {
        self.feature = feature
        self.matcher = matcher
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard feature.isAvailable else { return .text(Self.unavailable) }
        var answer = await matcher.identify(seconds: 8)
        if answer == .failed { answer = await matcher.identify(seconds: 8) }   // live fix D: once more, not after a no-match
        switch answer {
        case .match(let title, let artist):
            return .text("That's \(title) by \(artist.isEmpty ? "an unknown artist" : artist), sir.")
        case .noMatch: return .text(Self.noMatch)
        case .notEntitled: return .text(Self.unavailable)
        case .failed: return .text(Self.failed)
        }
    }
}

