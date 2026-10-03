import Foundation
import JarvisCore
import Observation

/// Batch C part 4: "What JARVIS Learns From". Every source in one list with its switch, what it
/// reads, whether it stays on this Mac, its macOS permission and a forget button. Every source is
/// off until switched on, and asks for its permission on the first switch-on. Facts carry their
/// source (`MemoryFact.source`), so the Memory window can filter by it and "forget" removes
/// exactly that source's facts.
public enum LearningSourceID: String, CaseIterable, Sendable, Codable {
    case files, music, mediaLibrary, tv, calendar, reminders, notes, contacts, mailHeaders, messages, photos, safari
}

public struct LearningSourceInfo: Sendable, Equatable {
    public let id: LearningSourceID
    public let title: String
    public let reads: String
    public let onDevice: Bool
    /// The `MemoryFact.source` prefix of what it writes ("file:" covers "file:<digest>").
    public let factSource: String
    /// False while its reader is not built in this version: the switch and the permission work,
    /// and the window says it learns nothing yet.
    public let readerBuilt: Bool

    public static let all: [LearningSourceInfo] = [
        .init(id: .files, title: "Files", reads: "Your documents in the background (long ones with Claude, redacted).",
              onDevice: false, factSource: "file:", readerBuilt: true),
        .init(id: .music, title: "Music", reads: "Your Music library: artists, albums, play counts, loved songs.",
              onDevice: true, factSource: "music", readerBuilt: true),
        .init(id: .mediaLibrary, title: "Media Library", reads: "Your Music and TV libraries and the media folders you pick, to search and play.",
              onDevice: true, factSource: "media", readerBuilt: true),
        .init(id: .tv, title: "TV", reads: "What the TV app is playing, when you ask.", onDevice: true, factSource: "tv", readerBuilt: false),
        .init(id: .calendar, title: "Calendar", reads: "Your events: titles, times and places.", onDevice: true, factSource: "calendar", readerBuilt: false),
        .init(id: .reminders, title: "Reminders", reads: "Your reminders and their lists.", onDevice: true, factSource: "reminders", readerBuilt: false),
        .init(id: .notes, title: "Notes", reads: "Your notes in the Notes app.", onDevice: true, factSource: "notes", readerBuilt: false),
        .init(id: .contacts, title: "Contacts", reads: "Names, relationships and birthdays in Contacts.", onDevice: true, factSource: "contacts", readerBuilt: false),
        .init(id: .mailHeaders, title: "Mail", reads: "Sender, subject and date only; never message bodies.", onDevice: true, factSource: "mail", readerBuilt: false),
        .init(id: .messages, title: "Messages", reads: "Who and when; message text only if you tick it below.", onDevice: true, factSource: "messages", readerBuilt: false),
        .init(id: .photos, title: "Photos", reads: "Places, dates and the people names Photos has already assigned.", onDevice: true, factSource: "photos", readerBuilt: false),
        .init(id: .safari, title: "Safari", reads: "Arrives with batch D.", onDevice: true, factSource: "safari", readerBuilt: false),
    ]

    public static func info(_ id: LearningSourceID) -> LearningSourceInfo { all.first { $0.id == id }! }
}

/// A source the user added: an app whose use is learned (when and how long it is in front,
/// never its contents), a website or web app, an app's files, or an app's screen on request.
public struct CustomLearningSource: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case appUsage       // "Add App…": when and how long it is in front
        case website        // a URL or a Safari web app's start URL
        case appFiles       // the files of a notes or document app
        case appScreen      // its front window's text, on request only (Accessibility)
    }
    public var id: String { "\(kind.rawValue):\(value)" }
    public var kind: Kind
    public var name: String
    /// The bundle path, URL or folder.
    public var value: String
    public var enabled: Bool

    public init(kind: Kind, name: String, value: String, enabled: Bool = true) {
        self.kind = kind
        self.name = name
        self.value = value
        self.enabled = enabled
    }

    /// Its facts' `MemoryFact.source`.
    public var factSource: String { "\(kind.rawValue):\(value)" }

    /// Whether this version learns from it yet (app usage only; the others are kept for later).
    public var learnerBuilt: Bool { kind == .appUsage }
}

