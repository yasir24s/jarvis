import Foundation
import JarvisBrain
@testable import JarvisChat
import JarvisTools
import Testing

/// UI1 part 5: editing an earlier message, with fakes. Sending the edit replaces the
/// conversation from that message on and runs it again, telling the coordinator which turns it
/// replaces; the earlier version is kept, and the arrows switch between versions.
@Suite("UI1 edit and versions", .serialized)
@MainActor
struct EditTests {
    static func echo() -> FakeCoordinator {
        FakeCoordinator { input, sink in
            await sink.delta("Reply to \(input.text)")
            return .reply("Reply to \(input.text)")
        }
    }

    static func conversation(_ coordinator: FakeCoordinator) async -> ChatViewModel {
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        for text in ["one", "two", "three"] {
            model.draft.text = text
            await model.send()?.value
        }
        return model
    }

    static func row(_ model: ChatViewModel, _ text: String) throws -> ChatMessage {
        try #require(model.messages.first { $0.role == .user && $0.text == text })
    }

    @Test func anEditReplacesTheConversationFromThatMessage() async throws {
        let coordinator = Self.echo()
        let model = await Self.conversation(coordinator)
        let two = try Self.row(model, "two")
        #expect(model.canEdit(two))
        let replaced = model.messages.suffix(4).compactMap(\.turnID)

        await model.edit(two.id, to: "two, edited")?.value

        #expect(model.messages.map(\.text) == ["one", "Reply to one", "two, edited", "Reply to two, edited"])
        let inputs = await coordinator.inputs
        #expect(inputs.last?.text == "two, edited")
        var turnIDs: [UUID] = []
        for turn in await coordinator.turns { turnIDs.append(await turn.turnID) }
        #expect(inputs.last?.replacing == [turnIDs[1], turnIDs[2]])
        #expect(Array(Set(replaced)).sorted { $0.uuidString < $1.uuidString }
                == [turnIDs[1], turnIDs[2]].sorted { $0.uuidString < $1.uuidString })
        #expect(inputs.dropLast().allSatisfy { $0.replacing.isEmpty })
        let edited = try Self.row(model, "two, edited")
        #expect(model.versions(of: edited)! == (1, 2))
        #expect(model.versions(of: try Self.row(model, "one")) == nil)
    }

    @Test func arrowsSwitchBetweenVersions() async throws {
        let model = await Self.conversation(Self.echo())
        await model.edit(try Self.row(model, "two").id, to: "two, edited")?.value
        let edited = try Self.row(model, "two, edited")

        model.showVersion(0, of: edited.id)
        #expect(model.messages.map(\.text) == ["one", "Reply to one", "two", "Reply to two", "three", "Reply to three"])
        let original = try Self.row(model, "two")
        #expect(model.versions(of: original)! == (0, 2))
        // An earlier version is for reading: nothing on screen can be edited while it shows.
        let one = try Self.row(model, "one")
        #expect(!model.canEdit(original) && !model.canEdit(one))

        model.showVersion(1, of: original.id)
        #expect(model.messages.map(\.text) == ["one", "Reply to one", "two, edited", "Reply to two, edited"])
        #expect(model.canEdit(try Self.row(model, "two, edited")))
    }

    @Test func sendingWhileAnEarlierVersionShowsGoesOnFromTheLatest() async throws {
        let model = await Self.conversation(Self.echo())
        await model.edit(try Self.row(model, "two").id, to: "two, edited")?.value
        model.showVersion(0, of: try Self.row(model, "two, edited").id)
        model.draft.text = "four"
        await model.send()?.value
        #expect(model.messages.map(\.text) == ["one", "Reply to one", "two, edited", "Reply to two, edited",
                                               "four", "Reply to four"])
    }

    @Test func editingAgainAddsAVersion() async throws {
        let model = await Self.conversation(Self.echo())
        await model.edit(try Self.row(model, "two").id, to: "two, edited")?.value
        await model.edit(try Self.row(model, "two, edited").id, to: "two, again")?.value
        let again = try Self.row(model, "two, again")
        #expect(model.versions(of: again)! == (2, 3))
        model.showVersion(1, of: again.id)
        #expect(model.messages.map(\.text) == ["one", "Reply to one", "two, edited", "Reply to two, edited"])
        model.showVersion(0, of: try Self.row(model, "two, edited").id)
        #expect(model.messages.map(\.text).prefix(4) == ["one", "Reply to one", "two", "Reply to two"])
    }

    @Test func onlyRowsFromATurnCanBeEdited() async throws {
        let gate = Gate()
        let coordinator = FakeCoordinator { input, sink in
            if input.text == "slow" { await gate.park() }
            await sink.delta("ok")
            return .reply("ok")
        }
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.post("A note he posted himself.")
        model.replaceMessages([ChatMessage(role: .user, text: "restored after an update", phase: .finished)])
        #expect(!model.canEdit(try Self.row(model, "restored after an update")))
        model.draft.text = "slow"
        let task = try #require(model.send())
        await gate.waitUntilParked()
        #expect(!model.canEdit(try Self.row(model, "slow")))   // not while a turn runs
        #expect(model.edit(try Self.row(model, "slow").id, to: "x") == nil)
        await gate.open()
        await task.value
        #expect(model.canEdit(try Self.row(model, "slow")))
        #expect(model.edit(try Self.row(model, "slow").id, to: "   ") == nil)   // nothing to send
    }

    @Test func anEditRefusedAsBusyChangesNothing() async throws {
        let outcomes = Outcomes([.reply("Reply to one"), .busy])
        let model = ChatViewModel(submitter: FakeCoordinator(outcomes), minimumGap: .zero)
        model.draft.text = "one"
        await model.send()?.value
        let before = model.messages
        let one = try Self.row(model, "one")
        await model.edit(one.id, to: "one, edited")?.value
        #expect(model.messages == before)
        #expect(model.versions(of: one) == nil)
        #expect(model.busy)
    }

    @Test func anEditStopsSpeech() async throws {
        let model = await Self.conversation(Self.echo())
        let order = Order()
        model.onStopSpeech = { order.add("speech stopped") }
        model.speaking = true
        await model.edit(try Self.row(model, "three").id, to: "three, edited")?.value
        #expect(order.events == ["speech stopped"])
    }
}
