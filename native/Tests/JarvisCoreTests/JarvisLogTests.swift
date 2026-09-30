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
        // Other suites share this sink, so their lines may land between ours: check that
        // Python's lines stay an untouched prefix and that ours follow, whole and in order.
        let prior = "===== JARVIS starting 2026-09-01 08:00:00 =====\n[JARVIS] from python\n"
        let ours = ["[JARVIS] Another JARVIS (python 4242) holds .jarvis.lock — exiting.",
                    "[JARVIS] activation policy: accessory"]
        let content = try s.read("logs/jarvis.log")
        #expect(content.hasPrefix(prior))
        #expect(content.hasSuffix("\n"))
        #expect(content.dropFirst(prior.count).split(separator: "\n").map(String.init).filter(ours.contains) == ours)
    }

    @Test func bannerMatchesPythonShapeWithNativeMarker() throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        JarvisLog.banner(now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "UTC")!)
        JarvisLog.banner(now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        // Each banner is one write, so it stays whole even when other suites log in between.
        let content = try s.read("logs/jarvis.log")
        let utc = try #require(content.range(of: "\n===== JARVIS (native) starting 2023-11-14 22:13:20 =====\n"))
        let tokyo = try #require(content.range(of: "\n===== JARVIS (native) starting 2023-11-15 07:13:20 =====\n"))
        #expect(utc.lowerBound < tokyo.lowerBound)
    }

    @Test func configureCreatesTheLogDirectory() throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.root.appending(path: "fresh/logs/jarvis.log"), mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        JarvisLog.log("first")
        #expect(try s.read("fresh/logs/jarvis.log").split(separator: "\n").contains("[JARVIS] first"))
    }

    @Test func logDescriptorIsAppendOnlyAndCloseOnExec() throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        let fds = openDescriptors(for: s.paths.logFile)
        try #require(fds.count == 1)
        #expect(fcntl(fds[0], F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
        #expect(fcntl(fds[0], F_GETFL) & O_APPEND == O_APPEND)
        #expect(fcntl(fds[0], F_GETFL) & O_ACCMODE == O_WRONLY)
        JarvisLog.log("before detach")
        JarvisLog.configure(file: nil, mirrorToStdout: false)
        #expect(openDescriptors(for: s.paths.logFile) == [], "reconfigure must close the old fd")
        // Other suites may have logged while attached; detaching must freeze the file.
        let detached = try s.read("logs/jarvis.log")
        JarvisLog.log("after detach")
        #expect(try s.read("logs/jarvis.log") == detached)
    }

    @Test func concurrentLinesNeverInterleave() async throws {
        let s = try Sandbox()
        defer { s.remove() }
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        let payload = String(repeating: "x", count: 900)
        let marker = "concurrent-log-\(UUID().uuidString)"
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<200 { JarvisLog.log("\(marker) t\(t) i\(i) \(payload)", category: .state) }
                }
            }
            // Other suites share this sink even though this suite is serialized.
            group.addTask {
                for i in 0..<200 { JarvisLog.log("unrelated log writer \(i)") }
            }
        }
        let lines = try s.read("logs/jarvis.log").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.last == "")
        // Use contains, not hasPrefix: interleaving that damages a marked line's
        // prefix must remain visible and fail the exact-content comparison.
        let body = lines.filter { $0.contains(marker) }.map(String.init)
        let expected = Set((0..<8).flatMap { t in
            (0..<200).map { i in "[JARVIS] \(marker) t\(t) i\(i) \(payload)" }
        })
        #expect(body.count == 8 * 200)
        #expect(Set(body) == expected)
    }
}
