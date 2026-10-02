import Foundation
import JarvisTestSupport
import Testing

/// B2 part 5: one real ChatGPT turn, gated by JARVIS_CHATGPT_LIVE=1. It runs the built
/// `JARVIS --brain-smoke --chatgpt "What's the time?"` (DEBUG) on a sandbox state root, so the
/// real `codex` answers on the user's ChatGPT sign-in through the real relay and gateway, and
/// checks from the smoke's output that:
/// - get_time ran through JARVIS's gateway over MCP (`tools/call get_time`),
/// - every item codex reported was a message, reasoning, a notice or a jarvis MCP call, so no
///   Codex built-in tool ran, and the driver recorded none,
/// - the reply came from "chatgpt (gpt-6-luna)".
/// It prints the first-reply and total times. `JARVIS_SMOKE_BINARY` overrides the binary
/// (default `.build/debug/JARVIS`). The smoke refuses to run outside an app bundle whose ID is
/// the app's (`StatePaths.live`), so the test copies the binary into a minimal bundle of its own
/// in a sandbox: an Info.plist and the binary, nothing else, and never the installed app.
@Suite("B2 ChatGPT live check (gated)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["JARVIS_CHATGPT_LIVE"] == "1"))
struct ChatGPTLiveTests {
    static var binary: URL {
        if let path = ProcessInfo.processInfo.environment["JARVIS_SMOKE_BINARY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/debug/JARVIS", directoryHint: .notDirectory)
    }

    /// The item types a JARVIS turn may show; anything else is a Codex built-in tool.
    static let allowedItems: Set<String> = ["agent_message", "reasoning", "mcp_tool_call", "error"]

    /// `<root>/JARVIS-smoke.app` holding a copy of `binary` and the bundle ID the smoke needs.
    static func smokeBundle(in root: URL, binary: URL) throws -> URL {
        let contents = root.appending(path: "JARVIS-smoke.app/Contents", directoryHint: .isDirectory)
        let macOS = contents.appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appending(path: "JARVIS", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: binary, to: executable)
        let plist: [String: String] = ["CFBundleIdentifier": "com.jarvis.assistant", "CFBundleExecutable": "JARVIS",
                                       "CFBundleName": "JARVIS", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist", directoryHint: .notDirectory))
        return executable
    }

    @Test(.timeLimit(.minutes(3)))
    func whatsTheTimeIsAnsweredThroughGetTime() async throws {
        let box = try Sandbox()
        let appBox = try Sandbox()
        defer { box.remove(); appBox.remove() }
        let process = Process()
        process.executableURL = try Self.smokeBundle(in: appBox.root, binary: Self.binary)
        process.arguments = ["--brain-smoke", "--chatgpt", "What's the time?"]
        var environment = ProcessInfo.processInfo.environment
        environment["JARVIS_HOME"] = box.root.path(percentEncoded: false)
        environment["JARVIS_CHATGPT_LIVE"] = nil
        process.environment = environment
        // stderr goes to a file, so a full stderr pipe can never stall the read of stdout.
        let errURL = box.root.appending(path: "smoke-stderr.txt", directoryHint: .notDirectory)
        try Data().write(to: errURL)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = try FileHandle(forWritingTo: errURL)
        let started = ContinuousClock.now
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let wall = ContinuousClock.now - started
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        for line in lines where line.hasPrefix("codex ") || line.hasPrefix("tools/call ") || line.hasPrefix("sentence: ")
            || line.hasPrefix("chatgpt ") || line.hasPrefix("timing ") || line.hasPrefix("backend=")
            || line.contains("Backend:") || line.contains("ChatGPT") {
            print("B2 live: \(line)")
        }
        print("B2 live: smoke process wall time \(Int(wall / .milliseconds(1))) ms (includes JARVIS start-up)")
        #expect(process.terminationStatus == 0, "stderr: \(stderr)")

        // get_time ran through JARVIS's gateway, over MCP, and was the only kind of tool.
        #expect(lines.contains { $0.hasPrefix("tools/call get_time -> ") }, "\(lines)")
        #expect(lines.contains("codex item mcp_tool_call jarvis.get_time completed"), "\(lines)")
        let items = lines.filter { $0.hasPrefix("codex item ") }
            .map { $0.dropFirst("codex item ".count).split(separator: " ").first.map(String.init) ?? "" }
        #expect(!items.isEmpty)
        #expect(Set(items).isSubset(of: Self.allowedItems), "a Codex built-in item ran: \(items)")
        for call in lines.filter({ $0.hasPrefix("codex item mcp_tool_call ") }) {
            #expect(call.hasPrefix("codex item mcp_tool_call jarvis."), "\(call)")
        }
        #expect(lines.contains("chatgpt tool_calls=[\"jarvis.get_time\"] built_ins=[]"), "\(lines)")
        #expect(lines.contains { $0.hasPrefix("sentence: ") })
        #expect(lines.contains("backend=chatgpt (gpt-6-luna)"), "\(lines)")
        let timing = try #require(lines.first { $0.hasPrefix("timing first_delta_ms=") })
        #expect(!timing.contains("first_delta_ms=none"))
    }
}
