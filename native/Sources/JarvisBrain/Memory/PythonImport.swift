import CryptoKit
import Foundation
import JarvisCore
import JarvisTools

/// P6 part 4 (DEV-P6-05, proposed): the one-time import of Python JARVIS's memory, for whoever
/// has Python-era data, started only by `JARVIS --import-python-memory`.
///
/// 1. The sources (`PythonEraMemory`): logs/jarvis.log's Python sessions (each heard line paired
///    with JARVIS's reply; the native sections, and empty, one-word, garbled and unanswered
///    heard lines, left out), history.json, knowledge.json's queue and corrections.json.
/// 2. They are cut into batches of one source and one day that fit P2's transcript.
/// 3. Each batch goes through P2's compile (`FactCompiler.compile(entries:source:)`): its prompt,
///    which keeps only what the user said about themselves, and P4's validator. A batch that
///    fits the on-device model (P3's `LocalFileBudget`) gets P2's writer, the on-device draft
///    that Claude improves; one that does not goes to Claude alone, redacted. Facts are tagged
///    `python:<YYYY-MM-DD>`.
/// 4. memory/python-import.json records each finished batch (by a hash of its transcript, never
///    its text) and, once every batch is done, the completion. A rerun skips finished batches,
///    and after completion it does nothing.
///
/// P6b: first, the log's paired exchanges are kept word for word in memory/archive-python.jsonl
/// (`PythonEraMemory.archived`: each with its session's date, on the channel "voice (Python)"),
/// written whole and once: python-import.json records it, so a run that already completed
/// writes the file and compiles nothing again, and a later run does neither. search_memory reads
/// that file and the backups cover it; the chat compile never reads it, since the batches above
/// already compiled the same exchanges.
///
/// One log line per batch and a summary, counts and dates only.
public final class PythonImport: Sendable {
    public struct Summary: Sendable, Equatable {
        public var batches = 0          // in the plan
        public var compiled = 0         // finished in this run
        public var resumed = 0          // finished in an earlier run
        public var failed = 0
        public var added = 0
        public var updated = 0
        public var dropped = 0          // reply lines the validator dropped
        public var skipped: [PythonEraMemory.Skip: Int] = [:]
        public var alreadyDone = false
        public var archived = 0         // P6b: messages kept word for word in this run
        public var archiveFailed = false // P6b: archive-python.jsonl could not be written

        public var complete: Bool { (alreadyDone || failed == 0) && !archiveFailed }
    }

    public enum Route: String, Sendable {
        case onDevice = "on-device"
        case claude = "Claude"
    }

    public static let logFile = "logs/jarvis.log"

    private let store: StateStore
    private let memory: MemoryStore
    private let compiler: FactCompiler
    private let claudeAlone: any AttributedWriting
    private let fits: @Sendable (String) async -> Bool
    private let clock: any JarvisClock
    private let timeZone: TimeZone
    private let log: @Sendable (String) -> Void

    /// - Parameters:
    ///   - compiler: P2's compile, with P2's writer (the on-device route).
    ///   - claudeAlone: the writer for a batch that does not fit the on-device model.
    ///   - fits: whether a transcript fits the on-device model with P2's instructions.
    public init(store: StateStore, memory: MemoryStore, compiler: FactCompiler, claudeAlone: any AttributedWriting,
                fits: @escaping @Sendable (String) async -> Bool, clock: any JarvisClock = SystemClock(),
                timeZone: TimeZone = .current,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.store = store
        self.memory = memory
        self.compiler = compiler
        self.claudeAlone = claudeAlone
        self.fits = fits
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
    }

