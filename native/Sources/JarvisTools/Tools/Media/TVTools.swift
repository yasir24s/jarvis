import Foundation
import JarvisCore

/// TV tools: `tv_find`, `tv_play` and `tv_now_playing`, through `TVControl`. Playing is
/// low-risk, so nothing asks for confirmation. Text read from the TV app's window is untrusted:
/// a call that read it taints the turn, so no executor runs after it in the same request.
enum TVToolText {
    static func show(_ args: JSONObject) -> String {
        TVUIReader.clean(args["show"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func finish(_ reply: TVControl.Reply, _ ctx: ToolRunContext) async -> ToolOutcome {
        if reply.readUI { await ctx.turn.markTainted(by: ctx.toolName) }
        return .text(reply.text)
    }
}

struct TVFind: ToolImpl {
    static let name = "tv_find"
    static let schema = ToolSchema(
        name: name,
        description: "What episodes of a TV show are available to watch on this Mac: the user's TV app library first (with what is watched), then the TV app's own show page, searched through Accessibility.",
        parametersJSON: #"{"type": "object", "properties": {"show": {"type": "string"}}, "required": ["show"]}"#)

    let tv: TVControl

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let show = TVToolText.show(args)
        guard !show.isEmpty else { return .text("Which show, sir?") }
        return await TVToolText.finish(await tv.find(show: show), ctx)
    }
}

struct TVPlay: ToolImpl {
    static let name = "tv_play"
    static let schema = ToolSchema(
        name: name,
        description: "Play an episode of a TV show in the TV app on this Mac. episode: 'latest' (default: the next unwatched episode when watch state is known, otherwise the newest), 'next', or a code like 'S2E3'. Uses the user's library first, then the TV app's own search. where: only 'mac'.",
        parametersJSON: #"{"type": "object", "properties": {"show": {"type": "string"}, "episode": {"type": "string"}, "where": {"type": "string", "enum": ["mac"]}}, "required": ["show"]}"#)

    let tv: TVControl

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        if let place = args["where"]?.stringValue, !place.isEmpty, place.lowercased() != "mac" { return .text(TVControl.onlyMacLine) }
        let show = TVToolText.show(args)
        guard !show.isEmpty else { return .text("Which show, sir?") }
        guard let want = TVEpisodeWant(args["episode"]?.stringValue) else {
            return .text("I didn't follow which episode, sir. Say latest, next, or a season and episode like S2E3.")
        }
        return await TVToolText.finish(await tv.play(show: show, want: want), ctx)
    }
}

struct TVNowPlaying: ToolImpl {
    static let name = "tv_now_playing"
    static let schema = ToolSchema(
        name: name,
        description: "What the TV app on this Mac is playing (show, episode and whether it is paused). Only works while the TV switch in Learning Sources is on.",
        parametersJSON: #"{"type": "object", "properties": {}}"#)

    let tv: TVControl

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        await TVToolText.finish(await tv.nowPlaying(), ctx)
    }
}
