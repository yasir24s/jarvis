import Foundation
import JarvisBrain
@testable import JarvisChat
import JarvisCore
import JarvisTools
import Testing

/// F1: the morning briefing, with a ManualClock for "05:00" and "once a day", a throwaway
/// UserDefaults suite, and a fake coordinator: no brain runs and nothing is spoken.
@Suite("F1 morning briefing", .serialized)
@MainActor
struct MorningBriefingTests {
    static let zone = TimeZone(identifier: "Europe/London")!

    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
            .timeIntervalSince1970
    }

    static func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "jarvis-briefing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    @Test func requestsAreRecognised() {
        for text in ["brief me", "Brief me, Jarvis.", "Morning briefing", "hey jarvis, morning briefing please",
                     "What's my briefing?", "daily briefing"] {
            #expect(MorningBriefing.isRequest(text), "\(text)")
        }
        for text in ["good morning", "what's the weather", "brief me on the news", "", "briefing notes for work"] {
            #expect(!MorningBriefing.isRequest(text), "\(text)")
        }
    }

    @Test func onByDefaultAndOnceADayFromFive() async throws {
        try await Self.withDefaults { defaults in
            let clock = ManualClock(Self.at(3, 4, 59))
            let setting = MorningBriefingSetting(defaults: defaults, clock: clock, timeZone: Self.zone)
            #expect(setting.isOn)
            #expect(!setting.claimIfDue())                 // before 05:00
            clock.set(Self.at(3, 5))
            #expect(setting.claimIfDue())
            #expect(setting.lastDay == "2026-10-03")
            clock.set(Self.at(3, 23, 59))
            #expect(!setting.claimIfDue())                 // once a day
            // A relaunch reads the same record.
            let relaunched = MorningBriefingSetting(defaults: defaults, clock: clock, timeZone: Self.zone)
            #expect(!relaunched.claimIfDue())
            clock.set(Self.at(4, 0, 30))
            #expect(!relaunched.claimIfDue())              // the next day, still before 05:00
            clock.set(Self.at(4, 9))
            #expect(relaunched.claimIfDue())
        }
    }

    @Test func offOrAskedForMeansNoUnaskedBriefing() async throws {
        try await Self.withDefaults { defaults in
            let clock = ManualClock(Self.at(3, 8))
            let setting = MorningBriefingSetting(defaults: defaults, clock: clock, timeZone: Self.zone)
            setting.isOn = false
            #expect(defaults.bool(forKey: MorningBriefingSetting.defaultsKey) == false)
            #expect(!setting.claimIfDue())
            setting.isOn = true
            setting.recordToday()
            #expect(!setting.claimIfDue())
        }
    }

    @Test func theRequestCarriesTheAgenda() {
        let entry = AlarmEntry(stamp: "", time: Date(timeIntervalSince1970: Self.at(3, 18)), label: "call a friend",
                               repeats: nil, kind: .reminder)
        let line = MorningBriefing.agendaLine(entry, timeZone: Self.zone)
        #expect(line == "6:00 PM, reminder: call a friend")
        let request = MorningBriefing.request(agenda: [line])
        #expect(request.hasSuffix("Reminders and alarms due later today: 6:00 PM, reminder: call a friend."))
        for tool in ["get_time", "get_weather", "get_calendar", "get_news"] { #expect(request.contains(tool)) }
        #expect(request.contains("60 to 90 words"))
        #expect(MorningBriefing.request(agenda: []).hasSuffix("due later today: none."))
    }

    // MARK: through the chat

    private func model(_ coordinator: FakeCoordinator, _ defaults: UserDefaults, clock: ManualClock) -> ChatViewModel {
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.briefing = MorningBriefingSetting(defaults: defaults, clock: clock, timeZone: Self.zone)
        model.briefingAgenda = { ["6:00 PM, reminder: call a friend"] }
        return model
    }

    /// The first message of the day: the briefing goes first on its channel, then the message as
    /// sent. The second message of the day has none.
    @Test func firstVoiceTurnOfTheDayIsPrecededByTheBriefing() async throws {
        try await Self.withDefaults { defaults in
            let coordinator = FakeCoordinator { input, sink in
                let reply = input.briefing == nil ? "It is sunny, sir." : "Good morning, sir. Your rundown."
                await sink.sentence(reply)
                return .reply(reply)
            }
            let model = model(coordinator, defaults, clock: ManualClock(Self.at(3, 7, 30)))
            var finished: [String] = []
            model.onReplyFinished = { message, _ in finished.append(message.text) }
            await model.sendVoice("what's the weather")?.value
            let inputs = await coordinator.inputs
            #expect(inputs.map(\.text) == [MorningBriefing.shown, "what's the weather"])
            #expect(inputs.map(\.channel) == [.voice, .voice])
            #expect(inputs.first?.briefing == MorningBriefing.request(agenda: ["6:00 PM, reminder: call a friend"]))
            #expect(inputs.last?.briefing == nil)
            #expect(finished == ["Good morning, sir. Your rundown.", "It is sunny, sir."])
            #expect(model.messages.filter { $0.role == .user }.map(\.text) == [MorningBriefing.shown, "what's the weather"])
            #expect(!model.responding)

            await model.sendVoice("and tomorrow?")?.value
            #expect(await coordinator.inputs.count == 3)
            #expect(await coordinator.inputs.last?.briefing == nil)
        }
    }

    @Test func aTypedFirstMessageGetsItOnTheTextChannel() async throws {
        try await Self.withDefaults { defaults in
            let coordinator = FakeCoordinator(answering: .reply("Done, sir."))
            let model = model(coordinator, defaults, clock: ManualClock(Self.at(3, 6)))
            model.draft.text = "open my notes"
            await model.send()?.value
            let inputs = await coordinator.inputs
            #expect(inputs.map(\.text) == [MorningBriefing.shown, "open my notes"])
            #expect(inputs.map(\.channel) == [.text, .text])
        }
    }

    @Test func beforeFiveOrSwitchedOffTheMessageGoesAlone() async throws {
        try await Self.withDefaults { defaults in
            let coordinator = FakeCoordinator(answering: .reply("Yes, sir."))
            let clock = ManualClock(Self.at(3, 4, 45))
            let model = model(coordinator, defaults, clock: clock)
            await model.sendVoice("what time is it")?.value
            clock.set(Self.at(3, 9))
            model.briefing?.isOn = false
            await model.sendVoice("what time is it")?.value
            let inputs = await coordinator.inputs
            #expect(inputs.map(\.text) == ["what time is it", "what time is it"])
            #expect(inputs.allSatisfy { $0.briefing == nil })
        }
    }

    /// "Brief me" is the briefing itself, whenever it is said, and counts as today's.
    @Test func briefMeAsksForItOnDemand() async throws {
        try await Self.withDefaults { defaults in
            let coordinator = FakeCoordinator(answering: .reply("Your rundown, sir."))
            let clock = ManualClock(Self.at(3, 4))
            let model = model(coordinator, defaults, clock: clock)
            await model.sendVoice("Brief me, Jarvis")?.value
            var inputs = await coordinator.inputs
            #expect(inputs.map(\.text) == ["Brief me, Jarvis"])
            #expect(inputs.first?.briefing != nil)
            // Asked for at 04:00, it is today's: none plays unasked later on.
            clock.set(Self.at(3, 10))
            await model.sendVoice("thanks")?.value
            inputs = await coordinator.inputs
            #expect(inputs.map(\.text) == ["Brief me, Jarvis", "thanks"])
            #expect(inputs.last?.briefing == nil)
        }
    }

    /// Stop while the briefing is being written stops it, and the message after it is not sent.
    @Test func stopDuringTheBriefingStopsBoth() async throws {
        try await Self.withDefaults { defaults in
            let gate = Gate()
            let coordinator = FakeCoordinator { input, sink in
                await sink.delta("Good mor")
                if input.briefing != nil { await gate.park() }
                return .reply("Good morning, sir.")
            }
            let model = model(coordinator, defaults, clock: ManualClock(Self.at(3, 8)))
            model.draft.text = "hello"
            let task = try #require(model.send())
            await gate.waitUntilParked()
            #expect(model.stop() != nil)
            await gate.open()
            await task.value
            #expect(await coordinator.inputs.map(\.text) == [MorningBriefing.shown])
            #expect(model.draft.text == "hello")
            #expect(!model.responding)
        }
    }
}