    /// The app's import: P1's two writers, P2's writer and validator, P3's budget and redaction.
    public static func live(store: StateStore, memory: MemoryStore, environment: [String: String],
                            claudeWorkingDirectory: URL) -> PythonImport {
        let config = ClaudeConfig(environment: environment)
        let home = environment["HOME"] ?? NSHomeDirectory()
        let executable = BrainAssembly.locateClaude(environment: environment, config: config)
            ?? URL(fileURLWithPath: Py.rstrip(home, "/") + "/.local/bin/claude")
        let local = LocalPersonaLLM()
        let claude = ClaudePersonaLLM(config: config, executable: executable, workingDirectory: claudeWorkingDirectory,
                                      parentEnvironment: environment, online: { await Net.isOnline() })
        let compiler = FactCompiler(memory: memory, writer: BrainAssembly.factWriter(local: local, claude: claude),
                                    vectors: FactVectors(embedding: SystemSentenceEmbedding()))
        let budget = LocalFileBudget.system()
        return PythonImport(store: store, memory: memory, compiler: compiler, claudeAlone: ClaudeAlone(claude: claude),
                            fits: { transcript in
                                await budget.measure(text: transcript, prompt: transcript,
                                                     instructions: FactExtraction.system).fits
                            })
    }

    /// The plan: every batch, oldest day first, and what the sources left out.
    public func plan() -> (batches: [PythonEraMemory.Batch], skipped: [PythonEraMemory.Skip: Int]) {
        var groups: [PythonEraMemory.Group] = []
        var skipped: [PythonEraMemory.Skip: Int] = [:]
        let logPath = (store.root.isEmpty || store.root.hasSuffix("/") ? store.root : store.root + "/") + Self.logFile
        if let data = AtomicFile.read(logPath) {
            let reading = PythonEraMemory.readLog(String(decoding: data, as: UTF8.self), timeZone: timeZone)
            groups += reading.groups
            skipped.merge(reading.skipped, uniquingKeysWith: +)
        }
        if let (date, t) = modified(store.path(.history)) {
            groups += PythonEraMemory.readHistory(store.load(.history), date: date, at: t, skipped: &skipped)
        }
        if let (date, t) = modified(store.path(.knowledge)) {
            groups += PythonEraMemory.readKnowledgeQueue(store.load(.knowledge), date: date, at: t, skipped: &skipped)
        }
        if let (date, t) = modified(store.path(.corrections)) {
            groups += PythonEraMemory.readCorrections(store.load(.corrections), timeZone: timeZone,
                                                      fallbackDate: date, fallbackTime: t)
        }
        return (PythonEraMemory.batches(groups), skipped)
    }

    /// P6b: the log's paired exchanges as archive-python.jsonl keeps them; none without a log.
    public func exchanges() -> [ArchiveEntry] {
        let logPath = (store.root.isEmpty || store.root.hasSuffix("/") ? store.root : store.root + "/") + Self.logFile
        guard let data = AtomicFile.read(logPath) else { return [] }
        return PythonEraMemory.archived(PythonEraMemory.readLog(String(decoding: data, as: UTF8.self),
                                                                timeZone: timeZone))
    }

