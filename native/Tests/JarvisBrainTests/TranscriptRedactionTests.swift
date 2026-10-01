import Foundation
@testable import JarvisBrain
import JarvisCore
import Testing

/// D-51 P3, piece 3 (a flag from P2's review): P2's fact compile redacts the transcript, and
/// the on-device draft, before the Claude stage; the on-device model still gets the
/// transcript unchanged. The key-shaped value is assembled at run time.
@Suite("Transcript redaction for P2's Claude stage (D-51 P3)", .timeLimit(.minutes(1)))
struct TranscriptRedactionTests {
    static let timeout: Duration = .seconds(5)
    static let key = "sk-" + "ant-" + "api03-" + String(repeating: "Zq7", count: 14)
    static let transcript = """
        Conversation on 2026-09-30:
        User: my wifi password is tomato-soup-77, and I moved to Leeds
        User: the deploy key is \(key)
        JARVIS: Noted.
        """

    @Test func claudeGetsTheTranscriptAndDraftRedactedAndTheLocalModelDoesNot() async throws {
        let draft = "The user moved to Leeds.\nThe user's wifi password is tomato-soup-77."
        let local = ScriptedWriter(.reply(draft))
        let claude = ScriptedWriter(.reply("The user moved to Leeds."))
        let writer = BrainAssembly.factWriter(local: local, claude: claude, log: { _ in })

        let text = try await writer.write(system: FactExtraction.system, user: Self.transcript,
                                          timeout: Self.timeout)

        #expect(text.text == "The user moved to Leeds.")
        #expect(local.calls.map(\.user) == [Self.transcript])                 // unchanged
        let sent = try #require(claude.calls.first?.user)
        #expect(claude.calls.count == 1)
        #expect(!sent.contains("tomato-soup-77") && !sent.contains(Self.key))
        #expect(sent.contains("my wifi password is \(Redactor.mask)"))
        #expect(sent.contains("The user's wifi password is \(Redactor.mask)"))  // the draft too
        #expect(sent.contains("The user moved to Leeds."))
    }

    @Test func claudeAloneGetsTheRedactedTranscript() async throws {
        let local = ScriptedWriter(.fail(.localUnavailable("off")))
        let claude = ScriptedWriter(.reply("NONE"))
        let writer = BrainAssembly.factWriter(local: local, claude: claude, log: { _ in })

        _ = try await writer.write(system: FactExtraction.system, user: Self.transcript, timeout: Self.timeout)

        #expect(local.calls.map(\.user) == [Self.transcript])
        #expect(claude.calls.map(\.user) == [Redactor.redact(Self.transcript).text])
        #expect(claude.calls.first?.user.contains(Self.key) == false)
    }

    @Test func thePersonaWriterStillSendsClaudeItsTextAsItIs() async throws {
        let local = ScriptedWriter(.reply("The user likes jokes."))
        let claude = ScriptedWriter(.reply("The user likes a dry joke."))
        let writer = CollaborativePersonaLLM(local: local, claude: claude, log: { _ in })
        _ = try await writer.write(system: PersonaDistill.distillSystem, user: Self.transcript,
                                   timeout: Self.timeout)
        #expect(claude.calls.first?.user ==
                CollaborativePersonaLLM.improveRequest(user: Self.transcript, draft: "The user likes jokes."))
    }
}
