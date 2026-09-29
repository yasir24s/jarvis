import Foundation
import JarvisBrain
import JarvisTools
import Testing

/// Plan §3.9: the voice addendum is empty, and the text addendum is the plan's string byte for
/// byte. The expected text is read from the plan itself (the one line that starts with
/// `\n\nCHANNEL: TEXT CHAT.`), with its two `\n` escapes turned into newlines.
@Suite("M3 channel addendum (plan 3.9)")
struct ChannelAddendumTests {
    static let marker = #"\n\nCHANNEL: TEXT CHAT."#

    static func planLine(_ file: String = #filePath) throws -> String {
        let plan = URL(filePath: file)
            .deletingLastPathComponent()   // JarvisBrainTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // native
            .appending(path: "plan/M02-M04-security-brain-chat.md")
        let lines = try String(contentsOf: plan, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(marker) }
        try #require(lines.count == 1, "the plan has \(lines.count) addendum lines")
        return String(lines[0])
    }

    @Test func voiceIsEmpty() {
        #expect(ChannelAddendum.text(.voice).utf8.isEmpty)
    }

    @Test func textIsThePlanStringByteForByte() throws {
        let line = try Self.planLine()
        let expected = "\n\n" + line.dropFirst(4)   // the literal `\n\n` escapes
        #expect(Array(ChannelAddendum.text(.text).utf8) == Array(expected.utf8))
        #expect(Array(ChannelAddendum.textChat.utf8) == Array(expected.utf8))
        print("channel addendum: \(expected.utf8.count) bytes, matches plan 3.9")
    }
}
