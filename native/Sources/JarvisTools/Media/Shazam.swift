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
///
/// Live fix D: the first live attempt failed with no word of why. Failures are now logged (the
/// error's domain, code and description; never audio), and so is what was heard (the signature's
/// length and the loudest sample). The first `warmUp` of input is not used: a freshly started
/// input can deliver silence while it settles, so the listening runs that much longer.
public struct LiveShazam: SongMatching {
    /// How much of the start of the input is thrown away.
    public static let warmUp: Double = 0.5

    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }) {
        self.log = log
    }

    /// Whether a buffer that starts `framesBefore` frames into the input is past the warm-up.
    static func pastWarmUp(framesBefore: Int64, sampleRate: Double) -> Bool {
        Double(framesBefore) >= warmUp * sampleRate
    }

    public func identify(seconds: Int) async -> SongMatch {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log("song id: the microphone has no usable format (\(format.sampleRate) Hz, \(format.channelCount) ch)")
            return .failed
        }
        let generator = SHSignatureGenerator()
        let lock = NSLock()
        let heard = Heard()
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            lock.withLock {
                let before = heard.frames
                heard.frames += Int64(buffer.frameLength)
                guard Self.pastWarmUp(framesBefore: before, sampleRate: rate) else { return }
                heard.peak = max(heard.peak, Self.peak(buffer))
                do {
                    try generator.append(buffer, at: time)
                } catch {
                    heard.appendError = heard.appendError ?? Self.describe(error)
                }
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log("song id: the microphone did not start (\(Self.describe(error)))")
            return .failed
        }
        try? await Task.sleep(for: .seconds(Double(seconds) + Self.warmUp))
        engine.stop()
        input.removeTap(onBus: 0)
        let (signature, peak, appendError) = lock.withLock { (generator.signature(), heard.peak, heard.appendError) }
        if let appendError { log("song id: some sound could not be used (\(appendError))") }
        log(String(format: "song id: listened %.1f s at %.0f Hz, loudest sample %.3f", signature.duration, rate, peak))
        do {
            let result = try await SHSession().result(from: signature)
            switch result {
            case .match(let match):
                guard let item = match.mediaItems.first, let title = item.title else { return .noMatch }
                return .match(title: title, artist: item.artist ?? "")
            case .noMatch: return .noMatch
            case .error(let error, _): return classify(error)
            @unknown default: return .failed
            }
        } catch {
            return classify(error)
        }
    }

    private func classify(_ error: any Error) -> SongMatch {
        let answer = Self.classify(error)
        log("song id: Shazam answered with an error (\(Self.describe(error))); taken as \(answer)")
        return answer
    }

    static func classify(_ error: any Error) -> SongMatch {
        let ns = error as NSError
        // Not verified on a real refusal yet: an app without the ShazamKit service is assumed to get an
        // error that names its entitlement. Anything else is a plain failure (a no-match is
        // ShazamKit's `.noMatch` result, never an error).
        if ns.localizedDescription.localizedCaseInsensitiveContains("entitle") {
            return .notEntitled
        }
        return .failed
    }

    /// "domain code: description", for the log.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// The loudest sample in `buffer`'s first channel (float buffers; 0 for others).
    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var top: Float = 0
        for i in 0..<Int(buffer.frameLength) { top = max(top, abs(data[0][i])) }
        return top
    }

    /// What the tap has seen, under the tap's lock.
    private final class Heard: @unchecked Sendable {
        var frames: Int64 = 0
        var peak: Float = 0
        var appendError: String?
    }
}
