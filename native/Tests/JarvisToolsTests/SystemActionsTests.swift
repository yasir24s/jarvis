import CoreGraphics
import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

@Suite("SystemActionsTests")
struct SystemActionsTests {
    @Test func fixtureHoldsEveryCase() throws {
        let cases = try M5Fixture.cases("m5_actions")
        #expect(cases.count == 47)
        let tools = Dictionary(grouping: cases) { $0.input.string("tool") ?? "" }.mapValues(\.count)
        #expect(tools == ["set_volume": 15, "set_brightness": 19, "type_text": 9, "notify": 4])
        #expect(cases.filter { $0.expected.string("deviation") != nil }.map(\.name) == ["notify/45"])
    }

    /// Every case through the gateway, each effect checked against what Python sent, not
    /// recomputed: the osascript volume level, the brightness CLI argv or System Events key
    /// taps, the keystroke lines and returns, and the notification script.
    @Test func goldenRepliesAndEffects() async throws {
        for c in try M5Fixture.cases("m5_actions") {
            let gateway = ToolGateway(log: { _ in })
            // Python's System Events call failed: natively, the Accessibility preflight says no.
            let denied = !(c.input.string("script_output") ?? "").isEmpty
            let keyboard = FakeKeyboard(allowed: !denied)
            let volume = FakeVolume()
            let commands = FakeRunner(stdout: "")
            let scripts = FakeStdinRunner()
            let cli = c.input["cli"] == .bool(true)
            await gateway.register(SetVolume(volume: volume))
            await gateway.register(SetBrightness(keyboard: keyboard, runner: commands, cli: { cli ? "/fake/brightness" : nil }))
            await gateway.register(TypeText(keyboard: keyboard))
            await gateway.register(Notify(notifications: FakeNotification(), runner: scripts))
            let tool = try #require(c.input.string("tool"))
            let args = try #require(c.input.object("args"))
            let result = await gateway.call(tool, args, turn: TurnContext(channel: .voice), origin: .ui)
            #expect(result.text == c.expected.string("text"), "\(c.name)")
            let argv = (c.expected["argv"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue) }
            let script = c.expected["scripts"]?.arrayValue?.first?.stringValue
            switch tool {
            case "set_volume":
                // Python ran osascript -e "set volume output volume N".
                #expect(volume.levels == argv.map { Int($0[2].split(separator: " ").last ?? "") ?? -1 }, "\(c.name)")
            case "set_brightness":
                #expect(commands.calls == (cli ? argv : []), "\(c.name)")
                #expect(keyboard.events == (denied ? [] : script.map(Self.taps) ?? []), "\(c.name)")
            case "type_text":
                #expect(keyboard.merged == (denied ? [] : script.map(Self.keystrokes) ?? []), "\(c.name)")
                #expect(keyboard.payloads.allSatisfy { $0.count <= 20 && String(validating: $0, as: UTF16.self) != nil })
            default:
                // notify, no notification permission: the escaped osascript fallback.
                let sent = await scripts.calls.map { String(decoding: $0.input, as: UTF8.self) }
                let python = argv.map { $0[2] }
                if c.expected.string("deviation") != nil {
                    #expect(sent == [try #require(c.expected.string("native_script"))], "\(c.name)")
                    withKnownIssue("R11: Python embeds quotes and backslashes unescaped") {
                        #expect(sent == python)
                    }
                } else {
                    #expect(sent == python, "\(c.name)")
                }
            }
        }
    }

