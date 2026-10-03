import Foundation
import JarvisCore
import Synchronization

/// Batch C part 6: the ladder, its self-test and its state (memory/display-routes.json, and the
/// repair brief beside it when a rung breaks).
public final class DisplayRoutes: Sendable {
    let store: StateStore
    let ladder: RouteLadder
    let browser: any AirPlayBrowsing
    let build: @Sendable () -> String
    let clock: any JarvisClock
    let log: @Sendable (String) -> Void
    private let lock = Mutex(())

    public init(store: StateStore, drivers: [any DisplayRouteDriver] = [PrivateFrameworkRung(), ScriptableRung(), AccessibilityRung()],
                browser: any AirPlayBrowsing = BonjourAirPlayBrowser(), build: @escaping @Sendable () -> String = DisplayRoutes.osBuild,
                clock: any JarvisClock = SystemClock(),
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.store = store
        ladder = RouteLadder(drivers: drivers)
        self.browser = browser
        self.build = build
        self.clock = clock
        self.log = log
    }

    /// `kern.osversion`, e.g. "25C56".
    public static func osBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    public func state() -> DisplayRouteState? {
        store.read(.displayRoutes).flatMap(DisplayRouteState.init(data:))
    }

    func save(_ s: DisplayRouteState) {
        if !store.write(s.data, to: .displayRoutes) { log("airplay: display-routes.json not saved") }
    }

    /// The self-test, when due (first run, a new macOS build, or `force`): probes each rung
    /// without starting anything, saves the results and, when a rung broke, the repair brief.
    /// Nil when it was not due.
    @discardableResult
    public func selfTest(force: Bool = false) -> DisplaySelfTestResult? {
        lock.withLock { _ in
            let stored = state(), now = build()
            guard DisplaySelfTest.isDue(stored: stored, build: now, force: force) else { return nil }
            let result = DisplaySelfTest.run(drivers: ladder.drivers, stored: stored, build: now, now: clock.now())
            save(result.state)
            if let brief = result.brief, !store.write(Data(brief.utf8), to: .displayRepairBrief) {
                log("airplay: the repair brief was not saved")
            }
            log("airplay: self-test on \(now): " + result.state.probes.map { "\($0.kind.rawValue) covers "
                + ($0.covers.isEmpty ? "nothing" : $0.covers.map(\.rawValue).joined(separator: "/")) }.joined(separator: "; ")
                + (result.broken.isEmpty ? "" : "; broken: " + result.broken.map(\.rawValue).joined(separator: ", ")))
            return result
        }
    }

    public var repairBrief: String? {
        store.read(.displayRepairBrief).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every device name the network and the rungs report, without repeats.
    public func devices() async -> [String] {
        var names = await browser.names()
        for d in ladder.drivers { names += await d.devices() }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    func isApproved(_ device: String) -> Bool {
        state()?.approved.contains { $0.caseInsensitiveCompare(device) == .orderedSame } ?? false
    }

    func approve(_ device: String) {
        lock.withLock { _ in
            guard var s = state() else { return }
            if !s.approved.contains(where: { $0.caseInsensitiveCompare(device) == .orderedSame }) { s.approved.append(device) }
            save(s)
        }
    }

    /// Runs the ladder and records the rung that did it.
    public func perform(_ action: DisplayAction, device: String?) async -> RungKind? {
        if state() == nil { selfTest() }
        let (done, tried) = await ladder.perform(action, device: device, state: state())
        log("airplay: \(action.rawValue) tried \(tried.map(\.rawValue).joined(separator: " > ")); "
            + (done.map { "done by \($0.rawValue)" } ?? "none worked"))
        if let done {
            lock.withLock { _ in
                guard var s = state() else { return }
                s.lastRung[action.rawValue] = done
                save(s)
            }
        }
        return done
    }
}

/// `airplay_devices`.
public struct AirPlayDevices: ToolImpl {
    public static let name = "airplay_devices"
    public static let schema = ToolSchema(
        name: name,
        description: "List the AirPlay receivers (Apple TV, AirPlay speakers) and Sidecar iPads this Mac can see, by the names they announce.",
        parametersJSON: #"{"type": "object", "properties": {}, "required": []}"#)
    let routes: DisplayRoutes
    public init(routes: DisplayRoutes) { self.routes = routes }

    public func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let names = await routes.devices()
        return .text(names.isEmpty ? "I can't see any AirPlay or Sidecar devices, sir." : names.joined(separator: "\n"))
    }
}

/// `airplay_to`: audio and video need no confirmation; mirroring or extending to a device asks the
/// first time, since it shows the screen elsewhere.
public struct AirPlayTo: ToolImpl {
    public static let name = "airplay_to"
    public static let schema = ToolSchema(
        name: name,
        description: "Send to an AirPlay or Sidecar device by name (from airplay_devices). what: 'audio' (this Mac's sound), 'video' (what is playing), 'mirror' (the screen) or 'extend' (use an iPad as a second display).",
        parametersJSON: #"{"type": "object", "properties": {"device": {"type": "string"}, "what": {"type": "string", "enum": ["audio", "video", "mirror", "extend"]}}, "required": ["device", "what"]}"#)
    let routes: DisplayRoutes
    public init(routes: DisplayRoutes) { self.routes = routes }

    public static func spoken(_ action: DisplayAction, _ device: String) -> String {
        switch action {
        case .extend: "Extending the display to \(device), sir."
        case .mirror: "Mirroring the screen to \(device), sir."
        default: "Sending it to \(device), sir."
        }
    }

    public func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let raw = (args["device"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let action = DisplayAction(rawValue: args["what"]?.stringValue ?? ""), action != .stop else {
            return .text("Error: give a device and what to send (audio, video, mirror or extend).")
        }
        let known = await routes.devices()
        guard let device = known.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame })
                ?? known.first(where: { $0.localizedCaseInsensitiveContains(raw) }) else {
            return .text("I can't see a device called \(raw), sir." + (known.isEmpty ? "" : " I can see: \(known.joined(separator: ", "))."))
        }
        let routes = routes
        let go: @Sendable () async -> String = {
            guard let rung = await routes.perform(action, device: device) else {
                return "I couldn't reach \(device), sir: no route worked."
            }
            if action == .mirror || action == .extend { routes.approve(device) }
            return Self.spoken(action, device) + (rung == .privateFramework ? "" : " (by the \(rung.rawValue) route)")
        }
        if (action == .mirror || action == .extend) && !routes.isApproved(device) {
            return .needsConfirmation(desc: "\(action == .mirror ? "Mirror your screen" : "Extend your display") to \(device)",
                                      action: { await go() })
        }
        return .text(await go())
    }
}

/// `airplay_stop`.
public struct AirPlayStop: ToolImpl {
    public static let name = "airplay_stop"
    public static let schema = ToolSchema(
        name: name,
        description: "Stop AirPlay audio, video, mirroring and Sidecar, bringing everything back to this Mac.",
        parametersJSON: #"{"type": "object", "properties": {}, "required": []}"#)
    let routes: DisplayRoutes
    public init(routes: DisplayRoutes) { self.routes = routes }

    public func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(await routes.perform(.stop, device: nil) != nil ? "Everything's back on this Mac, sir." : "Nothing was being sent anywhere, sir.")
    }
}
