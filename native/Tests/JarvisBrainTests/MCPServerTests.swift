import Darwin
import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// A-6 (plan §3.7): the MCP server's handshake, JSON-RPC table, error rows and socket rules.
/// Every connection here is a socketpair or the real socket in a short /tmp directory.
@Suite("MCPServerTests")
struct MCPServerTests {
    // MARK: - Replay of the recorded claude <-> stub traffic

    /// A stand-in for the recording's one tool; its reply text comes from the recording.
    struct RecordedPing: ToolImpl {
        static let name = "ping"
        static let schema = ToolSchema(name: "ping")
        let reply: String
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text(reply) }
    }

    static func recordedTraffic() throws -> [(fromClient: Bool, line: String)] {
        let url = Golden.directory.deletingLastPathComponent().appending(path: "claude/mcp-traffic-2026-09-28.log")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { raw in
            let fromClient = raw.hasPrefix("<< ")
            #expect(fromClient || raw.hasPrefix(">> "))
            return (fromClient, String(raw.dropFirst(3)))
        }
    }

    /// The one field where plan §3.7's initialize reply differs from what the stub sent:
    /// `capabilities.tools` is `{"listChanged":false}` there and `{}` in the recording.
    static func withListChangedFalse(_ reply: JSONValue) -> JSONValue {
        guard case .object(var top) = reply, case .object(var result)? = top["result"],
              case .object(var capabilities)? = result["capabilities"],
              case .object(var tools)? = capabilities["tools"] else { return reply }
        tools["listChanged"] = .bool(false)
        capabilities["tools"] = .object(tools)
        result["capabilities"] = .object(capabilities)
        top["result"] = .object(result)
        return .object(top)
    }

    @Test func replayingTheRecordedTrafficGivesTheRecordedReplies() async throws {
        let traffic = try Self.recordedTraffic()
        #expect(traffic.count == 7)
        // The recording's tools/list and tools/call replies define the stub tool.
        let recordedList = try json(traffic.first { !$0.fromClient && $0.line.contains(#""tools": ["#) }?.line)
        let recordedTool = try #require(recordedList.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.first?.objectValue)
        let recordedCall = try json(traffic.last { !$0.fromClient }?.line)
        let pong = try #require(recordedCall.objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        let ping = ToolSchema(name: try #require(recordedTool["name"]?.stringValue),
                              description: try #require(recordedTool["description"]?.stringValue),
                              parametersJSON: PyJSON.dumps(try #require(recordedTool["inputSchema"])))
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(RecordedPing(reply: pong))

        let h = try MCPHarness(tools: [ping], gateway: gateway)
        let (turn, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        var replies = 0
        for (fromClient, line) in traffic {
            if fromClient {
                end.send(line + "\n")
                continue
            }
            let ours = try #require(await end.line(), "no reply for \(line)")
            let recorded = try json(line)
            if recorded.objectValue?["id"] == .int(0) {
                // initialize: key-order-normalized equality once the plan's listChanged is added.
                #expect(sortedKeys(try json(ours)) == sortedKeys(Self.withListChangedFalse(recorded)))
                #expect(sortedKeys(try json(ours)) != sortedKeys(recorded))
            } else {
                // tools/list and tools/call: byte for byte, since PyJSON.dumps is json.dumps.
                #expect(ours == line)
                #expect(sortedKeys(try json(ours)) == sortedKeys(recorded))
            }
            replies += 1
        }
        #expect(replies == 3)
        #expect(await end.line(seconds: 0.3) == nil, "notifications/initialized must get no reply")
        let runs = await turn.summary().toolRuns
        #expect(runs == [ToolRunRecord(name: "ping", origin: .model(.claude), outcome: .ran)])
        end.close()
        await h.remove()
    }

    // MARK: - tools/list

    @Test func toolsListServesTheCatalogWhichEqualsTheFixture() async throws {
        let cases = try Golden.cases("m3_tool_schemas")
        let h = try MCPHarness()
        let (_, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        end.send(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"# + "\n")
        let reply = try json(await end.line())
        #expect(reply.objectValue?["id"] == .int(7))
        let tools = try #require(reply.objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        #expect(tools.count == 46)
        #expect(cases.count == 46)
        for (i, (tool, c)) in zip(tools, cases).enumerated() {
            let t = try #require(tool.objectValue)
            #expect(t.keys == ["name", "description", "inputSchema"])
            #expect(t["name"]?.stringValue == c.expected["name"]?.stringValue)
            #expect(t["description"] == c.expected["description"], "\(c.name)")
            // Ordered equality: Python's key order survives the round trip.
            #expect(t["inputSchema"] == c.expected["parameters"], "\(c.name)")
            #expect(t["name"]?.stringValue == ToolCatalog.tools[i].name)
            #expect(t["inputSchema"] == (try PyJSON.loads(Data(ToolCatalog.tools[i].parametersJSON.utf8))))
        }
        end.close()
        await h.remove()
    }

    // MARK: - The JSON-RPC table and its error rows

    @Test func everyErrorRowOfTheTable() async throws {
        let h = try MCPHarness()
        let (turn, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        func exchange(_ line: String) async throws -> JSONValue {
            end.send(line + "\n")
            return try json(await end.line())
        }
        func error(_ id: JSONValue, _ code: Int64, _ message: String) -> JSONValue {
            .object(JSONObject([.init(key: "jsonrpc", value: .string("2.0")), .init(key: "id", value: id),
                                .init(key: "error", value: .object(JSONObject([
                                    .init(key: "code", value: .int(code)),
                                    .init(key: "message", value: .string(message))])))]))
        }
        #expect(try await exchange(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#)
                == error(.int(1), -32602, "Unknown tool: no_such_tool"))
        #expect(try await exchange(#"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
                == error(.int(2), -32601, "Method not found"))
        #expect(try await exchange(#"{"jsonrpc":"2.0","id":3,"method":"tools/li"#) == error(.null, -32700, "Parse error"))
        #expect(try await exchange(#"{"jsonrpc":"2.0","id":4}"#) == error(.int(4), -32600, "Invalid Request"))
        #expect(try await exchange(#"[{"jsonrpc":"2.0","id":5,"method":"ping"}]"#) == error(.null, -32600, "Invalid Request"))
        // Notifications get no reply: the next line is the ping's.
        end.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"# + "\n")
        end.send(#"{"jsonrpc":"2.0","method":"notifications/other"}"# + "\n")
        #expect(try await exchange(#"{"jsonrpc":"2.0","id":"six","method":"ping"}"#)
                == .object(JSONObject([.init(key: "jsonrpc", value: .string("2.0")), .init(key: "id", value: .string("six")),
                                       .init(key: "result", value: .object(JSONObject()))])))
        #expect(h.logs.all.contains("mcp: notification notifications/cancelled"))
        #expect(h.logs.all.contains("mcp: notification notifications/other"))
        // Any request after turn.close().
        await turn.close()
        #expect(try await exchange(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#) == error(.int(7), -32000, "Turn closed"))
        #expect(try await exchange(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_time"}}"#)
                == error(.int(8), -32000, "Turn closed"))
        #expect(await turn.summary().toolRuns.isEmpty)
        end.close()
        await h.remove()
    }

    /// Codex review finding 4: the envelope is checked before anything is dispatched. A missing
    /// or wrong version, or an id that is not a string or an integer, is -32600 and runs nothing.
    @Test func malformedEnvelopesAreRejectedWithoutDispatch() async throws {
        let h = try MCPHarness()
        let (turn, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        func exchange(_ line: String) async throws -> JSONValue {
            end.send(line + "\n")
            return try json(await end.line())
        }
        func invalid(_ id: JSONValue) -> JSONValue {
            .object(JSONObject([.init(key: "jsonrpc", value: .string("2.0")), .init(key: "id", value: id),
                                .init(key: "error", value: .object(JSONObject([
                                    .init(key: "code", value: .int(-32600)),
                                    .init(key: "message", value: .string("Invalid Request"))])))]))
        }
        let call = #""method":"tools/call","params":{"name":"get_time","arguments":{}}}"#
        // The review's scenario: a wrong version and an object id.
        #expect(try await exchange(#"{"jsonrpc":"wrong","id":{},"# + call) == invalid(.null))
        // A bad version with a good id: rejected, and the id is echoed.
        #expect(try await exchange(#"{"id":1,"# + call) == invalid(.int(1)))
        #expect(try await exchange(#"{"jsonrpc":"1.0","id":2,"# + call) == invalid(.int(2)))
        #expect(try await exchange(#"{"jsonrpc":2.0,"id":3,"# + call) == invalid(.int(3)))
        #expect(try await exchange(#"{"jsonrpc":"2.0 ","id":"four","# + call) == invalid(.string("four")))
        // The right version with an id that is not a string or an integer.
        for id in ["{}", "[5]", "true", "null", "6.5", "7.0"] {
            #expect(try await exchange(#"{"jsonrpc":"2.0","id":\#(id),"# + call) == invalid(.null), "id \(id)")
        }
        // A notification needs the version too.
        #expect(try await exchange(#"{"jsonrpc":"1.0","method":"notifications/initialized"}"#) == invalid(.null))
        #expect(await turn.summary().toolRuns.isEmpty)
        // String and integer ids, one past Int64 included, still work, and a good call runs.
        let big = try await exchange(#"{"jsonrpc":"2.0","id":123456789012345678901234567890,"method":"ping"}"#)
        #expect(big.objectValue?["id"] == .bigInt("123456789012345678901234567890"))
        #expect(big.objectValue?["result"] == .object(JSONObject()))
        let ran = try await exchange(#"{"jsonrpc":"2.0","id":"s","# + call)
        #expect(ran.objectValue?["id"] == .string("s"))
        #expect(ran.objectValue?["result"]?.objectValue?["content"] != nil)
        #expect(await turn.summary().toolRuns.map(\.name) == ["get_time"])
        end.close()
        await h.remove()
    }

    /// Codex review finding 3: closeTurn closes the turn's bound connection, so an idle relay does
    /// not outlive its turn. A request sent after it gets no reply and runs nothing.
    @Test func closeTurnDropsTheIdleBoundConnection() async throws {
        let h = try MCPHarness()
        let (turn, files, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        end.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
        #expect(try json(await end.line()).objectValue?["result"] == .object(JSONObject()))
        await h.registry.closeTurn(files.turnID)
        #expect(await end.closed(), "the bound connection outlived its turn")
        #expect(await h.logs.waitFor("mcp: relay closed: turn \(files.turnID) closed"))
        #expect(await turn.isOpen)   // closeTurn ends the MCP side only
        end.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_time","arguments":{}}}"# + "\n")
        #expect(await end.line(seconds: 0.3) == nil)
        #expect(await turn.summary().toolRuns.isEmpty)
        end.close()
        await h.remove()
    }

    /// The same while a call is parked in its tool: the connection closes at closeTurn, before the
    /// call returns, and the call's reply goes nowhere.
    @Test func closeTurnClosesTheConnectionUnderAParkedCall() async throws {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        let release = TestGate()
        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        await gateway.register(ParkedTool(entered: enteredContinuation, release: release))
        let h = try MCPHarness(tools: [ParkedTool.schema], gateway: gateway)
        let (turn, files, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        end.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"park","arguments":{}}}"# + "\n")
        var calls = entered.makeAsyncIterator()
        _ = await calls.next()
        await h.registry.closeTurn(files.turnID)
        #expect(await end.closed(), "the connection outlived its turn while a call was parked")
        await release.open()
        #expect(await h.logs.waitFor("mcp: relay closed: turn \(files.turnID) closed"))
        #expect(await end.line(seconds: 0.1) == nil, "the parked call's reply was delivered")
        #expect(await turn.isOpen)
        end.close()
        await h.remove()
    }

    @Test func initializeNegotiatesTheProtocolVersion() async throws {
        let h = try MCPHarness()
        let (_, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        func version(_ params: String) async throws -> JSONValue? {
            end.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize""# + params + "}\n")
            let result = try json(await end.line()).objectValue?["result"]?.objectValue
            #expect(result?.keys == ["protocolVersion", "capabilities", "serverInfo"])
            #expect(result?["capabilities"] == (try PyJSON.loads(Data(#"{"tools":{"listChanged":false}}"#.utf8))))
            #expect(result?["serverInfo"] == (try PyJSON.loads(Data(#"{"name":"jarvis","version":"1.0.0"}"#.utf8))))
            return result?["protocolVersion"]
        }
        for supported in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] {
            #expect(try await version(#","params":{"protocolVersion":"\#(supported)"}"#) == .string(supported))
        }
        #expect(try await version(#","params":{"protocolVersion":"2099-01-01"}"#) == .string("2025-11-25"))
        #expect(try await version(#","params":{"protocolVersion":7}"#) == .string("2025-11-25"))
        #expect(try await version("") == .string("2025-11-25"))
        end.close()
        await h.remove()
    }

    // MARK: - tools/call goes through the gateway, bound to the turn

    struct StubReadFile: ToolImpl {
        static let name = "read_file"
        static let schema = ToolSchema(name: "read_file")
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            .text("contents of \(args["path"]?.stringValue ?? "?")")
        }
    }

    /// Registered so the gateway reaches its taint check (an unregistered name stops earlier,
    /// at "Unknown tool"). It must never run in this test.
    struct StubRunCommand: ToolImpl {
        static let name = "run_command"
        static let schema = ToolSchema(name: "run_command")
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text("ran") }
    }

    @Test func toolsCallRunsThroughTheGatewayOnTheBoundTurn() async throws {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(StubReadFile())
        await gateway.register(StubRunCommand())
        let h = try MCPHarness(gateway: gateway)
        let (turn, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        func call(_ id: Int, _ name: String, _ arguments: String) async throws -> JSONObject {
            end.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments),"_meta":{"progressToken":\#(id)}}}"# + "\n")
            let reply = try json(await end.line())
            #expect(reply.objectValue?["id"] == .int(Int64(id)))
            return try #require(reply.objectValue?["result"]?.objectValue)
        }
        func content(_ text: String) -> JSONValue {
            .array([.object(JSONObject([.init(key: "type", value: .string("text")), .init(key: "text", value: .string(text))]))])
        }
        // A catalog tool with no body yet: the gateway's own answer, not an MCP error.
        let noBody = try await call(1, "get_time", "{}")
        #expect(noBody.keys == ["content"])
        #expect(noBody["content"] == content(GuardStrings.unknownTool("get_time")))
        // An untrusted tool taints the bound turn...
        let read = try await call(2, "read_file", #"{"path":"/tmp/notes.txt"}"#)
        #expect(read.keys == ["content"])
        #expect(read["content"] == content("contents of /tmp/notes.txt"))
        #expect(await turn.tainted)
        // ...so an executor is refused, and the refusal carries isError.
        let blocked = try await call(3, "run_command", #"{"command":"ls"}"#)
        #expect(blocked.keys == ["content", "isError"])
        #expect(blocked["content"] == content(TaintPolicy.blockedTextClaude))
        #expect(blocked["isError"] == .bool(true))
        let runs = await turn.summary().toolRuns
        #expect(runs.map(\.name) == ["get_time", "read_file", "run_command"])
        #expect(runs.allSatisfy { $0.origin == .model(.claude) })
        #expect(runs.map(\.outcome) == [.unknown, .ran, .blockedTaint])
        end.close()
        await h.remove()
    }

    // MARK: - Handshake

    @Test func handshakeBindsTheRegisteredParent() async throws {
        let h = try MCPHarness()
        let (_, files, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        #expect(await h.logs.waitFor("mcp: relay bound to turn \(files.turnID)"))
        #expect(!h.logs.all.joined().contains(token))
        end.close()
        await h.remove()
    }

    /// Sends `hello` on a fresh connection and expects the server to close it with `reason`.
    func expectRejected(_ h: MCPHarness, hello: String, reason: String) async throws {
        let end = try h.connect()
        end.send(hello)
        #expect(await end.closed(), "connection stayed open for: \(reason)")
        #expect(await h.logs.waitFor("relay rejected: \(reason)"), "log: \(h.logs.all)")
        end.close()
    }

    @Test func handshakeRejectsAWrongToken() async throws {
        let h = try MCPHarness()
        let (_, _, token) = try await h.openTurn()
        let wrong = String(token.dropLast()) + (token.hasSuffix("0") ? "1" : "0")
        try await expectRejected(h, hello: #"{"jarvis_relay":1,"token":"\#(wrong)"}"# + "\n", reason: "unknown token")
        try await expectRejected(h, hello: #"{"jarvis_relay":1,"token":"\#(token.prefix(32))"}"# + "\n", reason: "unknown token")
        try await expectRejected(h, hello: #"{"jarvis_relay":2,"token":"\#(token)"}"# + "\n", reason: "malformed handshake line")
        // The right token still binds: failed attempts do not use it up.
        let end = try await h.bound(token: token)
        #expect(!h.logs.all.joined().contains(token))
        #expect(!h.logs.all.joined().contains(wrong))
        end.close()
        await h.remove()
    }

    @Test func handshakeRejectsASecondConnectionForOneToken() async throws {
        let h = try MCPHarness()
        let (_, files, token) = try await h.openTurn()
        let first = try await h.bound(token: token)
        try await expectRejected(h, hello: #"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n",
                                 reason: "second connection for turn \(files.turnID)")
        first.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
        #expect(try json(await first.line()).objectValue?["result"] == .object(JSONObject()))
        first.close()
        await h.remove()
    }

    @Test func handshakeRejectsAWrongParentPID() async throws {
        let h = try MCPHarness()
        let (_, _, token) = try await h.openTurn(claudePID: 1)
        try await expectRejected(h, hello: #"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n",
                                 reason: "parent pid \(getppid()) is not claude pid 1")
        let turn = TurnContext(channel: .voice)
        let files = try await h.registry.openTurn(turn)   // no setClaudePID yet
        let unset = try #require(MCPRelay.readToken(at: files.tokenPath.path(percentEncoded: false)))
        try await expectRejected(h, hello: #"{"jarvis_relay":1,"token":"\#(unset)"}"# + "\n",
                                 reason: "no claude pid registered for turn \(files.turnID)")
        await h.remove()
    }

    @Test func handshakeRejectsAnOversizedLine() async throws {
        let h = try MCPHarness()
        _ = try await h.openTurn()
        // 4096 bytes is within the limit (and then fails as JSON); 4097 is not.
        try await expectRejected(h, hello: String(repeating: "x", count: 4096) + "\n", reason: "malformed handshake line")
        try await expectRejected(h, hello: String(repeating: "x", count: 4097) + "\n", reason: "handshake line over 4096 bytes")
        try await expectRejected(h, hello: String(repeating: "x", count: 5000), reason: "handshake line over 4096 bytes")
        await h.remove()
    }

    @Test func handshakeRejectsALateLine() async throws {
        let h = try MCPHarness()
        let (_, _, token) = try await h.openTurn()
        let end = try h.connect()
        // Awake time only, like the server's 2 s window (a DispatchTime deadline, which does not
        // count system sleep): a closed lid cannot push `waited` past 5 s, or cut it below 1.9 s.
        let start = SuspendingClock.now
        end.send(#"{"jarvis_relay":1,"#)   // never finished
        #expect(await end.closed(seconds: 6))
        let waited = SuspendingClock.now - start
        #expect(waited >= .milliseconds(1900) && waited < .seconds(5), "closed after \(waited)")
        #expect(await h.logs.waitFor("relay rejected: no handshake line within 2 s"))
        end.close()
        // A line that arrives in time still binds afterwards.
        let late = try await h.bound(token: token)
        late.close()
        await h.remove()
    }

    // MARK: - The socket

    @Test func listensOnRunMcpSockWithTheModeRules() async throws {
        let h = try MCPHarness()
        let run = h.server.runDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path(percentEncoded: false))
        try await h.server.start()
        let socket = h.server.socketPath
        #expect(socket == run.appending(path: "mcp.sock").path(percentEncoded: false))
        var st = stat()
        let socketStat = lstat(socket, &st)
        #expect(socketStat == 0)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
        #expect(st.st_mode & 0o777 == 0o600)
        let runStat = lstat(run.path(percentEncoded: false), &st)
        #expect(runStat == 0)
        #expect(st.st_mode & S_IFMT == S_IFDIR)
        #expect(st.st_mode & 0o777 == 0o700)

        let (_, _, token) = try await h.openTurn()
        let end = TestEnd(fd: try MCPSocket.connect(to: socket))
        end.send(#"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n")
        #expect(await end.line() == #"{"jarvis_relay_ok":1}"#)
        end.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
        #expect(await end.line() == #"{"jsonrpc": "2.0", "id": 1, "result": {}}"#)
        end.close()
        await h.server.stop()
        let removed = lstat(socket, &st) != 0 && errno == ENOENT
        #expect(removed)
        await h.remove()
    }

    @Test func staleSocketRule() async throws {
        let h = try MCPHarness()
        let socket = h.server.socketPath
        // A socket of ours left behind by a dead process is replaced.
        let stale = try MCPSocket.listen(at: socket)
        close(stale)
        try await h.server.start()
        let (_, _, token) = try await h.openTurn()
        let end = TestEnd(fd: try MCPSocket.connect(to: socket))
        end.send(#"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n")
        #expect(await end.line() == #"{"jarvis_relay_ok":1}"#)
        end.close()
        await h.server.stop()

        // Anything else at the path is left alone.
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: socket))
        let other = MCPServer(runDirectory: h.server.runDirectory, registry: h.registry, gateway: h.gateway, log: h.logs.sink)
        await #expect(throws: MCPSocketError.notOurSocket(socket)) { try await other.start() }
        #expect(try String(contentsOfFile: socket, encoding: .utf8) == "not a socket")
        await h.remove()
    }

    @Test func refusesASocketPathOverSunPath() async throws {
        let dir = try ShortTempDir()
        let run = dir.url.appending(path: String(repeating: "r", count: 100), directoryHint: .isDirectory)
        let server = MCPServer(runDirectory: run, registry: MCPTurnRegistry(runDirectory: run),
                               gateway: ToolGateway(log: { _ in }), log: { _ in })
        #expect(MCPSocket.sunPathSize == 104)
        #expect(server.socketPath.utf8.count >= 104)
        await #expect(throws: MCPSocketError.pathTooLong(server.socketPath)) { try await server.start() }
        dir.remove()
    }
}
