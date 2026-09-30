import Foundation
import JarvisCore

/// The app's research path (plan: M01b §3.5, T10; D-36, D-37). The app makes one UsageStore,
/// holding the InstanceLock lease, and hands it to everything that bumps: CoreState, the brain
/// and the chat's counters. `scheduler` builds the ResearchLogger over that same instance and
/// the ResearchScheduler over both. UsageStore's Mutex makes usage.json's read-modify-write
/// atomic only within one instance, so there is never a second one.
public enum AppResearch {
    /// The local backend's id: the text inside `LocalBrain.backendName`'s parentheses
    /// ("apple-foundation-model"), which its `backend_local_…` counter is made from.
    public static let localModel: String = {
        let name = LocalBrain.backendName
        guard let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close else {
            return name
        }
        return String(name[name.index(after: open)..<close])
    }()

    /// What a snapshot row records about this run: the build facts from Info.plist, when the
    /// process started (unix time), and the M3 configuration.
    public static func runtime(processStarted: Double, claudeEnabled: Bool) -> @Sendable () -> RuntimeInfo {
        { RuntimeInfo.current(processStarted: processStarted, claudeEnabled: claudeEnabled, localModel: localModel) }
    }

    /// The ResearchLogger over `store` and the ResearchScheduler over both; the caller starts
    /// it. `store` must be the app's one UsageStore over `paths.usage`, and `core` the CoreState
    /// that bumps through it (D-37: snapshots count its cached corrections and history).
    @MainActor
    public static func scheduler(store: UsageStore, paths: ResearchPaths, here: URL, core: CoreState,
                                 runtime: @escaping @Sendable () -> RuntimeInfo,
                                 git: @escaping GitProbe.Runner = GitProbe.run,
                                 host: @escaping @Sendable () -> HostSample = { HostSample.current() },
                                 log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .research) })
        -> ResearchScheduler {
        // `historyTurns` is only the fallback for a snapshot taken without CoreState's counts.
        // The scheduler hands every snapshot those counts (D-37), and they win.
        let sources = FileSnapshotSources(here: here, historyTurns: { 0 })
        let logger = ResearchLogger(paths: paths, clock: ResearchClock(), sources: sources, runtime: runtime,
                                    store: store, git: git, host: host, log: log)
        return ResearchScheduler(store: store, logger: logger, build: runtime().build, core: core, log: log)
    }
}
