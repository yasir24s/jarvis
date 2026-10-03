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
public struct IdentifySong: ToolImpl {
    public static let name = "identify_song"
    public static let schema = ToolSchema(
        name: name,
        description: "Identify the song playing around the user (Shazam): listens through the microphone for about eight seconds, then names the song and artist. Use it when the user asks what song is playing.",
        parametersJSON: #"{"type": "object", "properties": {}, "required": []}"#)

    public static let unavailable = "Song recognition isn't set up yet, sir. It needs my build signed with the "
        + "Apple Developer profile that has ShazamKit switched on; the steps are in the batch C report."
    public static let noMatch = "I listened, but couldn't identify that song, sir."
    public static let failed = "I had trouble identifying that, sir."

    let feature: ShazamFeature
    let matcher: any SongMatching

    public init(feature: ShazamFeature = .live(), matcher: any SongMatching = LiveShazam()) {
        self.feature = feature
        self.matcher = matcher
    }

    public func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard feature.isAvailable else { return .text(Self.unavailable) }
        switch await matcher.identify(seconds: 8) {
        case .match(let title, let artist):
            return .text("That's \(title) by \(artist.isEmpty ? "an unknown artist" : artist), sir.")
        case .noMatch: return .text(Self.noMatch)
        case .notEntitled: return .text(Self.unavailable)
        case .failed: return .text(Self.failed)
        }
    }
}

/// Whether ShazamKit can work in this build: the framework's classes are there, and build-app.sh
/// marked the bundle as signed with the ShazamKit profile (`JARVISShazamKit` in Info.plist, which
/// it sets only when `JARVIS_SHAZAMKIT_PROFILE` names a provisioning profile).
public struct ShazamFeature: Sendable {
    public static let infoKey = "JARVISShazamKit"
    public let isAvailable: Bool

    public init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    public static func live(bundle: Bundle = .main) -> ShazamFeature {
        let marked = bundle.object(forInfoDictionaryKey: infoKey) as? Bool ?? false
        return ShazamFeature(isAvailable: marked && NSClassFromString("SHSession") != nil)
    }
}

public enum SongMatch: Sendable, Equatable {
    case match(title: String, artist: String)
    case noMatch
    case notEntitled      // ShazamKit refused the app (no ShazamKit service on its App ID)
    case failed
}

public protocol SongMatching: Sendable {
    func identify(seconds: Int) async -> SongMatch
}

/// The microphone through AVAudioEngine for `seconds`, then one SHSession match. Records only; it
/// never plays anything.
public struct LiveShazam: SongMatching {
    public init() {}

    public func identify(seconds: Int) async -> SongMatch {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return .failed }
        let generator = SHSignatureGenerator()
        let lock = NSLock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            lock.withLock { try? generator.append(buffer, at: time) }
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); return .failed }
        try? await Task.sleep(for: .seconds(seconds))
        engine.stop()
        input.removeTap(onBus: 0)
        let signature = lock.withLock { generator.signature() }
        do {
            let result = try await SHSession().result(from: signature)
            switch result {
            case .match(let match):
                guard let item = match.mediaItems.first, let title = item.title else { return .noMatch }
                return .match(title: title, artist: item.artist ?? "")
            case .noMatch: return .noMatch
            case .error(let error, _): return Self.classify(error)
            @unknown default: return .failed
            }
        } catch {
            return Self.classify(error)
        }
    }

    static func classify(_ error: any Error) -> SongMatch {
        let ns = error as NSError
        // Not verified on a real refusal yet: an app without the ShazamKit service is assumed to get an
        // error that names its entitlement. Anything else is a plain failure.
        if ns.localizedDescription.localizedCaseInsensitiveContains("entitle") {
            return .notEntitled
        }
        return .failed
    }
}
