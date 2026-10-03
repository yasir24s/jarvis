import Darwin
import Foundation
import JarvisCore
import ObjectiveC

/// Batch C part 6, rung 1: Apple's own AirPlay and Sidecar classes, loaded at runtime with dlopen
/// and looked up by name, never linked. SidecarCore extends the display to an iPad; AVRouting's
/// output contexts send system audio and the screen to an AirPlay device. Every class and selector
/// is looked up before use; a missing one makes its actions unavailable, never a crash.
///
/// The probe only loads and looks up. Device discovery and routing call into the frameworks and
/// run only for a tool call.
public struct PrivateFrameworkRung: DisplayRouteDriver {
    public let kind = RungKind.privateFramework

    public static let frameworks = ["/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",
                                    "/System/Library/PrivateFrameworks/AVRouting.framework/AVRouting"]

    /// One class and the selectors needed on it ("+" for a class method).
    public struct Requirement: Sendable, Equatable {
        public let cls: String
        public let selectors: [String]
    }

    public static let discovery = [Requirement(cls: "AVOutputDeviceDiscoverySession",
                                               selectors: ["initWithDeviceFeatures:", "availableOutputDevices", "setDiscoveryMode:"]),
                                   Requirement(cls: "AVOutputDevice", selectors: ["name", "deviceID"])]
    public static let requirements: [DisplayAction: [Requirement]] = [
        .extend: [Requirement(cls: "SidecarDisplayManager",
                              selectors: ["+sharedManager", "devices", "connectToDevice:completion:", "disconnectFromDevice:completion:", "connectedDevices"]),
                  Requirement(cls: "SidecarDevice", selectors: ["name"])],
        .audio: [Requirement(cls: "AVOutputContext", selectors: ["+sharedSystemAudioContext", "setOutputDevice:options:completionHandler:"])] + discovery,
        .video: [Requirement(cls: "AVOutputContext", selectors: ["+sharedSystemAudioContext", "setOutputDevice:options:completionHandler:"])] + discovery,
        .mirror: [Requirement(cls: "AVOutputContext", selectors: ["+sharedSystemScreenContext", "setOutputDevice:options:completionHandler:"])] + discovery,
        .stop: [Requirement(cls: "AVOutputContext",
                            selectors: ["+sharedSystemScreenContext", "+sharedSystemAudioContext", "outputDevice", "removeOutputDevice:options:completionHandler:"])],
    ]

    /// Looks a class up after loading the frameworks; injectable for tests.
    let lookup: @Sendable (String) -> AnyClass?

    public init(lookup: (@Sendable (String) -> AnyClass?)? = nil) {
        self.lookup = lookup ?? { name in
            for path in PrivateFrameworkRung.frameworks { _ = dlopen(path, RTLD_LAZY | RTLD_LOCAL) }
            return NSClassFromString(name)
        }
    }

    /// The missing pieces of `req`: "Class" when the class is gone, "Class sel" per missing selector.
    func missing(_ req: Requirement) -> [String] {
        guard let cls = lookup(req.cls) else { return [req.cls] }
        return req.selectors.compactMap { sel in
            let isClass = sel.hasPrefix("+")
            let name = isClass ? String(sel.dropFirst()) : sel
            let found = isClass ? class_getClassMethod(cls, NSSelectorFromString(name)) != nil
                : class_getInstanceMethod(cls, NSSelectorFromString(name)) != nil
            return found ? nil : "\(req.cls) \(sel)"
        }
    }

    public func probe() -> RungProbe {
        var covers: [DisplayAction] = [], missingAll: [String] = [], log: [String] = []
        for action in DisplayAction.allCases {
            let gone = (Self.requirements[action] ?? []).flatMap(missing)
            if gone.isEmpty { covers.append(action) } else { missingAll += gone }
            log.append("\(action.rawValue): " + (gone.isEmpty ? "classes and selectors present" : "missing " + gone.joined(separator: ", ")))
        }
        return RungProbe(kind: kind, covers: covers, missing: Array(Set(missingAll)).sorted(), log: log)
    }

    // MARK: - Calls (tool calls only, never the probe)

    private func available(_ action: DisplayAction) -> Bool {
        (Self.requirements[action] ?? []).allSatisfy { missing($0).isEmpty }
    }

    private func sidecarManager() -> NSObject? {
        guard let cls = lookup("SidecarDisplayManager") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
    }

    private func sidecarDevices() -> [NSObject] {
        sidecarManager()?.perform(NSSelectorFromString("devices"))?.takeUnretainedValue() as? [NSObject] ?? []
    }

