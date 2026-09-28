import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// JarvisLog is process-global, so this suite is serialized and every test points the sink
/// into its own Sandbox and detaches it (`configure(file: nil, …)`) before the sandbox goes.
@Suite("JarvisLog", .serialized)
struct JarvisLogTests {
    @Test func logAppendsPythonFormatLines() throws {
        let s = try Sandbox()
        defer { s.remove() }
        try s.write("logs/jarvis.log", "===== JARVIS starting 2026-09-01 08:00:00 =====\n[JARVIS] from python\n")
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        JarvisLog.log("Another JARVIS (python 4242) holds .jarvis.lock — exiting.", category: .lock)
        JarvisLog.log("activation policy: accessory")
        #expect(try s.read("logs/jarvis.log") == """
            ===== JARVIS starting 2026-09-01 08:00:00 =====
            [JARVIS] from python
            [JARVIS] Another JARVIS (python 4242) holds .jarvis.lock — exiting.
            [JARVIS] activation policy: accessory

            """)
    }

    @Test func bannerMatchesPythonShapeWithNativeMarker() throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        JarvisLog.banner(now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "UTC")!)
        JarvisLog.banner(now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(try s.read("logs/jarvis.log")
                == "\n===== JARVIS (native) starting 2023-11-14 22:13:20 =====\n"
                 + "\n===== JARVIS (native) starting 2023-11-15 07:13:20 =====\n")
    }

    @Test func configureCreatesTheLogDirectory() throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.root.appending(path: "fresh/logs/jarvis.log"), mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        JarvisLog.log("first")
        #expect(try s.read("fresh/logs/jarvis.log") == "[JARVIS] first\n")
    }

    @Test func logDescriptorIsAppendOnlyAndCloseOnExec() throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        let fds = openDescriptors(for: s.paths.logFile)
        try #require(fds.count == 1)
        #expect(fcntl(fds[0], F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
        #expect(fcntl(fds[0], F_GETFL) & O_APPEND == O_APPEND)
        #expect(fcntl(fds[0], F_GETFL) & O_ACCMODE == O_WRONLY)
        JarvisLog.configure(file: nil, mirrorToStdout: false)
        #expect(openDescriptors(for: s.paths.logFile) == [], "reconfigure must close the old fd")
        JarvisLog.log("after detach")
        #expect(try s.read("logs/jarvis.log") == "")
    }

    @Test func concurrentLinesNeverInterleave() async throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        let payload = String(repeating: "x", count: 900)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<200 { JarvisLog.log("t\(t) i\(i) \(payload)", category: .state) }
                }
            }
        }
        let lines = try s.read("logs/jarvis.log").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 8 * 200 + 1 && lines.last == "")
        let body = lines.dropLast()
        #expect(body.allSatisfy { $0.hasPrefix("[JARVIS] t") && $0.hasSuffix(" " + payload) })
        #expect(Set(body).count == 8 * 200)
    }
}
