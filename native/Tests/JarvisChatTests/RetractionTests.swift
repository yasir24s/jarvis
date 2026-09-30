import Foundation
import JarvisBrain
import JarvisChat
import Testing

/// R6 in the text channel (plan §3.6, M4 C2 item 4): the rows a retracted message fed are
/// struck through, and emitted sentences still stand.
@Suite("M4 retracted rows (R6)", .timeLimit(.minutes(1)))
@MainActor
struct RetractionTests {
    static func run(_ script: @escaping FakeCoordinator.Script, minimumGap: Duration = .zero) async -> ChatViewModel {
        let model = ChatViewModel(submitter: FakeCoordinator(script), minimumGap: minimumGap)
        model.draft.text = "what time is it"
        await model.send()?.value
        return model
    }

    @Test("emitted sentences stand: the struck row keeps what streamed, the reply row the spoken sentence")
    func emittedSentencesStand() async {
        let model = await Self.run { _, sink in
            await sink.delta("Right away, sir. ")
            await sink.sentence("Right away, sir.")
            await sink.delta("I can't help with")
            await sink.retracted(messageID: "msg_01")
            return .reply("Right away, sir.")
        }
        #expect(model.messages.map(\.text) == ["what time is it", "Right away, sir. I can't help with", "Right away, sir."])
        #expect(model.messages.map(\.retracted) == [false, true, false])
        #expect(model.messages.allSatisfy { $0.phase == .finished })
    }

    @Test("a retraction before anything streamed adds no row")
    func nothingShown() async {
        let model = await Self.run { _, sink in
            await sink.retracted(messageID: "msg_01")
            await sink.delta("It is three o'clock, sir.")
            await sink.sentence("It is three o'clock, sir.")
            return .reply("It is three o'clock, sir.")
        }
        #expect(model.messages.map(\.text) == ["what time is it", "It is three o'clock, sir."])
        #expect(model.messages.allSatisfy { !$0.retracted })
    }

    @Test("two retracted messages in one turn give two struck rows")
    func twoRetractions() async {
        let model = await Self.run { _, sink in
            await sink.delta("First try")
            await sink.retracted(messageID: "msg_01")
            await sink.delta("Second try")
            await sink.retracted(messageID: "msg_02")
            await sink.delta("It is three o'clock, sir.")
            await sink.sentence("It is three o'clock, sir.")
            return .reply("It is three o'clock, sir.")
        }
        #expect(model.messages.map(\.text) == ["what time is it", "First try", "Second try", "It is three o'clock, sir."])
        #expect(model.messages.map(\.retracted) == [false, true, true, false])
    }

    @Test("a struck row keeps text the update gap was still holding back, and is never markdown")
    func heldTextIsStruckToo() async {
        let model = await Self.run({ _, sink in
            await sink.delta("I **can't** ")
            await sink.delta("help with that")
            await sink.retracted(messageID: "msg_01")
            return .reply("")
        }, minimumGap: .seconds(600))
        #expect(model.messages.map(\.text) == ["what time is it", "I **can't** help with that"])
        #expect(model.messages.last?.retracted == true)
        #expect(model.messages.last?.rendersMarkdown == false)
    }
}
