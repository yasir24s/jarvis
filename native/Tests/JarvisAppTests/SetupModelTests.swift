import Foundation
@testable import JarvisApp
import JarvisChat
import JarvisVoice
import Synchronization
import Testing

/// M10 part 4: the setup window's steps, driven through SetupModel with fakes: TCC, the takes,
/// the voiceprint and the voice. No test opens the microphone, loads ORT or touches the real
/// defaults; each has a defaults suite of its own.
@MainActor
@Suite("M10 setup window (model)", .serialized)
struct SetupModelTests {
    final class FakePermissions: PermissionAsking, @unchecked Sendable {
        var mic: PermissionStatus
        var speech: PermissionStatus
        var grantMic: Bool
        var grantSpeech: Bool
        init(mic: PermissionStatus = .granted, speech: PermissionStatus = .granted, grantMic: Bool = true, grantSpeech: Bool = true) {
            (self.mic, self.speech, self.grantMic, self.grantSpeech) = (mic, speech, grantMic, grantSpeech)
        }
        func microphone() -> PermissionStatus { mic }
        func requestMicrophone() async -> Bool {
            mic = grantMic ? .granted : .denied
            return grantMic
        }
        func speechRecognition() -> PermissionStatus { speech }
        func requestSpeechRecognition() async -> Bool {
            speech = grantSpeech ? .granted : .denied
            return grantSpeech
        }
    }

    /// Hands out takes in order; a take may also be an error, or wait to be released.
    final class FakeRecorder: TakeRecording, @unchecked Sendable {
        enum Next { case take([Int16]), fail(any Error), hold(level: Double) }
        private let queue: Mutex<[Next]>
        private let held = Mutex<CheckedContinuation<[Int16], any Error>?>(nil)
        init(_ next: [Next]) { queue = Mutex(next) }

