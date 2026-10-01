import Foundation
import JarvisCore
import Observation

// Live updates (U1, D-58). build-app.sh leaves a new build in dist/staged/ while JARVIS runs.
// The running app notices it (a watch on the folder, and a 30 s poll), shows "Update Ready" in
// its menus, and swaps over only when nothing is going on: no turn, no speech, no pending
// confirmation, and no typing, sending or voice turn for 10 minutes. "Update Now" skips the 10
// minutes and still waits for the rest. The rule is `UpdateRule.verdict`, a pure function.

/// One build's identity: the version.json that build-app.sh seals inside the bundle
/// (Contents/Resources/version.json) and writes beside the staged bundle.
public struct BuildID: Sendable, Equatable, Codable {
    public var commit: String
    public var dirty: Bool
    /// The build time, ISO 8601 in UTC: two builds of one dirty commit differ only here.
    public var built: String

    public init(commit: String, dirty: Bool, built: String) {
        self.commit = commit
        self.dirty = dirty
        self.built = built
    }

    /// "f5808cd+dirty 2026-10-01T21:30:00Z", for the log and the menus.
    public var label: String { "\(commit)\(dirty ? "+dirty" : "") \(built)" }

    /// The build a version.json describes; nil if it is missing or does not parse.
    public static func read(_ url: URL) -> BuildID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BuildID.self, from: data)
    }

    /// This process's own build, sealed in its bundle; nil when it is not a built bundle.
    public static func running(bundle: Bundle = .main) -> BuildID? {
        read(bundle.bundleURL.appending(path: "Contents/Resources/version.json"))
    }
}

/// The folder a bundle runs from (native/dist) and the build waiting beside it.
public struct UpdateFolders: Sendable, Equatable {
    public static let appName = "JARVIS.app"
    /// The update helper's place in a bundle, written by build-app.sh.
    public static let helperPath = "Contents/Helpers/jarvis-update"

    public let dist: URL

    public init(dist: URL) {
        self.dist = dist
    }

    /// The folders of a bundle that runs as dist/JARVIS.app with its update helper inside;
    /// nil for anything else (an unbundled build, a test runner), which never updates itself.
    public static func of(bundle url: URL) -> UpdateFolders? {
        guard url.lastPathComponent == appName,
              FileManager.default.isExecutableFile(atPath: url.appending(path: helperPath).path(percentEncoded: false))
        else { return nil }
        return UpdateFolders(dist: url.deletingLastPathComponent())
    }

    public var app: URL { dist.appending(path: Self.appName, directoryHint: .isDirectory) }
    public var stagedFolder: URL { dist.appending(path: "staged", directoryHint: .isDirectory) }
    public var stagedApp: URL { stagedFolder.appending(path: Self.appName, directoryHint: .isDirectory) }
    public var stagedVersion: URL { stagedFolder.appending(path: "version.json", directoryHint: .notDirectory) }

    /// The staged build once it is complete: its bundle and its version.json both exist
    /// (build-app.sh writes the version.json last).
    public func staged() -> BuildID? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stagedApp.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return BuildID.read(stagedVersion)
    }
}

/// When a staged build may replace the running one (D-58). Every signal is passed in.
public enum UpdateRule {
    /// No typing, sending or voice turn for this long before a swap that was not asked for.
    public static let quietSeconds: Double = 600

    public struct Signals: Sendable, Equatable {
        /// A turn is running, typed or spoken.
        public var turnInFlight: Bool
        /// A reply is being spoken, or one is queued.
        public var speechActive: Bool
        /// A confirmation is waiting for the user.
        public var confirmationPending: Bool
        /// The latest of: the launch, the last keystroke in the composer, the last send, the
        /// last turn's start or end, and the end of the last spoken reply. By `JarvisClock`.
        public var lastUse: Double

        public init(turnInFlight: Bool, speechActive: Bool, confirmationPending: Bool, lastUse: Double) {
            self.turnInFlight = turnInFlight
            self.speechActive = speechActive
            self.confirmationPending = confirmationPending
            self.lastUse = lastUse
        }
    }

    /// What holds a swap back, in the order the rule checks it.
    public enum Hold: Sendable, Equatable {
        case turnInFlight
        case speaking
        case confirmationPending
        /// In use less than `quietSeconds` ago; this many seconds are left.
        case recentUse(secondsLeft: Double)

        /// For the menu and the log.
        public var reason: String {
            switch self {
            case .turnInFlight: "a reply is in progress"
            case .speaking: "he is speaking"
            case .confirmationPending: "a confirmation is waiting"
            case .recentUse(let left): "in use; \(Int(left.rounded(.up))) s of quiet to go"
            }
        }
    }

    public enum Verdict: Sendable, Equatable {
        case swap
        case wait(Hold)
    }

