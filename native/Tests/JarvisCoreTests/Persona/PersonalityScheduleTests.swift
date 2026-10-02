import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// PersonalitySchedule (P1 piece 3): proactive_loop's timing (jarvis.py 2535-2567), first
/// pass 120 s after start and then every 3600 s, in virtual time (VirtualSleeper), and stop().
/// Serialized: the two slow-sink tests each hold a thread for 200 ms, and run one at a time.
@Suite("Personality schedule: consolidation 120 s after start, then hourly", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct PersonalityScheduleTests {
    static let t0: Double = 1_790_582_400

    /// Every pass, with the virtual time it ran at.
    final class Passes: Sendable {
        private let at = Mutex<[Double]>([])
        func add(_ t: Double) { at.withLock { $0.append(t) } }
        var all: [Double] { at.withLock { $0 } }
    }

    @Test func firstPassAt120SecondsThenHourlyUntilStopped() async throws {
        let clock = ManualClock(Self.t0)
        let sleeper = VirtualSleeper(clock: clock, budget: 4)
        let passes = Passes()
        let logs = LogLines()
        let schedule = PersonalitySchedule(consolidate: { passes.add(clock.now()) }, clock: clock,
                                           sleep: { try await sleeper.sleep($0) }, log: logs.record)

        schedule.start()
        defer { schedule.stop() }
        try await until("four passes and the fifth sleep") { sleeper.isParked }

        #expect(sleeper.asked == [.seconds(120), .seconds(3600), .seconds(3600), .seconds(3600), .seconds(3600)])
        #expect(passes.all == [120, 3720, 7320, 10920].map { Self.t0 + $0 })
        schedule.stop()
        try await until("the loop to end after stop()") { sleeper.released }
        #expect(sleeper.sawCancellation)
        #expect(passes.all.count == 4)
        #expect(logs.all == [
            "Personality schedule started: first consolidation check in 120 s, then every 3600 s",
            "Personality consolidation check 1 at +120 s",
            "Personality consolidation check 2 at +3720 s",
            "Personality consolidation check 3 at +7320 s",
            "Personality consolidation check 4 at +10920 s",
            "Personality schedule stopped",
        ])
    }

    /// Stopped before the first pass (quit within two minutes of launch): no pass ever runs.
    /// A stopped schedule does not start again, and a second start() does nothing.
    @Test func stopBeforeTheFirstPassRunsNone() async throws {
        let clock = ManualClock(Self.t0)
        let sleeper = VirtualSleeper(clock: clock, budget: 0)
        let passes = Passes()
        let logs = LogLines()
        let schedule = PersonalitySchedule(consolidate: { passes.add(clock.now()) }, clock: clock,
                                           sleep: { try await sleeper.sleep($0) }, log: logs.record)

        schedule.start()
        schedule.start()
        try await until("the first sleep") { sleeper.isParked }
        schedule.stop()
        try await until("the loop to end after stop()") { sleeper.released }
        schedule.start()
        schedule.stop()

        #expect(sleeper.asked == [.seconds(120)])
        #expect(passes.all.isEmpty)
        #expect(logs.all.filter { $0.hasPrefix("Personality schedule started") }.count == 1)
        #expect(logs.all.filter { $0 == "Personality schedule stopped" }.count == 1)
    }

    static let startedLine = "Personality schedule started: first consolidation check in 120 s, then every 3600 s"

    /// A log sink that takes 200 ms over the "started" line before it records it, as a slow disk
    /// would. A loop task that already exists runs ahead of the line in that time. `entered`
    /// notes the moment the sink has the line.
    static func sinkSlowOnTheStartLine(_ lines: LogLines, entered: LogLines = LogLines()) -> @Sendable (String) -> Void {
        { line in
            if line.hasPrefix("Personality schedule started") {
                entered.record("the sink has the started line")
                Thread.sleep(forTimeInterval: 0.2)
            }
            lines.record(line)
        }
    }

    /// The "started" line is logged before the loop's task exists, so the first check's line
    /// cannot come ahead of it, however slow the sink. Before the fix it could: the task was made
    /// first and the line logged after the lock was released. start() runs off the main actor,
    /// so the sink's 200 ms does not hold it.
    @Test func startedLineComesBeforeTheFirstCheckLineWithASlowSink() async throws {
        let clock = ManualClock(Self.t0)
        let sleeper = VirtualSleeper(clock: clock, budget: 1)
        let lines = LogLines()
        let schedule = PersonalitySchedule(consolidate: {}, clock: clock, sleep: { try await sleeper.sleep($0) },
                                           log: Self.sinkSlowOnTheStartLine(lines))
        await Task.detached { schedule.start() }.value
        defer { schedule.stop() }
        try await until("the first check and the second sleep") { sleeper.isParked }
        try await until("both lines") { lines.all.count >= 2 }
        #expect(Array(lines.all.prefix(2)) == [Self.startedLine, "Personality consolidation check 1 at +120 s"],
                "got \(lines.all)")
    }

    /// stop() waits for the lock start() holds while it logs, so "stopped" cannot come before
    /// "started" even with a slow sink. Before the fix the lock was free by then and stop() logged
    /// at once. Both calls run off the main actor: the 200 ms in the sink is the only gap between
    /// them.
    @Test func stoppedLineComesAfterTheStartedLineWithASlowSink() async throws {
        let clock = ManualClock(Self.t0)
        let sleeper = VirtualSleeper(clock: clock, budget: 0)
        let lines = LogLines(), entered = LogLines()
        let schedule = PersonalitySchedule(consolidate: {}, clock: clock, sleep: { try await sleeper.sleep($0) },
                                           log: Self.sinkSlowOnTheStartLine(lines, entered: entered))
        let starter = Task.detached { schedule.start() }
        let stopper = Task.detached {
            for _ in 0..<5_000 where entered.all.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
            schedule.stop()
        }
        await starter.value
        await stopper.value
        try await until("the loop to end after stop()") { sleeper.released }
        #expect(lines.all == [Self.startedLine, "Personality schedule stopped"], "got \(lines.all)")
    }

    /// stop() while a pass waits on its writer cancels the pass too.
    @Test func stopCancelsAPassInFlight() async throws {
        let clock = ManualClock(Self.t0)
        let sleeper = VirtualSleeper(clock: clock, budget: 1)
        let entered = Passes(), cancelled = Passes()
        let schedule = PersonalitySchedule(consolidate: {
            entered.add(clock.now())
            do {
                try await Task.sleep(for: .seconds(60), clock: .suspending)
            } catch {
                cancelled.add(clock.now())
            }
        }, clock: clock, sleep: { try await sleeper.sleep($0) }, log: { _ in })

        schedule.start()
        try await until("the first pass to start") { !entered.all.isEmpty }
        schedule.stop()
        try await until("the pass to see the cancellation") { !cancelled.all.isEmpty }
        #expect(entered.all == [Self.t0 + 120])
    }

    /// A dismissal's distillation runs only while the schedule runs, in the background (the
    /// call returns while it is still going), and stop() cancels one in flight.
    @Test func conversationEndedDistillsOnlyWhileRunning() async throws {
        let clock = ManualClock(Self.t0)
        let sleeper = VirtualSleeper(clock: clock, budget: 0)
        let entered = Passes(), cancelled = Passes()
        let schedule = PersonalitySchedule(consolidate: {}, distill: {
            entered.add(clock.now())
            do {
                try await Task.sleep(for: .seconds(60), clock: .suspending)
            } catch {
                cancelled.add(clock.now())
            }
        }, clock: clock, sleep: { try await sleeper.sleep($0) }, log: { _ in })

        schedule.conversationEnded()                      // before start(): nothing
        schedule.start()
        schedule.conversationEnded()                      // returns at once
        #expect(cancelled.all.isEmpty)
        try await until("the distillation to start") { entered.all.count == 1 }
        schedule.stop()
        try await until("the distillation to see the cancellation") { cancelled.all.count == 1 }
        schedule.conversationEnded()                      // after stop(): nothing
        try await Task.sleep(for: .milliseconds(20))
        #expect(entered.all.count == 1)
    }

    /// Through CoreState: the first pass consolidates a due file (one writer call, one
    /// personality_consolidations bump); the later passes find it not due and call nothing.
    @Test func passesRunCoreStatesConsolidation() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let notes = (0..<12).map { i in
            JSONValue.object(JSONObject([.init(key: "note", value: .string("Synthetic style note \(i) here")),
                                         .init(key: "added", value: .double(1_780_000_000 + Double(i)))]))
        }
        let p = JSONObject([.init(key: "core", value: .array([.string("Synthetic trait.")])),
                            .init(key: "learned", value: .array(notes))])
        try sb.write("personality.json", PyJSON.dumps(.object(p), indent: 1))
        let clock = ManualClock(Self.t0)
        let counter = RecordingCounter()
        let core = CoreState(store: try StateStore(root: sb.root.path(percentEncoded: false), lease: nil, clock: clock),
                             clock: clock, research: counter, frontApp: BlankFrontApp())
        let llm = CannedLLM(core: core)
        llm.arm(reply: "Merged style note one\nMerged style note two", fail: false, during: nil)
        let sleeper = VirtualSleeper(clock: clock, budget: 3)
        let schedule = PersonalitySchedule(core: core, writer: llm, clock: clock,
                                           sleep: { try await sleeper.sleep($0) }, log: { _ in })

        schedule.start()
        defer { schedule.stop() }
        try await until("three passes") { sleeper.isParked }
        schedule.stop()
        try await until("the loop to end after stop()") { sleeper.released }

        #expect(llm.requests.map(\.system) == [PersonaDistill.consolidateSystem])
        #expect(counter.bumps.map(\.description) == ["personality_consolidations+1"])
        let saved = try #require(PyJSON.loads(Data(try sb.read("personality.json").utf8)).objectValue)
        #expect(saved["learned"]?.arrayValue?.compactMap { $0.objectValue?["note"]?.stringValue }
            == ["Merged style note one", "Merged style note two"])
        #expect(saved["consolidated_at"] == .double(Self.t0 + 120))
    }
}
