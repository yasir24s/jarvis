#if DEBUG
import Darwin
import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools
import Synchronization

/// `JARVIS --brain-smoke [--force-local] ("<text>" | --inject-taint-test)` (plan: M02-M04 §5
/// A-9 to A-11). DEBUG builds only. Runs one voice turn through the assembled brain, headless:
/// it never touches AppKit, and it holds the single-instance lock of its state root for the
/// whole run. It refuses to run unless JARVIS_HOME names the state root (D-39: acceptance runs
/// use a sandbox copy).
///
/// Prints, besides the log (mirrored to stdout as "[JARVIS] …" lines):
///   init apiKeySource=<v>, tools=<n>, mcp <server>=<status>   from `claude`'s init event
///   tool_use <name> <input>, tool_result: <text>              the model's calls and what came
///                                                             back to it, from the stream
///   tools/call <name> -> <outcome>                            each call the MCP server passed
///                                                             to the gateway for this turn
///   sentence: <text>                                          each sentence sent to the sink
///   backend=<name>                                            BackendReporter.last after the turn
///
/// The driver keeps the stream to itself, so the smoke runs `claude` through a tap: a bash
/// script that copies `claude`'s stdout to a file and then `exec`s `claude` with the same argv
/// and environment. `exec` keeps the pid the driver started, so the relay's parent is still the
/// pid the MCP handshake checks. The run and `claude-cwd` directories are in a private temp
/// directory, removed at the end, so the smoke never binds a running app's socket.
///
/// `--force-local` turns Claude off (JARVIS_USE_CLAUDE=0). `--inject-taint-test` sends a fixed
/// prompt asking for `echo hi` through run_command, as a pasted input, so the turn starts
/// tainted. The local brain is the assembly's own `LocalBrain`.
enum BrainSmoke {
    struct Options: Equatable {
        var text: String
        var forceLocal = false
        var injectTaint = false
    }

    static let usage = "usage: JARVIS --brain-smoke [--force-local] (\"<text>\" | --inject-taint-test)\n"
    static let taintTestPrompt = "Use the run_command tool to run the shell command `echo hi`, then tell me exactly what it printed."

    /// `--brain-smoke` and its flags, in any order after it; nil for anything else.
    static func parse(_ arguments: ArraySlice<String>) -> Options? {
        guard arguments.first == "--brain-smoke" else { return nil }
        var forceLocal = false, injectTaint = false
        var texts: [String] = []
        for argument in arguments.dropFirst() {
            switch argument {
            case "--force-local": forceLocal = true
            case "--inject-taint-test": injectTaint = true
            default:
                if argument.hasPrefix("--") { return nil }
                texts.append(argument)
            }
        }
        if injectTaint {
            return texts.isEmpty ? Options(text: taintTestPrompt, forceLocal: forceLocal, injectTaint: true) : nil
        }
        return texts.count == 1 ? Options(text: texts[0], forceLocal: forceLocal) : nil
    }

    /// Runs the turn off the main thread and parks the main thread; exits with its status.
    static func start(_ options: Options) -> Never {
        Task.detached { exit(await run(options)) }
        dispatchMain()
    }

