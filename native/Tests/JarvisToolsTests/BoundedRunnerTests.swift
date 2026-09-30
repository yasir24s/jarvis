import Foundation
@testable import JarvisTools
import Testing

/// The bounded child runner (plan: M05-M06 §3.4, T5.3's timeout-kill and pipe-drain checks).
/// The children are /bin/sleep, /bin/sh and /usr/bin/yes only; real-time bounds are measured
/// on SuspendingClock.
@Suite("BoundedRunnerTests")
struct BoundedRunnerTests {
    @Test func timeoutKillsTheChild() async throws {
        let clock = SuspendingClock()
        let start = clock.now
        let output = try #require(await BoundedRunner().run(["/bin/sleep", "5"], timeout: 1))
        let elapsed = clock.now - start
        #expect(output.timedOut)
        #expect(!output.completed)
        #expect(output.status == -SIGKILL)
        #expect(elapsed >= .milliseconds(900))
        #expect(elapsed < .seconds(3), "a 1 s limit must not wait out the 5 s sleep (\(elapsed))")
    }

    /// A grandchild that inherited the pipe is killed with the group, so EOF cannot hang.
    @Test func timeoutKillsTheProcessGroup() async throws {
        let clock = SuspendingClock()
        let start = clock.now
        let output = try #require(await BoundedRunner().run(["/bin/sh", "-c", "/bin/sleep 30 & wait"], timeout: 1))
        #expect(output.timedOut)
        #expect(clock.now - start < .seconds(3))
    }

    @Test func drainsOneMebibyteFromBothPipes() async throws {
        let script = "/usr/bin/head -c 1048576 /dev/zero; /usr/bin/head -c 1048576 /dev/zero >&2; echo done >&2"
        let output = try #require(await BoundedRunner().run(["/bin/sh", "-c", script], timeout: 20))
        #expect(output.completed)
        #expect(output.status == 0)
        #expect(output.stdout.count == 1 << 20)
        #expect(output.stdout.allSatisfy { $0 == 0 })
        #expect(output.stderr.count == (1 << 20) + 5)
        #expect(output.stderr.suffix(5) == Data("done\n".utf8))
    }

    @Test func capTruncatesAndKills() async throws {
        let clock = SuspendingClock()
        let start = clock.now
        let output = try #require(await BoundedRunner(cap: 10_000).run(["/usr/bin/yes"], timeout: 20))
        #expect(output.truncated)
        #expect(!output.timedOut)
        #expect(output.stdout.count == 10_000)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellingTheTaskKillsTheChild() async throws {
        let clock = SuspendingClock()
        let start = clock.now
        let task = Task { await BoundedRunner().run(["/bin/sleep", "30"], timeout: 60) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let output = try #require(await task.value)
        #expect(!output.completed || output.status == -SIGKILL)
        #expect(output.status == -SIGKILL)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func exitStatusAndSeparateStreams() async throws {
        let output = try #require(await BoundedRunner().run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], timeout: 10))
        #expect(output.completed)
        #expect(output.status == 3)
        #expect(output.stdout == Data("out\n".utf8))
        #expect(output.stderr == Data("err\n".utf8))
    }

    @Test func launchFailureIsNil() async {
        #expect(await BoundedRunner().run(["/nonexistent/jarvis-no-such-tool"], timeout: 1) == nil)
        #expect(await BoundedRunner().run(["sleep", "1"], timeout: 1) == nil, "argv[0] must be absolute")
        #expect(await BoundedRunner().run([], timeout: 1) == nil)
    }
}
