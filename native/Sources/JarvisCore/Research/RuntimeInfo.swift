import Darwin
import Foundation

// The schema-2 `runtime` block of a snapshot row (plan: M01b §3.2, §3.3, §3.6): which
// implementation and build wrote the row, on what OS and hardware, using how much memory.
// Native-specified: jarvis.py was not patched, so there is no Python oracle for these
// values; SnapshotTests check their types, key order and the dev/release rule.

public struct RuntimeInfo: Sendable, Equatable {
    public var impl = "swift"
    public var build: BuildChannel
    public var version: String?                 // CFBundleShortVersionString, nil without an app bundle
    public var sourceCommit: String             // Info.plist JARVISGitCommit, "" without one
    public var sourceDirty: Bool?               // Info.plist JARVISGitDirty, nil without one
    public var processStarted: Double
    public var voice: Bool                      // voice pipeline running at snapshot time (false until M9/M12)
    public var claudeEnabled: Bool              // M3 configuration (JARVIS_USE_CLAUDE equivalent), not a probe
    public var localModel: String?              // M3's local-backend id, as in backend_local_…

    public init(build: BuildChannel = .dev, version: String? = nil, sourceCommit: String = "",
                sourceDirty: Bool? = nil, processStarted: Double, voice: Bool = false,
                claudeEnabled: Bool = false, localModel: String? = nil) {
        self.build = build
        self.version = version
        self.sourceCommit = sourceCommit
        self.sourceDirty = sourceDirty
        self.processStarted = processStarted
        self.voice = voice
        self.claudeEnabled = claudeEnabled
        self.localModel = localModel
    }

    /// Reads the build facts from an Info.plist dictionary (nil: not running from a bundle).
    /// `build` is `.release` only when `JARVISBuildChannel` is exactly "release"; anything
    /// else, or no key, is `.dev`, so a mislabel can only hide release data (§3.6).
    public init(infoDictionary info: [String: Any]?, processStarted: Double, voice: Bool = false,
                claudeEnabled: Bool = false, localModel: String? = nil) {
        self.init(build: (info?["JARVISBuildChannel"] as? String) == "release" ? .release : .dev,
                  version: info?["CFBundleShortVersionString"] as? String,
                  sourceCommit: info?["JARVISGitCommit"] as? String ?? "",
                  sourceDirty: RuntimeInfo.flag(info?["JARVISGitDirty"]),
                  processStarted: processStarted, voice: voice,
                  claudeEnabled: claudeEnabled, localModel: localModel)
    }

    /// The running process: Info.plist only when it is an `.app` bundle (`swift test` and
    /// `swift run` executables have none, or a tool's own), so they record `dev`.
    public static func current(bundle: Bundle = .main, processStarted: Double, voice: Bool = false,
                               claudeEnabled: Bool = false, localModel: String? = nil) -> RuntimeInfo {
        let info = bundle.bundleURL.pathExtension == "app" ? bundle.infoDictionary : nil
        return RuntimeInfo(infoDictionary: info, processStarted: processStarted, voice: voice,
                           claudeEnabled: claudeEnabled, localModel: localModel)
    }

    /// A plist boolean (`<true/>`), or the strings build scripts tend to write.
    private static func flag(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let s as String:
            switch s.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// The row's `runtime` object, in the §3.3 key order. Host and memory facts are read now;
    /// `utcOffset` is the local offset behind the row's `date`.
    public func json(utcOffset: String, host: HostSample = .current()) -> JSONObject {
        func opt(_ v: UInt64?) -> JSONValue { v.map { .int(Int64(clamping: $0)) } ?? .null }
        return JSONObject([
            .init(key: "impl", value: .string(impl)),
            .init(key: "build", value: .string(build.rawValue)),
            .init(key: "version", value: version.map { .string($0) } ?? .null),
            .init(key: "source_commit", value: .string(sourceCommit)),
            .init(key: "source_dirty", value: sourceDirty.map { .bool($0) } ?? .null),
            .init(key: "process_started", value: .double(processStarted)),
            .init(key: "os", value: .string(host.os)),
            .init(key: "os_build", value: .string(host.osBuild)),
            .init(key: "hw_model", value: .string(host.hwModel)),
            .init(key: "ram_bytes", value: opt(host.ramBytes)),
            .init(key: "mem_footprint_bytes", value: opt(host.footprint)),
            .init(key: "mem_footprint_peak_bytes", value: opt(host.peakFootprint)),
            .init(key: "voice", value: .bool(voice)),
            .init(key: "backends", value: .object(JSONObject([
                .init(key: "claude", value: .bool(claudeEnabled)),
                .init(key: "local", value: localModel.map { .string($0) } ?? .null),
            ]))),
            .init(key: "utc_offset", value: .string(utcOffset)),
        ])
    }
}

/// The host and memory facts of one snapshot. A field Python's §3.7 reference would leave
/// at its fallback ("" / None) when the read fails is "" / nil here.
public struct HostSample: Sendable, Equatable {
    public var os: String
    public var osBuild: String
    public var hwModel: String
    public var ramBytes: UInt64?
    public var footprint: UInt64?
    public var peakFootprint: UInt64?

    public init(os: String, osBuild: String, hwModel: String, ramBytes: UInt64?,
                footprint: UInt64?, peakFootprint: UInt64?) {
        self.os = os
        self.osBuild = osBuild
        self.hwModel = hwModel
        self.ramBytes = ramBytes
        self.footprint = footprint
        self.peakFootprint = peakFootprint
    }

    public static func current() -> HostSample {
        let v = HostInfo.osVersion()
        let m = MemoryFootprint.current()
        return HostSample(os: v.product, osBuild: v.build, hwModel: HostInfo.hwModel(),
                          ramBytes: HostInfo.ramBytes(), footprint: m?.footprint, peakFootprint: m?.peak)
    }
}

public enum MemoryFootprint {
    /// `proc_pid_rusage(getpid(), RUSAGE_INFO_V4)`: `ri_phys_footprint` and
    /// `ri_lifetime_max_phys_footprint`, the same kernel ledger Python's §3.7 reference reads
    /// (offsets 72 / 240). nil when the call fails.
    public static func current() -> (footprint: UInt64, peak: UInt64)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }
}

public enum HostInfo {
    /// /System/Library/CoreServices/SystemVersion.plist ProductVersion / ProductBuildVersion;
    /// "" for what cannot be read.
    public static func osVersion() -> (product: String, build: String) {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return ("", "")
        }
        return (plist["ProductVersion"] as? String ?? "", plist["ProductBuildVersion"] as? String ?? "")
    }

    /// `sysctlbyname("hw.model")`, "" on failure.
    public static func hwModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `sysctlbyname("hw.memsize")`, nil on failure.
    public static func ramBytes() -> UInt64? {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &v, &size, nil, 0) == 0, size == MemoryLayout<UInt64>.size else {
            return nil
        }
        return v
    }
}