    private func outputDevices() async -> [NSObject] {
        guard let cls = lookup("AVOutputDeviceDiscoverySession") as? NSObject.Type else { return [] }
        let alloc = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        // Features: audio (1) | screen (2) | video (4).
        typealias InitFn = @convention(c) (AnyObject, Selector, UInt) -> AnyObject?
        let sel = NSSelectorFromString("initWithDeviceFeatures:")
        guard let alloc, let imp = alloc.method(for: sel) else { return [] }
        guard let session = unsafeBitCast(imp, to: InitFn.self)(alloc, sel, 7) as? NSObject else { return [] }
        typealias ModeFn = @convention(c) (AnyObject, Selector, Int) -> Void
        let modeSel = NSSelectorFromString("setDiscoveryMode:")
        if let m = session.method(for: modeSel) { unsafeBitCast(m, to: ModeFn.self)(session, modeSel, 2) }
        try? await Task.sleep(for: .seconds(2))
        let found = session.perform(NSSelectorFromString("availableOutputDevices"))?.takeUnretainedValue() as? [NSObject] ?? []
        if let m = session.method(for: modeSel) { unsafeBitCast(m, to: ModeFn.self)(session, modeSel, 0) }
        return found
    }

    private static func name(_ o: NSObject) -> String {
        (o.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String) ?? ""
    }

    public func devices() async -> [String] {
        var names: [String] = []
        if available(.extend) { names += sidecarDevices().map(Self.name) }
        if available(.audio) { names += await outputDevices().map(Self.name) }
        return names.filter { !$0.isEmpty }
    }

    public func perform(_ action: DisplayAction, device: String?) async -> Bool {
        guard available(action) else { return false }
        switch action {
        case .extend:
            guard let device, let manager = sidecarManager(),
                  let target = sidecarDevices().first(where: { Self.name($0).localizedCaseInsensitiveContains(device) }) else { return false }
            return await call2(manager, "connectToDevice:completion:", target)
        case .audio, .video, .mirror:
            guard let device, let context = context(action == .mirror ? "sharedSystemScreenContext" : "sharedSystemAudioContext"),
                  let target = await outputDevices().first(where: { Self.name($0).localizedCaseInsensitiveContains(device) }) else { return false }
            return await call3(context, "setOutputDevice:options:completionHandler:", target)
        case .stop:
            var any = false
            for ctxName in ["sharedSystemScreenContext", "sharedSystemAudioContext"] {
                guard let ctx = context(ctxName),
                      let current = ctx.perform(NSSelectorFromString("outputDevice"))?.takeUnretainedValue() as? NSObject else { continue }
                if await call3(ctx, "removeOutputDevice:options:completionHandler:", current) { any = true }
            }
            if let manager = sidecarManager(),
               let connected = manager.perform(NSSelectorFromString("connectedDevices"))?.takeUnretainedValue() as? [NSObject] {
                for d in connected where await call2(manager, "disconnectFromDevice:completion:", d) { any = true }
            }
            return any
        }
    }

    private func context(_ selector: String) -> NSObject? {
        guard let cls = lookup("AVOutputContext") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? NSObject
    }

    /// `[target sel:arg completion:^(NSError *)]`, waiting at most 15 s.
    private func call2(_ target: NSObject, _ selector: String, _ arg: NSObject) async -> Bool {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel), let imp = target.method(for: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        return await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            let once = Once(k)
            let block: @convention(block) (NSError?) -> Void = { error in once.resume(error == nil) }
            unsafeBitCast(imp, to: Fn.self)(target, sel, arg, block as AnyObject)
            once.timeout(after: 15)
        }
    }

    /// `[target sel:arg options:nil completionHandler:^(id result)]`, waiting at most 15 s. The
    /// handler's argument is not documented; any call of it counts as done.
    private func call3(_ target: NSObject, _ selector: String, _ arg: NSObject) async -> Bool {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel), let imp = target.method(for: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject) -> Void
        return await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            let once = Once(k)
            let block: @convention(block) (AnyObject?) -> Void = { _ in once.resume(true) }
            unsafeBitCast(imp, to: Fn.self)(target, sel, arg, nil, block as AnyObject)
            once.timeout(after: 15)
        }
    }
}

/// A continuation resumed once: by the completion, or false by the timeout.
private final class Once: @unchecked Sendable {
    private var k: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    init(_ k: CheckedContinuation<Bool, Never>) { self.k = k }
    func resume(_ value: Bool) {
        let c: CheckedContinuation<Bool, Never>? = lock.withLock { defer { k = nil }; return k }
        c?.resume(returning: value)
    }
    func timeout(after seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.resume(false) }
    }
}
