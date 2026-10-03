import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// TV tools on the fast path: "play the latest episode of X" reaches tv_play, "what's on TV"
/// reaches tv_now_playing, "play the latest X" goes to the brain, and everything else that the
/// play branch takes still reaches music_play. The tools are recording stubs.
@Suite("TV fast path", .timeLimit(.minutes(1)))
struct TVFastPathTests {
    final class Calls: Sendable {
        let list = Mutex<[String]>([])
        func add(_ s: String) { list.withLock { $0.append(s) } }
        var all: [String] { list.withLock { $0 } }
    }

    struct Recorder<Tag: RecorderName>: ToolImpl {
        static var name: String { Tag.name }
        static var schema: ToolSchema { ToolSchema(name: Tag.name) }
        let calls: Calls
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            let shown = args.members.map { "\($0.key)=\($0.value.stringValue ?? "")" }.joined(separator: " ")
            calls.add("\(Self.name) \(shown)".trimmingCharacters(in: .whitespaces))
            return .text("\(Self.name) ran")
        }
    }

    protocol RecorderName { static var name: String { get } }
    enum PlayTag: RecorderName { static let name = "tv_play" }
    enum NowTag: RecorderName { static let name = "tv_now_playing" }
    enum MusicTag: RecorderName { static let name = "music_play" }

    static func commands(tv: Bool, calls: Calls, sandbox: ToolCoreSandbox) async -> QuickCommands {
        let gateway = ToolGateway(log: { _ in })
        await gateway.register(Recorder<MusicTag>(calls: calls))
        if tv {
            await gateway.register(Recorder<PlayTag>(calls: calls))
            await gateway.register(Recorder<NowTag>(calls: calls))
        }
        return QuickCommands(router: FastPathRouter(), core: sandbox.core, confirmations: ConfirmationGate(),
                             timers: nil, alarms: nil, timeZone: TimeZone(identifier: "Europe/London")!, hooks: .init(),
                             runner: QuickCommandsTests.Runner(), web: QuickCommandsTests.Web(nil),
                             online: { false }, log: { _ in }, tools: gateway, browser: StubBrowser())
    }

    @Test(arguments: [
        ("play the latest episode of Harbour Lights", "tv_play episode=latest show=harbour lights"),
        ("Play the next episode of Harbour Lights.", "tv_play episode=next show=harbour lights"),
        ("play the newest harbour lights episode", "tv_play episode=latest show=harbour lights"),
        ("play season 2 episode 3 of harbour lights", "tv_play episode=S2E3 show=harbour lights"),
        ("play harbour lights s2e3", "tv_play episode=S2E3 show=harbour lights"),
        ("what's on TV", "tv_now_playing"),
        ("what is playing on the tv?", "tv_now_playing"),
        ("play glass harbour", "music_play query=glass harbour"),
    ])
    func routes(_ phrase: String, _ call: String) async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let calls = Calls()
        let commands = await Self.commands(tv: true, calls: calls, sandbox: sandbox)
        let reply = await commands.route(phrase, turn: TurnContext(channel: .voice))
        #expect(reply == "\(call.split(separator: " ").first!) ran")
        #expect(calls.all == [call])
    }

    @Test func latestWithoutEpisodeGoesToTheBrain() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let calls = Calls()
        let commands = await Self.commands(tv: true, calls: calls, sandbox: sandbox)
        #expect(await commands.route("play the latest harbour lights", turn: TurnContext(channel: .voice)) == nil)
        #expect(calls.all.isEmpty)
    }

    @Test func withoutTheTVToolsTheMusicRouteIsUnchanged() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let calls = Calls()
        let commands = await Self.commands(tv: false, calls: calls, sandbox: sandbox)
        #expect(await commands.route("play the latest harbour lights", turn: TurnContext(channel: .voice)) == "music_play ran")
        #expect(await commands.route("play the latest episode of harbour lights", turn: TurnContext(channel: .voice)) == "music_play ran")
        #expect(await commands.route("what's on tv", turn: TurnContext(channel: .voice)) == nil)
        #expect(calls.all == ["music_play query=the latest harbour lights", "music_play query=the latest episode of harbour lights"])
    }
}
