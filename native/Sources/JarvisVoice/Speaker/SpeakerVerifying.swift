import Foundation

/// Which of speaker_ok's bars a hands-free clip is held to.
public enum SpeakerCheck: Sendable, Equatable {
    /// A command: speaker_ok(audio), SPEAKER_THRESHOLD (J:5672, 5696).
    case command
    /// A wake clip, too short for a stable embedding: speaker_ok(wake_clip,
    /// threshold=WAKE_SPK_THRESHOLD) (J:5638).
    case wake
}

/// Hands-free listening's one door to speaker verification (M10 for M11's wake word and
/// conversation loop). `Voiceprint` is the app's; it reads both bars from the environment as
/// Python does (`SpeakerThresholds`).
///
/// Two things never come through here. Push-to-talk turns are not gated: the user pressed the
/// button. And a spoken confirmation is never approved by a voice match: it keeps M9a part 6's
/// owner check (Touch ID or the password) even with a voiceprint enrolled, since a synthetic
/// voice of another speaker scored 0.65 against the 0.60 bar here (see `VoiceConfirmation`).
public protocol SpeakerVerifying: Sendable {
    /// speaker_ok: true to accept the clip. Fails open: no voiceprint, the gate off, a clip too
    /// short to judge or an embedding error all accept.
    func speakerOK(_ clip: [Int16], for check: SpeakerCheck) async -> Bool
    /// _barge_in_speaker_match: true only for a clip that matches. Fails closed.
    func matchesForBargeIn(_ clip: [Int16]) async -> Bool
}

extension Voiceprint: SpeakerVerifying {
    public func speakerOK(_ clip: [Int16], for check: SpeakerCheck) async -> Bool {
        await speakerOK(clip, threshold: check == .wake ? thresholds.wake : nil)
    }
}
