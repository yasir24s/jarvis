import Foundation

// Batch C part 6: AirPlay and Sidecar as a fallback ladder. Each action (audio, video, mirror,
// extend, stop) is tried on the rungs in order: Apple's private frameworks, loaded at runtime and
// never linked; a public or scriptable route; then Accessibility. A self-test on every macOS
// build change probes each rung without starting anything (classes and selectors only), marks a
// broken rung down, and writes a repair brief. JARVIS never edits or rebuilds himself.

public enum DisplayAction: String, Codable, Sendable, CaseIterable {
    case audio, video, mirror, extend, stop
}

public enum RungKind: String, Codable, Sendable, CaseIterable {
    case privateFramework = "private framework"
    case scriptable = "scriptable"
    case accessibility = "accessibility"
}

/// What a rung's probe found: the actions it can do, and for the rest what is missing.
public struct RungProbe: Codable, Sendable, Equatable {
    public var kind: RungKind
    public var covers: [DisplayAction]
    /// Missing classes, selectors or permissions, as "SidecarDisplayManager +sharedManager".
    public var missing: [String]
    public var log: [String]

    public init(kind: RungKind, covers: [DisplayAction], missing: [String] = [], log: [String] = []) {
        self.kind = kind
        self.covers = covers
        self.missing = missing
        self.log = log
    }
}

/// One rung. `probe` must be non-intrusive: load, look up, never call into a route.
public protocol DisplayRouteDriver: Sendable {
    var kind: RungKind { get }
    func probe() -> RungProbe
    /// Device names this rung can see (empty when it sees none or cannot look).
    func devices() async -> [String]
    /// Does `action` (with `device`, except for stop); true when the route reported success.
    func perform(_ action: DisplayAction, device: String?) async -> Bool
}

/// memory/display-routes.json: the last self-test.
public struct DisplayRouteState: Codable, Sendable, Equatable {
    public var osBuild: String
    public var probedAt: Double
    public var probes: [RungProbe]
    /// The rung that last did each action.
    public var lastRung: [String: RungKind] = [:]
    /// The build JARVIS last told the user about, so he says it once.
    public var announcedBuild: String?
    /// Devices the user has allowed mirroring or extending to.
    public var approved: [String] = []

    public init(osBuild: String, probedAt: Double, probes: [RungProbe]) {
        self.osBuild = osBuild
        self.probedAt = probedAt
        self.probes = probes
    }

    public func probe(_ kind: RungKind) -> RungProbe? { probes.first { $0.kind == kind } }

    public var data: Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }

    public init?(data: Data) {
        guard let s = try? JSONDecoder().decode(DisplayRouteState.self, from: data) else { return nil }
        self = s
    }
}

/// The self-test's verdict.
public struct DisplaySelfTestResult: Sendable, Equatable {
    public var state: DisplayRouteState
    /// Rungs that covered actions before and now cover fewer (or, on a first run, the private
    /// rung when it covers nothing).
    public var broken: [RungKind]
    /// What JARVIS says once per build when the private rung broke; nil otherwise.
    public var announcement: String?
    /// The repair brief, when anything broke.
    public var brief: String?
}

public enum DisplaySelfTest {
    public static let announcement = "Apple's update changed AirPlay, sir. I'm using the backup route for now."
    public static let ask = "Shall I have it repaired? Choose Repair AirPlay in the JARVIS menu when convenient."

    /// Due when there is no stored state, the build changed, or `force` (the "Check AirPlay" item).
    public static func isDue(stored: DisplayRouteState?, build: String, force: Bool) -> Bool {
        force || stored?.osBuild != build
    }

