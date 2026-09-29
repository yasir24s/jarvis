import Darwin
import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// BrainAssembly (the T3.5 wiring): the parts share one gate and one research counter, the
/// gateway counts and logs, secrets are registered before use, and `claude` is found on the
/// child's PATH. Nothing here starts `claude`: the executable is a path that does not exist.
@Suite("M3 brain wiring (BrainAssembly)")
struct BrainRouterWiringTests {
    /// Every log line of the parts, as "<category>: <line>".
    final class CategoryLog: Sendable {
        private let state = Mutex<[String]>([])
        func add(_ line: String, _ category: LogCategory) { state.withLock { $0.append("\(category.rawValue): \(line)") } }
        var lines: [String] { state.withLock { $0 } }
    }

    struct Rig {
        let dir: ShortTempDir
        let harness: CoreHarness
        let research = BumpRecorder()
        let logs = CategoryLog()
        let assembly: BrainAssembly

        init() throws {
            dir = try ShortTempDir()
            let run = dir.url.appending(path: "run", directoryHint: .isDirectory)
            try MCPSocket.prepareRunDirectory(run)
            harness = try CoreHarness(research: NullCounter())
            let logs = logs
            assembly = BrainAssembly(core: harness.core, research: research,
                                     config: ClaudeConfig(environment: [:]), environment: [:],
                                     runDirectory: run,
                                     claudeWorkingDirectory: dir.url.appending(path: "claude-cwd", directoryHint: .isDirectory),
                                     claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
                                     localBrain: { _ in FakeLocalBrain(.reply("Local reply, sir.")) },
                                     textAuthenticator: FakeAuthenticator(answer: false), online: { false },
                                     log: { logs.add($0, $1) })
        }

        func remove() async {
            await assembly.stop()
            harness.remove()
            dir.remove()
        }
    }

    /// A-10's path without `claude`: a tools/call for run_command on a tainted turn, through the
    /// assembled MCP server, is blocked by the assembled gateway, which counts `taint_block`
    /// and logs Python's line.
    @Test func assembledGatewayCountsATaintBlock() async throws {
        let rig = try Rig()
        let turn = TurnContext(channel: .text, startTainted: true)
        let files = try await rig.assembly.registry.openTurn(turn)
        // Both socket ends are this process, so the relay's parent is this process's parent.
        await rig.assembly.registry.setClaudePID(getppid(), for: files.turnID)
        let token = try #require(MCPRelay.readToken(at: files.tokenPath.path(percentEncoded: false)))
        let (served, ours) = try socketPair()
        let server = rig.assembly.server
        Task { await server.serve(connection: served) }
        let end = TestEnd(fd: ours)
        end.send(#"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n")
        #expect(await end.line() == #"{"jarvis_relay_ok":1}"#)

        end.send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_command","arguments":{"command":"echo hi"}}}"# + "\n")
        let reply = try json(await end.line()).objectValue
        let result = try #require(reply?.object("result"))
        #expect(result["isError"] == .bool(true))
        #expect(result.array("content")?.first?.objectValue?.string("text") == TaintPolicy.blockedTextClaude)

        #expect(rig.research.bumps == ["taint_block+1"])
        #expect(rig.logs.lines.contains("tools: BLOCKED run_command after untrusted-content ingestion (injection guard)"))
        #expect(await turn.summary().toolRuns.map(\.outcome) == [.blockedTaint])
        end.close()
        await rig.assembly.registry.closeTurn(files.turnID)
        await rig.remove()
    }

    /// The gateway stashes into the same gate the coordinator consumes from.
    @Test func gatewayAndCoordinatorShareTheGate() async throws {
        let rig = try Rig()
        let turn = TurnContext(channel: .voice)
        let args = JSONObject([.init(key: "command", value: .string("killall"))])
        let gated = await rig.assembly.gateway.call("run_command", args, turn: turn,
                                                    origin: .model(.claude))
        #expect(gated.record.outcome == .gated)
        #expect(await rig.assembly.confirmations.pending != nil)
        let outcome = await rig.assembly.coordinator.submit(UserInput(text: "yes", channel: .voice), sink: RecordingSink())
        guard case .confirmation = outcome else {
            Issue.record("expected the coordinator to consume the gateway's confirmation, got \(outcome)")
            return
        }
        #expect(await rig.assembly.confirmations.pending == nil)
        await rig.remove()
    }

    @Test func secretIsRegisteredBeforeItIsReturned() {
        let registry = SecretRegistry()
        let value = BrainAssembly.secret(account: "elevenlabs", registry: registry) { service, account in
            service == SecretStore.service && account == "elevenlabs" ? "sentinel-4b1d-value" : nil
        }
        #expect(value == "sentinel-4b1d-value")
        #expect(registry.contains("key=sentinel-4b1d-value;"))
        #expect(registry.redact("x sentinel-4b1d-value y") == "x \(SecretRegistry.mask) y")

        let none = SecretRegistry()
        #expect(BrainAssembly.secret(account: "elevenlabs", registry: none) { _, _ in nil } == nil)
        #expect(!none.contains("sentinel-4b1d-value"))
    }

    /// ChildEnvironment puts ~/.local/bin, /opt/homebrew/bin and /usr/local/bin first; the
    /// test needs the last two to hold no `claude`.
    static let noSystemClaude = !["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .contains { FileManager.default.fileExists(atPath: $0) }

    @Test(.enabled(if: noSystemClaude))
    func claudeIsFoundOnTheChildPath() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let bin = sb.root.appending(path: "bin", directoryHint: .isDirectory)
        try sb.write("bin/claude", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: bin.appending(path: "claude").path(percentEncoded: false))
        let home = sb.root.path(percentEncoded: false)
        let config = ClaudeConfig(environment: [:])
        let found = BrainAssembly.locateClaude(environment: ["HOME": home, "PATH": bin.path(percentEncoded: false)],
                                               config: config)
        #expect(found?.resolvingSymlinksInPath() == bin.appending(path: "claude").resolvingSymlinksInPath())
        #expect(BrainAssembly.locateClaude(environment: ["HOME": home, "PATH": "/usr/bin:/bin"], config: config) == nil)
    }
}
