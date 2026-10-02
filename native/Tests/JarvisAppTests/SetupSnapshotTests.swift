import Foundation
@testable import JarvisApp
import JarvisChat
import JarvisVoice
import Testing

/// M10 part 4: the setup window's steps as PNGs, for checking the look by eye. Runs only with
/// UI1_SNAPSHOT_DIR set (UISnapshot); a plain `swift test` skips it and writes nothing.
@MainActor
@Suite("M10 setup window snapshots", .serialized, .enabled(if: UISnapshot.enabled))
struct SetupSnapshotTests {
    typealias Rig = SetupModelTests

    func shoot(_ model: SetupModel, _ name: String) async throws {
        let url = try await UISnapshot.write(SetupView(model: model, startsOnAppear: false), size: SetupView.size,
                                             name: "m10-part4-\(name)")
        print("M10 setup snapshot \(url.path)")
    }

    @Test func everyStep() async throws {
        let recorder = Rig.FakeRecorder([.hold(level: 0.72)])
        try await Rig.withRig(permissions: Rig.FakePermissions(mic: .notDetermined, speech: .notDetermined),
                              recorder: recorder, voiceprint: Rig.FakeVoiceprint(enrolled: true), enrolled: true) { rig in
            let model = rig.model
            try await shoot(model, "1-welcome")
            model.next()
            try await shoot(model, "2-permissions")
            model.askPermissions()
            try await Rig.settle(model) { model.access == .granted }
            try await shoot(model, "2a-permissions-granted")
            model.next()
            try await shoot(model, "3a-voice-existing")
            model.recordAgain()
            try await shoot(model, "3b-voice-ready")
            model.recordTake()
            try await Rig.settle(model) { model.level == 0.72 }
            try await shoot(model, "3c-voice-recording")
            model.cancelRecording()
            model.keepVoiceprint()
            try await shoot(model, "3d-voice-kept")
            model.next()
            try await shoot(model, "4-files")
            model.next()
            try await shoot(model, "5-speech")
            model.next()
            try await shoot(model, "6-done")
        }
    }

    @Test func theRetryAndTheDeniedMicrophone() async throws {
        let voiceprint = Rig.FakeVoiceprint(qualities: [.tooLittleVoice(voicedSamples: 6720)])
        try await Rig.withRig(permissions: Rig.FakePermissions(mic: .denied), recorder: Rig.FakeRecorder([.take([1])]),
                              voiceprint: voiceprint) { rig in
            let model = rig.model
            model.next()
            try await shoot(model, "2b-permissions-mic-denied")
            model.next()
            try await shoot(model, "3e-voice-mic-off")
        }
        try await Rig.withRig(recorder: Rig.FakeRecorder([.take([1])]), voiceprint: voiceprint) { rig in
            let model = rig.model
            model.next(); model.next()
            model.recordTake()
            try await Rig.settle(model) { if case .retry = model.voice { true } else { false } }
            try await shoot(model, "3f-voice-retry")
        }
    }
}
