import Darwin
import Foundation
import JarvisCore

struct RunCommand: ToolImpl {
    static let name = "run_command"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let runner: any CommandRunning

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        // The gateway's reading, as Python's args.get("command", ""): the line it verified.
        let command = args["command"]?.stringValue ?? ""
        guard let verified = ctx.verifiedShellCommand, Py.eq(verified.line, command),
              verified.verdict.tier != .block else {
            return .text(GuardStrings.systemDamaging)
        }
        if command.utf8.contains(0) { return .text("Error: embedded null byte") }
        return .text(ShellText.command(await runner.run(["/bin/sh", "-c", verified.line], timeout: 30)))
    }
}

struct RunAppleScript: ToolImpl {
    static let name = "run_applescript"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let runner: any StdinCommandRunning

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let script = args["script"]?.stringValue ?? ""
        return .text(await AppleScriptRunner(runner: runner).run(script))
    }
}

/// Internal scripts (later system controls) share transport, not the model script guard.
struct AppleScriptRunner: Sendable {
    let runner: any StdinCommandRunning

    func run(_ script: String) async -> String {
        ShellText.appleScript(await runner.run(["/usr/bin/osascript", "-"],
                                              input: Data(script.utf8), timeout: 30))
    }
}

enum ShellText {
    static func command(_ output: ProcessOutput?) -> String {
        guard let output else { return "Error: command could not be started" }
        if output.timedOut { return "Command timed out." }
        if let code = output.launchErrno { return "Error: \(osError(code, executable: "/bin/sh"))" }
        // subprocess text=True decodes both streams before choosing stdout over stderr.
        if let error = PyText.decodeError(output.stdout) ?? PyText.decodeError(output.stderr) {
            return "Error: \(error)"
        }
        let stdout = PyText.decode(output.stdout) ?? ""
        let stderr = PyText.decode(output.stderr) ?? ""
        return Py.prefix(Py.strip(!stdout.isEmpty ? stdout : !stderr.isEmpty ? stderr : "Done."), 1500)
    }

    static func appleScript(_ output: ProcessOutput?) -> String {
        guard let output else { return "AppleScript error: command could not be started" }
        if output.timedOut {
            return "AppleScript error: Command '['osascript', '-']' timed out after 30 seconds"
        }
        if let code = output.launchErrno { return "AppleScript error: \(osError(code, executable: "osascript"))" }
        let bytes = !output.stdout.isEmpty ? output.stdout : !output.stderr.isEmpty ? output.stderr : Data("Done.".utf8)
        return Py.prefix(Py.strip(String(decoding: bytes, as: UTF8.self)), 1000)
    }

    private static func osError(_ code: Int32, executable: String) -> String {
        "[Errno \(code)] \(String(cString: strerror(code))): '\(executable)'"
    }
}

enum ActionProcess {
    /// Python subprocess errors for the fixed internal command vectors (not shell input).
    static func require(_ output: ProcessOutput?, argv: [String], timeout: Int) throws -> ProcessOutput {
        guard let output else { throw PyError(description: "command could not be started") }
        if output.timedOut {
            let command = PyArgs.repr(.array(argv.map(JSONValue.string)))
            throw PyError(description: "Command '\(command)' timed out after \(timeout) seconds")
        }
        if let code = output.launchErrno {
            throw PyError(description: "[Errno \(code)] \(String(cString: strerror(code))): \(PyRepr.string(argv[0]))")
        }
        if output.truncated { throw PyError(description: "Command output exceeded the safety limit.") }
        return output
    }
}
