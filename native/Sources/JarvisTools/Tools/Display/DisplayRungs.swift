import ApplicationServices
import Foundation
import JarvisCore
import Network
import Synchronization

/// Batch C part 6, rung 2: Music's AppleScript `current AirPlay devices`, for audio. There is no
/// built-in Shortcuts action for AirPlay or Sidecar, so this rung covers audio and stop only.
public struct ScriptableRung: DisplayRouteDriver {
    public let kind = RungKind.scriptable
    let scripts: any ScriptRunning
    /// The Music app's scripting dictionary (sdef), read by the probe.
    let dictionary: @Sendable () -> String

    public init(scripts: any ScriptRunning = LiveScripts(), dictionary: (@Sendable () -> String)? = nil) {
        self.scripts = scripts
        self.dictionary = dictionary ?? { ScriptableRung.sdef("/System/Applications/Music.app") }
    }

    public static let terms = ["AirPlay device", "current AirPlay devices"]

    public func probe() -> RungProbe {
        let text = dictionary()
        let gone = Self.terms.filter { !text.contains("name=\"\($0)\"") }.map { "Music dictionary: \($0)" }
        return RungProbe(kind: kind, covers: gone.isEmpty ? [.audio, .stop] : [], missing: gone,
                         log: [gone.isEmpty ? "Music's AirPlay terms present" : "missing " + gone.joined(separator: ", "),
                               "no Shortcuts action for AirPlay or Sidecar on this system"])
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    public func devices() async -> [String] {
        let out = await scripts.run("if application \"Music\" is not running then return \"\"\n"
                                    + "tell application \"Music\" to return name of every AirPlay device")
        guard !out.lowercased().contains("error") else { return [] }
        return out.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public func perform(_ action: DisplayAction, device: String?) async -> Bool {
        let script: String
        switch action {
        case .audio:
            guard let device else { return false }
            script = "tell application \"Music\"\n  set targets to (every AirPlay device whose name contains \"\(Self.escape(device))\")\n"
                + "  if targets is {} then return \"error: no such device\"\n  set current AirPlay devices to targets\nend tell"
        case .stop:
            script = "if application \"Music\" is not running then return \"\"\n"
                + "tell application \"Music\" to set current AirPlay devices to (every AirPlay device whose kind is computer)"
        default:
            return false
        }
        return !(await scripts.run(script)).lowercased().contains("error")
    }

    static func sdef(_ app: String) -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/sdef")
        p.arguments = [app]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Batch C part 6, rung 3: Control Center's Screen Mirroring menu through System Events. Needs the
/// Accessibility permission; the last resort, and the most fragile (menu titles are localised).
public struct AccessibilityRung: DisplayRouteDriver {
    public let kind = RungKind.accessibility
    let scripts: any ScriptRunning
    let trusted: @Sendable () -> Bool

    public init(scripts: any ScriptRunning = LiveScripts(), trusted: (@Sendable () -> Bool)? = nil) {
        self.scripts = scripts
        self.trusted = trusted ?? { AXIsProcessTrusted() }
    }

    public func probe() -> RungProbe {
        let ok = trusted()
        return RungProbe(kind: kind, covers: ok ? [.mirror, .extend, .stop] : [],
                         missing: ok ? [] : ["the Accessibility permission"],
                         log: [ok ? "Accessibility granted" : "Accessibility not granted: rung down until it is"])
    }

    public func devices() async -> [String] { [] }

    /// Opens Screen Mirroring in Control Center and clicks the checkbox named after the device
    /// (an iPad there extends the display by default; "stop" clicks the checked one).
    static func script(device: String?) -> String {
        let pick = device.map { "whose name contains \"\(ScriptableRung.escape($0))\"" } ?? "whose value is 1"
        return """
            tell application "System Events" to tell process "ControlCenter"
              set mi to (first menu bar item of menu bar 1 whose description contains "Screen Mirroring")
              click mi
              delay 1
              set boxes to (every checkbox of scroll area 1 of group 1 of window 1 \(pick))
              if boxes is {} then
                key code 53
                return "error: not listed"
              end if
              click item 1 of boxes
              delay 0.5
              key code 53
            end tell
            """
    }

    public func perform(_ action: DisplayAction, device: String?) async -> Bool {
        guard trusted() else { return false }
        switch action {
        case .mirror, .extend:
            guard let device else { return false }
            return !(await scripts.run(Self.script(device: device))).lowercased().contains("error")
        case .stop:
            return !(await scripts.run(Self.script(device: nil))).lowercased().contains("error")
        default:
            return false
        }
    }
}

/// AirPlay receivers on the network through Bonjour (`_airplay._tcp`, `_raop._tcp`), browsed for
/// two seconds. RAOP names are "<mac>@<name>"; the name is kept.
public protocol AirPlayBrowsing: Sendable {
    func names() async -> [String]
}

public struct BonjourAirPlayBrowser: AirPlayBrowsing {
    public init() {}

    public static func displayName(_ service: String) -> String {
        guard let at = service.firstIndex(of: "@") else { return service }
        return String(service[service.index(after: at)...])
    }

    public func names() async -> [String] {
        let found = Mutex<Set<String>>([])
        var browsers: [NWBrowser] = []
        for type in ["_airplay._tcp", "_raop._tcp"] {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { results, _ in
                for r in results {
                    if case .service(let name, _, _, _) = r.endpoint {
                        found.withLock { _ = $0.insert(Self.displayName(name)) }
                    }
                }
            }
            b.start(queue: .global())
            browsers.append(b)
        }
        try? await Task.sleep(for: .seconds(2))
        browsers.forEach { $0.cancel() }
        return found.withLock { $0 }.sorted()
    }
}