/// A source's macOS permission as the window shows it.
public enum SourcePermission: String, Sendable, Equatable {
    case granted = "Allowed"
    case notAsked = "Not asked yet"
    case denied = "Not allowed (System Settings › Privacy & Security)"
    case notNeeded = "No permission needed"
    case onFirstUse = "Asked when first used"
}

/// The platform's permissions, behind a protocol so the window's logic tests headless.
public protocol SourcePermissions: Sendable {
    func status(_ id: LearningSourceID) -> SourcePermission
    /// Asks macOS (shows its prompt when it has not been answered); true when allowed.
    func request(_ id: LearningSourceID) async -> Bool
}

@MainActor
@Observable
public final class LearningSources {
    public static let windowTitle = "What JARVIS Learns From"
    public static let menuTitle = "Learning Sources…"
    static let enabledKey = "learningSources"
    static let customKey = "learningSourcesCustom"
    static let messageTextKey = "learningSourcesMessageText"

    /// The switches of sources without a consent of their own.
    public private(set) var enabled: Set<LearningSourceID>
    public private(set) var custom: [CustomLearningSource]
    public var includeMessageText: Bool { didSet { defaults.set(includeMessageText, forKey: Self.messageTextKey) } }
    public private(set) var status = ""

    @ObservationIgnored let files: FileLearningConsent
    @ObservationIgnored let media: MediaConsent
    @ObservationIgnored let permissions: any SourcePermissions
    @ObservationIgnored let defaults: UserDefaults
    /// Forgets a source's facts (by `MemoryFact.source` prefix) and anything it keeps besides.
    @ObservationIgnored public var forgetter: ((_ factSource: String, _ id: LearningSourceID?) -> Int)?
    /// Told after a switch changes (the app refreshes the media catalogue, for one).
    @ObservationIgnored public var changed: ((LearningSourceID?) -> Void)?

    public init(files: FileLearningConsent, media: MediaConsent, permissions: any SourcePermissions,
                defaults: UserDefaults = FileLearningConsent.appDefaults) {
        self.files = files
        self.media = media
        self.permissions = permissions
        self.defaults = defaults
        enabled = Set((defaults.stringArray(forKey: Self.enabledKey) ?? []).compactMap(LearningSourceID.init(rawValue:)))
        custom = (defaults.data(forKey: Self.customKey)).flatMap { try? JSONDecoder().decode([CustomLearningSource].self, from: $0) } ?? []
        includeMessageText = defaults.bool(forKey: Self.messageTextKey)
    }

    public func isOn(_ id: LearningSourceID) -> Bool {
        switch id {
        case .files: files.isOn
        case .music: media.music
        case .mediaLibrary: media.library
        default: enabled.contains(id)
        }
    }

    public func permission(_ id: LearningSourceID) -> SourcePermission { permissions.status(id) }

    /// Switches a source. Switching on asks for its permission first; refused, it stays off.
    @discardableResult
    public func set(_ id: LearningSourceID, on: Bool) async -> Bool {
        if on, id != .safari {
            guard await permissions.request(id) else {
                status = "\(LearningSourceInfo.info(id).title) stays off: macOS did not allow it."
                return false
            }
        }
        apply(id, on)
        status = "\(LearningSourceInfo.info(id).title) is \(on ? "on" : "off")."
        changed?(id)
        return true
    }

