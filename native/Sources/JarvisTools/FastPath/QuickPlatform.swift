import Foundation
import Synchronization

/// PR2: what the fast path's own tools need from the app, which JarvisTools cannot reach
/// without AppKit: the running apps (`NSWorkspace.runningApplications`) and the last reply.
public struct QuickPlatform: Sendable {
    public var runningApps: any RunningAppsControlling
    public var lastReply: LastReply

    public init(runningApps: any RunningAppsControlling = NoRunningApps(), lastReply: LastReply = LastReply()) {
        self.runningApps = runningApps
        self.lastReply = lastReply
    }
}

/// One entry of `NSWorkspace.runningApplications`: its `localizedName` (or ""), whether its
/// activation policy is regular (Python's `activationPolicy() == 0`) and its process id.
public struct RunningApp: Sendable, Equatable {
    public let name: String
    public let regular: Bool
    public let pid: Int32

    public init(name: String, regular: Bool, pid: Int32) {
        self.name = name
        self.regular = regular
        self.pid = pid
    }
}

/// The running apps, and `terminate()` (a polite quit, so an app may ask to save).
public protocol RunningAppsControlling: Sendable {
    func runningApps() async -> [RunningApp]
    /// `NSRunningApplication.terminate()`'s result.
    func terminate(_ app: RunningApp) async -> Bool
}

/// No running apps: what a platform has until the app supplies the real list.
public struct NoRunningApps: RunningAppsControlling {
    public init() {}
    public func runningApps() async -> [RunningApp] { [] }
    public func terminate(_ app: RunningApp) async -> Bool { false }
}

/// jarvis.py's `_last_reply[0]`: the most recent reply, for "copy that". The coordinator
/// records each turn's reply; a copy confirmation is not recorded, so copying twice copies
/// the same thing (handle_one 5603-5605).
public final class LastReply: Sendable {
    private let text = Mutex("")

    public init() {}

    public var value: String { text.withLock { $0 } }

    /// `if reply_text and not reply_text.startswith("Copied to your clipboard")`.
    public func record(_ reply: String) {
        guard !reply.isEmpty, !reply.hasPrefix("Copied to your clipboard") else { return }
        text.withLock { $0 = reply }
    }
}

/// Runs nothing: the fast path's `open` runner on a platform the app has not given one.
struct NoCommands: StdinCommandRunning {
    func run(_ argv: [String], timeout: Double) async -> ProcessOutput? { nil }
    func run(_ argv: [String], input: Data, timeout: Double) async -> ProcessOutput? { nil }
}
