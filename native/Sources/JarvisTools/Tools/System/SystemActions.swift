import AudioToolbox
import CoreAudio
import Foundation
import JarvisCore
import UserNotifications

protocol VolumeSetting: Sendable { func set(_ level: Int) }
struct LiveVolume: VolumeSetting {
    func set(_ level: Int) {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr else { return }
        address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value = Float32(level) / 100
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}

struct SetVolume: ToolImpl {
    static let name = "set_volume"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let volume: any VolumeSetting
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let level = try ActionLevel.clamped(args["level"] ?? .int(50))
        volume.set(level)
        return .text("Volume set to \(level).")
    }
}

struct SetBrightness: ToolImpl {
    static let name = "set_brightness"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let denied = "I need Accessibility permission to change brightness, sir — or install the brightness command with brew."
    let keyboard: any KeyboardPosting
    let runner: any CommandRunning
    let cli: @Sendable () -> String?
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let level = try ActionLevel.clamped(args["level"] ?? .int(50))
        if let cli = cli() {
            let argv = [cli, PyFloat.repr(Double(level) / 100)]
            _ = try ActionProcess.require(await runner.run(argv, timeout: 5), argv: argv, timeout: 5)
            return .text("Brightness set to \(level) percent, sir.")
        }
        guard keyboard.permitted() else { return .text(Self.denied) }
        for _ in 0..<16 { guard keyboard.key(145) else { return .text(Self.denied) } }
        for _ in 0..<Int((Double(level) / 6.25).rounded(.toNearestOrEven)) {
            guard keyboard.key(144) else { return .text(Self.denied) }
        }
        return .text("Brightness set to about \(level) percent, sir.")
    }
    static func liveCLI() -> String? {
        ["/opt/homebrew/bin/brightness", "/usr/local/bin/brightness"].first { FileManager.default.fileExists(atPath: $0) }
    }
}

protocol NotificationPosting: Sendable { func post(title: String, message: String) async -> Bool }
struct LiveNotification: NotificationPosting {
    func post(title: String, message: String) async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = message
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return true
        } catch { return false }
    }
}

struct Notify: ToolImpl {
    static let name = "notify"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let notifications: any NotificationPosting
    let runner: any StdinCommandRunning
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let title = PyArgs.str(args["title"] ?? .string("JARVIS"))
        let message = PyArgs.str(args["message"] ?? .string(""))
        if !((await notifications.post(title: title, message: message))) {
            _ = await AppleScriptRunner(runner: runner).run(
                "display notification \"\(Self.escape(message))\" with title \"\(Self.escape(title))\"")
        }
        return .text("Notification shown.")
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum ActionLevel {
    /// Python int(), then max(0, min(100, ...)); saturation avoids overflowing Swift Int.
    static func clamped(_ value: JSONValue) throws -> Int {
        switch value {
        case .bool(let b): return b ? 1 : 0
        case .int(let n): return Int(max(0, min(100, n)))
        case .bigInt(let s): return s.hasPrefix("-") ? 0 : 100
        case .double(let d):
            guard d.isFinite else { throw PyError(description: d.isNaN ? "cannot convert float NaN to integer" : "cannot convert float infinity to integer") }
            return Int(max(0, min(100, d)))
        case .string(let raw):
            var scalars = Array(Py.strip(raw).unicodeScalars)
            var negative = false
            if scalars.first == "-" || scalars.first == "+" { negative = scalars.removeFirst() == "-" }
            var result = 0, digits = 0, separator = false
            for scalar in scalars {
                if scalar == "_", digits > 0, !separator { separator = true; continue }
                guard scalar.properties.numericType == .decimal,
                      let n = scalar.properties.numericValue else { throw invalid(raw) }
                result = min(100, result * 10 + Int(n)); digits += 1; separator = false
            }
            guard digits > 0, !separator else { throw invalid(raw) }
            return negative ? 0 : result
        default: throw PyError(description: "int() argument must be a string, a bytes-like object or a real number, not '\(PyArgs.typeName(value))'")
        }
    }
    private static func invalid(_ raw: String) -> PyError {
        PyError(description: "invalid literal for int() with base 10: \(PyRepr.string(raw))")
    }
}
