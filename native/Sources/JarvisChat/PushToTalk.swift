import Foundation
import Observation

/// Whether listening may start: both the microphone and speech recognition are needed.
public enum ListeningAccess: Sendable, Equatable {
    case granted
    case microphoneDenied
    case speechRecognitionDenied
}

/// What one push-to-talk utterance came to, after the confidence guard and the corrections.
public enum HeardOutcome: Sendable, Equatable {
    case text(String)
    /// Nothing to send: no speech, or every result under the confidence floor (`dropped` of them).
    case nothing(dropped: Int)
    /// The recogniser could not run (no model, or it failed); the log says why.
    case unavailable
    case cancelled
}

/// The microphone and the transcriber, as push-to-talk uses them: the app's implementation runs
/// JarvisVoice's MicCapture and Transcriber; tests use a fake, so they open no microphone.
public protocol VoiceListening: Sendable {
    /// Asks for what listening needs, prompting the first time.
    func access() async -> ListeningAccess
    /// Opens the microphone and starts transcribing. Until `finish` or `cancel`, each frame's
    /// level (0...1) goes to `level` and the live text to `preview`, on any thread.
    func begin(level: @escaping @Sendable (Double) -> Void,
               preview: @escaping @Sendable (String) -> Void) async throws
    /// Closes the microphone and returns what was heard.
    func finish() async -> HeardOutcome
    /// Closes the microphone and drops what was heard.
    func cancel() async
}

