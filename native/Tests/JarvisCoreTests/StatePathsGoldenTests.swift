import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// paths.golden.json: os.path.relpath(getattr(jarvis, C), jarvis.HERE) for every state path.
@Suite("StatePaths golden (Python jarvis.py constants)")
struct PathsGoldenTests {
    private static func url(_ key: String, _ p: StatePaths) -> URL? {
        switch key {
        case "LOG_FILE": p.logFile
        case "KB_FILE": p.knowledge
        case "HIST_FILE": p.history
        case "CORR_FILE": p.corrections
        case "CHANGELOG_FILE": p.changelog
        case "PROFILE_FILE": p.profile
        case "PERSONALITY_FILE": p.personality
        case "EMOTIONS_FILE": p.emotions
        case "PROACTIVE_FILE": p.proactive
        case "ALARMS_FILE": p.alarms
        case "VOICEPRINT_FILE": p.voiceprint
        case "RESEARCH_DIR": p.researchDir
        case "RESEARCH_METRICS": p.researchMetrics
        case "RESEARCH_USAGE": p.researchUsage
        case "jarvis_notes.txt": p.notesFallback
        case "audd_key.txt": p.auddKey
        default: nil
        }
    }

    @Test(arguments: try Golden.cases("paths"))
    func matchesPython(_ c: GoldenCase) throws {
        let key = try #require(c.input.string("constant") ?? c.input.string("literal"))
        let root = URL(fileURLWithPath: "/nonexistent/jarvis-root", isDirectory: true)
        let paths = StatePaths(root: root)
        let url = try #require(Self.url(key, paths), "no StatePaths property for \(key)")
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        let prefix = "/nonexistent/jarvis-root/"
        #expect(path.hasPrefix(prefix))
        #expect(String(path.dropFirst(prefix.count)) == c.expected.string("relative"))
    }
}