    /// Runs the import, or says it already ran.
    public func run() async -> Summary {
        var summary = Summary()
        var progress = ImportProgress(data: store.read(.pythonImport)) ?? ImportProgress(started: clock.now())
        if progress.archived == nil { keepExchanges(&progress, &summary) }
        if let done = progress.completed {
            summary.alreadyDone = true
            summary.batches = progress.batches
            summary.added = progress.added
            summary.updated = progress.updated
            log("memory: Python memory was imported on \(day(done)) (\(progress.batches) batch(es), "
                + "\(progress.added) fact(s) added, \(progress.updated) updated); nothing to do")
            return summary
        }
        let (batches, skipped) = plan()
        summary.batches = batches.count
        summary.skipped = skipped
        progress.batches = batches.count
        progress.skipped = skipped
        if batches.isEmpty {
            log("memory: no Python-era conversations to import" + skippedNote(skipped))
            progress.completed = clock.now()
            save(progress)
            return summary
        }
        log("memory: importing Python memory in \(batches.count) batch(es)" + skippedNote(skipped))
        for (k, batch) in batches.enumerated() {
            let (transcript, _) = FactExtraction.transcript(batch.entries)
            let id = Self.hash(batch, transcript: transcript)
            let tag = "batch \(k + 1) of \(batches.count) (\(batch.source.rawValue), \(batch.date)"
            if progress.done.contains(id) {
                summary.resumed += 1
                continue
            }
            if Task.isCancelled {
                summary.failed += 1
                continue
            }
            let route: Route = await fits(transcript) ? .onDevice : .claude
            let outcome = await compiler.compile(entries: batch.entries, source: batch.factSource,
                                                 writer: route == .claude ? claudeAlone : nil)
            switch outcome {
            case .compiled(let added, let updated, let dropped):
                summary.compiled += 1
                summary.added += added
                summary.updated += updated
                summary.dropped += dropped
                progress.record(id, added: added, updated: updated, dropped: dropped)
                save(progress)
                log("memory: Python import \(tag), \(route.rawValue)): \(added) new fact(s), \(updated) updated, "
                    + "\(dropped) line(s) dropped")
            case .nothingNew:
                summary.compiled += 1
                progress.record(id, added: 0, updated: 0, dropped: 0)
                save(progress)
                log("memory: Python import \(tag)): nothing from the user")
            default:
                summary.failed += 1
                log("memory: Python import \(tag), \(route.rawValue)) not compiled (\(Self.describe(outcome))); "
                    + "the next run tries it again")
            }
        }
        let totals = "\(summary.batches) batch(es) (\(summary.compiled) now, \(summary.resumed) earlier), "
            + "\(progress.added) fact(s) added, \(progress.updated) updated, \(progress.dropped) line(s) dropped"
            + skippedNote(skipped)
        if summary.failed == 0 {
            progress.completed = clock.now()
            save(progress)
            log("memory: Python import complete: " + totals)
        } else {
            log("memory: Python import incomplete, \(summary.failed) batch(es) not compiled: " + totals
                + ". Run JARVIS --import-python-memory again to finish it")
        }
        return summary
    }

    // MARK: - Batch C part 1: the boot log

    /// The boot log against jarvis.log, read-only: nil when either file is missing.
    public func checkBootLog() -> PythonEraMemory.BootLogCheck? {
        let root = store.root.isEmpty || store.root.hasSuffix("/") ? store.root : store.root + "/"
        guard let boot = AtomicFile.read(root + PythonEraMemory.bootLogFile),
              let main = AtomicFile.read(root + Self.logFile) else { return nil }
        return PythonEraMemory.checkBootLog(boot: String(decoding: boot, as: UTF8.self),
                                            log: String(decoding: main, as: UTF8.self), timeZone: timeZone)
    }