    private func apply(_ id: LearningSourceID, _ on: Bool) {
        switch id {
        case .files: files.isOn = on
        case .music: media.music = on
        case .mediaLibrary: media.library = on
        default:
            if on { enabled.insert(id) } else { enabled.remove(id) }
            defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.enabledKey)
        }
    }

    /// "Forget what you learned from this": its facts go to the forgotten bin. The switch is left
    /// as it is.
    @discardableResult
    public func forget(_ id: LearningSourceID) -> Int {
        let n = forgetter?(LearningSourceInfo.info(id).factSource, id) ?? 0
        status = "Forgot \(n) fact\(n == 1 ? "" : "s") from \(LearningSourceInfo.info(id).title)."
        return n
    }

    // MARK: - Added sources

    public func add(_ source: CustomLearningSource) {
        guard !custom.contains(where: { $0.id == source.id }) else {
            status = "\(source.name) is already listed."
            return
        }
        custom.append(source)
        saveCustom()
        status = "Added \(source.name)."
        changed?(nil)
    }

    public func setCustom(_ id: String, on: Bool) {
        guard let i = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[i].enabled = on
        saveCustom()
        changed?(nil)
    }

    /// Forgets an added source's facts and removes it from the list.
    @discardableResult
    public func remove(_ id: String) -> Int {
        guard let i = custom.firstIndex(where: { $0.id == id }) else { return 0 }
        let s = custom.remove(at: i)
        saveCustom()
        let n = forgetter?(s.factSource, nil) ?? 0
        status = "Removed \(s.name) and forgot \(n) fact\(n == 1 ? "" : "s")."
        changed?(nil)
        return n
    }

    /// The apps whose use is learned, for the usage tracker.
    public var trackedApps: [CustomLearningSource] { custom.filter { $0.kind == .appUsage && $0.enabled } }

    private func saveCustom() {
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
    }

    /// A Safari web app's start URL ("Add to Dock" apps keep it in their Info.plist or manifest).
    public nonisolated static func webAppStartURL(infoPlist: [String: Any]?, manifest: [String: Any]?) -> String? {
        for key in ["Manifest Start URL", "WebAppStartURL", "start_url"] {
            if let s = infoPlist?[key] as? String, s.hasPrefix("http") { return s }
        }
        if let s = manifest?["start_url"] as? String, s.hasPrefix("http") { return s }
        return nil
    }
}

/// Forgetting by source prefix through the store (the bin, the lease and the guard all apply; the
/// user's explicit pick is exempt from the mass-deletion guard, as forget_memory's ids are).
public enum SourceForgetting {
    public static func forget(prefix: String, in memory: MemoryStore) -> Int {
        let outcome = memory.forget(byIDs: true) { file in
            Set(file.facts.indices.filter { matches(file.facts[$0].source, prefix: prefix) })
        }
        if case .moved(let facts) = outcome { return facts.count }
        return 0
    }

    /// "file:" matches every "file:<digest>"; "music" matches "music" exactly or "music:…".
    public static func matches(_ source: String, prefix: String) -> Bool {
        prefix.hasSuffix(":") ? source.hasPrefix(prefix) : (source == prefix || source.hasPrefix(prefix + ":"))
    }
}

/// Batch C part 4: an added app's use, memory/app-usage.json: minutes in front per app, day and
/// part of the day. Only when it is frontmost and for how long; never what it shows.
public struct AppUsageLog: Codable, Sendable, Equatable {
    /// app path → "YYYY-MM-DD" → part of day ("morning", "afternoon", "evening", "night") → seconds.
    public var seconds: [String: [String: [String: Double]]] = [:]
    public static let keptDays = 30

    public init() {}

    public static func part(hour: Int) -> String {
        switch hour {
        case 5..<12: "morning"
        case 12..<18: "afternoon"
        case 18..<23: "evening"
        default: "night"
        }
    }

    public mutating func add(app: String, day: String, hour: Int, seconds s: Double) {
        guard s > 0 else { return }
        seconds[app, default: [:]][day, default: [:]][Self.part(hour: hour), default: 0] += s
    }

    public mutating func prune(before cutoff: String) {
        seconds = seconds.mapValues { $0.filter { $0.key >= cutoff } }.filter { !$0.value.isEmpty }
    }

    /// One fact over the days from `from` on: average minutes a day and the busiest part of day.
    public func fact(app: String, name: String, from: String) -> String? {
        guard let days = seconds[app]?.filter({ $0.key >= from }), !days.isEmpty else { return nil }
        var parts: [String: Double] = [:]
        for (_, p) in days { for (k, v) in p { parts[k, default: 0] += v } }
        let total = parts.values.reduce(0, +)
        let perDay = Int((total / 60 / Double(days.count)).rounded())
        guard perDay > 0, let top = parts.max(by: { $0.value < $1.value })?.key else { return nil }
        return "The user uses \(name) for about \(perDay) minute\(perDay == 1 ? "" : "s") a day, mostly in the \(top)."
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data("{}".utf8) }
    public init?(data: Data) {
        guard let v = try? JSONDecoder().decode(AppUsageLog.self, from: data) else { return nil }
        self = v
    }
}
