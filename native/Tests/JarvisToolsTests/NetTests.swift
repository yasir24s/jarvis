import Foundation
@testable import JarvisTools
import Synchronization
import Testing

@Suite("NetTests", .timeLimit(.minutes(1)))
struct NetTests {
    @Test func firstSuccessStopsImmediately() async {
        let calls = Calls(results: [true])
        #expect(await Net.isOnline(connector: calls.connector))
        #expect(await calls.requests == [Request(host: "1.1.1.1", port: 443, timeout: 1.2)])
    }

    @Test func firstFailureTriesSecondHostWithItsOwnTimeout() async {
        let calls = Calls(results: [false, true])
        #expect(await Net.isOnline(connector: calls.connector))
        #expect(await calls.requests == Self.bothRequests)
    }

    @Test func bothFailMeansOffline() async {
        let calls = Calls(results: [false, false])
        #expect(await !Net.isOnline(connector: calls.connector))
        #expect(await calls.requests == Self.bothRequests)
    }

    /// DEV-M4-02: native probes port 443; Python's is_online (jarvis.py 521-528) probes 53.
    @Test func probesPort443WherePythonProbes53() async {
        let calls = Calls(results: [false, false])
        _ = await Net.isOnline(connector: calls.connector)
        let ports = await calls.requests.map(\.port)
        #expect(ports == [443, 443])
        withKnownIssue("DEV-M4-02: Python's is_online connects to port 53") {
            #expect(ports == [53, 53])
        }
    }

    @Test func alreadyCancelledDoesNotProbe() async {
        let calls = Calls(results: [true])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Net.isOnline(connector: calls.connector)
        }
        #expect(await !task.value)
        #expect(await calls.requests.isEmpty)
    }

    @Test(arguments: [true, false])
    func cancellationDuringProbeDoesNotTryNextHost(_ result: Bool) async {
        let calls = Mutex(0)
        let task = Task {
            await Net.isOnline { _, _, _ in
                calls.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }
        }
        #expect(await !task.value)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: [true, false])
    func completionClosesConnectionExactlyOnce(_ success: Bool) async {
        let probe = Probe(results: [success, !success, success])
        #expect(await Net.connect(probe, timeout: 1.2) == success)
        #expect(probe.cancels.withLock { $0 } == 1)
    }

    @Test func silentConnectionTimesOutAndCloses() async {
        let probe = Probe(results: [])
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await !Net.connect(probe, timeout: 0.02))
        // Only a lower bound: busy CI should not turn this into a timing flake.
        #expect(start.duration(to: clock.now) >= .milliseconds(20))
        #expect(probe.cancels.withLock { $0 } == 1)
    }

    @Test func cancellationClosesAnInFlightConnection() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let probe = Probe(results: [], onStart: { signal.yield(); signal.finish() })
        let task = Task { await Net.connect(probe, timeout: 30) }
        for await _ in started { break }
        // Awake time only: the suspending clock stops while the Mac sleeps, so a closed lid
        // cannot use the bound up.
        let start = SuspendingClock.now
        task.cancel()
        #expect(await !task.value)
        // Well below the 30 s deadline, with ample room for a loaded test host.
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(probe.cancels.withLock { $0 } == 1)
    }

    @Test func cancellationBeforeContinuationInstallationIsSafe() async {
        let probe = Probe(results: [])
        let start = SuspendingClock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Net.connect(probe, timeout: 30)
        }
        #expect(await !task.value)
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(probe.cancels.withLock { $0 } == 1)
        #expect(probe.starts.withLock { $0 } == 0)
    }

    // This deliberately makes no assertion about internet availability.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_LIVE_NET"] == "1"))
    func liveConnectivitySmokeTest() async {
        let online = await Net.isOnline()
        print("Net live TCP probe: \(online)")
    }

    private static let bothRequests = [
        Request(host: "1.1.1.1", port: 443, timeout: 1.2),
        Request(host: "8.8.8.8", port: 443, timeout: 1.2),
    ]

    private struct Request: Equatable, Sendable {
        let host: String
        let port: UInt16
        let timeout: TimeInterval
    }

    private actor Calls {
        var requests: [Request] = []
        let results: [Bool]

        init(results: [Bool]) { self.results = results }

        nonisolated var connector: Net.Connector {
            { host, port, timeout in await self.connect(host: host, port: port, timeout: timeout) }
        }

        func connect(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
            requests.append(Request(host: host, port: port, timeout: timeout))
            return results.indices.contains(requests.count - 1) ? results[requests.count - 1] : false
        }
    }

    private final class Probe: NetProbeConnection {
        let starts = Mutex(0)
        let cancels = Mutex(0)
        let results: [Bool]
        let onStart: @Sendable () -> Void

        init(results: [Bool], onStart: @escaping @Sendable () -> Void = {}) {
            self.results = results
            self.onStart = onStart
        }

        func start(queue: DispatchQueue, completion: @escaping @Sendable (Bool) -> Void) {
            starts.withLock { $0 += 1 }
            onStart()
            for result in results { completion(result) }
        }

        func cancel() { cancels.withLock { $0 += 1 } }
    }
}
