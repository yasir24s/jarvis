import AppKit
import Contacts
import EventKit
import JarvisChat
import JarvisCore
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Batch C part 4: the "What JARVIS Learns From" window, in the J.A.R.V.I.S. theme. An AppKit
/// window like the Memory window, opened from both menus' "Learning Sources…".
@MainActor
final class LearningSourcesWindowController {
    static let size = CGSize(width: 720, height: 640)
    private var window: NSWindow?
    let sources: LearningSources
    let chooseFolders: () -> Void

    init(sources: LearningSources, chooseFolders: @escaping () -> Void) {
        self.sources = sources
        self.chooseFolders = chooseFolders
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = LearningSources.windowTitle
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: LearningSourcesView(sources: sources, chooseFolders: chooseFolders))
            w.setContentSize(Self.size)
            JarvisTheme.style(w)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct LearningSourcesView: View {
    @Bindable var sources: LearningSources
    let chooseFolders: () -> Void
    @State private var website = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WHAT JARVIS LEARNS FROM").font(JarvisTheme.label).tracking(JarvisTheme.labelTracking)
                .foregroundStyle(JarvisTheme.cyan.color).padding(.horizontal, 18).padding(.vertical, 12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Every source is off until you switch it on, and asks for its macOS permission the first time.")
                        .font(JarvisTheme.small).foregroundStyle(JarvisTheme.muted.color)
                    ForEach(LearningSourceInfo.all, id: \.id) { info in
                        SourceRow(sources: sources, info: info, chooseFolders: chooseFolders)
                    }
                    Hairline()
                    added
                }
                .padding(16)
            }
            Hairline()
            Text(sources.status.isEmpty ? " " : sources.status).font(JarvisTheme.small)
                .foregroundStyle(JarvisTheme.muted.color).padding(.horizontal, 18).padding(.vertical, 8)
        }
        .foregroundStyle(JarvisTheme.ice.color)
        .font(JarvisTheme.body)
        .tint(JarvisTheme.cyan.color)
        .background(JarvisTheme.navy.color)
        .preferredColorScheme(.dark)
    }

    private var added: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADDED SOURCES").font(JarvisTheme.label).tracking(JarvisTheme.labelTracking).foregroundStyle(JarvisTheme.cyan.color)
            Text("An added app is learned from by its use only: when and how long it is in front. JARVIS never reads its contents, keystrokes or screen.")
                .font(JarvisTheme.small).foregroundStyle(JarvisTheme.muted.color)
            ForEach(sources.custom) { s in
                HStack {
                    Toggle(isOn: Binding(get: { s.enabled }, set: { sources.setCustom(s.id, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text(Self.describe(s)).font(JarvisTheme.small).foregroundStyle(JarvisTheme.muted.color)
                        }
                    }
                    Spacer()
                    Button("Remove and Forget") { sources.remove(s.id) }.buttonStyle(SetupButtonStyle(kind: .quiet))
                }
            }
            HStack(spacing: 8) {
                Button("Add App…") { pickApp(kind: .appUsage) }
                Button("Add App's Files…") { pickApp(kind: .appFiles) }
                Button("Add App's Screen…") { pickApp(kind: .appScreen) }
            }
            .buttonStyle(SetupButtonStyle(kind: .quiet))
            HStack(spacing: 8) {
                TextField("A website to learn from (https://…)", text: $website).textFieldStyle(.roundedBorder)
                Button("Add Website") {
                    guard let url = URL(string: website.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true,
                          let host = url.host() else { return }
                    sources.add(CustomLearningSource(kind: .website, name: host, value: url.absoluteString))
                    website = ""
                }
                .buttonStyle(SetupButtonStyle(kind: .quiet))
            }
        }
    }

    static func describe(_ s: CustomLearningSource) -> String {
        let what = switch s.kind {
        case .appUsage: "When and how long it is in front"
        case .website: "The site, within its own domain (\(s.value))"
        case .appFiles: "Its documents, through file learning"
        case .appScreen: "Its front window's text, only when you ask"
        }
        return what + (s.learnerBuilt ? "" : ". Kept for later: this version does not learn from it yet.")
    }

    private func pickApp(kind: CustomLearningSource.Kind) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
        if kind == .appUsage, let info = Bundle(url: url)?.infoDictionary,
           let start = LearningSources.webAppStartURL(infoPlist: info, manifest: nil) {
            // A Safari web app: its site is the source.
            sources.add(CustomLearningSource(kind: .website, name: name, value: start))
            return
        }
        sources.add(CustomLearningSource(kind: kind, name: name, value: url.path(percentEncoded: false)))
    }
}

