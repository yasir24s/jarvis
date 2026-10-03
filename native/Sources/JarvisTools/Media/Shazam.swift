@preconcurrency import AVFAudio
import Foundation
import JarvisCore
import ShazamKit

/// Whether ShazamKit can work in this build: the framework's classes are there, and build-app.sh
/// marked the bundle as signed with the ShazamKit profile (`JARVISShazamKit` in Info.plist, which
/// scripts/sign-app.sh sets only when it embeds the Developer ID provisioning profile).
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
