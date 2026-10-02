import Foundation
import JarvisBrain
import Observation

/// UI1 part 3: the floating HUD's states, hud.html's `data-state`.
public enum HUDState: String, Sendable, Equatable, CaseIterable {
    case idle
    case listening
    case thinking
    case speaking

    /// The status pill's text (`jarvisState`'s labels).
    public var label: String {
        switch self {
        case .idle: "J.A.R.V.I.S"
        case .listening: "Listening"
        case .thinking: "Processing"
        case .speaking: "Speaking"
        }
    }

    /// The bars' level: 0.6 listening and speaking, 0.35 thinking, still when idle.
    public var level: Double {
        switch self {
        case .idle: 0
        case .listening, .speaking: 0.6
        case .thinking: 0.35
        }
    }
}

/// The captions of one spoken reply: its sentences, as Python's `pop_sentences` splits them,
/// each shown for its share of the reply's audio. A sentence's share is its length in code
/// points over the length of them all, since the voice speaks the reply whole (V1 part 2) and
/// says nothing about where each sentence falls.
public struct CaptionTimeline: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let text: String
        /// Seconds from the start of the audio.
        public let start: Double
    }

    public let lines: [Line]
    public let duration: Double

    public init(text: String, duration: Double) {
        let sentences = SentenceSplitter.pop(text, force: true).sentences.filter { !$0.isEmpty }
        let total = sentences.reduce(0) { $0 + $1.unicodeScalars.count }
        var start = 0.0
        var lines: [Line] = []
        for sentence in sentences {
            lines.append(Line(text: sentence, start: start))
            if total > 0 {
                start += duration * Double(sentence.unicodeScalars.count) / Double(total)
            }
        }
        self.lines = lines
        self.duration = max(0, duration)
    }

    /// The line showing `elapsed` seconds into the audio: the last to have started. nil before
    /// the audio, or with no lines.
    public func line(at elapsed: Double) -> String? {
        guard elapsed >= 0 else { return nil }
        return lines.last(where: { $0.start <= elapsed })?.text
    }
}

/// UI1 part 3: what the floating HUD shows (plan: M08-M13 §3.7). The four calls of hud.html,
/// `state`, `caption`, `hide` and `level`, and what drives them now: a turn makes him think, with
/// the user's message as the caption; the reply's audio makes him speak, its caption advancing
/// sentence by sentence; when both are over he goes idle, which hides the HUD 2.6 s later.
/// Listening comes from push-to-talk (M9a): `listening()`, `level` per frame, `listeningEnded()`.
@MainActor
@Observable
public final class HUDModel {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// hud.html's idle hide: `setTimeout(jarvisHide, 2600)`.
    public static let idleHide: Duration = .milliseconds(2600)

    public private(set) var state: HUDState = .idle
    /// The status pill's text: the state's label, or the text `state` was given.
    public private(set) var status = HUDState.idle.label
    /// The caption, or nil when none shows.
    public private(set) var caption: String?
    /// Shown (hud.html's `show` class). The view animates between shown and hidden.
    public private(set) var shown = false
    /// The bars' level, 0...1.
    public private(set) var level = 0.0
    /// The Show HUD setting: while it is off, nothing shows.
    public var enabled: Bool {
        didSet { if !enabled { hide() } }
    }

    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var hideTimer: Task<Void, Never>?
    @ObservationIgnored private var captions: Task<Void, Never>?
    /// The message of the turn running now, nil between turns.
    @ObservationIgnored private var turnMessage: String?
    /// A reply's speech was handed to the voice and its audio has not started.
    @ObservationIgnored private var awaitingSpeech = false

    /// - sleep: waits out the idle hide and each caption; tests pass their own.
    public init(enabled: Bool = true, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.enabled = enabled
        self.sleep = sleep
    }

    // MARK: - hud.html

    /// `jarvisState(s, t)`: any state shows the HUD and cancels the idle hide; idle starts it.
    public func state(_ s: HUDState, text: String = "") {
        hideTimer?.cancel()
        hideTimer = nil
        state = s
        status = text.isEmpty ? s.label : text
        level = s.level
        shown = enabled
        guard s == .idle else { return }
        let sleep = self.sleep
        hideTimer = Task { [weak self] in
            do { try await sleep(Self.idleHide) } catch { return }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// `jarvisCaption(t)`: nil or empty hides the caption.
    public func caption(_ text: String?) {
        caption = text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `jarvisHide()`: hidden, and the bars stop.
    public func hide() {
        hideTimer?.cancel()
        hideTimer = nil
        shown = false
        level = 0
    }

    /// `jarvisLevel(v)`, clamped to 0...1.
    public func level(_ value: Double) {
        level = min(1, max(0, value))
    }

    // MARK: - What drives it

    /// A turn was taken: thinking, with the user's message as the caption (Python's
    /// `handle_one`: `hud.state("thinking")`, `hud.caption(command)`).
    public func turnBegan(_ message: String) {
        turnMessage = message
        stopCaptions()
        state(.thinking)
        caption(message)
    }

    /// The turn is over. When its reply is to be spoken he keeps thinking until the audio
    /// starts; otherwise he goes idle, unless the voice is still speaking.
    public func turnEnded(speechFollows: Bool) {
        turnMessage = nil
        if speechFollows {
            awaitingSpeech = true
        } else if state != .speaking {
            settle()
        }
    }

    /// The reply's audio started: speaking, the caption advancing through `timeline`.
    public func speechStarted(_ timeline: CaptionTimeline) {
        awaitingSpeech = false
        stopCaptions()
        state(.speaking)
        caption(timeline.line(at: 0))
        let sleep = self.sleep
        captions = Task { [weak self] in
            var at = 0.0
            for line in timeline.lines.dropFirst() {
                do { try await sleep(.milliseconds(Int(((line.start - at) * 1000).rounded()))) } catch { return }
                guard !Task.isCancelled, let self else { return }
                at = line.start
                self.caption(line.text)
            }
        }
    }

    /// The reply's audio ended, or its speech ended without any (stopped, or the voice failed).
    /// Back to thinking if a turn is running, else idle. Nothing changes if no reply was being
    /// spoken or awaited.
    public func speechEnded() {
        guard state == .speaking || awaitingSpeech else { return }
        awaitingSpeech = false
        stopCaptions()
        if let turnMessage {
            state(.thinking)
            caption(turnMessage)
        } else {
            settle()
        }
    }

    /// M9a: the microphone opened (push-to-talk): listening. The bars follow `level` from here.
    public func listening() {
        stopCaptions()
        state(.listening)
        caption(nil)
    }

    /// M9a: listening ended and nothing was sent: idle, unless a turn or his speech has already
    /// taken over.
    public func listeningEnded() {
        guard state == .listening else { return }
        settle()
    }

    private func settle() {
        stopCaptions()
        state(.idle)
        caption(nil)
    }

    private func stopCaptions() {
        captions?.cancel()
        captions = nil
    }
}

/// UI1 part 3: the "Show HUD" item in the app menu and the menu-bar menu, kept as `showHUD` in
/// the app's defaults (`com.jarvis.assistant`). On until the user switches it off.
@MainActor
@Observable
public final class ShowHUDSetting {
    public static let defaultsKey = "showHUD"
    public static let menuTitle = "Show HUD"

    public var isOn: Bool {
        didSet { defaults.set(isOn, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = FileLearningConsent.appDefaults) {
        self.defaults = defaults
        isOn = defaults.object(forKey: Self.defaultsKey) == nil ? true : defaults.bool(forKey: Self.defaultsKey)
    }
}