    /// `.swap` only when no turn runs, nothing is spoken or queued, no confirmation waits, and
    /// (unless `updateNow`) `quietSeconds` have passed since `lastUse`. A clock that went
    /// backwards counts as recent use.
    public static func verdict(_ signals: Signals, now: Double, updateNow: Bool) -> Verdict {
        if signals.turnInFlight { return .wait(.turnInFlight) }
        if signals.speechActive { return .wait(.speaking) }
        if signals.confirmationPending { return .wait(.confirmationPending) }
        if updateNow { return .swap }
        let quiet = now - signals.lastUse
        if quiet >= quietSeconds { return .swap }
        return .wait(.recentUse(secondsLeft: quietSeconds - max(0, quiet)))
    }
}

/// Watches dist/staged/ for a finished build and starts the swap when `UpdateRule` allows it.
/// The menus read `ready` ("Update Ready") and call `updateNow()`. `check()` is one look: the
/// folder watch and the poll both call it, and so can a test, with a `ManualClock`.
@MainActor
@Observable
public final class UpdateWatcher {
    /// How often the folder is looked at when no file-system event comes, and how often the
    /// rule is asked again while a build waits.
    nonisolated public static let pollInterval: Duration = .seconds(30)
    /// How often the rule is asked again once the user has chosen Update Now.
    nonisolated public static let updateNowInterval: Duration = .seconds(1)

    /// The staged build, while one is complete and the swap has not begun.
    public private(set) var ready: BuildID?
    /// The user chose Update Now; the swap waits only for the turn, speech and confirmation.
    public private(set) var updateNowRequested = false
    /// What the swap is waiting for, while a build is ready.
    public private(set) var hold: UpdateRule.Hold?
    /// The swap has begun: no further checks.
    public private(set) var swapping = false

    @ObservationIgnored public let folders: UpdateFolders?
    @ObservationIgnored private let clock: any JarvisClock
    @ObservationIgnored private let log: @Sendable (String) -> Void
    @ObservationIgnored private var signals: (@MainActor () -> UpdateRule.Signals)?
    @ObservationIgnored private var swap: (@MainActor (BuildID) -> Void)?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var lastHold: UpdateRule.Hold?

    /// `folders` nil (not a dist/JARVIS.app bundle) makes a watcher that never sees a build.
    public init(folders: UpdateFolders?, clock: any JarvisClock = SystemClock(),
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0) }) {
        self.folders = folders
        self.clock = clock
        self.log = log
    }

    /// Starts the watch and the poll. `signals` is read at each check; `swap` is called once,
    /// on the main actor, when the rule says so. With no folders this does nothing.
    public func start(signals: @escaping @MainActor () -> UpdateRule.Signals,
                      swap: @escaping @MainActor (BuildID) -> Void,
                      sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        guard folders != nil, poll == nil else { return }
        self.signals = signals
        self.swap = swap
        check()
        poll = Task { @MainActor [weak self] in
            while true {
                let interval = self?.updateNowRequested == true ? Self.updateNowInterval : Self.pollInterval
                do { try await sleep(interval) } catch { return }
                guard let self, !self.swapping else { return }
                self.check()
            }
        }
    }

    /// Stops the watch and the poll (quit, and the swap itself).
    public func stop() {
        poll?.cancel()
        poll = nil
        source?.cancel()
        source = nil
    }

    /// The menus' "Update Now": the 10 minutes are skipped, the rest still holds.
    public func updateNow() {
        guard ready != nil, !swapping else { return }
        if !updateNowRequested {
            updateNowRequested = true
            log("update: Update Now chosen; waiting only for the reply, speech and confirmation")
        }
        check()
    }

    /// One look: is a build staged, and may the swap start?
    public func check() {
        guard !swapping, let folders else { return }
        if source == nil { watchStagedFolder(folders.stagedFolder) }
        guard let build = folders.staged() else {
            if ready != nil { log("update: the staged build is gone") }
            ready = nil
            hold = nil
            lastHold = nil
            updateNowRequested = false
            return
        }
        if ready != build {
            log("update: build \(build.label) is staged")
            ready = build
        }
        guard let signals else { return }
        switch UpdateRule.verdict(signals(), now: clock.now(), updateNow: updateNowRequested) {
        case .swap:
            hold = nil
            swapping = true
            log("update: swapping to \(build.label)\(updateNowRequested ? " (Update Now)" : "")")
            stop()
            swap?(build)
        case .wait(let reason):
            hold = reason
            if !Self.sameKind(reason, lastHold) { log("update: waiting, \(reason.reason)") }
            lastHold = reason
        }
    }

    /// A vnode watch on dist/staged/, which build-app.sh writes into; the poll covers the time
    /// before the folder exists and anything the watch misses.
    private func watchStagedFolder(_ folder: URL) {
        let fd = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .rename, .delete, .link],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                // A deleted or renamed folder is watched again from the next check.
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.source?.cancel()
                    self.source = nil
                }
                self.check()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// The same hold, ignoring how many seconds are left (one log line per kind of wait).
    private static func sameKind(_ a: UpdateRule.Hold, _ b: UpdateRule.Hold?) -> Bool {
        switch (a, b) {
        case (.turnInFlight, .turnInFlight?), (.speaking, .speaking?),
             (.confirmationPending, .confirmationPending?), (.recentUse, .recentUse?): true
        default: false
        }
    }
}