    /// Probes every rung (non-intrusively) and compares with what was stored.
    public static func run(drivers: [any DisplayRouteDriver], stored: DisplayRouteState?, build: String,
                           now: Double) -> DisplaySelfTestResult {
        let probes = drivers.map { $0.probe() }
        var state = DisplayRouteState(osBuild: build, probedAt: now, probes: probes)
        state.lastRung = stored?.lastRung ?? [:]
        state.announcedBuild = stored?.announcedBuild
        state.approved = stored?.approved ?? []
        var broken: [RungKind] = []
        for p in probes {
            if let before = stored?.probe(p.kind) {
                if !Set(before.covers).isSubset(of: Set(p.covers)) { broken.append(p.kind) }
            } else if p.kind == .privateFramework, p.covers.isEmpty {
                broken.append(p.kind)
            }
        }
        var announcement: String?
        if broken.contains(.privateFramework), state.announcedBuild != build {
            announcement = Self.announcement(for: state)
            state.announcedBuild = build
        }
        let brief = broken.isEmpty ? nil : RepairBrief.text(state: state, previous: stored, broken: broken)
        return DisplaySelfTestResult(state: state, broken: broken, announcement: announcement, brief: brief)
    }

    static func announcement(for state: DisplayRouteState) -> String {
        let backups = state.probes.filter { $0.kind != .privateFramework && !$0.covers.isEmpty }
        return backups.isEmpty ? "Apple's update changed AirPlay, sir, and I have no backup route for it at the moment."
            : Self.announcement
    }
}

/// Tries an action down the ladder, skipping rungs the last probe found unable to do it.
public struct RouteLadder: Sendable {
    public let drivers: [any DisplayRouteDriver]

    public init(drivers: [any DisplayRouteDriver]) {
        self.drivers = drivers
    }

    /// The rung that did it (nil when none could), and every rung tried, in order.
    public func perform(_ action: DisplayAction, device: String?, state: DisplayRouteState?) async
        -> (done: RungKind?, tried: [RungKind]) {
        var tried: [RungKind] = []
        for d in drivers {
            if let p = state?.probe(d.kind), !p.covers.contains(action) { continue }
            tried.append(d.kind)
            if await d.perform(action, device: device) { return (d.kind, tried) }
        }
        return (nil, tried)
    }
}

/// The brief JARVIS writes for a repair session: the build, what went missing, the probe log and
/// what the surviving rungs still cover. It goes to a Claude Code session only on the user's yes.
public enum RepairBrief {
    public static func text(state: DisplayRouteState, previous: DisplayRouteState?, broken: [RungKind]) -> String {
        var s = "# AirPlay and Sidecar repair brief\n\n"
        s += "macOS build: \(state.osBuild)" + (previous.map { " (was \($0.osBuild))" } ?? "") + "\n"
        s += "Broken rungs: \(broken.map(\.rawValue).joined(separator: ", "))\n\n"
        s += "## What went missing\n\n"
        for kind in broken {
            let p = state.probe(kind)
            let lost = Set(previous?.probe(kind)?.covers ?? DisplayAction.allCases).subtracting(p?.covers ?? [])
            s += "- \(kind.rawValue): lost \(lost.map(\.rawValue).sorted().joined(separator: ", ")); missing: "
                + ((p?.missing.isEmpty ?? true) ? "nothing reported" : p!.missing.joined(separator: "; ")) + "\n"
        }
        s += "\n## What still works\n\n"
        for action in DisplayAction.allCases {
            let rungs = state.probes.filter { $0.covers.contains(action) }.map(\.kind.rawValue)
            s += "- \(action.rawValue): " + (rungs.isEmpty ? "no rung" : rungs.joined(separator: ", ")) + "\n"
        }
        s += "\n## Probe log\n\n"
        for p in state.probes {
            for line in p.log { s += "- [\(p.kind.rawValue)] \(line)\n" }
        }
        s += """

            ## How to fix it

            Work in native/Sources/JarvisTools/Tools/Display/PrivateFrameworkRung.swift: find the classes
            or selectors that replace the missing ones on this build (load and look up only), update the
            requirements and calls, and keep every call behind its responds(to:) check. Then the normal
            path: the build lock, the three suites, verify, and a live update. Never start mirroring or
            extend from a test.

            """
        return s
    }
}
