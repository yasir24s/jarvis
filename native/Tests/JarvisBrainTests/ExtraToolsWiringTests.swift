import Foundation
@testable import JarvisBrain
import JarvisTools
import Testing

/// Batch C: the app's own tools are served after the memory tools, and allowed by the same list.
@Suite("Batch C extra tools in the brain", .timeLimit(.minutes(1)))
struct ExtraToolsWiringTests {
    @Test func extraToolsFollowTheMemoryTools() {
        let with = BrainAssembly.claudeTools(memory: true, extra: [IdentifySong.schema])
        #expect(with.tools.last?.name == IdentifySong.name)
        #expect(with.tools.dropLast() == BrainAssembly.claudeTools(memory: true).tools[...])
        #expect(with.allowed == with.tools.map { "mcp__jarvis__" + $0.name })
    }
}
