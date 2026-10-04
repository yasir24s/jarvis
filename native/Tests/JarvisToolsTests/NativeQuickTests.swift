import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// od/phase2 item 2 (DEV-OD2-01): native-only fast-path phrasings, tried after every Python
/// branch has deferred. The quick_router golden suite keeps Python's own phrasings.
@Suite("OD2 native fast paths: battery, Wi-Fi, time, CPU, volume, media, reminders, alarms, timers")
struct NativeQuickTests {
    @Test(arguments: [
        ("whats my batery at", "battery.native", FastPathCommand.systemInfo("battery")),
        ("what's my battery at?", "battery.native", .systemInfo("battery")),
        ("how's the battery looking", "battery.native", .systemInfo("battery")),
        ("is the laptop charging", "battery.native", .systemInfo("battery")),
        ("whats the battery like", "battery.native", .systemInfo("battery")),
        ("check my battry", "battery.native", .systemInfo("battery")),
        ("what wifi am i on", "wifi.native", .systemInfo("wifi")),
        ("what's my wi-fi network called", "wifi.native", .systemInfo("wifi")),
        ("which network am i connected to", "wifi.native", .systemInfo("wifi")),
        ("what's the cpu usage", "cpu.native", .systemInfo("cpu")),
        ("how busy is my mac", "cpu.native", .systemInfo("cpu")),
        ("what tiem is it", "time.native", .systemInfo("time")),
        ("could you tell me the time please", "time.native", .systemInfo("time")),
        ("set the volume to 40%", "volume.native", .setVolume(announcement: "Setting volume to 40, sir.", level: 40)),
        ("turn it up a bit", "volume.native", .nudgeVolume(announcement: "Turning it up, sir.", delta: 15)),
        ("turn the volume up", "volume.native", .nudgeVolume(announcement: "Turning it up, sir.", delta: 15)),
        ("can you turn it down please", "volume.native", .nudgeVolume(announcement: "Turning it down, sir.", delta: -15)),
        ("mute the sound", "volume.native", .setVolume(announcement: "Muting, sir.", level: 0)),
        ("pause the music", "media.native", .media(announcement: "Paused, sir.", command: "pause")),
        ("could you puase the music", "media.native", .media(announcement: "Paused, sir.", command: "pause")),
        ("resume the music", "media.native", .media(announcement: "Playing, sir.", command: "play")),
        ("skip this song", "media.native", .media(announcement: "Next track, sir.", command: "next track")),
        ("go back one track", "media.native", .media(announcement: "Going back, sir.", command: "previous track")),
        ("can you remind me to call mum in 10 minutes", "reminder.native",
         .reminder(task: "call mum", when: "in 10 minutes")),
        ("set a reminder for 5pm to call mum", "reminder.native", .reminder(task: "call mum", when: "at 5pm")),
        ("don't let me forget to buy milk", "reminder.native", .reminder(task: "buy milk", when: "")),
        ("set me an alarm for 7am", "alarm.native", .setAlarm("7am")),
        ("please set an alarm for 6:30", "alarm.native", .setAlarm("6:30")),
        ("set a 5 minute timer", "timer.native", .setTimer(300)),
        ("can you set a timer for 5 minutes", "timer.native", .setTimer(300)),
        ("10 second timer", "timer.native", .setTimer(10)),
    ] as [(String, String, FastPathCommand?)])
    func nativePhrasings(_ text: String, _ branch: String, _ command: FastPathCommand?) {
        let match = FastPathRouter().route(text)
        #expect(match.branch == branch, "\(text)")
        #expect(match.command == command, "\(text)")
    }

    /// Python's own phrasings keep Python's branch names.
    @Test(arguments: [
        ("what time is it", "time"), ("battery level", "battery"), ("volume 30", "volume.set"),
        ("pause", "media.pause"), ("next song", "media.next"), ("remind me to call mum", "reminder"),
        ("set an alarm for 7", "alarm.set"), ("set a timer for 5 minutes", "timer.set"), ("mute", "volume.mute"),
    ])
    func pythonPhrasingsKeepPythonsBranch(_ text: String, _ branch: String) {
        #expect(FastPathRouter().route(text).branch == branch)
    }

    @Test(arguments: [
        "what's the tide", "is the battery saver on", "what's the weather", "set up my wifi password",
        "turn on wifi", "what time is it in tokyo", "how long does the battery last on an iphone",
        "tell me about cpu architectures", "play something by queen", "remind me why we're here",
        "what's the volume of a sphere", "how many times have i asked", "set an alarm",
        // Python's golden defers these, so they stay with the model.
        "alarm for 5:45 tomorrow labelled gym", "my battery", "volume fifty", "what  time is it", "timer for five minutes", "set a timer for ten minutes",
    ])
    func otherPhrasesAreNotNativeQuick(_ text: String) {
        #expect(!FastPathRouter.quickBranches.contains(FastPathRouter().route(text).branch), "\(text)")
    }

    @Test func everyNativeBranchIsDispatched() {
        #expect(FastPathRouter.quickBranches.isSubset(of: FastPathRouter.native))
    }

    @Test func wifiAndCpuGoToTheirTools() async throws {
        let rig = try await QuickDispatchTests.Rig()
        defer { rig.sandbox.remove() }
        for (phrase, tool) in [("what wifi am i on", "get_wifi_status"), ("what's the cpu usage", "get_cpu_usage"),
                               ("whats my batery at", "get_battery"), ("what tiem is it", "get_time")] {
            let expected = await rig.direct(tool, JSONObject())
            #expect(await rig.say(phrase) == expected, "\(phrase)")
        }
    }
}
