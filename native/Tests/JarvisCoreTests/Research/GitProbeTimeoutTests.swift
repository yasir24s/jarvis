import Darwin
import Foundation
import JarvisCore
import Testing

@Suite("GitProbeTimeoutTests", .timeLimit(.minutes(1)))
struct GitProbeTimeoutTests {
    @Test func normalRunnerPreservesStdoutAndIgnoresExitStatus() {
        #expect(GitProbe.run(["/bin/sh", "-c", "printf '  abc \\n'; exit 7"], 2) == "  abc \n")
    }

    @Test func callerStillTrimsBothFields() {
        let result = GitProbe.headAndCommits(repo: URL(fileURLWithPath: "/tmp"), timeout: 2) { _, timeout in
            GitProbe.run(["/bin/sh", "-c", "printf '  abc \\n'"], timeout)
        }
        #expect(result.head == "abc")
        #expect(result.commits == "abc")
    }

    @Test func invalidUTF8StillReturnsNil() {
        #expect(GitProbe.run(["/bin/sh", "-c", "printf '\\377'"], 2) == nil)
    }

    @Test func outputLargerThanThePipeBufferIsDrained() {
        let output = GitProbe.run(["/usr/bin/head", "-c", "262144", "/dev/zero"], 2)
        #expect(output?.utf8.count == 262_144)
        #expect(output?.utf8.allSatisfy { $0 == 0 } == true)
    }

    @Test(arguments: [false, true])
    func timeoutKillsInheritedPipeWriters(_ leaderWaits: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("git-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let idsFile = dir.appendingPathComponent("pids")
        defer {
            // Cleanup remains scoped to the process group created by this fixture,
            // even if an assertion fails. Never target unrelated sleep processes.
            if let ids = try? Self.readIDs(idsFile), ids.group > 1, ids.group != getpgrp() {
                kill(-ids.group, SIGKILL)
            }
            try? FileManager.default.removeItem(at: dir)
        }
        let script = "/bin/sleep 30 & child=$!; printf '%s %s\\n' \"$$\" \"$child\" > \"$1\"; echo x"
            + (leaderWaits ? "; wait" : "")
        let timeout = 0.3
        // Awake time only: the suspending clock stops while the Mac sleeps, so a closed lid
        // cannot use the bounds up.
        let start = SuspendingClock.now
        let result = GitProbe.run(["/bin/sh", "-c", script, "git-probe-test", idsFile.path], timeout)
        #expect(result == nil)
        #expect(start.duration(to: .now) < .seconds(timeout + 2))
        let ids = try Self.readIDs(idsFile)
        #expect(ids.group != getpgrp())
        // Allow launchd to reap the orphan after SIGKILL; no long-lived child remains.
        let reapedBy = SuspendingClock.now.advanced(by: .seconds(2))
        while kill(ids.child, 0) == 0 && SuspendingClock.now < reapedBy { usleep(10_000) }
        #expect(kill(ids.child, 0) == -1 && errno == ESRCH, "fixture sleep child was not reaped")
    }

    @Test func earlyEOFDoesNotAllowTheChildToOutliveTheDeadline() {
        let start = SuspendingClock.now
        #expect(GitProbe.run(["/bin/sh", "-c", "exec 1>&-; exec /bin/sleep 30"], 0.2) == nil)
        #expect(start.duration(to: .now) < .seconds(2.2))
    }

    private static func readIDs(_ file: URL) throws -> (group: pid_t, child: pid_t) {
        let values = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isWhitespace)
        try #require(values.count == 2)
        return (try #require(pid_t(values[0])), try #require(pid_t(values[1])))
    }
}
