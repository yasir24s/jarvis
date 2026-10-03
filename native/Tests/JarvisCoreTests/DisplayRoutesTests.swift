import Foundation
import JarvisCore
import Synchronization
import Testing

/// Batch C part 6: the ladder order, OS-change detection, the self-test and the repair brief, with
/// fake rungs only. No real device is touched.
@Suite("Batch C display routes")
struct DisplayRoutesTests {
    final class Rung: DisplayRouteDriver, @unchecked Sendable {
        let kind: RungKind
        var covers: [DisplayAction]
        var missing: [String] = []
        var succeeds: Bool
        private(set) var performed: [DisplayAction] = []
        init(_ kind: RungKind, covers: [DisplayAction], succeeds: Bool = true) {
            self.kind = kind
            self.covers = covers
            self.succeeds = succeeds
        }
        func probe() -> RungProbe { RungProbe(kind: kind, covers: covers, missing: missing, log: ["probe of \(kind.rawValue)"]) }
        func devices() async -> [String] { [] }
        func perform(_ action: DisplayAction, device: String?) async -> Bool {
            performed.append(action)
            return succeeds
        }
    }

    static func rungs() -> (Rung, Rung, Rung) {
        (Rung(.privateFramework, covers: DisplayAction.allCases), Rung(.scriptable, covers: [.audio, .stop]),
         Rung(.accessibility, covers: [.mirror, .extend, .stop]))
    }

    @Test("the self-test is due on the first run, on a new build and when forced")
    func due() {
        let s = DisplayRouteState(osBuild: "25C56", probedAt: 0, probes: [])
        #expect(DisplaySelfTest.isDue(stored: nil, build: "25C56", force: false))
        #expect(!DisplaySelfTest.isDue(stored: s, build: "25C56", force: false))
        #expect(DisplaySelfTest.isDue(stored: s, build: "25D10", force: false))
        #expect(DisplaySelfTest.isDue(stored: s, build: "25C56", force: true))
    }

    @Test("a healthy first run breaks nothing and says nothing")
    func healthy() {
        let (a, b, c) = Self.rungs()
        let r = DisplaySelfTest.run(drivers: [a, b, c], stored: nil, build: "25C56", now: 1)
        #expect(r.broken.isEmpty && r.announcement == nil && r.brief == nil)
        #expect(r.state.probe(.privateFramework)?.covers == DisplayAction.allCases)
    }

    @Test("an update that removes a selector marks the private rung broken, says so once, and writes the brief")
    func broken() {
        let (a, b, c) = Self.rungs()
        let first = DisplaySelfTest.run(drivers: [a, b, c], stored: nil, build: "25C56", now: 1).state
        a.covers = [.audio, .video, .mirror, .stop]
        a.missing = ["SidecarDisplayManager connectToDevice:completion:"]
        let r = DisplaySelfTest.run(drivers: [a, b, c], stored: first, build: "25D10", now: 2)
        #expect(r.broken == [.privateFramework])
        #expect(r.announcement == DisplaySelfTest.announcement)
        let brief = try! #require(r.brief)
        #expect(brief.contains("macOS build: 25D10 (was 25C56)"))
        #expect(brief.contains("private framework: lost extend; missing: SidecarDisplayManager connectToDevice:completion:"))
        #expect(brief.contains("- extend: accessibility"))
        #expect(brief.contains("[private framework] probe of private framework"))
        // The same build again (forced): broken against the stored state? No: it already lacks extend.
        let again = DisplaySelfTest.run(drivers: [a, b, c], stored: r.state, build: "25D10", now: 3)
        #expect(again.broken.isEmpty && again.announcement == nil)
        // Broken again on a later build but already announced for that build: silent.
        var announced = first
        announced.announcedBuild = "25D10"
        #expect(DisplaySelfTest.run(drivers: [a, b, c], stored: announced, build: "25D10", now: 4).announcement == nil)
    }

    @Test("with no backup rung the announcement says so")
    func noBackup() {
        let a = Rung(.privateFramework, covers: [])
        let r = DisplaySelfTest.run(drivers: [a, Rung(.scriptable, covers: [])], stored: nil, build: "x", now: 0)
        #expect(r.announcement?.contains("no backup route") == true)
    }

    @Test("the ladder: in order, skipping rungs the probe found unable, falling through failures")
    func ladder() async {
        let (a, b, c) = Self.rungs()
        a.succeeds = false
        let state = DisplaySelfTest.run(drivers: [a, b, c], stored: nil, build: "x", now: 0).state
        let ladder = RouteLadder(drivers: [a, b, c])
        let mirror = await ladder.perform(.mirror, device: "Living Room", state: state)
        #expect(mirror.done == .accessibility && mirror.tried == [.privateFramework, .accessibility])   // scriptable skipped
        let audio = await ladder.perform(.audio, device: "Living Room", state: state)
        #expect(audio.done == .scriptable && audio.tried == [.privateFramework, .scriptable])
        b.succeeds = false
        c.succeeds = false
        let stop = await ladder.perform(.stop, device: nil, state: state)
        #expect(stop.done == nil && stop.tried == [.privateFramework, .scriptable, .accessibility])
    }

    @Test("the state round-trips")
    func state() {
        var s = DisplayRouteState(osBuild: "25C56", probedAt: 5, probes: [RungProbe(kind: .scriptable, covers: [.audio])])
        s.lastRung["audio"] = .scriptable
        s.approved = ["Invented iPad"]
        #expect(DisplayRouteState(data: s.data) == s)
    }
}