    /// The boot log's exchanges that jarvis.log lacks, compiled through the same batches, routes
    /// and records as `run()` (a finished batch is skipped on a rerun; python-import.json gains
    /// "boot_log" once every one is done). Counts only in the log.
    public func importBootLog() async -> (check: PythonEraMemory.BootLogCheck?, summary: Summary) {
        var summary = Summary()
        guard let check = checkBootLog() else {
            log("memory: no boot log, or no jarvis.log, to compare")
            return (nil, summary)
        }
        log("memory: " + check.summary)
        var progress = ImportProgress(data: store.read(.pythonImport)) ?? ImportProgress(started: clock.now())
        let batches = PythonEraMemory.batches(check.groups)
        summary.batches = batches.count
        for (k, batch) in batches.enumerated() {
            let (transcript, _) = FactExtraction.transcript(batch.entries)
            let id = Self.hash(batch, transcript: transcript)
            let tag = "boot-log batch \(k + 1) of \(batches.count) (\(batch.date)"
            if progress.done.contains(id) { summary.resumed += 1; continue }
            if Task.isCancelled { summary.failed += 1; continue }
            let route: Route = await fits(transcript) ? .onDevice : .claude
            let outcome = await compiler.compile(entries: batch.entries, source: batch.factSource,
                                                 writer: route == .claude ? claudeAlone : nil)
            switch outcome {
            case .compiled(let added, let updated, let dropped):
                summary.compiled += 1
                summary.added += added
                summary.updated += updated
                summary.dropped += dropped
                progress.record(id, added: added, updated: updated, dropped: dropped)
                save(progress)
                log("memory: Python \(tag), \(route.rawValue)): \(added) new fact(s), \(updated) updated")
            case .nothingNew:
                summary.compiled += 1
                progress.record(id, added: 0, updated: 0, dropped: 0)
                save(progress)
                log("memory: Python \(tag)): nothing from the user")
            default:
                summary.failed += 1
                log("memory: Python \(tag), \(route.rawValue)) not compiled (\(Self.describe(outcome)))")
            }
        }
        if summary.failed == 0 {
            progress.bootLog = clock.now()
            progress.bootLogExchanges = check.newExchanges
            save(progress)
        }
        log("memory: boot-log import \(summary.failed == 0 ? "complete" : "incomplete"): \(summary.batches) batch(es) "
            + "(\(summary.compiled) now, \(summary.resumed) earlier, \(summary.failed) not compiled), "
            + "\(summary.added) fact(s) added, \(summary.updated) updated")
        return (check, summary)
    }

    // MARK: - Helpers

    /// P6b: archive-python.jsonl, written whole, then recorded. Nothing to keep records nothing.
    private func keepExchanges(_ progress: inout ImportProgress, _ summary: inout Summary) {
        let exchanges = exchanges()
        guard !exchanges.isEmpty else { return }
        guard memory.writePythonArchive(exchanges) else {
            summary.archiveFailed = true
            log("memory: memory/archive-python.jsonl not written; run JARVIS --import-python-memory again "
                + "to keep the Python conversations")
            return
        }
        progress.archived = clock.now()
        progress.archivedMessages = exchanges.count
        save(progress)
        summary.archived = exchanges.count
        log("memory: kept \(exchanges.count) Python-era message(s) word for word in memory/archive-python.jsonl")
    }

    private func save(_ progress: ImportProgress) {
        if !store.write(progress.data, to: .pythonImport) {
            log("memory: python-import.json not saved; a rerun repeats the finished batches")
        }
    }

    /// The file's local modification date and time, nil when there is no file.
    private func modified(_ path: String) -> (String, Double)? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        let t = date.timeIntervalSince1970
        return (day(t), t)
    }

    private func day(_ t: Double) -> String {
        PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: t), timeZone: timeZone)
    }

    private func skippedNote(_ skipped: [PythonEraMemory.Skip: Int]) -> String {
        let total = skipped.values.reduce(0, +)
        guard total > 0 else { return "; nothing skipped" }
        let parts = PythonEraMemory.Skip.allCases.compactMap { why -> String? in
            guard let n = skipped[why], n > 0 else { return nil }
            let name = switch why {
            case .empty: "empty"
            case .oneWord: "one word"
            case .garbled: "garbled"
            case .unpaired: "unanswered"
            }
            return "\(n) \(name)"
        }
        return "; \(total) heard line(s) skipped (" + parts.joined(separator: ", ") + ")"
    }

    /// A batch's id in python-import.json: a hash of its source, day and transcript.
    static func hash(_ batch: PythonEraMemory.Batch, transcript: String) -> String {
        let text = batch.source.rawValue + "\n" + batch.date + "\n" + transcript
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func describe(_ outcome: FactCompiler.Outcome) -> String {
        switch outcome {
        case .busy: "another compile was running"
        case .unreadable: "facts.json is unreadable"
        case .writersFailed: "both writers failed"
        case .cancelled: "stopped"
        case .notSaved: "facts.json was not saved"
        case .nothingNew, .compiled: "done"
        }
    }
}

