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

/// One native-only memory file (D-51). Python never reads or writes these, and `memory/` is
/// git-ignored and in the pre-commit denylist: it holds the user's own conversations.
public enum MemoryFile: String, CaseIterable, Sendable {
    case archive = "memory/archive.jsonl"      // append-only, one JSON object per message
    case facts = "memory/facts.json"           // compiled facts, written atomically
    case filesIndex = "memory/files-index.json" // the file scanner's index (P3), written atomically
    case forgotten = "memory/forgotten.json"   // what forget_memory removed, kept 30 days (P6)
    case pythonImport = "memory/python-import.json" // the one-time Python-era import's progress (P6)
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
    /// Told the file and its bytes after each successful `save` (P6: the memory store's hourly
    /// backups of personality.json and profile.json). Nil until one is set.
    private let saved = Mutex<(@Sendable (StateFile, Data) -> Void)?>(nil)

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
            let data = Data(text.utf8)
            try AtomicFile.write(data, to: path(f))
            saved.withLock { $0 }?(f, data)
            return true
        } catch {
            JarvisLog.log("state: \(f.rawValue) save failed: \(error)", category: .state)
            return false
        }
    }

    /// Sets the one observer `save` tells after each successful write (P6), replacing any other.
    public func onSave(_ observer: @escaping @Sendable (StateFile, Data) -> Void) {
        saved.withLock { $0 = observer }
    }

    /// True when a write may go ahead: no lease is needed or given, or the lease is held.
    public var mayWrite: Bool {
        !((needsLease || lease != nil) && lease?.isHeld != true)
    }

    /// Writes `data` as `f` exactly (P6: a backup put back at launch), atomically and under the
    /// lease rule `save` keeps. The observer is not told: the bytes are a backup's already.
    @discardableResult
    public func restore(_ f: StateFile, bytes data: Data) -> Bool {
        guard mayWrite else {
            JarvisLog.log("state: \(f.rawValue) not restored: \(StateStoreError.leaseLost)", category: .state)
            return false
        }
        do {
            try AtomicFile.write(data, to: path(f))
            return true
        } catch {
            JarvisLog.log("state: \(f.rawValue) restore failed: \(error)", category: .state)
            return false
        }
    }

    // MARK: - Native-only memory files (D-51)

    /// `root/memory/<name>`.
    public func path(_ f: MemoryFile) -> String {
        StateStore.join(root, f.rawValue)
    }

    /// The file's bytes; nil if it is missing or unreadable.
    public func read(_ f: MemoryFile) -> Data? {
        AtomicFile.read(path(f))
    }

    /// Appends `line + "\n"` in one O_APPEND write, creating `memory/` (0o700) first. False,
    /// logged by file name only, when the lease is needed or given and not held, or on failure.
    @discardableResult
    public func appendLine(_ line: String, to f: MemoryFile) -> Bool {
        guard memoryWriteAllowed(f) else { return false }
        do {
            try AtomicFile.appendLine(line, to: path(f))
            return true
        } catch {
            JarvisLog.log("state: \(f.rawValue) append failed: \(error)", category: .state)
            return false
        }
    }

    /// Writes `data` atomically (temp file, fsync, rename), as `save` does, under the same
    /// lease rule. False, logged by file name only, on refusal or failure.
    @discardableResult
    public func write(_ data: Data, to f: MemoryFile) -> Bool {
        guard memoryWriteAllowed(f) else { return false }
        do {
            try AtomicFile.write(data, to: path(f))
            return true
        } catch {
            JarvisLog.log("state: \(f.rawValue) write failed: \(error)", category: .state)
            return false
        }
    }

    /// The lease check `save` makes, then `memory/` created owner-only. Nothing under `root`
    /// is touched when the lease is missing.
    private func memoryWriteAllowed(_ f: MemoryFile) -> Bool {
        if (needsLease || lease != nil) && lease?.isHeld != true {
            JarvisLog.log("state: \(f.rawValue) not written: \(StateStoreError.leaseLost)", category: .state)
            return false
        }
        let dir = StateStore.join(root, "memory")
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            JarvisLog.log("state: memory/ not created: \(error)", category: .state)
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