/// M9a push-to-talk: the composer's mic button (hold to talk, or click to toggle), holding
/// ⌥Space in the chat window, and the global ⌃⌥J (a toggle). Starting stops his speech and any
/// reply being written (`onStart`, UI1's stop). While it listens the composer shows the live text
/// and the HUD listens, its bars following the microphone. When the user lets go, the final text
/// goes to `onHeard`; nothing heard sends nothing and the composer says so for a few seconds.
@MainActor
@Observable
public final class PushToTalkModel {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Asking for access and opening the microphone.
        case starting
        case listening
        /// Let go: the transcriber is finishing.
        case finishing
    }

    /// A press of the mic button shorter than this is a click: it toggles listening on, and the
    /// next click ends it. Held longer, letting go ends it.
    nonisolated public static let holdThreshold: Duration = .milliseconds(350)
    /// The longest one utterance listens, so a toggle left on or a key-up that never came
    /// cannot keep the microphone open. CONV_TIMEOUT (J:73), the longest Python waited on the mic.
    nonisolated public static let longest: Duration = .seconds(30)
    /// How long a notice stays in the composer.
    nonisolated public static let noticeTime: Duration = .seconds(4)

    nonisolated public static let nothingHeard = "I didn't hear anything, so nothing was sent."
    nonisolated public static let notClear = "I couldn't make that out clearly, so nothing was sent."
    nonisolated public static let unavailableNotice = "Speech recognition isn't available, so nothing was sent. The log says why."
    nonisolated public static let cannotStart = "The microphone would not start, so nothing was sent."
    nonisolated public static let microphoneOff = "Microphone access is off, so I can't listen."
    nonisolated public static let speechOff = "Speech recognition is off, so I can't listen."

    /// The chat's explanation the first time access is found denied (once per launch for each).
    nonisolated public static func explanation(_ access: ListeningAccess) -> String? {
        switch access {
        case .granted:
            nil
        case .microphoneDenied:
            "Push-to-talk needs the microphone, and access to it is off for JARVIS. To allow it, open "
                + "System Settings, choose Privacy & Security, then Microphone, and switch JARVIS on. "
                + "Then press the mic button again."
        case .speechRecognitionDenied:
            "Push-to-talk needs speech recognition, and it is off for JARVIS. To allow it, open "
                + "System Settings, choose Privacy & Security, then Speech Recognition, and switch "
                + "JARVIS on. Then press the mic button again. What you say is transcribed on this Mac."
        }
    }

    public private(set) var phase: Phase = .idle
    /// The live text while listening; empty otherwise.
    public private(set) var preview = ""
    /// The microphone's level, 0...1, falling back gently between frames.
    public private(set) var level = 0.0
    /// A short line for the composer: why nothing was sent, or that access is off.
    public private(set) var notice: String?
    /// The microphone is open, or opening: the mic button shows it on.
    public var isOn: Bool { phase == .starting || phase == .listening }

    /// UI1's stop: his speech and any reply being written stop when listening starts.
    @ObservationIgnored public var onStart: (() -> Void)?
    /// The microphone opened (the HUD listens).
    @ObservationIgnored public var onListening: (() -> Void)?
    /// Each level change (the HUD's bars).
    @ObservationIgnored public var onLevel: ((Double) -> Void)?
    /// Listening is over. True when text went to `onHeard` (a turn follows).
    @ObservationIgnored public var onEnded: ((Bool) -> Void)?
    /// The final text.
    @ObservationIgnored public var onHeard: ((String) -> Void)?
    /// Access was found denied for the first time this launch: the chat explains.
    @ObservationIgnored public var onDenied: ((ListeningAccess) -> Void)?

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private enum Mode { case none, press, toggle, hold }
    @ObservationIgnored private var listener: (any VoiceListening)?
    @ObservationIgnored private var mode = Mode.none
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?
    @ObservationIgnored private var endWhenOpen = false
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var limit: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var explained: Set<ListeningAccess> = []
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let now: () -> ContinuousClock.Instant

    /// - sleep: waits out the notice and the longest listen; tests pass their own.
    /// - now: times a press of the mic button; tests pass their own.
    public init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.sleep = sleep
        self.now = now
    }

    /// Called once the voice is ready; until then the mic button is off.
    public func connect(_ listener: any VoiceListening) {
        self.listener = listener
    }

    public var isConnected: Bool { listener != nil }

    // MARK: - Inputs

    /// The mic button went down: starts listening, or ends a session a click turned on.
    public func buttonDown() {
        if phase == .idle {
            mode = .press
            pressedAt = now()
            start()
        } else if mode == .toggle {
            mode = .none
            end()
        }
    }

    /// The mic button came up: after a hold, listening ends; after a click, it stays on.
    public func buttonUp() {
        guard mode == .press, let pressedAt else { return }
        self.pressedAt = nil
        if now() - pressedAt >= Self.holdThreshold {
            mode = .none
            end()
        } else {
            mode = .toggle
        }
    }

    /// ⌥Space went down in the chat window (not a key repeat).
    public func holdBegan() {
        if phase == .idle {
            mode = .hold
            start()
        } else if mode == .toggle {
            mode = .none
            end()
        }
    }

    /// ⌥Space came up, or the window stopped being key while it was held.
    public func holdEnded() {
        guard mode == .hold else { return }
        mode = .none
        end()
    }

    /// ⌃⌥J: on, or off.
    public func toggle() {
        if phase == .idle {
            mode = .toggle
            start()
        } else {
            mode = .none
            end()
        }
    }

    /// Drops the utterance, if any: nothing is sent.
    public func cancel() {
        guard phase != .idle else { return }
        mode = .none
        session += 1
        limit?.cancel()
        let listener = self.listener
        phase = .idle
        preview = ""
        setLevel(0)
        onEnded?(false)
        Task { await listener?.cancel() }
    }

    // MARK: - The session

    private func start() {
        guard let listener else { return }
        session += 1
        let mine = session
        phase = .starting
        preview = ""
        endWhenOpen = false
        clearNotice()
        onStart?()
        Task {
            let access = await listener.access()
            guard mine == self.session else { return }
            guard access == .granted else {
                self.denied(access)
                return
            }
            do {
                try await listener.begin(level: { v in Task { @MainActor in self.heardLevel(v, session: mine) } },
                                         preview: { t in Task { @MainActor in self.heardPreview(t, session: mine) } })
            } catch {
                guard mine == self.session else { return }
                self.over(notice: Self.cannotStart, sent: false)
                return
            }
            guard mine == self.session else {
                await listener.cancel()
                return
            }
            self.phase = .listening
            self.onListening?()
            self.limit = Task { [sleep] in
                do { try await sleep(Self.longest) } catch { return }
                guard !Task.isCancelled, mine == self.session, self.phase == .listening else { return }
                self.mode = .none
                self.end()
            }
            if self.endWhenOpen { self.end() }
        }
    }

    /// Let go: ends listening once the microphone is open.
    private func end() {
        switch phase {
        case .starting:
            endWhenOpen = true
        case .listening:
            finish()
        case .idle, .finishing:
            break
        }
    }

    private func finish() {
        guard let listener else { return }
        let mine = session
        phase = .finishing
        limit?.cancel()
        limit = nil
        setLevel(0)
        Task {
            let outcome = await listener.finish()
            guard mine == self.session else { return }
            switch outcome {
            case .text(let text):
                self.over(notice: nil, sent: true)
                self.onHeard?(text)
            case .nothing(let dropped):
                self.over(notice: dropped > 0 ? Self.notClear : Self.nothingHeard, sent: false)
            case .unavailable:
                self.over(notice: Self.unavailableNotice, sent: false)
            case .cancelled:
                self.over(notice: nil, sent: false)
            }
        }
    }

    private func denied(_ access: ListeningAccess) {
        over(notice: access == .microphoneDenied ? Self.microphoneOff : Self.speechOff, sent: false)
        if explained.insert(access).inserted { onDenied?(access) }
    }

    private func over(notice: String?, sent: Bool) {
        phase = .idle
        mode = .none
        preview = ""
        setLevel(0)
        if let notice { show(notice) }
        onEnded?(sent)
    }

    private func heardLevel(_ value: Double, session mine: Int) {
        guard mine == session, phase == .listening else { return }
        // Up at once, down by a quarter a frame, so the bars do not flicker between words.
        setLevel(max(min(1, max(0, value)), level * 0.75))
    }

    private func heardPreview(_ text: String, session mine: Int) {
        guard mine == session, phase == .listening || phase == .finishing else { return }
        preview = text
    }

    private func setLevel(_ value: Double) {
        guard value != level else { return }
        level = value
        onLevel?(value)
    }

    private func show(_ text: String) {
        noticeTimer?.cancel()
        notice = text
        let sleep = self.sleep
        noticeTimer = Task {
            do { try await sleep(Self.noticeTime) } catch { return }
            guard !Task.isCancelled, self.notice == text else { return }
            self.notice = nil
        }
    }

    private func clearNotice() {
        noticeTimer?.cancel()
        noticeTimer = nil
        notice = nil
    }
}
