import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools

// Fakes for CodexDriverTests. Nothing here runs a real `codex`: the child is a /bin/sh script
// named fake-codex, written into a Sandbox, that replays a transcript of exec's JSON events.
// The recorder types (RecordingSink, RecordingBackend, BumpRecorder, Stamp, LogRecorder) are
// ClaudeDriverFakes.swift's.

/// A bridge like `FakeBridge` that also writes the turn's MCP config, as `MCPTurnRegistry`
/// does, since the Codex driver reads the relay's command from it.
actor ConfigBridge: MCPTurnBridge {
    enum Call: Equatable, Sendable {
        case open(UUID)
        case pid(Int32, UUID)
        case close(UUID)
    }

    struct OpenFailed: Error {}

    static let relayCommand = "/opt/jarvis-test/JARVIS"
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
        let token = runDirectory.appending(path: "turn-\(id.uuidString.lowercased()).token")
        let config = try ClaudeInvocation.writeMCPConfig(in: runDirectory, turnID: id, command: Self.relayCommand,
                                                         socket: runDirectory.appending(path: "mcp.sock").path(percentEncoded: false),
                                                         tokenFile: token.path(percentEncoded: false))
        return MCPTurnFiles(turnID: id, tokenPath: token, configPath: config)
    }

    func setClaudePID(_ pid: Int32, for turnID: UUID) async {
        calls.append(.pid(pid, turnID))
    }

    func closeTurn(_ turnID: UUID) async {
        calls.append(.close(turnID))
        try? FileManager.default.removeItem(at: ClaudeInvocation.mcpConfigURL(in: runDirectory, turnID: turnID))
    }

    var pid: Int32? {
        for case .pid(let pid, _) in calls { return pid }
        return nil
    }
}

/// A fake `codex` in its own Sandbox. The script records its argv (NUL-separated), its working
/// directory, its environment, all of stdin, and a copy of the catalog file its argv names;
/// then prints the transcript's parts to stdout with the pauses between them, `stderr.txt` to
/// stderr, and ends as `Ending` says (FakeClaude's endings).
struct FakeCodex {
    enum Ending {
        case exit(Int32)
        case hang
        case hangIgnoringTerm
    }

    let sandbox: Sandbox
    var dir: URL { sandbox.root }
    var script: URL { dir.appending(path: "fake-codex", directoryHint: .notDirectory) }
    var cwd: URL { dir.appending(path: "codex-cwd", directoryHint: .isDirectory) }
    var runDirectory: URL { dir.appending(path: "run", directoryHint: .isDirectory) }

    /// `parts` are printed in order with `pause` seconds between them.
    init(_ parts: [[String]], pause: Double = 0, stderr: String = "", ending: Ending) throws {
        sandbox = try Sandbox()
        let root = sandbox.root.path(percentEncoded: false)
        precondition(!root.contains("'"), "sandbox path must not contain a single quote")
        let trap: String, end: String
        switch ending {
        case .exit(let code):
            trap = ""
            end = "exit \(code)"
        case .hang:
            trap = ""
            end = "exec /bin/sleep 30"
        case .hangIgnoringTerm:
            trap = "trap '' TERM"
            end = "exec /bin/sleep 30"
        }
        var replay = ""
        for (i, part) in parts.enumerated() {
            if i > 0 && pause > 0 { replay += "/bin/sleep \(pause)\n" }
            try sandbox.write("part\(i).jsonl", part.map { $0 + "\n" }.joined())
            replay += "/bin/cat \"$D/part\(i).jsonl\"\n"
        }
        let text = """
            #!/bin/sh
            # fake-codex for CodexDriverTests: records argv, cwd, env, stdin and the catalog,
            # then replays a transcript.
            D='\(root)'
            \(trap)
            for a in "$@"; do printf '%s\\0' "$a"; done > "$D/argv"
            for a in "$@"; do
              case "$a" in
                model_catalog_json=*) p=$(printf '%s' "$a" | /usr/bin/sed -e 's/^model_catalog_json="//' -e 's/"$//')
                  /bin/cp "$p" "$D/catalog.json";;
              esac
            done
            /bin/pwd -P > "$D/cwd"
            /usr/bin/env > "$D/env"
            /bin/cat > "$D/stdin.part"
            /bin/mv "$D/stdin.part" "$D/stdin"
            \(replay)
            /bin/cat "$D/stderr.txt" >&2
            \(end)

            """
        try sandbox.write("stderr.txt", stderr)
        try sandbox.write("fake-codex", text)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    }

    init(_ lines: [String], stderr: String = "", ending: Ending) throws {
        try self.init([lines], stderr: stderr, ending: ending)
    }

    func text(_ name: String) -> String? {
        try? String(contentsOf: dir.appending(path: name, directoryHint: .notDirectory), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appending(path: name).path(percentEncoded: false))
    }

    var argv: [String]? {
        guard let data = try? Data(contentsOf: dir.appending(path: "argv", directoryHint: .notDirectory)) else {
            return nil
        }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

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

/// exec --json lines in codex-cli 0.159.2's shapes (recorded 2026-10-02 against the CLI).
enum CodexLine {
    static func json(_ text: String) -> String {
        PyJSON.dumps(.string(text))
    }

    static let thread = #"{"type":"thread.started","thread_id":"01a0fc7f-27e8-7b11-9127-902fed1ffbb8"}"#
    static let turnStarted = #"{"type":"turn.started"}"#

    static func message(_ id: String, _ text: String) -> String {
        #"{"type":"item.completed","item":{"id":"\#(id)","type":"agent_message","text":\#(json(text))}}"#
    }

    static func toolStarted(_ id: String, server: String = "jarvis", tool: String) -> String {
        #"{"type":"item.started","item":{"id":"\#(id)","type":"mcp_tool_call","server":"\#(server)","tool":"\#(tool)","arguments":{},"result":null,"error":null,"status":"in_progress"}}"#
    }

    static func toolCompleted(_ id: String, server: String = "jarvis", tool: String, text: String = "13:09") -> String {
        #"{"type":"item.completed","item":{"id":"\#(id)","type":"mcp_tool_call","server":"\#(server)","tool":"\#(tool)","arguments":{},"result":{"content":[{"type":"text","text":\#(json(text))}],"structured_content":null},"error":null,"status":"completed"}}"#
    }

    static func item(_ type: String, id: String = "item_9") -> String {
        #"{"type":"item.started","item":{"id":"\#(id)","type":"\#(type)","status":"in_progress"}}"#
    }

    static func error(_ message: String) -> String {
        #"{"type":"error","message":\#(json(message))}"#
    }

    static func turnFailed(_ message: String) -> String {
        #"{"type":"turn.failed","error":{"message":\#(json(message))}}"#
    }

    static let turnCompleted = #"{"type":"turn.completed","usage":{"input_tokens":1834,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":21,"reasoning_output_tokens":0}}"#
}
