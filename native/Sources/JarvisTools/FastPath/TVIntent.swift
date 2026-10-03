import Foundation

/// TV tools on the fast path (native only; Python has no TV branch). "Play the latest episode of
/// X" reaches the router's play branch as the query "the latest episode of x"; it goes to
/// tv_play instead of music_play. "Play the latest X", without the word episode, could be music
/// as well as TV, so it goes to the brain, which has both tools. "What's on TV" is matched before
/// the router (no Python branch takes it).
enum TVIntent: Equatable {
    case episode(show: String, episode: String)
    case ambiguous

    static let nowPlayingPhrases: Set<String> = [
        "what's on tv", "what is on tv", "what's on the tv", "what is on the tv", "what's playing on tv",
        "what is playing on tv", "what's playing on the tv", "what is playing on the tv", "what am i watching",
    ]

    /// `text` already normalised by `FastPathRouter.normalise`.
    static func isNowPlaying(_ text: String) -> Bool { nowPlayingPhrases.contains(text) }

    /// The play branch's query, read as a TV request, or nil when it is not one.
    static func play(_ query: String) -> TVIntent? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let m = TVUIReader.firstMatch(#"^(?:the )?(latest|newest|new|next|last) episode of (.+)$"#, in: q) {
            return .episode(show: m[2], episode: m[1] == "next" ? "next" : "latest")
        }
        if let m = TVUIReader.firstMatch(#"^(?:the )?(latest|newest|new|next|last) (.+?) episode$"#, in: q) {
            return .episode(show: m[2], episode: m[1] == "next" ? "next" : "latest")
        }
        if let m = TVUIReader.firstMatch(#"^season (\d{1,3}),? episode (\d{1,4}) of (.+)$"#, in: q) {
            return .episode(show: m[3], episode: "S\(m[1])E\(m[2])")
        }
        if let m = TVUIReader.firstMatch(#"^(.+?),? season (\d{1,3}),? episode (\d{1,4})$"#, in: q) {
            return .episode(show: m[1], episode: "S\(m[2])E\(m[3])")
        }
        if let m = TVUIReader.firstMatch(#"^(.+?) (s\d{1,3}\s?e\d{1,4})$"#, in: q) {
            return .episode(show: m[1], episode: m[2].replacingOccurrences(of: " ", with: "").uppercased())
        }
        if TVUIReader.firstMatch(#"^(?:the )?(?:latest|newest) .+$"#, in: q) != nil { return .ambiguous }
        return nil
    }
}