    /// Python's brightness script (`repeat N times` / `key code K`) as the taps it asks for.
    static func taps(_ script: String) -> [FakeKeyboard.Event] {
        var taps: [FakeKeyboard.Event] = [], count = 0
        for line in script.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("repeat "), line.hasSuffix(" times") { count = Int(line.dropFirst(7).dropLast(6)) ?? -1 }
            if line.hasPrefix("key code ") { taps += Array(repeating: .key(CGKeyCode(line.dropFirst(9)) ?? 0), count: count) }
        }
        return taps
    }

    /// Python's typing script as the events it asks for: each `keystroke "…"` line's text with
    /// _as_escape undone, and each `key code 36`. Split and compared by code units.
    static func keystrokes(_ script: String) -> [FakeKeyboard.Event] {
        let prefix = Array("  keystroke \"".unicodeScalars)
        var events: [FakeKeyboard.Event] = []
        for line in script.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Array.init) {
            if line == Array("  key code 36".unicodeScalars) { events.append(.key(36)) }
            guard line.starts(with: prefix), line.count > prefix.count, line.last == "\"" else { continue }
            var text = String.UnicodeScalarView(), escaped = false
            for u in line.dropFirst(prefix.count).dropLast() {
                if !escaped, u == "\\" { escaped = true; continue }
                text.append(u)
                escaped = false
            }
            events.append(.text(Array(String(text).utf16)))
        }
        return events
    }

    /// The four bodies are registered with their generated catalog entries (m3_tool_schemas).
    @Test func registeredSchemasAreTheCatalogEntries() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let listed = await M5Fixture.gateway(.fake(), sandbox: sandbox).toolList()
        for (name, schema) in [(SetVolume.name, SetVolume.schema), (SetBrightness.name, SetBrightness.schema),
                               (Notify.name, Notify.schema), (TypeText.name, TypeText.schema)] {
            let catalog = try #require(ToolCatalog.tools.first { $0.name == name })
            #expect(schema == catalog)
            #expect(listed.first { $0.name == name } == catalog)
        }
    }

    @Test func liveActionRunnerCarriesTheAgentPath() {
        #expect((ToolPlatform.live.actionRunner as? BoundedRunner)?.environment?["PATH"] == BoundedRunner.agentPATH)
    }

    @Test func chunksNeverSplitSurrogatePairs() {
        let text = String(repeating: "a", count: 19) + "🙂" + String(repeating: "🙂", count: 31)
        let chunks = TypeText.chunks(text)
        #expect(chunks.flatMap { $0 } == Array(text.utf16))
        #expect(chunks.allSatisfy { $0.count <= 20 && String(validating: $0, as: UTF16.self) != nil })
    }

    @Test func notificationsEscapeFallbackAndSkipItWhenDelivered() async throws {
        for delivered in [true, false] {
            let runner = FakeStdinRunner()
            let tool = Notify(notifications: FakeNotification(delivered: delivered), runner: runner)
            let ctx = ToolRunContext(toolName: Notify.name, origin: .ui, turn: TurnContext(channel: .voice))
            _ = try await tool.run(JSONObject([.init(key: "title", value: .string("a\"b")),
                                               .init(key: "message", value: .string("c\\d"))]), ctx)
            let calls = await runner.calls
            #expect(calls.count == (delivered ? 0 : 1))
            if !delivered {
                #expect(calls.first?.input == Data(#"display notification "c\\d" with title "a\"b""#.utf8))
            }
        }
    }

    @Test func taintedTypingPostsNothing() async {
        let keyboard = FakeKeyboard()
        let gateway = ToolGateway(log: { _ in })
        await gateway.register(TypeText(keyboard: keyboard))
        let result = await gateway.call("type_text", JSONObject([.init(key: "text", value: .string("hello"))]),
            turn: TurnContext(channel: .voice, startTainted: true), origin: .model(.claude))
        #expect(result.record.outcome == .blockedTaint)
        #expect(keyboard.payloads.isEmpty && keyboard.keys.isEmpty)
    }
}

/// Records what would have been posted, in order. Nothing reaches the event system.
final class FakeKeyboard: KeyboardPosting, @unchecked Sendable {
    enum Event: Equatable, Sendable { case text([UniChar]), key(CGKeyCode) }
    let allowed: Bool
    private let lock = NSLock()
    private var log: [Event] = []
    init(allowed: Bool = true) { self.allowed = allowed }
    var events: [Event] { lock.withLock { log } }
    /// Consecutive payloads joined, as one keystroke line types them.
    var merged: [Event] {
        events.reduce(into: []) { out, event in
            if case .text(let units) = event, case .text(let previous)? = out.last {
                out[out.count - 1] = .text(previous + units)
            } else { out.append(event) }
        }
    }
    var keys: [CGKeyCode] { events.compactMap { if case .key(let code) = $0 { code } else { nil } } }
    var payloads: [[UniChar]] { events.compactMap { if case .text(let units) = $0 { units } else { nil } } }
    func permitted() -> Bool { allowed }
    func key(_ code: CGKeyCode) -> Bool { lock.withLock { log.append(.key(code)) }; return true }
    func unicode(_ units: [UniChar]) -> Bool { lock.withLock { log.append(.text(units)) }; return true }
}

final class FakeVolume: VolumeSetting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    var levels: [Int] { lock.withLock { stored } }
    func set(_ level: Int) { lock.withLock { stored.append(level) } }
}

struct FakeNotification: NotificationPosting {
    var delivered = false
    func post(title: String, message: String) async -> Bool { delivered }
}
