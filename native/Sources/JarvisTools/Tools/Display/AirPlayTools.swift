import Foundation
import JarvisCore
import Synchronization

/// `airplay_devices`.
struct AirPlayDevices: ToolImpl {
    static let name = "airplay_devices"
    static let schema = ToolSchema(
        name: name,
        description: "List the AirPlay receivers (Apple TV, AirPlay speakers) and Sidecar iPads this Mac can see, by the names they announce.",
        parametersJSON: #"{"type": "object", "properties": {}, "required": []}"#)
    let routes: DisplayRoutes
    init(routes: DisplayRoutes) { self.routes = routes }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let names = await routes.devices()
        return .text(names.isEmpty ? "I can't see any AirPlay or Sidecar devices, sir." : names.joined(separator: "\n"))
    }
}

/// `airplay_to`: audio and video need no confirmation; mirroring or extending to a device asks the
/// first time, since it shows the screen elsewhere.
struct AirPlayTo: ToolImpl {
    static let name = "airplay_to"
    static let schema = ToolSchema(
        name: name,
        description: "Send to an AirPlay or Sidecar device by name (from airplay_devices). what: 'audio' (this Mac's sound), 'video' (what is playing), 'mirror' (the screen) or 'extend' (use an iPad as a second display).",
        parametersJSON: #"{"type": "object", "properties": {"device": {"type": "string"}, "what": {"type": "string", "enum": ["audio", "video", "mirror", "extend"]}}, "required": ["device", "what"]}"#)
    let routes: DisplayRoutes
    init(routes: DisplayRoutes) { self.routes = routes }

    static func spoken(_ action: DisplayAction, _ device: String) -> String {
        switch action {
        case .extend: "Extending the display to \(device), sir."
        case .mirror: "Mirroring the screen to \(device), sir."
        default: "Sending it to \(device), sir."
        }
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
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
struct AirPlayStop: ToolImpl {
    static let name = "airplay_stop"
    static let schema = ToolSchema(
        name: name,
        description: "Stop AirPlay audio, video, mirroring and Sidecar, bringing everything back to this Mac.",
        parametersJSON: #"{"type": "object", "properties": {}, "required": []}"#)
    let routes: DisplayRoutes
    init(routes: DisplayRoutes) { self.routes = routes }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(await routes.perform(.stop, device: nil) != nil ? "Everything's back on this Mac, sir." : "Nothing was being sent anywhere, sir.")
    }
}
