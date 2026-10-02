import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// M9a part 6 (D-41): the gate's voice port with the owner check. Approved runs the action;
/// denied runs nothing and puts the same card back until its deadline.
@Suite("M9 voice confirmation gate")
struct VoiceConfirmationGateTests {
    static let desc = "That will delete notes.txt permanently"

    final class Check: ConfirmAuthenticator, @unchecked Sendable {
        let answer: Bool
        let during: (@Sendable () async -> Void)?
        private let asked = Mutex<[String]>([])

        init(answer: Bool, during: (@Sendable () async -> Void)? = nil) {
            self.answer = answer
            self.during = during
        }

        var reasons: [String] { asked.withLock { $0 } }

        func authenticate(reason: String) async -> Bool {
            asked.withLock { $0.append(reason) }
            await during?()
            return answer
        }
    }

    final class Ran: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var runs: Int { count.withLock { $0 } }
    }

    @Test("approved: the action runs once and the slot is empty")
    func approved() async {
        let gate = ConfirmationGate()
        let ran = Ran()
        let check = Check(answer: true)
        await gate.stash(desc: Self.desc, action: { ran.add(); return "Deleted, sir." }, turn: TurnContext(channel: .text))
        let result = await gate.consume("yes", via: .voice(confirming: .ownerCheck(check)), runIn: TurnContext(channel: .voice))
        #expect(result == .handled("Deleted, sir."))
        #expect(ran.runs == 1 && check.reasons == [Self.desc])
        #expect(await gate.pending == nil)
    }

    @Test("denied: nothing runs, and the same card comes back to the chat")
    func denied() async {
        let gate = ConfirmationGate()
        let ran = Ran()
        var updates = gate.updates.makeAsyncIterator()
        await gate.stash(desc: Self.desc, action: { ran.add(); return "Deleted, sir." }, turn: TurnContext(channel: .text))
        let card = await updates.next()
        let result = await gate.consume("yes", via: .voice(confirming: .ownerCheck(Check(answer: false))),
                                        runIn: TurnContext(channel: .voice))
        #expect(result == .handled(VoiceConfirmation.notConfirmed))
        #expect(ran.runs == 0)
        // Cleared while the check was up, then the same card, deadline and all.
        let cleared = await updates.next()
        let back = await updates.next()
        #expect(cleared == .some(nil))
        #expect(back == card)
        #expect(await gate.pending == card ?? nil)
        // It can still be confirmed until its deadline.
        let second = await gate.consume("confirm", via: .voice(confirming: .ownerCheck(Check(answer: true))),
                                        runIn: TurnContext(channel: .voice))
        #expect(second == .handled("Deleted, sir."))
        #expect(ran.runs == 1)
    }

    @Test("a confirmation stashed while the check was up is not overwritten by the old card")
    func newerCardWins() async {
        let gate = ConfirmationGate()
        await gate.stash(desc: "old", action: { "old ran" }, turn: TurnContext(channel: .text))
        let check = Check(answer: false, during: {
            await gate.stash(desc: "new", action: { "new ran" }, turn: TurnContext(channel: .text))
        })
        _ = await gate.consume("yes", via: .voice(confirming: .ownerCheck(check)), runIn: TurnContext(channel: .voice))
        #expect(await gate.pending?.desc == "new")
    }

    @Test("a spoken no clears the slot without asking, as before")
    func spokenNo() async {
        let gate = ConfirmationGate()
        let check = Check(answer: true)
        await gate.stash(desc: Self.desc, action: { "Deleted, sir." }, turn: TurnContext(channel: .text))
        let result = await gate.consume("no", via: .voice(confirming: .ownerCheck(check)), runIn: TurnContext(channel: .voice))
        #expect(result == .notHandled)
        #expect(check.reasons.isEmpty)
        #expect(await gate.pending == nil)
    }

    @Test("the unchecked voice port the tool tests use still confirms without asking")
    func uncheckedPort() async {
        let gate = ConfirmationGate()
        await gate.stash(desc: Self.desc, action: { "Deleted, sir." }, turn: TurnContext(channel: .text))
        #expect(await gate.consume("yes", via: .voice, runIn: TurnContext(channel: .voice)) == .handled("Deleted, sir."))
    }
}