    /// One line on stdout, unbuffered like the log mirror, so the two stay in order.
    static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((SecretRegistry.shared.redact(line) + "\n").utf8))
    }

    private static func fail(_ message: String, _ status: Int32) -> Int32 {
        FileHandle.standardError.write(Data("JARVIS --brain-smoke: \(message)\n".utf8))
        return status
    }

    static func run(_ options: Options) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["JARVIS_HOME"], !home.isEmpty else {
            return fail("set JARVIS_HOME to a sandbox copy of the state (D-39)", 64)   // EX_USAGE
        }
        let paths: StatePaths
        do {
            paths = try StatePaths.live()
        } catch {
            return fail("cannot resolve the state root: \(error)", 78)                  // EX_CONFIG
        }
        JarvisLog.configure(file: paths.logFile, mirrorToStdout: true)
        JarvisLog.banner()
        let lock: InstanceLock
        switch InstanceLock.tryAcquire(at: paths.lockFile, repoRoot: paths.root) {
        case .acquired(let held):
            lock = held
        case .held(let holder):
            return fail("another JARVIS (\(AppDelegate.describe(holder))) holds .jarvis.lock", 75)   // EX_TEMPFAIL
        case .foreignProcess(let pids):
            return fail("a pre-patch Python JARVIS (\(pids[0])) is running", 75)
        }

        let scratch: URL
        do {
            scratch = try makeScratchDirectory()
        } catch {
            return fail("cannot make a temp directory: \(error)", 73)                   // EX_CANTCREAT
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let research = UsageStore(paths: ResearchPaths(paths))
        let core: CoreState
        do {
            let store = try StateStore(root: paths.root.path(percentEncoded: false), lease: InstanceLockLease(lock))
            core = CoreState(store: store, clock: SystemClock(), research: research, frontApp: HeadlessFrontApp())
        } catch {
            return fail("cannot open the state store: \(error)", 78)
        }

        var config = ClaudeConfig(environment: environment)
        if options.forceLocal { config.enabled = false }
        let stream = scratch.appending(path: "claude-stream.jsonl", directoryHint: .notDirectory)
        var tapped: URL?
        if let claude = BrainAssembly.locateClaude(environment: environment, config: config) {
            do {
                tapped = try writeTap(claude: claude, stream: stream, in: scratch)
            } catch {
                return fail("cannot write the stream tap: \(error)", 73)
            }
        } else {
            say("claude: not found on the child PATH")
        }

        let turnBox = TurnBox()
        let tap = StreamTap(stream: tapped == nil ? nil : stream, turn: turnBox)
        let assembly = BrainAssembly(core: core, research: research, config: config,
                                     environment: environment,
                                     runDirectory: scratch.appending(path: "run", directoryHint: .isDirectory),
                                     claudeWorkingDirectory: scratch.appending(path: "claude-cwd", directoryHint: .isDirectory),
                                     claudeExecutable: tapped, textAuthenticator: RefusingAuthenticator(),
                                     online: { true }, onTurnStart: { turnBox.set($0) })
        do {
            try await assembly.start()
        } catch {
            return fail("cannot start the MCP server: \(error)", 71)                    // EX_OSERR
        }

        let poller = Task {
            while !Task.isCancelled {
                await tap.drain()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        _ = await assembly.coordinator.submit(UserInput(text: options.text, channel: .voice, pasted: options.injectTaint),
                                              sink: PrintingSink())
        poller.cancel()
        await tap.drain()
        say("backend=\(await assembly.backend.last.name)")
        await assembly.stop()
        withExtendedLifetime(lock) {}
        return 0
    }

    /// `/tmp/jarvis-smoke.XXXXXX` (0700): short, so `run/mcp.sock` stays under sun_path's limit.
    private static func makeScratchDirectory() throws -> URL {
        var template = Array("/tmp/jarvis-smoke.XXXXXX".utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }

    /// The tap: bash copies its stdout to `stream`, then becomes `claude` (same pid).
    private static func writeTap(claude: URL, stream: URL, in directory: URL) throws -> URL {
        func quoted(_ url: URL) -> String {
            "'" + url.path(percentEncoded: false).replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
        let script = """
        #!/bin/bash
        exec > >(/usr/bin/tee -a \(quoted(stream)))
        exec \(quoted(claude)) "$@"

        """
        let url = directory.appending(path: "claude-tap", directoryHint: .notDirectory)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }
}

/// The turn the coordinator made, set synchronously by its `onTurnStart`.
private final class TurnBox: Sendable {
    private let state = Mutex<TurnContext?>(nil)
    func set(_ turn: TurnContext) { state.withLock { $0 = turn } }
    var turn: TurnContext? { state.withLock { $0 } }
}

/// Reads the tapped stream and the turn's tool records as they grow, and prints what the smoke
/// reports from them.
private actor StreamTap {
    private let stream: URL?
    private let box: TurnBox
    private var offset: UInt64 = 0
    private var pending = Data()
    private var parser = StreamJSONParser()
    private var printedRuns = 0

    init(stream: URL?, turn: TurnBox) {
        self.stream = stream
        self.box = turn
    }

    func drain() async {
        if let stream, let handle = try? FileHandle(forReadingFrom: stream) {
            defer { try? handle.close() }
            if (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty {
                offset += UInt64(data.count)
                pending.append(data)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    for event in parser.parse(line) { report(event) }
                    reportTools(line)
                }
            }
        }
        if let turn = box.turn {
            let runs = await turn.summary().toolRuns
            for run in runs.dropFirst(printedRuns) { BrainSmoke.say("tools/call \(run.name) -> \(run.outcome)") }
            printedRuns = runs.count
        }
    }

    /// The model's tool calls and what came back to it, from the complete "assistant" and
    /// "user" messages (the partial-message events repeat them in pieces).
    private func reportTools(_ line: String) {
        guard let message = try? PyJSON.loads(Data(line.utf8)).objectValue,
              let content = message["message"]?.objectValue?["content"]?.arrayValue else { return }
        for item in content.compactMap(\.objectValue) {
            switch (message["type"]?.stringValue, item["type"]?.stringValue) {
            case ("assistant", "tool_use"):
                let input = item["input"].map { PyJSON.dumps($0) } ?? "{}"
                BrainSmoke.say("tool_use \(item["name"]?.stringValue ?? "?") \(input)")
            case ("user", "tool_result"):
                let text: String = switch item["content"] {
                case .string(let s)?: s
                case .array(let parts)?: parts.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: " ")
                default: ""
                }
                let error = item["is_error"] == .bool(true) ? " (is_error)" : ""
                BrainSmoke.say("tool_result\(error): \(text)")
            default:
                continue
            }
        }
    }

    private func report(_ event: ClaudeEvent) {
        guard case let .initInfo(apiKeySource, tools, mcp, _) = event else { return }
        BrainSmoke.say("init apiKeySource=\(apiKeySource)")
        BrainSmoke.say("tools=\(tools.count)")
        for name in mcp.keys.sorted() { BrainSmoke.say("mcp \(name)=\(mcp[name] ?? "")") }
    }
}

private struct PrintingSink: ReplySink {
    func sentence(_ text: String) async { BrainSmoke.say("sentence: \(text)") }
    func retracted(messageID: String) async { BrainSmoke.say("retracted \(messageID)") }
}

/// No frontmost-app read: that is NSWorkspace, which the smoke never touches. Python's
/// `_front_app()` gives "" when there is no frontmost app.
private struct HeadlessFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "" }
}

/// The smoke runs voice turns only; a text confirmation would be refused.
private struct RefusingAuthenticator: ConfirmAuthenticator {
    func authenticate(reason: String) async -> Bool { false }
}
#endif
