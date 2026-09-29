import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization

// Fakes for ClaudeDriverTests. Nothing here runs a real `claude`: the child is a /bin/sh
// script named fake-claude, written into a Sandbox, that replays a transcript.

/// Records what the driver asks of the MCP bridge.
actor FakeBridge: MCPTurnBridge {
    enum Call: Equatable, Sendable {
        case open(UUID)
        case pid(Int32, UUID)
        case close(UUID)
    }

    struct OpenFailed: Error {}

    private(set) var calls: [Call] = []
    let runDirectory: URL
    let failOpen: Bool

    init(runDirectory: URL, failOpen: Bool = false) {
        self.runDirectory = runDirectory
        self.failOpen = failOpen
    }

    func openTurn(_ turn: TurnContext) async throws -> MCPTurnFiles {
        let id = await turn.turnID
        calls.append(.open(id))
        if failOpen { throw OpenFailed() }
        // The token path is a placeholder: the driver never reads it.
        return MCPTurnFiles(turnID: id, tokenPath: runDirectory.appending(path: "placeholder-token"),
                            configPath: ClaudeInvocation.mcpConfigURL(in: runDirectory, turnID: id))
    }

    func setClaudePID(_ pid: Int32, for turnID: UUID) async {
        calls.append(.pid(pid, turnID))
    }

    func closeTurn(_ turnID: UUID) async {
        calls.append(.close(turnID))
    }

    var pid: Int32? {
        for case .pid(let pid, _) in calls { return pid }
        return nil
    }
}

actor RecordingSink: ReplySink {
    private(set) var sentences: [String] = []
    private(set) var deltas: [String] = []
    private(set) var retractedIDs: [String] = []

    func sentence(_ text: String) { sentences.append(text) }
    func delta(_ text: String) { deltas.append(text) }
    func retracted(messageID: String) { retractedIDs.append(messageID) }
}

actor RecordingBackend: BackendReporting {
    private(set) var names: [String] = []

    func set(_ name: String) { names.append(name) }
}

/// `ResearchCounting` that keeps each bump as "key+n", in call order.
final class BumpRecorder: ResearchCounting, Sendable {
    private let state = Mutex<[String]>([])

    func bump(_ key: String, by n: Int) {
        state.withLock { $0.append("\(key)+\(n)") }
    }

    var bumps: [String] { state.withLock { $0 } }
}

/// The driver's injected log function. Tests never use JarvisLog, which is process-global.
final class LogRecorder: Sendable {
    private let state = Mutex<[String]>([])

    var lines: [String] { state.withLock { $0 } }

    var function: @Sendable (String) -> Void {
        { [self] line in state.withLock { $0.append(line) } }
    }
}

/// A fake `claude` in its own Sandbox. The script records its argv (NUL-separated), its
/// working directory, its environment and the stdin line, prints `transcript.jsonl` to
/// stdout and `stderr.txt` to stderr, then ends as `Ending` says. `.hang` writes a `term`
/// file when SIGTERM arrives and exits 143; `.hangIgnoringTerm` ignores SIGTERM (so only
/// SIGKILL stops it) and writes its `sleep`'s pid to `sleep.pid`.
struct FakeClaude {
    enum Ending {
        case exit(Int32)
        case hang
        case hangIgnoringTerm
    }

    let sandbox: Sandbox
    var dir: URL { sandbox.root }
    var script: URL { dir.appending(path: "fake-claude", directoryHint: .notDirectory) }
    var cwd: URL { dir.appending(path: "claude-cwd", directoryHint: .isDirectory) }
    var runDirectory: URL { dir.appending(path: "run", directoryHint: .isDirectory) }

    init(transcript: [String], stderr: String = "", ending: Ending) throws {
        sandbox = try Sandbox()
        let root = sandbox.root.path(percentEncoded: false)
        precondition(!root.contains("'"), "sandbox path must not contain a single quote")
        let trap: String, end: String
        switch ending {
        case .exit(let code):
            trap = ""
            end = "exit \(code)"
        case .hang:
            trap = #"trap 'echo TERM > "$D/term"; kill $! 2>/dev/null; exit 143' TERM"#
            end = "/bin/sleep 30 &\nwait $!"
        case .hangIgnoringTerm:
            trap = "trap '' TERM"
            end = "/bin/sleep 30 &\necho $! > \"$D/sleep.pid\"\nwait $!"
        }
        let text = """
            #!/bin/sh
            # fake-claude for ClaudeDriverTests: records argv, cwd, env and the stdin line,
            # then replays a transcript.
            D='\(root)'
            \(trap)
            for a in "$@"; do printf '%s\\0' "$a"; done > "$D/argv"
            /bin/pwd -P > "$D/cwd"
            /usr/bin/env > "$D/env"
            IFS= read -r line
            printf '%s\\n' "$line" > "$D/stdin"
            /bin/cat "$D/transcript.jsonl"
            /bin/cat "$D/stderr.txt" >&2
            \(end)

            """
        try sandbox.write("transcript.jsonl", transcript.map { $0 + "\n" }.joined())
        try sandbox.write("stderr.txt", stderr)
        try sandbox.write("fake-claude", text)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    }

    func text(_ name: String) -> String? {
        try? String(contentsOf: dir.appending(path: name, directoryHint: .notDirectory), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: name).path(percentEncoded: false))
    }

    /// The argv the script received, from its NUL-separated record.
    var argv: [String]? {
        guard let data = try? Data(contentsOf: dir.appending(path: "argv", directoryHint: .notDirectory)) else {
            return nil
        }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// The environment the script saw, without the variables /bin/sh sets itself.
    var environment: [String: String]? {
        guard let text = text("env") else { return nil }
        var env: [String: String] = [:]
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            env[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
        }
        for key in ["PWD", "SHLVL", "_", "OLDPWD"] { env[key] = nil }
        return env
    }

    func remove() {
        sandbox.remove()
    }
}

/// Transcript lines: the probe's, and hand-made events in the probe's shapes.
enum Transcript {
    static let probeURL = Golden.directory.deletingLastPathComponent()
        .appending(path: "claude/probe-2026-09-28.jsonl", directoryHint: .notDirectory)

    static func probe() throws -> [String] {
        try String(contentsOf: probeURL, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// The probe's `system`/`init` line.
    static func initLine() throws -> String {
        try probe()[0]
    }

    static func json(_ text: String) -> String {
        PyJSON.dumps(.string(text), ensureASCII: false)
    }

    static func messageStart(_ id: String, model: String = "claude-opus-5-5") -> String {
        #"{"type":"stream_event","event":{"type":"message_start","message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[]}},"parent_tool_use_id":null}"#
    }

    static func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(json(text))}},"parent_tool_use_id":null}"#
    }

    static func block(_ id: String, _ text: String) -> String {
        #"{"type":"assistant","message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":\#(json(text))}]},"parent_tool_use_id":null}"#
    }

    static func stop(_ reason: String) -> String {
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"\#(reason)","stop_sequence":null}},"parent_tool_use_id":null}"#
    }

    static func rateLimit(status: String, overage: Bool) -> String {
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(status)","rateLimitType":"five_hour","isUsingOverage":\#(overage)}}"#
    }

    static func result(subtype: String = "success", isError: Bool = false, text: String?, status: Int? = nil) -> String {
        let result = text.map(json) ?? "null"
        let api = status.map(String.init) ?? "null"
        return #"{"type":"result","subtype":"\#(subtype)","is_error":\#(isError),"result":\#(result),"api_error_status":\#(api),"stop_reason":"end_turn"}"#
    }
}
