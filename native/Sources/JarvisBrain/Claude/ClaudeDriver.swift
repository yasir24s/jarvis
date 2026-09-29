import Foundation
import JarvisCore
import JarvisTools

// jarvis.py `claude_generate` / `_claude_stream` (plan: M02-M04 §3.6, run loop R1-R10 and
// salvage), driving the `claude` CLI directly instead of through the Agent SDK.

/// Where the driver reports the backend that served a turn: Python's `_set_backend(name)`.
/// Plan §3.10 puts `set(_:)` on `BackendReporter`, which does not have it yet (T3.1 shipped
/// only the counter key), so the driver takes this protocol. Once `BackendReporter.set`
/// exists, `extension BackendReporter: BackendReporting {}` connects the two.
public protocol BackendReporting: Sendable {
    func set(_ name: String) async
}

/// One Claude turn per `generate` call: open the turn's MCP files, run `claude` with
/// `ClaudeInvocation`'s argv and `ChildEnvironment`'s env in the empty `claude-cwd`, write
/// the one stdin line, then apply R1-R10 to the stream-json events as they arrive.
///
/// Where native differs from Python:
/// - A timeout's error is "timeout after <ms> ms", so the fallback log line says "timed out".
///   Python's `asyncio.wait_for` raises a `TimeoutError` with no text, so it says
///   "unavailable".
/// - Salvage on the text channel also counts text shown through `ReplySink.delta` that no
///   sentence has taken yet (plan §3.6: any displayed delta counts as emitted), and returns
///   it after the sentences. The voice channel returns the spoken sentences, as Python does.
/// - Text for a message that has been retracted (R6) is not fed.
/// - Stop signals go to the child's process group (see `ClaudeChild`).
public actor ClaudeDriver {
    /// R7's research counter (plan §3.12, additive). Not in `ResearchKey` yet.
    public static let refusalFallbackCounter = "claude_refusal_fallback"
    /// The backend name when an error ends a turn that had already emitted text.
    public static let partialBackend = "claude (partial)"
    /// The wait between SIGTERM and SIGKILL.
    public static let stopGrace: Duration = .seconds(2)

    /// The 46 `mcp__jarvis__<name>` names, in TOOLS order: the `--allowedTools` list, and
    /// the tool set R3 requires.
    public static var defaultAllowedTools: [String] {
        DataSourceMap.toolNames.map(ClaudeInvocation.allowedToolName)
    }

    /// `int(CLAUDE_TIMEOUT_MS) / 1000.0 + 15`. Where Python's `int()` raises (a value
    /// `Double` cannot read either, or one that is not finite), native uses the default
    /// 45000 ms and gets 60 s. Capped at 1e9 s so a huge value cannot overflow `Duration`.
    public static func wallTimeout(for config: ClaudeConfig) -> Duration {
        let seconds = (Double(Py.strip(config.timeoutMS)) ?? 45_000) / 1000 + 15
        return .seconds(seconds.isFinite ? min(seconds, 1e9) : 60)
    }

    /// D-5: the default model keeps Python's name `"claude"` (counter `backend_claude`);
    /// any other model gets Python's `"claude (<model>)"`.
    public static func successBackend(model: String) -> String {
        Py.eq(model, ClaudeConfig.defaultModel) ? "claude" : "claude (\(model))"
    }

    /// The single stdin line, `{"type":"user","message":{"role":"user","content":<text>}}`
    /// and "\n". The content is `json.dumps(text)`, so non-ASCII arrives as `\u` escapes.
    public static func stdinLine(user: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"# + PyJSON.dumps(.string(user)) + "}}\n"
    }

    private let config: ClaudeConfig
    private let executable: URL
    private let bridge: any MCPTurnBridge
    private let workingDirectory: URL
    private let research: any ResearchCounting
    private let backend: any BackendReporting
    private let parentEnvironment: [String: String]
    private let allowedTools: [String]
    private let timeout: Duration
    private let log: @Sendable (String) -> Void

    /// The last finished turn's error (an R-rule's text), or nil if it succeeded.
    public private(set) var lastError: String?
    /// How the last turn's `claude` ended: its exit status, or minus the signal that killed
    /// it (-15 for SIGTERM, -9 for SIGKILL). nil if it did not start.
    public private(set) var lastExit: Int32?
    /// The model that served the last finished turn: the configured model, or R7's
    /// fallback model after a refusal fallback.
    public private(set) var servingModel: String?

    /// - Parameters:
    ///   - executable: the `claude` binary (`ClaudeLocator.find`).
    ///   - workingDirectory: `claude-cwd`. The app passes
    ///     `~/Library/Application Support/JARVIS/claude-cwd/` and keeps it empty; it is
    ///     created with mode 0700 if missing.
    ///   - timeout: the wall timeout; nil means `wallTimeout(for: config)`.
    ///   - log: where log lines go. Tests pass their own.
    public init(config: ClaudeConfig, executable: URL, bridge: any MCPTurnBridge, workingDirectory: URL,
                research: any ResearchCounting, backend: any BackendReporting,
                parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                allowedTools: [String] = ClaudeDriver.defaultAllowedTools, timeout: Duration? = nil,
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
        self.log = log
    }

    /// The reply, or nil to fall back to the local model. Never throws. Cancelling the
    /// calling task stops `claude` like a timeout does.
    public func generate(system: String, user: String, turn: TurnContext, sink: any ReplySink) async -> String? {
        let (signals, input) = AsyncStream.makeStream(of: ClaudeSignal.self)
        // The turn runs in its own task, so a cancelled caller still gets the full stop
        // sequence: a cancelled task's AsyncStream iteration and Task.sleep end at once.
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
        var state = TurnState(servingModel: config.model)
        let channel = await turn.channel

        let files: MCPTurnFiles
        do {
            files = try await bridge.openTurn(turn)
        } catch {
            state.error = "tool bridge: \(error)"
            await bridge.closeTurn(await turn.turnID)
            return await conclude(state, channel: channel)
        }

        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        do {
            let invocation = try ClaudeInvocation(executable: executable, systemPrompt: system,
                                                  mcpConfig: files.configPath, allowedTools: allowedTools,
                                                  config: config)
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.environment = ChildEnvironment.forClaude(parent: parentEnvironment, config: config, log: log)
            process.currentDirectoryURL = workingDirectory
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { input.yield(.exited(ClaudeExit($0))) }
            try process.run()
        } catch let error as ClaudeInvocationError {
            state.error = "argv: \(error)"
        } catch {
            state.error = Self.launchError(error)
        }
        if state.error != nil {
            await bridge.closeTurn(files.turnID)
            return await conclude(state, channel: channel)
        }

        let child = ClaudeChild(pid: process.processIdentifier)
        let wall = timeout
        let timer = Task.detached {
            do {
                try await Task.sleep(for: wall)
                input.yield(.timedOut)
            } catch {
                // Cancelled: the turn ended first.
            }
        }
        ClaudeStreams.startLineReader(stdout.fileHandleForReading, into: input)
        ClaudeStreams.startTailReader(stderr.fileHandleForReading, into: input)
        await bridge.setClaudePID(child.pid, for: files.turnID)
        Self.write(Self.stdinLine(user: user), to: stdin.fileHandleForWriting)

        var watch = Watch()
        loop: for await signal in signals {
            switch signal {
            case .line(let text):
                guard !watch.stopping, state.error == nil else { continue }
                for event in state.parser.parse(text) {
                    if let trip = await apply(event, to: &state, sink: sink) {
                        state.error = trip
                        watch.beginStop(child, why: trip, input: input, log: log)
                    }
                    if state.error != nil { break }
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
            } else if !watch.stdoutOpen, watch.exit != nil, !watch.stderrOpen || state.resultSeen {
                break loop
            }
        }
        timer.cancel()
        withExtendedLifetime(process) {}

        if watch.stopping {
            await turn.close()
        }
        await bridge.closeTurn(files.turnID)
        if state.error == nil && !state.resultSeen {
            // R10.
            let code = watch.exit.map { String($0.code) } ?? "?"
            state.error = "exit \(code): \(Py.strip(String(decoding: watch.stderrTail, as: UTF8.self)))"
        }
        if state.error == nil {
            // Python's pop_sentences(buf, force=True) after the loop: text after the result.
            let sentences = state.pop(force: true)
            await emit(sentences, to: &state, sink: sink)
        }
        return await conclude(state, channel: channel, exit: watch.exit)
    }

    /// R1-R9 for one event. Returns an error that must stop the child (a guard trip).
    private func apply(_ event: ClaudeEvent, to s: inout TurnState, sink: any ReplySink) async -> String? {
        switch event {
        case let .initInfo(apiKeySource, tools, mcp, _):
            if !Py.eq(apiKeySource, "none") {
                return "subscription-only: apiKeySource=\(apiKeySource)"                     // R1
            }
            if !Py.eq(mcp[ClaudeInvocation.serverName] ?? "", "connected") {
                return "tool bridge not connected"                                          // R2
            }
            if Self.scalarSet(tools) != Self.scalarSet(allowedTools) {
                return "unexpected tool set"                                                // R3
            }
        case let .textDelta(id, text):                                                      // R4
            guard !s.retracted.contains(id) else { break }
            s.deltaSeen.insert(id)
            await feed(text, from: id, to: &s, sink: sink)
        case let .blockText(id, text):                                                      // R5
            guard !s.deltaSeen.contains(id), !s.retracted.contains(id) else { break }
            await feed(text, from: id, to: &s, sink: sink)
        case let .stopReason(id, reason):                                                   // R6
            guard Py.eq(reason, "refusal") else { break }
            s.discard(id)
            s.retracted.insert(id)
            await sink.retracted(messageID: id)
        case let .refusalFallback(from, to, category):                                      // R7
            s.servingModel = to
            research.bump(Self.refusalFallbackCounter, by: 1)
            log("Claude refusal fallback: \(from)→\(to) (\(category))")
        case let .rateLimit(status, isUsingOverage):                                        // R8
            if isUsingOverage {
                return "overage billing refused"
            }
            if !Py.eq(status, "allowed") {
                s.rateLimitStatus = status
            }
        case let .result(subtype, isError, text, apiErrorStatus):                           // R9
            s.resultSeen = true
            if !Py.eq(subtype, "success") || isError {
                s.error = Self.resultError(subtype: subtype, apiErrorStatus: apiErrorStatus, text: text)
                break
            }
            if let text, !text.isEmpty, s.spoken.isEmpty, Py.strip(s.buf).isEmpty {
                await sink.delta(text)
                s.append(text, from: "")
            }
            let sentences = s.pop(force: true)
            await emit(sentences, to: &s, sink: sink)
        case .status, .messageStart, .toolResult, .unknown:
            break
        }
        return nil
    }

    /// `buf += text`, then `pop_sentences(buf)`, then emit. The raw text goes to `delta` first.
    private func feed(_ text: String, from id: String, to s: inout TurnState, sink: any ReplySink) async {
        guard !text.isEmpty else { return }
        await sink.delta(text)
        s.append(text, from: id)
        let sentences = s.pop(force: false)
        await emit(sentences, to: &s, sink: sink)
    }

    private func emit(_ sentences: [String], to s: inout TurnState, sink: any ReplySink) async {
        for sentence in sentences {
            s.spoken.append(sentence)
            await sink.sentence(sentence)
        }
    }

    /// Salvage (jarvis.py `claude_generate`'s except branch) and the success return.
    private func conclude(_ s: TurnState, channel: Channel, exit: ClaudeExit? = nil) async -> String? {
        lastError = s.error
        lastExit = exit?.code
        servingModel = s.servingModel
        if let error = s.error {
            var emitted = s.spoken
            if channel == .text {
                let shown = Py.strip(s.buf)
                if !shown.isEmpty { emitted.append(shown) }
            }
            if !emitted.isEmpty {
                await backend.set(Self.partialBackend)
                return Py.strip(emitted.joined(separator: " "))
            }
            // R8: a rate-limit status other than "allowed" is part of the reason.
            let reason = ClaudeReason.reason(s.rateLimitStatus.map { "rate limit \($0): \(error)" } ?? error)
            log("Claude unavailable this turn — using local model: \(reason)")
            return nil
        }
        let reply = Py.strip(s.spoken.joined(separator: " "))
        guard !reply.isEmpty else {
            log("Claude unavailable this turn — using local model: empty response")
            return nil
        }
        await backend.set(Self.successBackend(model: config.model))
        return reply
    }

    /// R9's error: `result: <subtype> <apiErrorStatus> <text prefix 200>`, leaving out a
    /// status or text the result does not have (with neither it is Python's
    /// `f"result: {message.subtype}"`). The prefix counts code points, as Python does.
    static func resultError(subtype: String, apiErrorStatus: Int?, text: String?) -> String {
        var parts = ["result:", subtype]
        if let apiErrorStatus { parts.append(String(apiErrorStatus)) }
        if let text, !text.isEmpty {
            parts.append(String(String.UnicodeScalarView(text.unicodeScalars.prefix(200))))
        }
        return parts.joined(separator: " ")
    }

    /// A `claude` that cannot be started. A missing file gives `ClaudeLocator`'s
    /// "enoent: claude", which `ClaudeReason` turns into "Claude Code CLI not found".
    static func launchError(_ error: any Error) -> String {
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) {
            return ClaudeLocator.notFoundMessage
        }
        return "spawn: \(ns.localizedDescription)"
    }

    /// Writes the stdin line and closes stdin, off the actor, so a child that never reads
    /// cannot block the turn. EPIPE from a child that already exited is ignored.
    private static func write(_ line: String, to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let data = Data(line.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// Tool names compared code point by code point, as Python's `set` compares `str`.
    private static func scalarSet(_ names: [String]) -> Set<[Unicode.Scalar]> {
        Set(names.map { Array($0.unicodeScalars) })
    }
}

/// One turn's text state.
private struct TurnState {
    struct Segment {
        let id: String
        var text: String
    }

    var parser = StreamJSONParser()
    /// Python's `buf`, kept as the runs of text each message fed, so R6 can drop one
    /// message's part.
    private(set) var segments: [Segment] = []
    /// Python's `spoken`: every sentence passed to `ReplySink.sentence`.
    var spoken: [String] = []
    var deltaSeen: Set<String> = []
    var retracted: Set<String> = []
    var resultSeen = false
    var error: String?
    var rateLimitStatus: String?
    var servingModel: String

    init(servingModel: String) {
        self.servingModel = servingModel
    }

    var buf: String {
        segments.map(\.text).joined()
    }

    mutating func append(_ text: String, from id: String) {
        if let last = segments.indices.last, segments[last].id == id {
            segments[last].text += text
        } else {
            segments.append(Segment(id: id, text: text))
        }
    }

    /// `pop_sentences(buf, force)`. The remainder is always a suffix of `buf`, so the
    /// segments lose text from the front.
    mutating func pop(force: Bool) -> [String] {
        let (sentences, rest) = SentenceSplitter.pop(buf, force: force)
        var drop = segments.reduce(0) { $0 + $1.text.unicodeScalars.count } - rest.unicodeScalars.count
        while drop > 0, let first = segments.first {
            let n = first.text.unicodeScalars.count
            if n <= drop {
                segments.removeFirst()
                drop -= n
            } else {
                segments[0].text = String(String.UnicodeScalarView(first.text.unicodeScalars.dropFirst(drop)))
                drop = 0
            }
        }
        return sentences
    }

    /// R6: the refused message's text that no sentence has taken yet.
    mutating func discard(_ id: String) {
        segments.removeAll { $0.id == id }
    }
}

/// The child's side of one turn: which pipes are still open, how it exited, and the stop
/// sequence. The stop sequence does not rely on SIGTERM being honoured: SIGTERM, then
/// `ClaudeDriver.stopGrace`, then SIGKILL. The loop ends once claude itself has exited;
/// the SIGKILL to its process group still follows the grace, for anything it started.
private struct Watch {
    var exit: ClaudeExit?
    var stdoutOpen = true
    var stderrOpen = true
    var stderrTail: [UInt8] = []
    var stopping = false
    var killed = false

    /// SIGTERM to claude's process group (to claude alone while it runs, if it is not a
    /// group leader), and the timer for SIGKILL. Once.
    mutating func beginStop(_ child: ClaudeChild, why: String, input: AsyncStream<ClaudeSignal>.Continuation,
                            log: @Sendable (String) -> Void) {
        guard !stopping else { return }
        stopping = true
        guard exit == nil || child.isGroupLeader else { return }
        log("Claude: stopping claude (\(why)): SIGTERM")
        child.send(SIGTERM)
        let exited = exit != nil
        Task.detached {
            do {
                try await Task.sleep(for: ClaudeDriver.stopGrace)
            } catch {
                return
            }
            if child.isGroupLeader { child.send(SIGKILL) }
            if !exited { input.yield(.stopDeadline) }
        }
    }

    /// The grace is over and claude has not exited: the group already got SIGKILL; a child
    /// that is not a group leader gets it now. Then one more grace. Returns false when there
    /// is nothing left to wait for.
    mutating func escalate(_ child: ClaudeChild, input: AsyncStream<ClaudeSignal>.Continuation,
                           log: @Sendable (String) -> Void) -> Bool {
        guard exit == nil else { return false }
        guard !killed else {
            log("Claude: claude still running after SIGKILL; giving up on it")
            return false
        }
        log("Claude: claude still running 2 s after SIGTERM: SIGKILL")
        if !child.isGroupLeader { child.send(SIGKILL) }
        killed = true
        Task.detached {
            do {
                try await Task.sleep(for: ClaudeDriver.stopGrace)
                input.yield(.stopDeadline)
            } catch {
                // Cancelled.
            }
        }
        return true
    }
}