/// Claude alone, given redacted text (P3's route for what does not fit the on-device model).
struct ClaudeAlone: AttributedWriting {
    let claude: any PersonaLLM

    func write(system: String, user: String, timeout: Duration) async throws -> AttributedText {
        AttributedText(text: try await claude.complete(system: system, user: Redactor.redacted(user), timeout: timeout),
                       author: .claude)
    }
}

/// memory/python-import.json: `{"version": 1, "started": t, "completed": t or null, "batches": n,
/// "done": [<batch hash>], "added": n, "updated": n, "dropped": n, "skipped": {<why>: n},
/// "archived": t or null, "archived_messages": n}`. P6b added the last two (when
/// archive-python.jsonl was written, and how many messages it holds); a file without them reads
/// as not yet archived.
struct ImportProgress: Equatable {
    var started: Double
    var completed: Double?
    var batches = 0
    var done: [String] = []
    var added = 0
    var updated = 0
    var dropped = 0
    var skipped: [PythonEraMemory.Skip: Int] = [:]
    var archived: Double?
    var archivedMessages = 0
    /// Batch C part 1: when the boot log's new exchanges were all compiled, and how many there were.
    /// Written only once set, so an older file reads and writes as before.
    var bootLog: Double?
    var bootLogExchanges = 0

    init(started: Double) {
        self.started = started
    }

    mutating func record(_ id: String, added: Int, updated: Int, dropped: Int) {
        done.append(id)
        self.added += added
        self.updated += updated
        self.dropped += dropped
    }

    var data: Data {
        let skips = PythonEraMemory.Skip.allCases.map { JSONObject.Member(key: $0.rawValue, value: .int(Int64(skipped[$0] ?? 0))) }
        let object = JSONObject([
            .init(key: "version", value: .int(1)),
            .init(key: "started", value: .double(started)),
            .init(key: "completed", value: completed.map { .double($0) } ?? .null),
            .init(key: "batches", value: .int(Int64(batches))),
            .init(key: "done", value: .array(done.map { .string($0) })),
            .init(key: "added", value: .int(Int64(added))),
            .init(key: "updated", value: .int(Int64(updated))),
            .init(key: "dropped", value: .int(Int64(dropped))),
            .init(key: "skipped", value: .object(JSONObject(skips))),
            .init(key: "archived", value: archived.map { .double($0) } ?? .null),
            .init(key: "archived_messages", value: .int(Int64(archivedMessages))),
        ] + (bootLog.map { [JSONObject.Member(key: "boot_log", value: .double($0)),
                            JSONObject.Member(key: "boot_log_exchanges", value: .int(Int64(bootLogExchanges)))] } ?? []))
        return Data(PyJSON.dumps(.object(object), indent: 1).utf8)
    }

    init?(data: Data?) {
        guard let data, let o = (try? PyJSON.loads(data))?.objectValue, let started = o["started"]?.doubleValue else {
            return nil
        }
        self.started = started
        completed = o["completed"]?.doubleValue
        batches = o["batches"]?.intValue ?? 0
        done = o["done"]?.arrayValue?.compactMap(\.stringValue) ?? []
        added = o["added"]?.intValue ?? 0
        updated = o["updated"]?.intValue ?? 0
        dropped = o["dropped"]?.intValue ?? 0
        for why in PythonEraMemory.Skip.allCases {
            if let n = o["skipped"]?.objectValue?[why.rawValue]?.intValue { skipped[why] = n }
        }
        archived = o["archived"]?.doubleValue
        archivedMessages = o["archived_messages"]?.intValue ?? 0
        bootLog = o["boot_log"]?.doubleValue
        bootLogExchanges = o["boot_log_exchanges"]?.intValue ?? 0
    }
}

private extension JSONValue {
    var doubleValue: Double? {
        switch self {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }

    var intValue: Int? {
        if case .int(let i) = self { return Int(i) }
        return nil
    }
}
