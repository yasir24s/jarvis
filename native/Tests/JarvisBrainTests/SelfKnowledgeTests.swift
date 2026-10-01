import Foundation
import JarvisBrain
import JarvisTools
import Testing

/// P4's self-knowledge: the exact text, pinned; its size; the text channel only (the voice
/// prompt stays Python's); and which brains are told of search_memory.
@Suite("P4 self-knowledge")
struct SelfKnowledgeTests {
    @Test func theTextIsPinned() {
        #expect(SelfKnowledge.withMemoryTools == "\n\nABOUT YOU: You were first built in Python and now run as a native macOS app written in Swift. The persona above is the one the Python version used, and your personality notes, profile, knowledge and memory carried over. search_memory finds what you remember, and your changelog (rule 7) says what has changed. You cannot hear your own voice, so never claim the user can hear you. Asked about any of this, answer as yourself: dry, brief, 'sir'.")
        #expect(SelfKnowledge.withoutMemoryTools == "\n\nABOUT YOU: You were first built in Python and now run as a native macOS app written in Swift. The persona above is the one the Python version used, and your personality notes, profile, knowledge and memory carried over. Your changelog (rule 7) says what has changed. You cannot hear your own voice, so never claim the user can hear you. Asked about any of this, answer as yourself: dry, brief, 'sir'.")
    }

    @Test func eachTextIsUnder500Bytes() {
        #expect(SelfKnowledge.withMemoryTools.utf8.count == 445)
        #expect(SelfKnowledge.withoutMemoryTools.utf8.count == 402)
        #expect(!SelfKnowledge.withoutMemoryTools.contains("search_memory"))
    }

    @Test func onlyTheTextChannelGetsIt() {
        #expect(SelfKnowledge.text(.voice, memoryTools: true) == "")
        #expect(SelfKnowledge.text(.voice, memoryTools: false) == "")
        #expect(SelfKnowledge.text(.text, memoryTools: true) == SelfKnowledge.withMemoryTools)
        #expect(SelfKnowledge.text(.text, memoryTools: false) == SelfKnowledge.withoutMemoryTools)
    }
}
