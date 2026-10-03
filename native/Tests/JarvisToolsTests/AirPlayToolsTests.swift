import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// Batch C part 6: the AirPlay tools and the private rung's probe, with fake rungs, a fake browser
/// and a fake class lookup, in a temp state folder. Nothing starts mirroring or extend, and no
/// device or private framework is called.
@Suite("Batch C AirPlay tools", .timeLimit(.minutes(1)))
struct AirPlayToolsTests {
    final class Rung: DisplayRouteDriver, @unchecked Sendable {
        let kind: RungKind
        let covers: [DisplayAction]
        let names: [String]
        private let lock = NSLock()
        private var _done: [String] = []
        var done: [String] { lock.withLock { _done } }
        init(_ kind: RungKind, covers: [DisplayAction], names: [String] = []) {
            self.kind = kind
            self.covers = covers
            self.names = names
        }
        func probe() -> RungProbe { RungProbe(kind: kind, covers: covers) }
        func devices() async -> [String] { names }
        func perform(_ action: DisplayAction, device: String?) async -> Bool {
            lock.withLock { _done.append("\(action.rawValue) \(device ?? "-")") }
            return true
        }
    }

    struct Browser: AirPlayBrowsing {
        func names() async -> [String] { ["Living Room", "Kitchen Speaker"] }
    }

    struct Rig {
        let root: URL
        let store: StateStore
        let routes: DisplayRoutes
        let rung = Rung(.privateFramework, covers: DisplayAction.allCases, names: ["Invented iPad", "living room"])
        let gate = ConfirmationGate()
        let gateway: ToolGateway

        init() async throws {
            gateway = ToolGateway(confirmationGate: gate, log: { _ in })
            root = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-airplay-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try StateStore(root: root.path(percentEncoded: false), lease: nil)
            routes = DisplayRoutes(store: store, drivers: [rung], browser: Browser(), build: { "25C56" }, log: { _ in })
            await gateway.register(AirPlayDevices(routes: routes))
            await gateway.register(AirPlayTo(routes: routes))
            await gateway.register(AirPlayStop(routes: routes))
        }

        func call(_ name: String, _ members: [(String, JSONValue)] = []) async -> ToolCallResult {
            await gateway.call(name, JSONObject(members.map { .init(key: $0.0, value: $0.1) }),
                               turn: TurnContext(channel: .text), origin: .model(.claude))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("devices: the network's and the rungs', without repeats")
    func devices() async throws {
        let rig = try await Rig()
        defer { rig.remove() }
        #expect(await rig.call(AirPlayDevices.name).text == "Living Room\nKitchen Speaker\nInvented iPad")
    }

    @Test("audio goes at once; mirroring asks the first time per device, then not again")
    func confirmation() async throws {
        let rig = try await Rig()
        defer { rig.remove() }
        #expect(await rig.call(AirPlayTo.name, [("device", .string("living")), ("what", .string("audio"))]).text
                == "Sending it to Living Room, sir.")
        let first = await rig.call(AirPlayTo.name, [("device", .string("Invented iPad")), ("what", .string("extend"))])
        #expect(!rig.rung.done.contains("extend Invented iPad"))   // waiting for the user
        #expect(first.text.contains("Extend your display to Invented iPad"))
        #expect(await rig.gate.pending != nil)
        guard case .handled = await rig.gate.consume("confirm", via: .voice, runIn: TurnContext(channel: .voice)) else {
            Issue.record("the confirmation was not handled"); return
        }
        #expect(rig.routes.state()?.approved == ["Invented iPad"])
        let second = await rig.call(AirPlayTo.name, [("device", .string("invented ipad")), ("what", .string("extend"))])
        #expect(second.text == "Extending the display to Invented iPad, sir.")
        #expect(rig.rung.done == ["audio Living Room", "extend Invented iPad", "extend Invented iPad"])
        #expect(rig.routes.state()?.lastRung["extend"] == .privateFramework)
    }

    @Test("an unknown device is refused with the names JARVIS can see")
    func unknown() async throws {
        let rig = try await Rig()
        defer { rig.remove() }
        let r = await rig.call(AirPlayTo.name, [("device", .string("Bedroom")), ("what", .string("audio"))])
        #expect(r.text.hasPrefix("I can't see a device called Bedroom, sir. I can see: Living Room"))
        #expect(rig.rung.done.isEmpty)
    }

    @Test("stop, and the self-test writes its state once per build")
    func stopAndSelfTest() async throws {
        let rig = try await Rig()
        defer { rig.remove() }
        #expect(await rig.call(AirPlayStop.name).text == "Everything's back on this Mac, sir.")
        #expect(rig.routes.state()?.osBuild == "25C56")
        #expect(rig.routes.selfTest() == nil)            // not due
        #expect(rig.routes.selfTest(force: true) != nil)
        #expect(rig.routes.repairBrief == nil)
    }

    @objc(JarvisFakeSidecarManager) final class FakeSidecarManager: NSObject {
        @objc class func sharedManager() -> AnyObject { NSObject() }
        @objc func devices() -> [AnyObject] { [] }
        @objc func connectedDevices() -> [AnyObject] { [] }
        @objc(connectToDevice:completion:) func connect(_ d: AnyObject, completion: AnyObject) {}
        @objc(disconnectFromDevice:completion:) func disconnect(_ d: AnyObject, completion: AnyObject) {}
    }
    @objc(JarvisFakeSidecarDevice) final class FakeSidecarDevice: NSObject {
        @objc var name: String { "x" }
    }

    @Test("the private rung's probe: classes and selectors looked up, missing ones named, nothing called")
    func privateProbe() {
        let none = PrivateFrameworkRung(lookup: { _ in nil }).probe()
        #expect(none.covers.isEmpty)
        #expect(none.missing.contains("SidecarDisplayManager") && none.missing.contains("AVOutputContext"))
        let sidecarOnly = PrivateFrameworkRung(lookup: { name in
            switch name {
            case "SidecarDisplayManager": FakeSidecarManager.self
            case "SidecarDevice": FakeSidecarDevice.self
            case "AVOutputContext": NSObject.self    // present, but without the selectors
            default: nil
            }
        }).probe()
        #expect(sidecarOnly.covers == [.extend])
        #expect(sidecarOnly.missing.contains("AVOutputContext +sharedSystemAudioContext"))
        #expect(sidecarOnly.log.contains("extend: classes and selectors present"))
    }

    @Test("the scriptable and accessibility rungs' probes")
    func otherProbes() {
        let ok = ScriptableRung(scripts: NoScripts(), dictionary: { #"<class name="AirPlay device"/><property name="current AirPlay devices"/>"# }).probe()
        #expect(ok.covers == [.audio, .stop])
        #expect(ScriptableRung(scripts: NoScripts(), dictionary: { "" }).probe().covers.isEmpty)
        #expect(AccessibilityRung(scripts: NoScripts(), trusted: { false }).probe().missing == ["the Accessibility permission"])
        #expect(AccessibilityRung(scripts: NoScripts(), trusted: { true }).probe().covers == [.mirror, .extend, .stop])
        #expect(BonjourAirPlayBrowser.displayName("A1B2C3D4E5F6@Living Room") == "Living Room")
    }

    struct NoScripts: ScriptRunning {
        func run(_ script: String) async -> String { "error: not in tests" }
    }
}