        func record(level: @escaping @Sendable (Double) -> Void) async throws -> [Int16] {
            let next = queue.withLock { $0.isEmpty ? Next.take([1]) : $0.removeFirst() }
            switch next {
            case .take(let samples):
                level(0.5)
                return samples
            case .fail(let error):
                throw error
            case .hold(let value):
                level(value)
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { c in held.withLock { $0 = c } }
                } onCancel: {
                    held.withLock { $0?.resume(throwing: CancellationError()); $0 = nil }
                }
            }
        }
    }

    actor FakeVoiceprint: VoiceEnrolling {
        var enrolled: Bool
        var qualities: [TakeQuality]
        var outcome: Voiceprint.EnrollOutcome
        private(set) var enrolledWith: [[Int16]] = []
        init(enrolled: Bool = false, qualities: [TakeQuality] = [], outcome: Voiceprint.EnrollOutcome = .saved(takes: 3)) {
            (self.enrolled, self.qualities, self.outcome) = (enrolled, qualities, outcome)
        }
        var isEnrolled: Bool { enrolled }
        func quality(of take: [Int16]) async throws -> TakeQuality {
            qualities.isEmpty ? .good(voicedSamples: 30000) : qualities.removeFirst()
        }
        func enroll(takes: [[Int16]]) async throws -> Voiceprint.EnrollOutcome {
            enrolledWith = takes
            enrolled = true
            return outcome
        }
    }

    struct Rig {
        let model: SetupModel
        let defaults: UserDefaults
        let spoken: Box<[String]>
        let closed: Box<Int>
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func withRig(permissions: FakePermissions = FakePermissions(), recorder: FakeRecorder = FakeRecorder([]),
                        voiceprint: FakeVoiceprint? = FakeVoiceprint(), enrolled: Bool = false,
                        _ body: @MainActor (Rig) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let spoken = Box<[String]>([]), closed = Box(0)
        let status = VoiceprintStatus(defaults: defaults)
        let model = SetupModel(completion: SetupCompletion(defaults: defaults), status: status,
                               fileLearning: FileLearningConsent(defaults: defaults),
                               speakReplies: SpeakRepliesToggle(defaults: defaults), permissions: permissions,
                               recorder: recorder, speak: { spoken.value.append($0) }, offerDefaults: defaults)
        model.close = { closed.value += 1 }
        model.start()
        if let voiceprint {
            status.loaded(enrolled: enrolled)
            model.attach(voiceprint)
        }
        try await body(Rig(model: model, defaults: defaults, spoken: spoken, closed: closed))
    }

    /// Waits for the model's work (a take, a check, a save) to settle.
    static func settle(_ model: SetupModel, until done: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    static func go(_ model: SetupModel, to step: SetupModel.Step) {
        while model.step < step, model.canContinue { model.next() }
    }

    // MARK: launch and steps

    @Test func opensAtLaunchOnlyWhileSetupIsNotCompleted() throws {
        let name = "jarvis-tests-setup-launch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SetupCompletion.opensAtLaunch(arguments: ["JARVIS"], defaults: defaults))
        #expect(!SetupCompletion.opensAtLaunch(arguments: ["JARVIS", "--background"], defaults: defaults))
        defaults.set(false, forKey: SetupCompletion.defaultsKey)      // present, whatever its value
        #expect(!SetupCompletion.opensAtLaunch(arguments: ["JARVIS"], defaults: defaults))
    }

    @Test func theWelcomeIsSpokenAndDoneCompletesSetup() async throws {
        try await Self.withRig { rig in
            let model = rig.model
            #expect(rig.spoken.value == [SetupModel.Lines.welcome])
            #expect(model.step == .welcome && !model.canGoBack)
            model.next()
            #expect(model.step == .permissions && model.canGoBack)
            model.next()
            #expect(model.step == .voice && !model.canContinue, "the voice step waits for an answer")
            model.skipVoice()
            #expect(model.voice == .skipped && model.canContinue)
            Self.go(model, to: .done)
            #expect(model.step == .done && !model.canGoBack && !model.completion.isCompleted)
            model.finish()
            #expect(model.completion.isCompleted && rig.closed.value == 1)
            #expect(rig.defaults.object(forKey: SetupCompletion.defaultsKey) as? Bool == true)
            #expect(!SetupCompletion.opensAtLaunch(arguments: ["JARVIS"], defaults: rig.defaults))
        }
    }

    @Test func theFilesStepAnswersTheChatsFirstRunOffer() async throws {
        try await Self.withRig { rig in
            let model = rig.model
            model.next(); model.next(); model.skipVoice(); model.next()
            #expect(model.step == .files)
            model.fileLearning.isOn = true
            model.next()
            #expect(model.step == .speech)
            #expect(rig.defaults.bool(forKey: FileLearningConsent.offeredKey))
            #expect(rig.defaults.bool(forKey: FileLearningConsent.defaultsKey))
            model.speakReplies.isOn = true
            #expect(rig.defaults.bool(forKey: SpeakRepliesToggle.defaultsKey))
        }
    }

    // MARK: permissions

    @Test(arguments: [(true, true, SetupModel.Access.granted), (false, true, .microphoneDenied), (true, false, .speechRecognitionDenied)])
    func askingForPermissions(grantMic: Bool, grantSpeech: Bool, want: SetupModel.Access) async throws {
        let permissions = FakePermissions(mic: .notDetermined, speech: .notDetermined, grantMic: grantMic, grantSpeech: grantSpeech)
        try await Self.withRig(permissions: permissions) { rig in
            #expect(rig.model.access == .unknown)
            rig.model.askPermissions()
            try await Self.settle(rig.model) { rig.model.access != .asking }
            #expect(rig.model.access == want)
            #expect(rig.model.microphoneAllowed == grantMic)
        }
    }

    @Test func aDeniedMicrophoneIsShownAtOnce() async throws {
        try await Self.withRig(permissions: FakePermissions(mic: .denied)) { rig in
            #expect(rig.model.access == .microphoneDenied && !rig.model.microphoneAllowed)
        }
    }

    // MARK: the voice

    @Test func thePythonBuildsVoiceprintCanBeKept() async throws {
        try await Self.withRig(voiceprint: FakeVoiceprint(enrolled: true), enrolled: true) { rig in
            let model = rig.model
            #expect(model.voice == .existing)
            #expect(model.status.origin == .pythonBuild)
            #expect(model.voiceLine == SetupModel.Lines.existingPython)
            model.keepVoiceprint()
            #expect(model.voice == .kept && model.canContinue)
        }
    }

    @Test func recordingAgainTakesThreePhrasesAndSaves() async throws {
        let takes: [[Int16]] = [[1, 1], [2, 2], [3, 3]]
        let recorder = FakeRecorder(takes.map { .take($0) })
        let voiceprint = FakeVoiceprint(enrolled: true)
        try await Self.withRig(recorder: recorder, voiceprint: voiceprint, enrolled: true) { rig in
            let model = rig.model
            model.recordAgain()
            #expect(model.voice == .ready(take: 0) && model.voiceLine == SetupModel.Lines.intro)
            for take in 0 ..< 3 {
                #expect(model.voice == .ready(take: take))
                model.recordTake()
                try await Self.settle(model) { model.voice != .recording(take: take) && model.voice != .checking(take: take) }
            }
            try await Self.settle(model) { model.voice == .enrolled }
            #expect(model.voice == .enrolled && model.goodTakes == 3)
            #expect(await voiceprint.enrolledWith == takes)
            guard case .recorded = model.status.origin else {
                Issue.record("origin \(String(describing: model.status.origin))")
                return
            }
            #expect(rig.defaults.object(forKey: VoiceprintStatus.recordedKey) is Date)
        }
    }

    @Test func aTakeWithTooLittleVoiceIsRetried() async throws {
        let recorder = FakeRecorder([.take([9]), .take([1]), .take([2]), .take([3])])
        let voiceprint = FakeVoiceprint(qualities: [.tooLittleVoice(voicedSamples: 8000), .good(voicedSamples: 20000),
                                                    .good(voicedSamples: 20000), .good(voicedSamples: 20000)])
        try await Self.withRig(recorder: recorder, voiceprint: voiceprint) { rig in
            let model = rig.model
            Self.go(model, to: .voice)
            #expect(model.step == .voice && model.voice == .ready(take: 0))
            model.recordTake()
            try await Self.settle(model) { if case .retry = model.voice { true } else { false } }
            #expect(model.voice == .retry(take: 0, voicedSeconds: 0.5))
            #expect(model.voiceLine == SetupModel.Lines.retry && !model.canContinue)
            model.recordTake()
            try await Self.settle(model) { model.voice == .ready(take: 1) }
            model.recordTake()
            try await Self.settle(model) { model.voice == .ready(take: 2) }
            model.recordTake()
            try await Self.settle(model) { model.voice == .enrolled }
            #expect(await voiceprint.enrolledWith == [[1], [2], [3]], "the retried take is not kept")
        }
    }

    @Test func aMicrophoneThatFailsEndsTheStep() async throws {
        let recorder = FakeRecorder([.fail(TakeError.microphone(.cannotStart("busy")))])
        try await Self.withRig(recorder: recorder) { rig in
            rig.model.recordTake()
            try await Self.settle(rig.model) { if case .failed = rig.model.voice { true } else { false } }
            #expect(rig.model.voice == .failed("the microphone did not open (the microphone would not start (busy))"))
            #expect(rig.model.canContinue)
        }
    }

    @Test func nothingSavedIsAFailure() async throws {
        let voiceprint = FakeVoiceprint(outcome: .nothingCaptured)
        try await Self.withRig(recorder: FakeRecorder([.take([1]), .take([2]), .take([3])]), voiceprint: voiceprint) { rig in
            let model = rig.model
            for take in 0 ..< 3 {
                model.recordTake()
                try await Self.settle(model) { model.voice != .recording(take: take) && model.voice != .checking(take: take) }
            }
            try await Self.settle(model) { if case .failed = model.voice { true } else { false } }
            #expect(model.voice == .failed("no take had enough voice"))
            #expect(!model.status.enrolled)
        }
    }

    @Test func closingTheWindowMidTakeStopsIt() async throws {
        try await Self.withRig(recorder: FakeRecorder([.hold(level: 0.7)])) { rig in
            let model = rig.model
            model.recordTake()
            try await Self.settle(model) { model.level == 0.7 }
            #expect(model.voice == .recording(take: 0) && model.isBusy && !model.canGoBack)
            model.cancelRecording()
            #expect(model.voice == .ready(take: 0) && !model.isBusy)
        }
    }

    @Test func beforeTheStoreIsBuiltTheStepWaits() async throws {
        try await Self.withRig(voiceprint: nil) { rig in
            #expect(rig.model.voice == .waiting && rig.model.voiceLine == SetupModel.Lines.waiting)
            rig.model.recordTake()
            #expect(rig.model.voice == .waiting)
            rig.model.status.loaded(enrolled: false)
            rig.model.attach(FakeVoiceprint())
            #expect(rig.model.voice == .ready(take: 0))
        }
    }
}