private struct SourceRow: View {
    let sources: LearningSources
    let info: LearningSourceInfo
    let chooseFolders: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Toggle(isOn: Binding(get: { sources.isOn(info.id) }, set: { on in Task { await sources.set(info.id, on: on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(info.title)
                            Text(info.onDevice ? "ON THIS MAC" : "MAY USE CLAUDE").font(JarvisTheme.label)
                                .foregroundStyle(info.onDevice ? JarvisTheme.cyan.color : JarvisTheme.gold.color)
                        }
                        Text(info.reads).font(JarvisTheme.small).foregroundStyle(JarvisTheme.muted.color)
                        Text("Permission: \(sources.permission(info.id).rawValue)").font(JarvisTheme.small)
                            .foregroundStyle(JarvisTheme.muted.color)
                        if !info.readerBuilt {
                            Text("Not built yet: the switch is kept and its permission asked; JARVIS learns nothing from it in this version.")
                                .font(JarvisTheme.small).foregroundStyle(JarvisTheme.gold.color)
                        }
                    }
                }
                .disabled(info.id == .safari)
                Spacer()
                if info.id == .mediaLibrary {
                    Button("Choose Folders…") { chooseFolders() }.buttonStyle(SetupButtonStyle(kind: .quiet))
                }
                Button("Forget") { sources.forget(info.id) }.buttonStyle(SetupButtonStyle(kind: .quiet))
                    .help("Forget what you learned from this")
            }
            if info.id == .messages {
                Toggle("Include message text", isOn: Binding(get: { sources.includeMessageText }, set: { sources.includeMessageText = $0 }))
                    .font(JarvisTheme.small).padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The real permissions: EventKit, Contacts and Photos ask through their APIs; the Music library,
/// Notes and Mail ask when first used (Media & Apple Music, Automation); Messages needs Full Disk
/// Access, which only the user can grant in System Settings.
struct LiveSourcePermissions: SourcePermissions {
    func status(_ id: LearningSourceID) -> SourcePermission {
        switch id {
        case .calendar: Self.map(EKEventStore.authorizationStatus(for: .event))
        case .reminders: Self.map(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized, .limited: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .safari: .notNeeded
        default: .onFirstUse
        }
    }

    static func map(_ s: EKAuthorizationStatus) -> SourcePermission {
        switch s {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func request(_ id: LearningSourceID) async -> Bool {
        switch id {
        case .calendar: return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        case .reminders: return (try? await EKEventStore().requestFullAccessToReminders()) ?? false
        case .contacts: return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        case .photos:
            let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return s == .authorized || s == .limited
        default: return true
        }
    }
}

/// Batch C part 4: the added apps' use. Only the frontmost app's switch and the time between
/// switches is seen (NSWorkspace, no permission); minutes are kept per day and part of the day
/// in memory/app-usage.json, and one fact per app ("about N minutes a day, mostly in the
/// evening") replaces the last once a day.
@MainActor
final class AppUsageTracker {
    private let store: StateStore
    private let memory: MemoryStore
    private let tracked: () -> [CustomLearningSource]
    private var current: (path: String, since: Date)?
    private var log: AppUsageLog
    private var observer: NSObjectProtocol?
    private var lastFactDay = ""

    init(store: StateStore, memory: MemoryStore, tracked: @escaping () -> [CustomLearningSource]) {
        self.store = store
        self.memory = memory
        self.tracked = tracked
        log = store.read(.appUsage).flatMap(AppUsageLog.init(data:)) ?? AppUsageLog()
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path(percentEncoded: false)
            MainActor.assumeIsolated { [weak self] in self?.switched(to: path) }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        switched(to: nil)
        save()
    }

    private func switched(to path: String?) {
        let now = Date()
        if let c = current {
            let hour = Calendar.current.component(.hour, from: c.since)
            log.add(app: c.path, day: Self.day(c.since), hour: hour, seconds: now.timeIntervalSince(c.since))
        }
        let apps = Set(tracked().map(\.value))
        current = path.flatMap { apps.contains($0) ? ($0, now) : nil }
        if Self.day(now) != lastFactDay { writeFacts(now) }
    }

    private func save() {
        log.prune(before: Self.day(Date().addingTimeInterval(-Double(AppUsageLog.keptDays) * 86_400)))
        store.write(log.data, to: .appUsage)
    }

    private func writeFacts(_ now: Date) {
        lastFactDay = Self.day(now)
        save()
        let from = Self.day(now.addingTimeInterval(-7 * 86_400))
        for app in tracked() {
            guard let line = log.fact(app: app.value, name: app.name, from: from) else { continue }
            let source = app.factSource
            let old = Set((memory.loadFacts()?.facts ?? []).filter { $0.source == source }.map(\.id))
            memory.writeFacts(allowingRemovalOf: old) { file in
                file.facts.removeAll { $0.source == source }
                let t = now.timeIntervalSince1970
                file.facts.append(MemoryFact(id: UUID().uuidString.lowercased(), text: line, source: source,
                                             created: t, updated: t, by: .local))
                return true
            }
        }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
