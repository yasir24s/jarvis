import AVFAudio
import Foundation

/// V1 part 1: the short line JARVIS says in his own voice the moment a typed message is sent,
/// before the reply exists. The lines are rendered once, by the clone, at install
/// (`install-voice-assets.sh` runs the helper's `--render` mode), into
/// `acknowledgements/<reference>/<name>.wav` beside the voice assets, so playing one needs no
/// model. `install-voice-assets.sh` lists the same names and lines (`AcknowledgementTests`).
///
/// A question prefers "Let me see", "One moment" or "Looking into it"; anything else prefers
/// "Right away", "Certainly" or "On it". None of the last three lines used is said again; when
/// all of the preferred ones are among them, any other line is used.
public enum Acknowledgement {
    public struct Line: Sendable, Equatable {
        /// The clip's file name without `.wav`.
        public let name: String
        public let text: String

        public init(_ name: String, _ text: String) {
            self.name = name
            self.text = text
        }
    }

    public static let lines: [Line] = [
        Line("right-away", "Right away, sir."),
        Line("one-moment", "One moment, sir."),
        Line("certainly", "Certainly, sir."),
        Line("of-course", "Of course, sir."),
        Line("on-it", "On it, sir."),
        Line("let-me-see", "Let me see, sir."),
        Line("looking-into-it", "Looking into it, sir."),
        Line("give-me-a-second", "Give me a second, sir."),
        Line("very-good", "Very good, sir."),
        Line("working-on-it", "Working on it, sir."),
    ]

    /// The names a question prefers, and those anything else prefers.
    static let forQuestions = ["let-me-see", "one-moment", "looking-into-it"]
    static let forCommands = ["right-away", "certainly", "on-it"]
    /// How many of the lines last used are never said again.
    public static let recentLimit = 3
    /// The F5 steps `install-voice-assets.sh` renders the lines with. Replies with the installed
    /// default reference use 4 (`VoiceHelperSetup.defaultSteps(for:)`; V2: the dry references use
    /// 8), but the lines are rendered once, and at 4 three of the ten
    /// came out blurred (transcribed "On its, uh", "Right way, sir.", "Working on its circle");
    /// at 8, three takes each of those three were transcribed exactly (V1 lab, 2026-10-02).
    public static let renderSteps = 8

    /// A message is a question when it ends with "?" or its first word is one that opens a
    /// question ("what", "how", "is", "can", ...).
    public static func isQuestion(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let first = trimmed.prefix { !$0.isWhitespace }.lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        return questionWords.contains(first)
    }

    static let questionWords: Set<String> = [
        "what", "what's", "whats", "when", "when's", "where", "where's", "who", "who's", "whom", "whose",
        "which", "why", "how", "how's", "is", "isn't", "are", "aren't", "am", "was", "wasn't", "were",
        "do", "does", "doesn't", "did", "didn't", "don't", "can", "can't", "could", "will", "won't",
        "would", "should", "shall",
    ]

    /// The line for `message`: one of its preferred lines that is not among `recent` (the
    /// names last used, oldest first; only the last `recentLimit` count), or, when all of
    /// those are, any other line that is not.
    public static func choose(for message: String, recent: [String],
                              using generator: inout some RandomNumberGenerator) -> Line {
        let avoid = Set(recent.suffix(recentLimit))
        let preferred = isQuestion(message) ? forQuestions : forCommands
        let fresh = preferred.filter { !avoid.contains($0) }
        let pool = fresh.isEmpty ? lines.map(\.name).filter { !avoid.contains($0) } : fresh
        // Never empty: ten lines, at most three avoided.
        let name = pool.randomElement(using: &generator) ?? preferred[0]
        return lines.first { $0.name == name } ?? lines[0]
    }

    public static func choose(for message: String, recent: [String]) -> Line {
        var generator = SystemRandomNumberGenerator()
        return choose(for: message, recent: recent, using: &generator)
    }

    /// The reply as it is spoken after an acknowledgement: when its first sentence is itself a
    /// short acknowledgement (four words or fewer, ending "sir.") and more follows, that
    /// sentence is dropped. A reply that is only such a sentence is spoken as it is. The text
    /// shown in the chat is never changed.
    public static func spokenText(_ reply: String) -> String {
        let scalars = Array(reply.unicodeScalars)
        var end = 0
        while end < scalars.count {
            if ".!?".unicodeScalars.contains(scalars[end]),
               end + 1 < scalars.count, scalars[end + 1].properties.isWhitespace {
                break
            }
            end += 1
        }
        guard end < scalars.count else { return reply }   // one sentence: nothing follows
        let first = String(String.UnicodeScalarView(scalars[0...end]))
        let rest = String(String.UnicodeScalarView(scalars[(end + 1)...])).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShortAcknowledgement(first), !rest.isEmpty else { return reply }
        return rest
    }

    /// Four words or fewer, ending "sir." (in any case).
    static func isShortAcknowledgement(_ sentence: String) -> Bool {
        let words = sentence.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 4, let last = words.last else { return false }
        return last.lowercased() == "sir."
    }

    // MARK: - Clips

    /// The folder `install-voice-assets.sh` renders a reference's lines into. V2: the app asks
    /// for the reference the voice speaks with (`VoiceHelperSetup.reference`), not the setting, so
    /// with `dry` not installed it is `acknowledgements/default/`, as the voice is the default's.
    public static func folder(assets: URL, reference: String) -> URL {
        assets.appending(path: "acknowledgements/\(reference)", directoryHint: .isDirectory)
    }

    /// V6: the set of clips (`acknowledgements/<set>/`) that matches the voice in use: Qwen's
    /// (`qwen-dry`, Qwen with the dry reference at its rate) while Qwen speaks, else the one of
    /// the reference F5 speaks with.
    public static func set(for engine: EngineID, f5Reference: String) -> String {
        engine == .qwen ? QwenHelperSetup.acknowledgementSet : f5Reference
    }

    public static func clipURL(_ line: Line, assets: URL, reference: String) -> URL {
        folder(assets: assets, reference: reference).appending(path: "\(line.name).wav", directoryHint: .notDirectory)
    }

    /// One rendered line as 24 kHz mono samples (the helper writes 16-bit WAV at that rate).
    public static func loadClip(_ url: URL) throws -> PCMChunk {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate == EnginePlayer.sampleRate, format.channelCount == 1 else {
            throw SpeechEngineError(.error, "\(url.lastPathComponent) is \(format.sampleRate) Hz with "
                                    + "\(format.channelCount) channel(s), not 24 kHz mono")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeechEngineError(.error, "cannot allocate \(file.length) frames")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw SpeechEngineError(.error, "\(url.lastPathComponent) has no samples")
        }
        return PCMChunk(samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
                        sampleRate: format.sampleRate)
    }
}
