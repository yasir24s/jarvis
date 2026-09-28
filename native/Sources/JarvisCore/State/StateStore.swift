import Foundation
import Synchronization

// The state files Python and native share, read and written byte-identically
// (plan: M01 §2.1 table, §3.5). The store is a faithful "json.load or exception" /
// "json.dump" primitive: per-file defaults and filters live in each *Logic.load.
// It is a synchronous class, not an actor, so CoreState's load → modify → save never
// suspends in the middle (the same critical section Python holds a threading.Lock across).

/// One shared state file, named as in `jarvis.py`.
public enum StateFile: String, CaseIterable, Sendable {
    case knowledge = "knowledge.json"          // KB_FILE           kb_save             indent=1
    case history = "history.json"              // HIST_FILE         _history_save       compact
    case corrections = "corrections.json"      // CORR_FILE         _corrections_save   indent=1
    case profile = "profile.json"              // PROFILE_FILE      profile_save        indent=1
    case personality = "personality.json"      // PERSONALITY_FILE  personality_save    indent=1
    case emotions = "emotions.json"            // EMOTIONS_FILE     _emotions_save      indent=1
    case proactive = "proactive.json"          // PROACTIVE_FILE    proactive_loop      compact
    case alarms = "alarms.json"                // ALARMS_FILE       _alarms_save        compact

    /// The `indent` Python's writer passes to `json.dump` (nil: the compact default).
    public var indent: Int? {
        switch self {
        case .history, .proactive, .alarms: nil
        case .knowledge, .corrections, .profile, .personality, .emotions: 1
        }
    }
}

public enum StateStoreError: Error, Sendable, Equatable {
    case realStateNeedsLease
    case leaseLost
    case io(String)
}

public final class StateStore: Sendable {
    /// Used verbatim (no realpath / standardizing), like Python's HERE.
    public let root: String
    private let lease: (any StateLease)?
    private let needsLease: Bool
    private let clock: any JarvisClock
    private let backups = Mutex(Backups())

    private struct Backups {
        var pending: [StateFile: Data] = [:]       // bytes of a failed load, not yet backed up
        var done: Set<StateFile> = []              // backed up once already: never again
    }

    /// Temp files `AtomicFile.write` left behind (a crash mid-write) are removed after this.
    public static let staleTempAge: Double = 3600

    /// Throws `.realStateNeedsLease` when `root` is a real repo root (it has `jarvis.py` and
    /// is not a test `Sandbox`) and `lease` is not held. Nothing under `root` is touched
    /// before that check. Then removes stale `.*.jarvis-tmp.*` files in `root`.
    public init(root: String, lease: (any StateLease)?,
                clock: any JarvisClock = SystemClock()) throws(StateStoreError) {
        let needsLease = StateStore.isRealRepoRoot(root)
        if needsLease && lease?.isHeld != true {
            throw .realStateNeedsLease
        }
        self.root = root
        self.lease = lease
        self.needsLease = needsLease
        self.clock = clock
        let removed = AtomicFile.removeStaleTemps(in: root, olderThan: StateStore.staleTempAge,
                                                  now: clock.now())
        for name in removed {
            JarvisLog.log("state: removed stale temp file \(name)", category: .state)
        }
    }

    /// `os.path.join(root, f.rawValue)`.
    public func path(_ f: StateFile) -> String {
        StateStore.join(root, f.rawValue)
    }

    /// `json.load(open(path))`; nil ⇔ Python's `except Exception` branch (missing,
    /// unreadable, not UTF-8, not JSON). A failed load of an existing, non-empty file is
    /// remembered so the next `save` can back its bytes up first; a later good load forgets it.
    public func load(_ f: StateFile) -> JSONValue? {
        guard let data = AtomicFile.read(path(f)) else { return nil }
        do {
            let v = try PyJSON.loads(data)
            backups.withLock { _ = $0.pending.removeValue(forKey: f) }
            return v
        } catch {
            if !data.isEmpty {
                backups.withLock { b in
                    if !b.done.contains(f) && b.pending[f] == nil { b.pending[f] = data }
                }
            }
            return nil
        }
    }

    /// `json.dump(v, open(path, "w"), indent=f.indent)`, written atomically. False on
    /// failure, logged and never thrown (Python swallows every writer exception). Returns
    /// false without writing when a lease was needed or given and is no longer held.
    @discardableResult
    public func save(_ f: StateFile, _ v: JSONValue) -> Bool {
        if (needsLease || lease != nil) && lease?.isHeld != true {
            JarvisLog.log("state: \(f.rawValue) not saved: \(StateStoreError.leaseLost)", category: .state)
            return false
        }
        backUpUnreadable(f)
        let text = PyJSON.dumps(v, indent: f.indent)
        do {
            try AtomicFile.write(Data(text.utf8), to: path(f))
            return true
        } catch {
            JarvisLog.log("state: \(f.rawValue) save failed: \(error)", category: .state)
            return false
        }
    }

    /// Where `.unreadable` backups go (M01 §8 R3, decision D-3). `logs/` is gitignored.
    public var backupDirectory: String {
        StateStore.join(StateStore.join(root, "logs"), "state-backups")
    }

    /// Copies the bytes of the failed load to `logs/state-backups/<name>.<epoch>.unreadable`
    /// before the save that overwrites them: at most once per file for this store (one store
    /// per process). A failed backup is logged, the save still goes ahead (as Python's would),
    /// and the next save retries it.
    private func backUpUnreadable(_ f: StateFile) {
        guard let data = backups.withLock({ $0.pending[f] }) else { return }
        let dir = backupDirectory
        let name = "\(f.rawValue).\(Int64(clock.now().rounded(.down))).unreadable"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try AtomicFile.write(data, to: StateStore.join(dir, name))
            backups.withLock { b in
                b.pending[f] = nil
                b.done.insert(f)
            }
            JarvisLog.log("state: \(f.rawValue) was unreadable; backed up as \(name)", category: .state)
        } catch {
            JarvisLog.log("state: \(f.rawValue) backup failed: \(error)", category: .state)
        }
    }

    /// A root holding `jarvis.py` is real state unless it is a test `Sandbox`
    /// (`jarvis-tests-*` under the temporary directory: the predicate `Sandbox.remove` uses).
    /// The Sandbox writes an empty `jarvis.py` marker, so the marker alone cannot tell.
    static func isRealRepoRoot(_ root: String) -> Bool {
        guard FileManager.default.fileExists(atPath: join(root, "jarvis.py")) else { return false }
        return !isTestSandbox(root)
    }

    static func isTestSandbox(_ root: String) -> Bool {
        guard let own = realPath(root),
              let tmp = realPath(FileManager.default.temporaryDirectory.path(percentEncoded: false))
        else { return false }
        let base = own.split(separator: "/").last.map(String.init) ?? ""
        return own.hasPrefix(tmp.hasSuffix("/") ? tmp : tmp + "/") && base.hasPrefix("jarvis-tests-")
    }

    private static func realPath(_ p: String) -> String? {
        guard let c = realpath(p, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// `os.path.join(a, b)` for a relative `b`.
    static func join(_ a: String, _ b: String) -> String {
        a.isEmpty || a.hasSuffix("/") ? a + b : a + "/" + b
    }
}
