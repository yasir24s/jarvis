import Foundation
import JarvisCore

/// The Claude persona writer: one `claude -p` call with no tools and no MCP server, under a
/// turn's rules. The argv is `ClaudeInvocation(oneShot:)` (subscription auth, never a
/// forbidden flag), the environment `ChildEnvironment.forClaude`, the working directory the
/// driver's, and the stop sequence the driver's `Watch`. From the stream it keeps the rules
/// that still apply: R1 subscription only, no MCP server and no tool in the init event, R6
/// a refused message's text dropped, R8 overage refused, R9 a successful result. It counts
/// nothing and reports no backend: this is not a turn.
///
/// `JARVIS_USE_CLAUDE=0` or offline: it throws without starting `claude`, as a turn falls
/// back to the local model there. Any failure throws a reason that holds no model output.
public struct ClaudePersonaLLM: PersonaLLM {
    private let config: ClaudeConfig
    private let executable: URL
    private let workingDirectory: URL
    private let parentEnvironment: [String: String]
    private let online: @Sendable () async -> Bool
    private let timeoutWait: @Sendable (Duration) async throws -> Void
    private let stopGrace: Duration
    private let log: @Sendable (String) -> Void

    /// - Parameters:
    ///   - executable, workingDirectory, parentEnvironment, config: the driver's.
    ///   - online: the check a turn makes before trying Claude.
    ///   - timeoutWait: waits out the timeout, which fires when it returns. Tests pass their own.
    ///   - stopGrace: the wait between SIGTERM and SIGKILL (`ClaudeDriver.stopGrace`).
    public init(config: ClaudeConfig, executable: URL, workingDirectory: URL,
                parentEnvironment: [String: String], online: @escaping @Sendable () async -> Bool,
                timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                stopGrace: Duration = ClaudeDriver.stopGrace,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.config = config
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.parentEnvironment = parentEnvironment
        self.online = online
        self.timeoutWait = timeoutWait
        self.stopGrace = stopGrace
        self.log = log
    }

    public func complete(system: String, user: String, timeout: Duration) async throws -> String {
        guard config.enabled else { throw PersonaWriterError.claudeOff }
        guard await online() else { throw PersonaWriterError.offline }
        try Task.checkCancellation()
        let (signals, input) = AsyncStream.makeStream(of: ClaudeSignal.self)
        // As in the driver: the call runs in its own task, so a cancelled caller still gets
        // the whole stop sequence.
        let call = Task {
            await self.run(system: system, user: user, timeout: timeout, signals: signals, input: input)
        }
        let outcome = await withTaskCancellationHandler {
            await call.value
        } onCancel: {
            input.yield(.cancelled)
        }
        return try outcome.get()
    }

