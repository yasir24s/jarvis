import AVFAudio
import Foundation

/// The system sounds jarvis.py's `chime(name)` plays (J:792-802).
public enum ChimeSound: String, Sendable, CaseIterable {
    /// Wake heard, and a command taken.
    case tink = "Tink"
    /// A voice enrolled.
    case glass = "Glass"

    public var url: URL { URL(fileURLWithPath: "/System/Library/Sounds/\(rawValue).aiff") }
}

/// `chime(name)`: Python starts `afplay /System/Library/Sounds/<name>.aiff` and does not wait.
/// Here the sound plays on the hub's effect player (plan §3.3), so voice processing hears it and
/// it does not reach the wake word or the endpointer, and `play` returns at once. Each sound is
/// read and converted to the effect player's 48 kHz stereo once.
public actor Chimes {
    private let hub: AudioHub
    private let log: @Sendable (String) -> Void
    private var loaded: [ChimeSound: HubAudio] = [:]

    public init(hub: AudioHub = .shared, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.hub = hub
        self.log = log
    }

    /// Starts `sound` and returns.
    public func play(_ sound: ChimeSound) {
        let audio: HubAudio
        if let cached = loaded[sound] {
            audio = cached
        } else {
            do {
                audio = try Self.load(sound.url)
                loaded[sound] = audio
            } catch {
                log("chime: cannot read \(sound.rawValue).aiff (\(error))")
                return
            }
        }
        let hub = self.hub
        let limit = Duration.seconds(Double(audio.frames) / SystemHubEngine.effectFormat.sampleRate) + .seconds(2)
        Task { try? await hub.play(audio, on: .effect, limit: limit) }
    }

    /// The file's audio as the effect player takes it: 48 kHz, two channels.
    static func load(_ url: URL) throws -> HubAudio {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeechEngineError(.error, "cannot allocate \(file.length) frames")
        }
        try file.read(into: input)
        let target = SystemHubEngine.effectFormat
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw SpeechEngineError(.error, "no converter from \(source) to \(target)")
        }
        let capacity = AVAudioFrameCount((Double(input.frameLength) * target.sampleRate / source.sampleRate).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let channels = output.floatChannelData else {
            throw SpeechEngineError(.error, "cannot allocate \(capacity) frames")
        }
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return input
        }
        guard status != .error else { throw error ?? SpeechEngineError(.error, "the chime would not convert") }
        let n = Int(output.frameLength)
        return HubAudio(channels: (0..<Int(target.channelCount)).map { Array(UnsafeBufferPointer(start: channels[$0], count: n)) },
                        sampleRate: target.sampleRate)
    }
}
