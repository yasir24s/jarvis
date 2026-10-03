@preconcurrency import EventKit
import Foundation

/// PR2: Apple Reminders, where Python's `_create_reminder` put every reminder (through
/// AppleScript) so it reached the iPhone. Tests inject a fake.
protocol RemindersStoring: Sendable {
    /// Saves a reminder titled `title` in the default list, alerting at `due` when given.
    /// Nil when JARVIS has no access to Reminders, false when EventKit refused the save.
    func add(title: String, due: Date?) async -> Bool?
}

/// No Reminders: what a platform has until the app's live one, so no test reaches EventKit.
struct NoReminders: RemindersStoring {
    func add(title: String, due: Date?) async -> Bool? { nil }
}

/// One `EKEventStore` for reminders, asking for full access the first time
/// (NSRemindersFullAccessUsageDescription) and waiting at most 12 seconds, as LiveCalendar does.
actor LiveReminders: RemindersStoring {
    static let shared = LiveReminders()
    private let store = EKEventStore()

    private func authorized() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .restricted, .denied: return false
        default: break
        }
        let store = self.store
        let granted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await store.requestFullAccessToReminders()) ?? false }
            group.addTask { try? await Task.sleep(for: .seconds(12)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return granted || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func add(title: String, due: Date?) async -> Bool? {
        guard await authorized() else { return nil }
        guard let list = store.defaultCalendarForNewReminders() else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            // Python's `remind me date`: the alert, and the due date Reminders shows.
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .timeZone], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }
}
