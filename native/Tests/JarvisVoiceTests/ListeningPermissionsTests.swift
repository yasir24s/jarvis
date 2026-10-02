import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// M9a part 5: which prompts push-to-talk shows and what it does with the answers, over a fake
/// system, so no test touches TCC or shows a prompt.
@Suite("M9 listening permissions")
struct ListeningPermissionsTests {
    final class FakeSystem: PermissionAsking, @unchecked Sendable {
        let mic: PermissionStatus
        let speech: PermissionStatus
        let micAnswer: Bool
        let speechAnswer: Bool
        private let asked = Mutex<[String]>([])

        init(mic: PermissionStatus, speech: PermissionStatus, micAnswer: Bool = true, speechAnswer: Bool = true) {
            self.mic = mic
            self.speech = speech
            self.micAnswer = micAnswer
            self.speechAnswer = speechAnswer
        }

        var prompts: [String] { asked.withLock { $0 } }
        func microphone() -> PermissionStatus { mic }
        func requestMicrophone() async -> Bool {
            asked.withLock { $0.append("microphone") }
            return micAnswer
        }
        func speechRecognition() -> PermissionStatus { speech }
        func requestSpeechRecognition() async -> Bool {
            asked.withLock { $0.append("speech") }
            return speechAnswer
        }
    }

    @Test("both already allowed: no prompt")
    func allowed() async {
        let s = FakeSystem(mic: .granted, speech: .granted)
        #expect(await ListeningPermissions.ask(s) == .granted)
        #expect(s.prompts.isEmpty)
    }

    @Test("the first use asks for the microphone, then speech recognition")
    func firstUse() async {
        let s = FakeSystem(mic: .notDetermined, speech: .notDetermined)
        #expect(await ListeningPermissions.ask(s) == .granted)
        #expect(s.prompts == ["microphone", "speech"])
    }

    @Test("a refused or denied microphone stops there, without asking for speech recognition")
    func microphoneRefused() async {
        let refused = FakeSystem(mic: .notDetermined, speech: .notDetermined, micAnswer: false)
        #expect(await ListeningPermissions.ask(refused) == .microphoneDenied)
        #expect(refused.prompts == ["microphone"])
        let denied = FakeSystem(mic: .denied, speech: .granted)
        #expect(await ListeningPermissions.ask(denied) == .microphoneDenied)
        #expect(denied.prompts.isEmpty)
    }

    @Test("speech recognition refused, or denied before, is reported as such")
    func speechRefused() async {
        let refused = FakeSystem(mic: .granted, speech: .notDetermined, speechAnswer: false)
        #expect(await ListeningPermissions.ask(refused) == .speechRecognitionDenied)
        #expect(refused.prompts == ["speech"])
        let denied = FakeSystem(mic: .granted, speech: .denied)
        #expect(await ListeningPermissions.ask(denied) == .speechRecognitionDenied)
        #expect(denied.prompts.isEmpty)
    }

    @Test("the prompts' texts are the ones already in Info.plist")
    func usageStrings() throws {
        let plist = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect((info["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
        #expect((info["NSSpeechRecognitionUsageDescription"] as? String)?.isEmpty == false)
    }
}
