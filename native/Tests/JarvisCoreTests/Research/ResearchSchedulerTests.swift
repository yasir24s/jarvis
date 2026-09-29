import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// M1b T10 (plan: M01b §3.5): the ResearchScheduler on virtual time, in a Sandbox. The timing
// is research_log_loop's (jarvis.py 2569–2578): the first check 90 s after start, then one
// every 3600 s; a check bumps alive_hours and snapshots only when metrics.jsonl's last line is
// not dated today. Plus the launch counter per build channel, the dev-only tick override, and
// D-37: the snapshot's corrections and history counts are CoreState's, not the files'.
//
// Opt-in: with JARVIS_RESEARCH_EXPORT_DIR set to an empty scratch directory outside the repo,
// the multi-day run copies its usage.json and metrics.jsonl there, for
// tools/research_schema_check.py (acceptance: 0 violations).

private let exportDir = ProcessInfo.processInfo.environment["JARVIS_RESEARCH_EXPORT_DIR"]
    .flatMap { $0.isEmpty ? nil : $0 }

@MainActor
@Suite("ResearchScheduler (M1b T10)")
struct ResearchSchedulerTests {
    // MARK: Timing

    @Test func firstCheckAt90SecondsThenHourly() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 4)
        try await rig.runUntilParked()

        #expect(rig.sleeper.asked == [.seconds(90)] + Array(repeating: .seconds(3600), count: 4))
        #expect(rig.lines.checks == [
            "Research check 1 at +90 s: alive_hours bumped; snapshot written for 2026-09-29",
            "Research check 2 at +3690 s: alive_hours bumped; today's row already written",
            "Research check 3 at +7290 s: alive_hours bumped; today's row already written",
            "Research check 4 at +10890 s: alive_hours bumped; today's row already written",
        ])
        #expect(described(try rig.counters("2026-09-29")) == ["starts_swift_dev=1", "alive_hours=4"])

        let rows = try rig.rows()
        try #require(rows.count == 1)
        #expect(rows[0]["date"] == .string("2026-09-29"))
        #expect(rows[0]["ts"] == .double(schedulerMorning + 90))
        #expect(rows[0]["usage_today"] == .object(JSONObject([
            .init(key: "starts_swift_dev", value: .int(1)),
            .init(key: "alive_hours", value: .int(1)),
        ])))
        #expect(rig.inputCalls.value == 1)            // D-37 counts asked for the one due row only
    }

    @Test func oneSnapshotPerLocalDayAcrossMidnight() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        // 20:00 London; 30 checks: 20:01:30 on the 29th, then hourly to 01:01:30 on 1 October.
        let rig = try SchedulerRig(root: box.root, at: schedulerEvening, budget: 30)
        try await rig.runUntilParked()

        let rows = try rig.rows()
        #expect(rows.map { $0["date"] } == [.string("2026-09-29"), .string("2026-09-30"), .string("2026-10-01")])
        // Each row is the first check of its local day.
        #expect(rows.map { $0["ts"] } == [.double(schedulerEvening + 90),
                                          .double(schedulerEvening + 90 + 4 * 3600),
                                          .double(schedulerEvening + 90 + 28 * 3600)])
        #expect(described(try rig.counters("2026-09-29")) == ["starts_swift_dev=1", "alive_hours=4"])
        #expect(described(try rig.counters("2026-09-30")) == ["alive_hours=24"])
        #expect(described(try rig.counters("2026-10-01")) == ["alive_hours=2"])
        #expect(rig.lines.checks.count == 30)
        #expect(rig.lines.checks.filter { $0.contains("snapshot written") }.count == 3)
        #expect(rig.inputCalls.value == 3)
    }

    @Test func todaysLastLineMeansNoSecondRow() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let seeded = "{\"date\": \"2026-09-28\"}\n{\"date\": \"2026-09-29\"}\n"
        try box.write("research/metrics.jsonl", seeded)
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 2)
        try await rig.runUntilParked()

        #expect(try box.read("research/metrics.jsonl") == seeded)
        #expect(rig.lines.checks.allSatisfy { $0.hasSuffix("today's row already written") })
        #expect(rig.inputCalls.value == 0)
    }

    @Test func onlyTheLastLineCountsAndTheLastRowPerDateWins() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        // A row for today that is not the last line does not count as today's row.
        try box.write("research/metrics.jsonl", "{\"date\": \"2026-09-29\"}\n{\"date\": \"2026-09-28\"}\n")
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 1)
        try await rig.runUntilParked()

        let rows = try rig.rows()
        #expect(rows.map { $0["date"] } == [.string("2026-09-29"), .string("2026-09-28"), .string("2026-09-29")])
        var lastPerDate: [String: JSONObject] = [:]
        for row in rows { if case .string(let d)? = row["date"] { lastPerDate[d] = row } }
        #expect(lastPerDate["2026-09-29"]?["ts"] == .double(schedulerMorning + 90))
        #expect(lastPerDate["2026-09-29"]?["schema"] == .int(2))
    }

    @Test func aRestartTheSameDayCountsTheLaunchButWritesNoSecondRow() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let first = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 1)
        try await first.runUntilParked()
        let second = try SchedulerRig(root: box.root, at: schedulerMorning + 7200, budget: 1)
        try await second.runUntilParked()

        #expect(try second.rows().count == 1)
        #expect(described(try second.counters("2026-09-29")) == ["starts_swift_dev=2", "alive_hours=2"])
        #expect(second.lines.checks == ["Research check 1 at +90 s: alive_hours bumped; today's row already written"])
    }

    // MARK: Launch counter and the tick override

    @Test(arguments: BuildChannel.allCases)
    func theLaunchCounterFollowsTheBuildChannel(_ build: BuildChannel) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 0, build: build)
        try await rig.runUntilParked()                // parks in the first 90 s: no check yet

        #expect(described(try rig.counters("2026-09-29")) == ["starts_swift_\(build.rawValue)=1"])
        #expect(rig.lines.all.first == "Research scheduler started (\(build.rawValue) build): "
                + "starts_swift_\(build.rawValue) bumped; first check in 90 s, then every 3600 s")
        #expect(rig.lines.checks.isEmpty)
        #expect(try rig.rows().isEmpty)
    }

    @Test func theTickOverrideSetsThePeriodInADevBuild() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 3,
                                   environment: [ResearchScheduler.tickVariable: "60"])
        #expect(rig.scheduler.interval == .seconds(60))
        try await rig.runUntilParked()

        #expect(rig.sleeper.asked == [.seconds(90), .seconds(60), .seconds(60), .seconds(60)])
        #expect(rig.lines.all.first?.hasSuffix("first check in 90 s, then every 60 s") == true)
        #expect(rig.lines.checks.map { $0.split(separator: ":")[0] } == [
            "Research check 1 at +90 s", "Research check 2 at +150 s", "Research check 3 at +210 s",
        ])
        #expect(!rig.lines.all.contains { $0.contains("ignored") })
    }

    @Test func theTickOverrideIsIgnoredInARelease() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 2, build: .release,
                                   environment: [ResearchScheduler.tickVariable: "60"])
        #expect(rig.scheduler.interval == .seconds(3600))
        try await rig.runUntilParked()

        #expect(rig.sleeper.asked == [.seconds(90), .seconds(3600), .seconds(3600)])
        #expect(rig.lines.all.contains("Research: JARVIS_RESEARCH_TICK ignored in a release build"))
        #expect(described(try rig.counters("2026-09-29")) == ["starts_swift_release=1", "alive_hours=2"])
    }

    @Test(arguments: ["0", "-60", "abc", "1.5", "", " 60"])
    func aTickOverrideThatIsNotWholePositiveSecondsIsIgnored(_ value: String) async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 0,
                                   environment: [ResearchScheduler.tickVariable: value])
        #expect(rig.scheduler.interval == .seconds(3600))
        try await rig.runUntilParked()
        #expect(rig.lines.all.contains(
            "Research: JARVIS_RESEARCH_TICK ignored: not a whole number of seconds above 0"))
    }

    @Test func withoutTheOverrideThePeriodIsAnHour() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 0,
                                   environment: ["PATH": "/usr/bin:/bin"])
        #expect(rig.scheduler.interval == ResearchScheduler.period)
        #expect(ResearchScheduler.period == .seconds(3600))
        #expect(ResearchScheduler.firstCheck == .seconds(90))
    }

    // MARK: Lifecycle

    @Test func startRunsOnceAndStopEndsTheLoop() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerMorning, budget: 1)
        rig.scheduler.start()
        rig.scheduler.start()
        try await until("the first check") { rig.sleeper.isParked }
        await rig.scheduler.stopAndWait()
        rig.scheduler.stop()

        #expect(rig.sleeper.sawCancellation)
        let asked = rig.sleeper.asked.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.sleeper.asked.count == asked)     // no sleep, so no check, after stop
        #expect(rig.lines.all.filter { $0.hasPrefix("Research scheduler started") }.count == 1)
        #expect(rig.lines.all.filter { $0 == "Research scheduler stopped" }.count == 1)
        #expect(described(try rig.counters("2026-09-29")) == ["starts_swift_dev=1", "alive_hours=1"])
    }

    // MARK: D-37

    @Test func snapshotCountsAreCoreStatesEvenWhenTheFilesSayOtherwise() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.write("history.json", Self.history(3))
        try box.write("corrections.json", Self.corrections(2, plusInvalid: true))
        let clock = ManualClock(schedulerMorning)
        let historyFile = box.paths.history.path(percentEncoded: false)
        let historyOnDisk: @Sendable () -> Int = {        // what re-reading history.json says
            guard let data = FileManager.default.contents(atPath: historyFile),
                  case .array(let turns)? = try? PyJSON.loads(data) else { return 0 }
            return turns.count
        }
        let logger = ResearchLogger(paths: ResearchPaths(box.paths),
                                    clock: ResearchClock(clock, timeZone: schedulerLondon),
                                    sources: FileSnapshotSources(here: box.root, historyTurns: historyOnDisk),
                                    runtime: { SchedulerFixtures.runtime(.dev) },
                                    git: { _, _ in "" }, host: { SchedulerFixtures.host })
        let store = try StateStore(root: box.root.path(percentEncoded: false), lease: nil, clock: clock)
        let core = CoreState(store: store, clock: clock, research: logger, frontApp: BlankFrontApp())

        await core.popTrailingUserTurn()                // memory 2 turns; the file still says 3
        let expected = await core.snapshotInputs()      // loads the corrections cache (2 pairs)
        #expect(expected.historyTurns == 2)
        #expect(expected.correctionsCount == 2)
        try box.write("history.json", Self.history(5))
        try box.write("corrections.json", Self.corrections(4, plusInvalid: false))
        let files = FileSnapshotSources(here: box.root, historyTurns: historyOnDisk)
        #expect(files.historyTurns() == 5)
        #expect(files.correctionsCount() == 4)

        let sleeper = VirtualSleeper(clock: clock, budget: 1)
        let lines = LogLines()
        let scheduler = ResearchScheduler(logger: logger, build: .dev, core: core, environment: [:],
                                          sleep: { try await sleeper.sleep($0) }, log: { lines.record($0) })
        scheduler.start()
        try await until("one check") { sleeper.isParked }
        await scheduler.stopAndWait()

        let data = try #require(FileManager.default.contents(atPath: box.paths.researchMetrics.path(percentEncoded: false)))
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n")
        try #require(rows.count == 1)
        let counts = try #require(try PyJSON.loads(Data(rows[0].utf8)).objectValue?["counts"]?.objectValue)
        #expect(counts["corrections"] == .int(Int64(expected.correctionsCount)))
        #expect(counts["history_turns"] == .int(Int64(expected.historyTurns)))
        #expect(await core.snapshotInputs() == expected)
    }

    // MARK: A text-only run, for the schema check

    @Test func aTextOnlyRunAcrossTwoMidnightsWritesSchemaTwoRows() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let rig = try SchedulerRig(root: box.root, at: schedulerEvening, budget: 30)
        // Text-chat-only operation (§3.5): a text command bumps interactions + interactions_text.
        rig.logger.bump(ResearchKey.interactions)
        rig.logger.bump(ResearchKey.interactionsText)
        try await rig.runUntilParked()

        let rows = try rig.rows()
        try #require(rows.count == 3)
        for row in rows {
            #expect(row.keys == SnapshotBuilder.schema1Keys + SnapshotBuilder.schema2Keys)
            #expect(row["schema"] == .int(2))
            let runtime = try #require(row["runtime"]?.objectValue)
            #expect(runtime["impl"] == .string("swift"))
            #expect(runtime["build"] == .string("dev"))
            #expect(runtime["voice"] == .bool(false))
        }
        #expect(described(try rig.counters("2026-09-29"))
                == ["interactions=1", "interactions_text=1", "starts_swift_dev=1", "alive_hours=4"])

        if let exportDir {
            let dir = URL(filePath: exportDir, directoryHint: .isDirectory)
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path(percentEncoded: false)
            let target = dir.standardizedFileURL.path(percentEncoded: false)
            try #require(!target.hasPrefix((home.hasSuffix("/") ? home : home + "/") + "jarvis/"),
                         "JARVIS_RESEARCH_EXPORT_DIR must be a scratch directory outside the repo")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["usage.json", "metrics.jsonl"] {      // copyItem never overwrites
                try FileManager.default.copyItem(at: rig.paths.dir.appending(path: name, directoryHint: .notDirectory),
                                                 to: dir.appending(path: name, directoryHint: .notDirectory))
            }
            print("exported: usage.json, metrics.jsonl")
        }
    }

    // MARK: Helpers

    /// history.json with `n` alternating turns, the last one a user turn when `n` is odd.
    static func history(_ n: Int) -> String {
        let turns = (0..<n).map { i in
            i % 2 == 0 ? "{\"role\": \"user\", \"content\": \"question \(i)\"}"
                       : "{\"role\": \"assistant\", \"content\": \"answer \(i)\"}"
        }
        return "[" + turns.joined(separator: ", ") + "]"
    }

    /// corrections.json with `n` valid pairs, optionally one invalid (empty "heard") after them.
    static func corrections(_ n: Int, plusInvalid: Bool) -> String {
        let names = ["Robin", "Morgan", "Sam", "Robin Sam"]
        var pairs = (0..<n).map { i in
            "{\"heard\": \"\(names[i % names.count].lowercased())x\", \"meant\": \"\(names[i % names.count])\"}"
        }
        if plusInvalid { pairs.append("{\"heard\": \"\", \"meant\": \"Sam\"}") }
        return "[" + pairs.joined(separator: ", ") + "]"
    }
}
