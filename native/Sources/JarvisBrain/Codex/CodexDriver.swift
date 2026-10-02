import Foundation
import JarvisCore
import JarvisTools

/// B2: one ChatGPT turn per `generate` call, through `codex exec` on the user's ChatGPT
/// sign-in. The sibling of `ClaudeDriver`, sharing its process plumbing (`ClaudeSignal`,
/// `ClaudeStreams`, `ClaudeChild`, `Watch`), its sentence splitting and its salvage rule:
///
/// 1. Open the turn's MCP files (the same per-turn relay Claude uses), read the relay's
///    command from them, and write the turn's model catalog, whose base instructions are the
///    system prompt (`CodexInvocation`).
/// 2. Run `codex` with `CodexInvocation`'s argv and `ChildEnvironment.forCodex`'s env in the
///    empty `codex-cwd`, write the message to stdin and close it.
/// 3. Apply C1-C6 to the JSON events as they arrive:
///    - C1: model output before `thread.started` stops the child.
///    - C2: an item that is a Codex built-in tool, or an MCP call to another server or to a tool
///      not in `allowedTools`, stops the child ("built-in tool: …", "unexpected tool: …").
///    - C3: an agent message goes to the sink whole (exec's JSON has no text deltas): its text
///      as one `delta`, then all its sentences. A message after a tool call is set apart by a
///      blank line, as Claude's are (P4).
///    - C4: a retry notice that cannot succeed this turn (signed out, rate limited, offline)
///      stops the child at once rather than after the CLI's own retries (about 25 s signed out;
///      offline it would wait for the network).
///    - C5: `turn.failed` ends the turn with its message.
///    - C6: `turn.completed` ends it well. Ending without either is "exit <code>: <stderr>".
///
/// The wall timeout, cancellation (UI1's Stop) and the stop sequence are Claude's: SIGTERM to
/// the child's process group, then SIGKILL after `stopGrace`, and a stopped turn's MCP turn is
/// revoked (`TurnContext.close`).
public actor CodexDriver: ClaudeGenerating {
    /// The backend name when an error ends a turn that had already emitted text.
    public static let partialBackend = "chatgpt (partial)"
    /// The wait between SIGTERM and SIGKILL.
    public static let stopGrace: Duration = .seconds(2)
    /// The log lines' name for this brain.
    public static let displayName = "ChatGPT"

    /// "chatgpt (<model>)": the "Backend: <name>" line and its `backend_…` counter.
    public static func successBackend(model: String) -> String {
        "chatgpt (\(model))"
    }

    /// `JARVIS_CHATGPT_TIMEOUT_MS / 1000 + 15`, Claude's formula, so the default is 60 s as
    /// Claude's is. A value `Double` cannot read, or one that is not finite, gives 60 s. Capped at
    /// 1e9 s so a huge value cannot overflow `Duration`.
    public static func wallTimeout(for config: CodexConfig) -> Duration {
        let seconds = (Double(Py.strip(config.timeoutMS)) ?? 45_000) / 1000 + 15
        return .seconds(seconds.isFinite && seconds > 0 ? min(seconds, 1e9) : 60)
    }

    private let config: CodexConfig
    private let executable: URL
    private let bridge: any MCPTurnBridge
    private let workingDirectory: URL
    private let research: any ResearchCounting
    private let backend: any BackendReporting
    private let parentEnvironment: [String: String]
    private let allowedTools: [String]
    private let timeout: Duration
    private let timeoutWait: @Sendable (Duration) async throws -> Void
    private let stopGrace: Duration
    private let log: @Sendable (String) -> Void

    /// The last finished turn's error, or nil if it succeeded.
    public private(set) var lastError: String?
    /// How the last turn's `codex` ended: its exit status, or minus the signal that killed it.
    /// nil if it did not start.
    public private(set) var lastExit: Int32?
    /// The JARVIS tools the last turn called, in order (`server.tool`).
    public private(set) var lastToolCalls: [String] = []
    /// The Codex built-in items the last turn saw (C2 stops the turn at the first).
    public private(set) var lastBuiltIns: [String] = []
    /// The last finished turn's token counts, from `turn.completed`.
    public private(set) var lastUsage: (input: Int?, output: Int?)?

    /// - Parameters:
    ///   - executable: the `codex` CLI (`CodexLocator.find`).
    ///   - workingDirectory: `codex-cwd`, kept empty; created with mode 0700 if missing.
    ///   - allowedTools: the MCP tool names offered (`enabled_tools`), in TOOLS order; an MCP
    ///     call to any other name stops the turn.
    ///   - timeout: the wall timeout; nil means `wallTimeout(for: config)`.
    ///   - timeoutWait, stopGrace, log: as `ClaudeDriver`'s.
    public init(config: CodexConfig, executable: URL, bridge: any MCPTurnBridge, workingDirectory: URL,
                research: any ResearchCounting, backend: any BackendReporting,
                parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                allowedTools: [String] = DataSourceMap.toolNames, timeout: Duration? = nil,
                timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                stopGrace: Duration = CodexDriver.stopGrace,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.config = config
        self.executable = executable
        self.bridge = bridge
        self.workingDirectory = workingDirectory
        self.research = research
        self.backend = backend
        self.parentEnvironment = parentEnvironment
        self.allowedTools = allowedTools
        self.timeout = timeout ?? Self.wallTimeout(for: config)
        self.timeoutWait = timeoutWait
        self.stopGrace = stopGrace
        self.log = log
    }

    /// The reply, or nil to fall back to the local model. Never throws. Cancelling the calling
    /// task stops `codex` like a timeout does.
    public func generate(system: String, user: String, turn: TurnContext, sink: any ReplySink) async -> String? {
        let (signals, input) = AsyncStream.makeStream(of: ClaudeSignal.self)
        let turnTask = Task {
            await self.run(system: system, user: user, turn: turn, sink: sink, signals: signals, input: input)
        }
        return await withTaskCancellationHandler {
            await turnTask.value
        } onCancel: {
            input.yield(.cancelled)
        }
    }

    private func run(system: String, user: String, turn: TurnContext, sink: any ReplySink,
                     signals: AsyncStream<ClaudeSignal>, input: AsyncStream<ClaudeSignal>.Continuation) async -> String? {
        defer { input.finish() }
        var state = CodexTurnState()
        let channel = await turn.channel

        let files: MCPTurnFiles
        do {
            files = try await bridge.openTurn(turn)
        } catch {
            state.error = "tool bridge: \(error)"
            await bridge.closeTurn(await turn.turnID)
            return await conclude(state, channel: channel)
        }

        var catalog: URL?
        defer {
            if let catalog { try? FileManager.default.removeItem(at: catalog) }
        }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        do {
            let relay: CodexInvocation.Relay
            do {
                relay = try CodexInvocation.Relay.read(mcpConfig: files.configPath)
            } catch {
                throw SetupError(text: "tool bridge: \(error)")
            }
            let written: URL
            do {
                written = try CodexInvocation.writeCatalog(in: files.configPath.deletingLastPathComponent(),
                                                           turnID: files.turnID, model: config.model,
                                                           instructions: system)
            } catch {
                throw SetupError(text: "catalog: \(error)")
            }
            catalog = written
            let invocation = try CodexInvocation(executable: executable, workingDirectory: workingDirectory,
                                                 catalog: written, relay: relay, enabledTools: allowedTools,
                                                 config: config)
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.environment = ChildEnvironment.forCodex(parent: parentEnvironment, log: log)
            process.currentDirectoryURL = workingDirectory
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { input.yield(.exited(ClaudeExit($0))) }
            try process.run()
        } catch let error as SetupError {
            state.error = error.text
        } catch let error as CodexInvocationError {
            state.error = "argv: \(error)"
        } catch {
            state.error = Self.launchError(error)
        }
        if state.error != nil {
            await bridge.closeTurn(files.turnID)
            return await conclude(state, channel: channel)
        }

        let child = ClaudeChild(pid: process.processIdentifier)
        let wall = timeout, wait = timeoutWait
        let timer = Task.detached {
            do {
                try await wait(wall)
                input.yield(.timedOut)
            } catch {
                // Cancelled: the turn ended first.
            }
        }
        ClaudeStreams.startLineReader(stdout.fileHandleForReading, into: input)
        ClaudeStreams.startTailReader(stderr.fileHandleForReading, into: input)
        // The relay's handshake checks its parent against this pid: `codex` itself starts it
        // (the app's launcher script `exec`s the binary, so the pid stays the same).
        await bridge.setClaudePID(child.pid, for: files.turnID)
        ClaudeDriver.write(user, to: stdin.fileHandleForWriting)

        var watch = Watch(grace: stopGrace, owner: Self.displayName, name: "codex")
        loop: for await signal in signals {
            switch signal {
            case .line(let text):
                guard !watch.stopping, state.error == nil, let event = CodexEvent.parse(text) else { continue }
                if let trip = await apply(event, to: &state, sink: sink) {
                    state.error = trip
                    watch.beginStop(child, why: trip, input: input, log: log)
                }
            case .stdoutClosed:
                watch.stdoutOpen = false
            case .stderrClosed(let tail):
                watch.stderrOpen = false
                watch.stderrTail = tail
            case .exited(let exit):
                watch.exit = exit
            case .timedOut:
                let why = "timeout after \(Int(wall / .milliseconds(1))) ms"
                state.error = state.error ?? why
                watch.beginStop(child, why: why, input: input, log: log)
            case .cancelled:
                state.error = state.error ?? "cancelled"
                watch.beginStop(child, why: "cancelled", input: input, log: log)
            case .stopDeadline:
                if !watch.escalate(child, input: input, log: log) { break loop }
            }
            if watch.stopping {
                if watch.exit != nil { break loop }
            } else if !watch.stdoutOpen, watch.exit != nil, !watch.stderrOpen || state.ended {
                break loop
            }
        }
        timer.cancel()
        withExtendedLifetime(process) {}

        if watch.stopping {
            await turn.close()
        }
        await bridge.closeTurn(files.turnID)
        if state.error == nil && !state.ended {
            let code = watch.exit.map { String($0.code) } ?? "?"
            let detail = state.lastRetry ?? Py.strip(String(decoding: watch.stderrTail, as: UTF8.self))
            state.error = "exit \(code): \(Py.prefix(detail, 300))"
        }
        if state.error == nil {
            await emit(state.pop(force: true), to: &state, sink: sink)
        }
        return await conclude(state, channel: channel, exit: watch.exit)
    }

    private struct SetupError: Error {
        let text: String
    }

    /// C1-C6 for one event. Returns an error that must stop the child.
    private func apply(_ event: CodexEvent, to s: inout CodexTurnState, sink: any ReplySink) async -> String? {
        switch event {
        case .message, .toolCall, .builtIn, .turnCompleted:
            if !s.threadSeen { return "no thread event before content" }                    // C1
        default:
            break
        }
        switch event {
        case .threadStarted:
            s.threadSeen = true
        case .turnStarted, .reasoning, .unknown:
            break
        case let .builtIn(type):                                                            // C2
            s.builtIns.append(type)
            return "built-in tool: \(type)"
        case let .toolCall(id, server, tool, finished, failed):                             // C2
            guard Py.eq(server, CodexInvocation.serverName), allowedTools.contains(where: { Py.eq($0, tool) }) else {
                s.builtIns.append("\(server).\(tool)")
                return "unexpected tool: \(server).\(tool)"
            }
            if !s.callIDs.contains(id) {
                s.callIDs.insert(id)
                s.toolCalls.append("\(server).\(tool)")
            }
            if finished && failed {
                log("ChatGPT: tool \(tool) failed")
            }
        case let .message(id, text):                                                        // C3
            await feed(text, from: id, to: &s, sink: sink)
        case let .notice(message):
            s.lastRetry = message
        case let .error(message):                                                           // C4
            s.lastRetry = message
            let reason = CodexReason.reason(message)
            if ["not signed in", "rate limited", "network unreachable"].contains(reason) {
                return Py.prefix(message, 300)
            }
        case let .turnFailed(message):                                                      // C5
            s.ended = true
            s.error = "turn failed: \(Py.prefix(message, 300))"
        case let .turnCompleted(input, output):                                             // C6
            s.ended = true
            s.usage = (input, output)
        }
        return nil
    }

    /// The message's text to `delta`, then all its sentences: the message is complete, so its
    /// last sentence is spoken now rather than when the next message or the end of the turn
    /// comes. A later message's text is set apart by a blank line in `delta` and the reply (P4).
    private func feed(_ text: String, from id: String, to s: inout CodexTurnState, sink: any ReplySink) async {
        guard !text.isEmpty else { return }
        if let last = s.lastTextID, last != id {
            s.messageStarts.insert(s.spoken.count)
            await sink.delta(CodexTurnState.messageBreak)
        }
        s.lastTextID = id
        await sink.delta(text)
        s.buf += text
        await emit(s.pop(force: true), to: &s, sink: sink)
    }

    private func emit(_ sentences: [String], to s: inout CodexTurnState, sink: any ReplySink) async {
        for sentence in sentences {
            s.spoken.append(sentence)
            await sink.sentence(sentence)
        }
    }

    /// Claude's salvage and success return, under ChatGPT's names.
    private func conclude(_ s: CodexTurnState, channel: Channel, exit: ClaudeExit? = nil) async -> String? {
        lastError = s.error
        lastExit = exit?.code
        lastToolCalls = s.toolCalls
        lastBuiltIns = s.builtIns
        lastUsage = s.usage
        if let error = s.error {
            var emitted = s.spoken
            if channel == .text {
                let shown = Py.strip(s.buf)
                if !shown.isEmpty { emitted.append(shown) }
            }
            if !emitted.isEmpty {
                await backend.set(Self.partialBackend)
                return Py.strip(s.joined(emitted))
            }
            log("ChatGPT unavailable this turn — using local model: \(CodexReason.reason(error))")
            return nil
        }
        let reply = Py.strip(s.joined(s.spoken))
        guard !reply.isEmpty else {
            log("ChatGPT unavailable this turn — using local model: empty response")
            return nil
        }
        await backend.set(Self.successBackend(model: config.model))
        return reply
    }

    /// A `codex` that cannot be started: a missing file gives `CodexLocator`'s "enoent: codex".
    static func launchError(_ error: any Error) -> String {
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) {
            return CodexLocator.notFoundMessage
        }
        return "spawn: \(ns.localizedDescription)"
    }
}

/// One ChatGPT turn's text state. Messages arrive whole, so unlike Claude's there is nothing to
/// retract and `buf` is a plain string.
private struct CodexTurnState {
    static let messageBreak = "\n\n"
    var buf = ""
    var spoken: [String] = []
    var messageStarts: Set<Int> = []
    var lastTextID: String?
    var threadSeen = false
    var ended = false
    var error: String?
    /// The last retry notice or error event, for an exit with no `turn.failed`.
    var lastRetry: String?
    var callIDs: Set<String> = []
    var toolCalls: [String] = []
    var builtIns: [String] = []
    var usage: (input: Int?, output: Int?)?

    func joined(_ sentences: [String]) -> String {
        var out = ""
        for (i, sentence) in sentences.enumerated() {
            if i > 0 { out += messageStarts.contains(i) ? Self.messageBreak : " " }
            out += sentence
        }
        return out
    }

    mutating func pop(force: Bool) -> [String] {
        let (sentences, rest) = SentenceSplitter.pop(buf, force: force)
        buf = rest
        return sentences
    }
}