    private func run(system: String, user: String, timeout: Duration, signals: AsyncStream<ClaudeSignal>,
                     input: AsyncStream<ClaudeSignal>.Continuation) async -> Result<String, PersonaWriterError> {
        defer { input.finish() }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        do {
            let invocation = try ClaudeInvocation(oneShot: executable, systemPrompt: system, config: config)
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
            return .failure(.claudeFailed("argv: \(error)"))
        } catch {
            return .failure(.claudeFailed(Self.reason(ClaudeDriver.launchError(error), otherwise: "spawn failed")))
        }

        let child = ClaudeChild(pid: process.processIdentifier)
        let wait = timeoutWait
        let timer = Task.detached {
            do {
                try await wait(timeout)
                input.yield(.timedOut)
            } catch {
                // Cancelled: the call ended first.
            }
        }
        ClaudeStreams.startLineReader(stdout.fileHandleForReading, into: input)
        ClaudeStreams.startTailReader(stderr.fileHandleForReading, into: input)
        ClaudeDriver.write(ClaudeDriver.stdinLine(user: user), to: stdin.fileHandleForWriting)

        var state = OneShotState()
        var watch = Watch(grace: stopGrace)
        loop: for await signal in signals {
            switch signal {
            case .line(let text):
                guard !watch.stopping, state.error == nil else { continue }
                for event in state.parser.parse(text) {
                    if let trip = state.apply(event) {
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
                let why = "timeout after \(Int(timeout / .milliseconds(1))) ms"
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

        if let error = state.error {
            guard !Py.eq(error, "cancelled") else { return .failure(.claudeFailed("cancelled")) }
            // R8: a rate-limit status other than "allowed" is part of the reason.
            let message = state.rateLimitStatus.map { "rate limit \($0): \(error)" } ?? error
            return .failure(.claudeFailed(Self.reason(message, otherwise: message)))
        }
        guard state.resultSeen else {
            // R10. stderr only ever contributes one of ClaudeReason's fixed reasons.
            let code = watch.exit.map { String($0.code) } ?? "?"
            let stderr = String(decoding: watch.stderrTail, as: UTF8.self)
            return .failure(.claudeFailed(Self.reason("exit \(code): \(stderr)", otherwise: "exit \(code)")))
        }
        guard let reply = state.reply, !Py.strip(reply).isEmpty else {
            return .failure(.claudeFailed("empty response"))
        }
        return .success(reply)
    }

    /// ClaudeReason's short reason for `message` when one of its keyword groups matches,
    /// otherwise `fallback`, so text of the child's own never reaches a log line.
    static func reason(_ message: String, otherwise fallback: String) -> String {
        let reason = ClaudeReason.reason(message)
        return ClaudeReason.groups.contains { Py.eq($0.reason, reason) } ? reason : fallback
    }
}

/// One call's stream state: the text of each message the model sent, less what R6 retracted,
/// and the first error. Every error here is one of this type's own fixed strings.
private struct OneShotState {
    var parser = StreamJSONParser()
    var initSeen = false
    var resultSeen = false
    var error: String?
    private(set) var rateLimitStatus: String?
    private var segments: [(id: String, text: String)] = []
    private var deltaSeen: Set<String> = []
    private var retracted: Set<String> = []
    private var resultText: String?

    /// The streamed text; with none (and nothing retracted), the result's text.
    var reply: String? {
        let streamed = segments.map(\.text).joined()
        if !streamed.isEmpty { return streamed }
        return retracted.isEmpty ? resultText : nil
    }

    /// The turn's rules for one event, as far as they apply to a call with no tools and no
    /// sink. Returns an error that must stop the child.
    mutating func apply(_ event: ClaudeEvent) -> String? {
        if !initSeen && ClaudeDriver.needsInit(event) {
            return "no init event before content"
        }
        switch event {
        case let .initInfo(apiKeySource, tools, mcp, _):
            initSeen = true
            if !Py.eq(apiKeySource, "none") {
                return "subscription-only: apiKeySource=\(apiKeySource)"                   // R1
            }
            if !mcp.isEmpty {
                return "an MCP server was loaded"
            }
            if !tools.isEmpty {
                return "unexpected tool set"
            }
        case let .textDelta(id, text):                                                     // R4
            guard !retracted.contains(id) else { break }
            deltaSeen.insert(id)
            append(text, from: id)
        case let .blockText(id, text):                                                     // R5
            guard !deltaSeen.contains(id), !retracted.contains(id) else { break }
            append(text, from: id)
        case let .stopReason(id, reason):                                                  // R6
            guard Py.eq(reason, "refusal") else { break }
            segments.removeAll { $0.id == id }
            retracted.insert(id)
        case let .rateLimit(status, isUsingOverage):                                       // R8
            if isUsingOverage {
                return "overage billing refused"
            }
            if !Py.eq(status, "allowed") {
                rateLimitStatus = status
            }
        case let .result(subtype, isError, text, apiErrorStatus):                          // R9
            resultSeen = true
            if !Py.eq(subtype, "success") || isError {
                error = ["result:", subtype, apiErrorStatus.map(String.init) ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                break
            }
            resultText = text
        case .toolResult:
            return "unexpected tool use"
        case .status, .messageStart, .refusalFallback, .unknown:
            break
        }
        return nil
    }

    private mutating func append(_ text: String, from id: String) {
        guard !text.isEmpty else { return }
        if let last = segments.indices.last, segments[last].id == id {
            segments[last].text += text
        } else {
            segments.append((id: id, text: text))
        }
    }
}
