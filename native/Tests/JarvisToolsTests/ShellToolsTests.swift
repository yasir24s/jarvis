import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

@Suite("ShellToolsTests")
struct ShellToolsTests {
    @Test func fixtureHoldsEveryCase() throws {
        let names = try M5Fixture.cases("m5_shell_execution").map(\.name)
        #expect(names.count == 24)
        #expect(names.filter { $0.hasPrefix("run_command/") }.count == 11)
        #expect(names.filter { $0.hasPrefix("run_applescript/") }.count == 10)
        #expect(names.contains("run_command/missing"))
    }

    @Test func goldenRepliesAndTransport() async throws {
        for c in try M5Fixture.cases("m5_shell_execution") {
            let name = try #require(c.input.string("tool"))
            // "missing" sends no command at all; Python and the gateway both read it as "".
            let missing = c.input["missing"] == .bool(true)
            let command = missing ? "" : try #require(c.input.string("command"))
            let output = ProcessOutput(stdout: bytes(c.input.string("stdout_hex") ?? ""),
                                       stderr: bytes(c.input.string("stderr_hex") ?? ""),
                                       status: Int32(c.input.int("status") ?? 0),
                                       timedOut: c.input["timeout"] == .bool(true), truncated: false)
            let runner = FakeStdinRunner(output: output)
            let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
            await gateway.register(RunCommand(runner: runner))
            await gateway.register(RunAppleScript(runner: runner))
            let key = name == "run_command" ? "command" : "script"
            let args = missing ? JSONObject() : JSONObject([.init(key: key, value: .string(command))])
            let result = await gateway.call(name, args, turn: TurnContext(channel: .voice), origin: .model(.claude))
            #expect(result.text == c.expected.string("text"), "\(c)")
            let calls = await runner.calls
            if c.input["blocked"] == .bool(true) {
                #expect(calls.isEmpty)
                #expect(result.record.outcome == .blockedGuard)
            } else {
                #expect(calls.count == 1)
                #expect(calls.first?.timeout == 30)
                #expect(calls.first?.argv == (name == "run_command" ? ["/bin/sh", "-c", command] : ["/usr/bin/osascript", "-"]))
                #expect(calls.first?.input == (name == "run_command" ? Data() : Data(command.utf8)))
            }
        }
    }

    @Test func refusesMissingOrMismatchedVerification() async throws {
        let runner = FakeStdinRunner()
        let tool = RunCommand(runner: runner)
        let args = JSONObject([.init(key: "command", value: .string("echo different"))])
        let turn = TurnContext(channel: .voice)
        for verification in [nil, VerifiedShellCommand(line: "echo verified", verdict: ShellPolicy.strictVerdict("echo verified"))] {
            let ctx = ToolRunContext(toolName: "run_command", origin: .ui, turn: turn,
                                     verifiedShellCommand: verification)
            let result = try await tool.run(args, ctx)
            guard case .text(let text) = result else { Issue.record("expected refusal"); continue }
            #expect(text == GuardStrings.systemDamaging)
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func confirmationDefersExecutionAndTaintPreventsIt() async throws {
        let runner = FakeStdinRunner()
        let gate = ConfirmationGate()
        let gateway = ToolGateway(confirmationGate: gate, log: { _ in })
        await gateway.register(RunCommand(runner: runner))
        let turn = TurnContext(channel: .voice)
        let args = JSONObject([.init(key: "command", value: .string("sudo pmset -g"))])
        let pending = await gateway.call("run_command", args, turn: turn, origin: .model(.claude))
        #expect(pending.record.outcome == .gated)
        #expect(await runner.calls.isEmpty)
        #expect(await gate.consume("confirm", via: .voice, runIn: turn) == .handled("Done."))
        #expect(await runner.calls.count == 1)
        let tainted = TurnContext(channel: .voice, startTainted: true)
        let denied = await gateway.call("run_command", args, turn: tainted, origin: .model(.claude))
        #expect(denied.record.outcome == .blockedTaint)
        #expect(await runner.calls.count == 1)
    }

    /// Plan §3.4: shell children get the LaunchAgent's PATH, the rest of the app environment kept.
    @Test func agentEnvironmentReplacesOnlyPath() {
        let env = BoundedRunner.agentEnvironment(["PATH": "/usr/bin:/bin", "HOME": "/h", "LANG": "C"])
        #expect(env == ["PATH": BoundedRunner.agentPATH, "HOME": "/h", "LANG": "C"])
        #expect(BoundedRunner.agentEnvironment([:]) == ["PATH": BoundedRunner.agentPATH])
    }

    @Test func liveShellRunnersCarryTheAgentPath() {
        let platform = ToolPlatform.live
        for runner in [platform.commandRunner, platform.scriptRunner as any CommandRunning] {
            #expect((runner as? BoundedRunner)?.environment?["PATH"] == BoundedRunner.agentPATH)
        }
    }

    /// What the child sees, observed: a harmless printf of its own PATH.
    @Test func childShellSeesTheAgentPath() async throws {
        let runner = BoundedRunner(environment: BoundedRunner.agentEnvironment())
        let output = try #require(await runner.run(["/bin/sh", "-c", #"printf %s "$PATH""#], timeout: 10))
        #expect(output.completed)
        #expect(String(decoding: output.stdout, as: UTF8.self) == BoundedRunner.agentPATH)
    }

    private func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
}
