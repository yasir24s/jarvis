import Foundation
import JarvisCore
import UserNotifications

/// Stop Speaking sticks: an urgent line (a timer, alarm, reminder or meeting alert) that comes
/// while speaking is off is shown as a macOS notification, with the system's default sound and no
/// other. Permission is asked the first time one is needed. Without it, or outside the app bundle,
/// `display notification` shows it instead, as the notify tool falls back.
struct MutedAlertNotifier: Sendable {
    static let title = "JARVIS"

    func post(_ line: String) async {
        if await postThroughCenter(line) { return }
        let script = "display notification \"\(Self.escape(line))\" with title \"\(Self.title)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            JarvisLog.log("voice: a muted alert could not be shown (\(error))", category: .voice)
        }
    }

    private func postThroughCenter(_ line: String) async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = line
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    /// For an AppleScript string literal.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
