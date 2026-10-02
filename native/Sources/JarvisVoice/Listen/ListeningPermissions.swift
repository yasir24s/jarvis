import AVFoundation
import Foundation
import Speech

/// One permission as macOS reports it.
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// The user has not been asked yet: asking shows the prompt.
    case notDetermined
}

/// The two permissions push-to-talk needs, behind a protocol so tests never touch TCC.
public protocol PermissionAsking: Sendable {
    func microphone() -> PermissionStatus
    /// Shows the microphone prompt (the Info.plist's NSMicrophoneUsageDescription).
    func requestMicrophone() async -> Bool
    func speechRecognition() -> PermissionStatus
    /// Shows the speech-recognition prompt (NSSpeechRecognitionUsageDescription).
    func requestSpeechRecognition() async -> Bool
}

/// What push-to-talk may do.
public enum ListeningPermission: Sendable, Equatable {
    case granted
    case microphoneDenied
    case speechRecognitionDenied
}

/// M9a part 5: the microphone first, as Python asked for it (`request_microphone_access`,
/// J:5251-5282, through AVCaptureDevice), then speech recognition. Each prompt shows only while
/// the user has not decided; a refusal is reported, never asked again here.
public enum ListeningPermissions {
    public static func ask(_ system: any PermissionAsking) async -> ListeningPermission {
        switch system.microphone() {
        case .granted:
            break
        case .denied:
            return .microphoneDenied
        case .notDetermined:
            guard await system.requestMicrophone() else { return .microphoneDenied }
        }
        switch system.speechRecognition() {
        case .granted:
            return .granted
        case .denied:
            return .speechRecognitionDenied
        case .notDetermined:
            return await system.requestSpeechRecognition() ? .granted : .speechRecognitionDenied
        }
    }
}

/// The real permissions: AVCaptureDevice for the microphone, SFSpeechRecognizer for speech
/// recognition. Restricted (by a profile) counts as denied.
public struct SystemPermissions: PermissionAsking {
    public init() {}

    public func microphone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func speechRecognition() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }
}
