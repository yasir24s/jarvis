import Darwin
import Foundation
import JarvisBrain
import JarvisCore

/// `JARVIS --import-python-memory` (P6 part 4, DEV-P6-05): the one-time import of Python
/// JARVIS's memory into memory/facts.json (`PythonImport`). Never run at launch. Headless: it
/// touches no AppKit or SwiftUI object. It holds the state root's single-instance lock for the
/// whole run, so the app must be quit first, and it runs the launch check before it reads. The
/// log is mirrored to stdout: one line per batch and a summary, counts only.
///
/// Exits 0 when the import is complete (now or before), 1 when a batch was not compiled (run it
/// again to finish), 73 when no temp folder can be made, 75 when another JARVIS holds the
/// lock, 78 when the state root cannot be resolved or opened.
enum PythonImportMain {
    static let flag = "--import-python-memory"
    /// Batch C part 1: the boot log's new exchanges through the same import (holds the lock).
    static let bootLogFlag = "--import-python-boot-log"
    /// Batch C part 1: the boot log against jarvis.log, read-only, counts only: `--check-python-boot-log <root>`.
    /// It opens no state store, takes no lock, writes no log and touches nothing under <root>.
    static let checkBootLogFlag = "--check-python-boot-log"

    static func checkBootLog(root: String) -> Int32 {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard let boot = FileManager.default.contents(atPath: base + PythonEraMemory.bootLogFile),
              let main = FileManager.default.contents(atPath: base + PythonImport.logFile) else {
            return fail("no \(PythonEraMemory.bootLogFile) or \(PythonImport.logFile) under that folder", 66)   // EX_NOINPUT
        }
        let check = PythonEraMemory.checkBootLog(boot: String(decoding: boot, as: UTF8.self),
                                                 log: String(decoding: main, as: UTF8.self), timeZone: .current)
        print(check.summary)
        return 0
    }

    /// Runs the import off the main thread and parks the main thread; exits with its status.
    static func start(bootLog: Bool = false) -> Never {
        Task.detached { exit(await run(bootLog: bootLog)) }
        dispatchMain()
    }

    private static func fail(_ message: String, _ status: Int32) -> Int32 {
        FileHandle.standardError.write(Data("JARVIS \(flag): \(message)\n".utf8))
        return status
    }

    static func run(bootLog: Bool = false) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let paths: StatePaths
        do {
            paths = try StatePaths.live()
        } catch {
            return fail("cannot resolve the state root: \(error)", 78)                  // EX_CONFIG
        }
        JarvisLog.configure(file: paths.logFile, mirrorToStdout: true)
        JarvisLog.banner()
        let lock: InstanceLock
        switch InstanceLock.tryAcquire(at: paths.lockFile, repoRoot: paths.root) {
        case .acquired(let held):
            lock = held
        case .held(let holder):
            return fail("another JARVIS (\(AppDelegate.describe(holder))) holds .jarvis.lock; quit it first", 75)
        case .foreignProcess(let pids):
            return fail("a pre-patch Python JARVIS (\(pids[0])) is running", 75)
        }
        let store: StateStore
        do {
            store = try StateStore(root: paths.root.path(percentEncoded: false), lease: InstanceLockLease(lock))
        } catch {
            return fail("cannot open the state store: \(error)", 78)
        }
        let memory = MemoryStore(store: store, clock: SystemClock(), timeZone: .autoupdatingCurrent)
        memory.checkAtLaunch()
        var template = Array((FileManager.default.temporaryDirectory.path(percentEncoded: false)
                              + "jarvis-import.XXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            return fail("cannot make a temp folder", 73)                                 // EX_CANTCREAT
        }
        let scratch = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let importer = PythonImport.live(store: store, memory: memory, environment: environment,
                                         claudeWorkingDirectory: scratch.appending(path: "claude-cwd",
                                                                                   directoryHint: .isDirectory))
        if bootLog {
            let (check, summary) = await importer.importBootLog()
            withExtendedLifetime(lock) {}
            return check == nil ? 66 : (summary.failed == 0 ? 0 : 1)
        }
        let summary = await importer.run()
        withExtendedLifetime(lock) {}
        return summary.complete ? 0 : 1
    }
}
