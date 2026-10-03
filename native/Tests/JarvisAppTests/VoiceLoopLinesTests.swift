import Foundation
@testable import JarvisApp
import JarvisVoice
import Synchronization
import Testing

/// PR2: the voice loop's three lines Python had (`request_microphone_access`, `main`'s missing
/// microphone and its Ctrl-C). No TCC prompt is shown and nothing is spoken: the permissions
/// and the voice are fakes.
@Suite("PR2 voice loop lines", .timeLimit(.minutes(1)))
struct VoiceLoopLinesTests {
    /// The microphone prompt: undecided until the test answers it.
    final class Prompt: PermissionAsking {
        private let state = Mutex<(mic: PermissionStatus, answer: CheckedContinuation<Bool, Never>?, asked: Bool)>(
            (.notDetermined, nil, false))
        let initial: PermissionStatus
        init(_ initial: PermissionStatus) {
            self.initial = initial
            state.withLock { $0.mic = initial }
        }
        var asked: Bool { state.withLock { $0.asked } }
        func microphone() -> PermissionStatus { state.withLock { $0.mic } }
        func requestMicrophone() async -> Bool {
            await withCheckedContinuation { c in state.withLock { $0.answer = c; $0.asked = true } }
        }
        func answer(_ granted: Bool) {
            let c = state.withLock { s -> CheckedContinuation<Bool, Never>? in
                s.mic = granted ? .granted : .denied
                defer { s.answer = nil }
                return s.answer
            }
            c?.resume(returning: granted)
        }
        func speechRecognition() -> PermissionStatus { .granted }
        func requestSpeechRecognition() async -> Bool { true }
    }

    final class Said: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    static func eventually(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aWaitingPromptIsAskedForOnce() async throws {
        let prompt = Prompt(.notDetermined)
        let said = Said()
        let task = Task { await VoiceLoopLines.askPermissions(prompt, wait: .milliseconds(1), say: { said.add($0) }) }
        #expect(await Self.eventually { said.all == [VoiceLoopLines.allowMicrophone] && prompt.asked })
        prompt.answer(true)
        #expect(await task.value == .granted)
        #expect(said.all == ["Please allow microphone access, sir."])
    }

    @Test func aPromptAnsweredAtOnceSaysNothing() async throws {
        let prompt = Prompt(.notDetermined)
        let said = Said()
        let task = Task { await VoiceLoopLines.askPermissions(prompt, wait: .seconds(3600), say: { said.add($0) }) }
        #expect(await Self.eventually { prompt.asked })
        prompt.answer(false)
        #expect(await task.value == .microphoneDenied)
        #expect(said.all.isEmpty)
    }

    @Test(arguments: [PermissionStatus.granted, .denied])
    func aDecidedMicrophoneSaysNothing(_ status: PermissionStatus) async {
        let prompt = Prompt(status)
        let said = Said()
        let result = await VoiceLoopLines.askPermissions(prompt, wait: .milliseconds(1), say: { said.add($0) })
        #expect(result == (status == .granted ? .granted : .microphoneDenied))
        #expect(said.all.isEmpty)
        #expect(!prompt.asked)
    }

    @Test func onlyAMissingInputIsCannotFindAMicrophone() {
        #expect(VoiceLoopLines.line(for: .noInputDevice("0 Hz")) == "I cannot find a microphone, sir.")
        #expect(VoiceLoopLines.line(for: .cannotConvert("x")) == nil)
        #expect(VoiceLoopLines.line(for: .cannotStart("x")) == nil)
    }

    @Test func theOfflineLineIsPythons() {
        #expect(VoiceLoopLines.offline == "Going offline, sir.")
    }
}
