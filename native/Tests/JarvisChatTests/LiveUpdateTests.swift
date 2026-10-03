import Foundation
import JarvisCore
import JarvisChat
import Synchronization
import Testing

/// Live updates (U1, D-58): the never-during-use rule as a pure function, and the watcher that
/// asks it, on a fake dist folder with a `ManualClock`. No app, window or timer runs here.
@Suite("U1 live-update rule and watcher", .timeLimit(.minutes(1)))
@MainActor
struct LiveUpdateTests {
    typealias Signals = UpdateRule.Signals

    static func idle(lastUse: Double) -> Signals {
        Signals(turnInFlight: false, speechActive: false, confirmationPending: false, lastUse: lastUse)
    }

    // MARK: - The rule

    @Test("a swap needs 10 quiet minutes after the last use, and nothing running")
    func quietMinutes() {
        let t0 = 1_000_000.0
        #expect(UpdateRule.quietSeconds == 600)
        #expect(UpdateRule.verdict(Self.idle(lastUse: t0), now: t0 + 600, updateNow: false) == .swap)
        #expect(UpdateRule.verdict(Self.idle(lastUse: t0), now: t0 + 3600, updateNow: false) == .swap)
        #expect(UpdateRule.verdict(Self.idle(lastUse: t0), now: t0 + 599, updateNow: false)
                == .wait(.recentUse(secondsLeft: 1)))
        #expect(UpdateRule.verdict(Self.idle(lastUse: t0), now: t0, updateNow: false)
                == .wait(.recentUse(secondsLeft: 600)))
        // A clock that went backwards is recent use, never a swap.
        #expect(UpdateRule.verdict(Self.idle(lastUse: t0), now: t0 - 50, updateNow: false)
                == .wait(.recentUse(secondsLeft: 600)))
    }

    @Test("a turn, speech or a pending confirmation holds the swap back, even after hours of quiet")
    func activeWorkHolds() {
        let t0 = 1_000_000.0, later = t0 + 7200
        var s = Self.idle(lastUse: t0)
        s.turnInFlight = true
        #expect(UpdateRule.verdict(s, now: later, updateNow: false) == .wait(.turnInFlight))
        s = Self.idle(lastUse: t0)
        s.speechActive = true
        #expect(UpdateRule.verdict(s, now: later, updateNow: false) == .wait(.speaking))
        s = Self.idle(lastUse: t0)
        s.confirmationPending = true
        #expect(UpdateRule.verdict(s, now: later, updateNow: false) == .wait(.confirmationPending))
        // The order the rule checks: the turn, then speech, then the confirmation.
        let all = Signals(turnInFlight: true, speechActive: true, confirmationPending: true, lastUse: t0)
        #expect(UpdateRule.verdict(all, now: later, updateNow: true) == .wait(.turnInFlight))
    }

    @Test("Update Now skips the 10 minutes but still waits for the turn, speech and confirmation")
    func updateNow() {
        let t0 = 1_000_000.0
        #expect(UpdateRule.verdict(Self.idle(lastUse: t0), now: t0 + 1, updateNow: true) == .swap)
        for hold in [UpdateRule.Hold.turnInFlight, .speaking, .confirmationPending] {
            var s = Self.idle(lastUse: t0)
            switch hold {
            case .turnInFlight: s.turnInFlight = true
            case .speaking: s.speechActive = true
            default: s.confirmationPending = true
            }
            #expect(UpdateRule.verdict(s, now: t0 + 1, updateNow: true) == .wait(hold))
        }
    }

    // MARK: - Builds and folders

    @Test("version.json gives the build id; a missing or broken one gives none")
    func buildID() throws {
        let fake = try UpdateScriptTests.FakeDist()
        defer { fake.remove() }
        let url = fake.url("version.json")
        try Data(#"{"commit": "abc1234", "dirty": true, "built": "2026-10-01T21:30:00Z"}"#.utf8).write(to: url)
        let id = try #require(BuildID.read(url))
        #expect(id == BuildID(commit: "abc1234", dirty: true, built: "2026-10-01T21:30:00Z"))
        #expect(id.label == "abc1234+dirty 2026-10-01T21:30:00Z")
        #expect(BuildID(commit: "abc1234", dirty: false, built: "x").label == "abc1234 x")
        try Data("{".utf8).write(to: url)
        #expect(BuildID.read(url) == nil)
        #expect(BuildID.read(fake.url("missing.json")) == nil)
        // Under swift test the main bundle is the runner, which carries no version.json.
        #expect(BuildID.running() == nil)
    }

    @Test("only a dist/JARVIS.app bundle with its update helper watches for builds")
    func foldersOfBundle() throws {
        let fake = try UpdateScriptTests.FakeDist()
        defer { fake.remove() }
        try fake.bundle("JARVIS.app", name: "current")
        #expect(UpdateFolders.of(bundle: fake.url("JARVIS.app")) == nil, "no helper, no self-update")
        let helper = fake.url("JARVIS.app").appending(path: UpdateFolders.helperPath)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path(percentEncoded: false))
        let folders = try #require(UpdateFolders.of(bundle: fake.url("JARVIS.app")))
        #expect(folders.dist.standardizedFileURL == fake.dist.standardizedFileURL)
        #expect(folders.stagedApp.path(percentEncoded: false).hasSuffix("/dist/staged/JARVIS.app/"))
        #expect(UpdateFolders.of(bundle: Bundle.main.bundleURL) == nil, "the test runner never updates")
        // A stage counts only once its version.json is there.
        #expect(folders.staged() == nil)
        try fake.bundle("staged/JARVIS.app", name: "new", version: false)
        #expect(folders.staged() == nil)
        try fake.bundle("staged/JARVIS.app", name: "new")
        #expect(folders.staged()?.commit == "new")
    }

    // MARK: - The watcher

    /// A fake dist with a running bundle, the signals the test sets, and the swaps it saw.
    @MainActor
    final class Rig {
        let fake: UpdateScriptTests.FakeDist
        let clock = ManualClock(1_000_000)
        var signals: Signals
        var swaps: [BuildID] = []
        let lines = LogLines()
        let watcher: UpdateWatcher

        init() throws {
            fake = try UpdateScriptTests.FakeDist()
            try fake.bundle("JARVIS.app", name: "current")
            signals = LiveUpdateTests.idle(lastUse: clock.now())
            let lines = self.lines
            watcher = UpdateWatcher(folders: UpdateFolders(dist: fake.dist), clock: clock,
                                    runningBundleID: AppIdentity.bundleID, log: { lines.append($0) })
        }

        /// Starts the watcher with a poll that never fires, so only `check()` looks.
        func start() {
            watcher.start(signals: { [unowned self] in self.signals },
                          swap: { [unowned self] build in self.swaps.append(build) },
                          sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        }

        func stage(_ name: String, bundleID: String? = AppIdentity.bundleID) throws {
            try fake.bundle("staged/JARVIS.app", name: name, bundleID: bundleID)
        }
    }

    @Test("a staged build under another bundle ID is never swapped in: manual install needed")
    func watcherRefusesAnotherBundleID() throws {
        let rig = try Rig()
        defer { rig.watcher.stop(); rig.fake.remove() }
        rig.start()
        try rig.stage("moved", bundleID: AppIdentity.legacyBundleID)
        #expect(UpdateFolders(dist: rig.fake.dist).stagedBundleID() == AppIdentity.legacyBundleID)
        rig.watcher.check()
        rig.watcher.updateNow()   // nothing is ready, so Update Now does nothing
        rig.clock.advance(3600)
        rig.watcher.check()
        #expect(rig.watcher.ready == nil)
        #expect(!rig.watcher.updateNowRequested)
        #expect(!rig.watcher.swapping)
        #expect(rig.swaps.isEmpty)
        let refusals = rig.lines.all.filter { $0.hasSuffix("manual install needed") }
        #expect(refusals == ["update: build moved 2026-10-01T00:00:00Z has bundle ID \(AppIdentity.legacyBundleID), "
                             + "not this app's \(AppIdentity.bundleID); not swapping, manual install needed"])
        // A build under this app's own ID, staged over it, is taken up as usual.
        try FileManager.default.removeItem(at: rig.fake.url("staged"))
        try rig.stage("fixed")
        rig.watcher.check()
        #expect(rig.watcher.ready?.commit == "fixed")
        rig.clock.advance(600)
        rig.watcher.check()
        #expect(rig.swaps.map(\.commit) == ["fixed"])
    }

    @Test("a staged build with no Info.plist is refused too")
    func watcherRefusesAMissingBundleID() throws {
        let rig = try Rig()
        defer { rig.watcher.stop(); rig.fake.remove() }
        rig.start()
        try rig.stage("bare", bundleID: nil)
        rig.clock.advance(3600)
        rig.watcher.check()
        #expect(rig.watcher.ready == nil && rig.swaps.isEmpty)
        #expect(rig.lines.all.contains { $0.contains("has bundle ID none") && $0.hasSuffix("manual install needed") })
    }

    @Test("a staged build is shown as ready, and swapped to once 10 quiet minutes have passed")
    func watcherSwapsWhenQuiet() throws {
        let rig = try Rig()
        defer { rig.watcher.stop(); rig.fake.remove() }
        rig.start()
        #expect(rig.watcher.ready == nil)
        try rig.stage("new")
        rig.watcher.check()
        #expect(rig.watcher.ready?.commit == "new")
        #expect(rig.watcher.hold == .recentUse(secondsLeft: 600))
        rig.clock.advance(599)
        rig.watcher.check()
        #expect(rig.swaps.isEmpty)
        rig.clock.advance(1)
        rig.watcher.check()
        #expect(rig.swaps.map(\.commit) == ["new"])
        #expect(rig.watcher.swapping)
        // Once begun, nothing is asked again and nothing swaps twice.
        rig.watcher.check()
        #expect(rig.swaps.count == 1)
        #expect(rig.lines.all.contains("update: swapping to new 2026-10-01T00:00:00Z"))
    }

    @Test("use during the wait restarts the 10 minutes; a turn or speech holds it past them")
    func watcherWaitsForUse() throws {
        let rig = try Rig()
        defer { rig.watcher.stop(); rig.fake.remove() }
        try rig.stage("new")
        rig.start()
        rig.clock.advance(500)
        rig.signals.lastUse = rig.clock.now()   // the user typed
        rig.clock.advance(500)
        rig.watcher.check()
        #expect(rig.swaps.isEmpty)
        #expect(rig.watcher.hold == .recentUse(secondsLeft: 100))
        rig.clock.advance(200)
        rig.signals.turnInFlight = true
        rig.watcher.check()
        #expect(rig.swaps.isEmpty)
        #expect(rig.watcher.hold == .turnInFlight)
        rig.signals.turnInFlight = false
        rig.signals.speechActive = true
        rig.watcher.check()
        #expect(rig.watcher.hold == .speaking)
        rig.signals.speechActive = false
        rig.signals.confirmationPending = true
        rig.watcher.check()
        #expect(rig.watcher.hold == .confirmationPending)
        #expect(rig.swaps.isEmpty)
        rig.signals.confirmationPending = false
        rig.watcher.check()
        #expect(rig.swaps.count == 1)
    }

    @Test("Update Now swaps at once when JARVIS is free, and waits while he speaks")
    func watcherUpdateNow() throws {
        let rig = try Rig()
        defer { rig.watcher.stop(); rig.fake.remove() }
        try rig.stage("new")
        rig.start()
        rig.signals.speechActive = true
        rig.watcher.updateNow()
        #expect(rig.watcher.updateNowRequested)
        #expect(rig.watcher.hold == .speaking)
        #expect(rig.swaps.isEmpty)
        rig.clock.advance(5)
        rig.signals.speechActive = false
        rig.watcher.check()
        #expect(rig.swaps.map(\.commit) == ["new"], "5 s after use, but Update Now skips the 10 minutes")
    }

    @Test("Update Now does nothing without a staged build, and a build that goes away clears it")
    func watcherBuildGoesAway() throws {
        let rig = try Rig()
        defer { rig.watcher.stop(); rig.fake.remove() }
        rig.start()
        rig.watcher.updateNow()
        #expect(!rig.watcher.updateNowRequested)
        try rig.stage("new")
        rig.signals.turnInFlight = true
        rig.watcher.check()
        rig.watcher.updateNow()
        #expect(rig.watcher.updateNowRequested)
        try FileManager.default.removeItem(at: rig.fake.url("staged/version.json"))
        rig.watcher.check()
        #expect(rig.watcher.ready == nil)
        #expect(!rig.watcher.updateNowRequested)
        rig.signals.turnInFlight = false
        rig.watcher.check()
        #expect(rig.swaps.isEmpty)
    }

    @Test("the folder watch notices a new stage without waiting for the poll")
    func watcherFolderEvent() async throws {
        let rig = try Rig()
        defer { rig.watcher.stop(); rig.fake.remove() }
        try FileManager.default.createDirectory(at: rig.fake.url("staged"), withIntermediateDirectories: true)
        rig.start()   // arms the watch on dist/staged/; the poll sleeps for an hour
        #expect(rig.watcher.ready == nil)
        try rig.stage("new")
        #expect(await eventually { rig.watcher.ready?.commit == "new" })
    }

    @Test("a watcher with no folders never sees a build")
    func watcherWithoutFolders() {
        let swapped = Mutex(false)
        let watcher = UpdateWatcher(folders: nil)
        watcher.start(signals: { Self.idle(lastUse: 0) }, swap: { _ in swapped.withLock { $0 = true } })
        watcher.check()
        watcher.updateNow()
        #expect(watcher.ready == nil && !watcher.swapping && !swapped.withLock { $0 })
    }

    // MARK: - The chat's signal

    @Test("typing and sending stamp the chat's lastUse with its clock")
    func chatLastUse() {
        let clock = ManualClock(500)
        let model = ChatViewModel(minimumGap: .zero, clock: clock)
        #expect(model.lastUse == nil)
        model.noteTyping()
        #expect(model.lastUse == 500)
        clock.advance(30)
        model.draft.text = "hello"
        _ = model.send()   // not connected: nothing is sent, but the user pressed Return
        #expect(model.lastUse == 530)
        clock.advance(5)
        _ = model.confirmPending()
        #expect(model.lastUse == 535)
    }
}

/// Log lines a test collects from a `@Sendable` log closure.
final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}
