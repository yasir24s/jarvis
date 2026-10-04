import AVFAudio
import Darwin
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// The V10 probe, with JARVIS_QWEN_RESIDENT=1: does keeping the model resident stop an idle helper
/// paging its model out, and what does it cost the rest of the Mac? For resident on, then off: the
/// real jarvis-voice-qwen helper (through QwenEngine) loads and speaks one line; a separate process
/// allocates and touches `JARVIS_QWEN_RESIDENT_PRESSURE_MB` (default 2048) for
/// `JARVIS_QWEN_RESIDENT_HOLD_S` (default 60) and frees it; the helper then sits idle
/// `JARVIS_QWEN_RESIDENT_IDLE_S` (default 200); then a reply is rendered offline, as the V9 probe
/// does. Throughout, the system's free memory and swap, the pressure process's own resident and
/// swapped figures and the helper's graphics memory are printed; with resident on, the app's guard
/// (`QwenResidency`) looks every 5 s and lets the model go if memory falls under 10% free.
/// Nothing reaches a device.
@Suite("Qwen resident probe (JARVIS_QWEN_RESIDENT=1)", .serialized)
struct QwenResidentProbeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["JARVIS_QWEN_RESIDENT"] == "1"

    static func number(_ key: String, _ fallback: Int) -> Int {
        environment[key].flatMap(Int.init) ?? fallback
    }

    /// The pressure process: allocates, fills (with bytes the compressor cannot shrink), holds,
    /// frees and exits; alarm() ends it even if the probe dies. Every 5 s it prints its own figures.
    static let pressureSource = #"""
    import Darwin
    import Foundation
    let mb = Int(CommandLine.arguments[1])!, hold = Int(CommandLine.arguments[2])!
    alarm(UInt32(hold + 30))
    setvbuf(stdout, nil, _IOLBF, 0)
    func own() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return "resident \(info.resident_size / 1_048_576) MB, compressed or swapped \(info.compressed / 1_048_576) MB"
    }
    let bytes = mb * 1_048_576
    let buffer = malloc(bytes)!
    arc4random_buf(buffer, bytes)
    print("pressure: \(mb) MB allocated and filled; \(own())")
    let start = Date()
    var t = 0
    while Date().timeIntervalSince(start) < Double(hold) {
        sleep(5); t += 5
        // Touch every page again so the buffer stays in use, as a real app's would.
        let p = buffer.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < bytes { p[i] &+= 1; i += 16_384 }
        print("pressure: t=\(t) s, \(own())")
    }
    free(buffer)
    print("pressure: freed")
    """#

    static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func freePercent() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    static func swapUsedMB() -> Int {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return -1 }
        return Int(usage.xsu_used / 1_048_576)
    }

    /// System free %, swap used, and the helper's graphics line from `footprint -w`
    /// (dirty, swapped, clean, reclaimable, wired).
    static func system(_ helper: String) -> String {
        let pid = run("/usr/bin/pgrep", ["-f", "^\(helper)( |$)"]).split(separator: "\n").first.map(String.init) ?? ""
        let graphics = pid.isEmpty ? "helper not running"
            : run("/usr/bin/footprint", ["-w", pid]).split(separator: "\n")
                .first { $0.contains("IOAccelerator (graphics)") }
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).prefix(10).joined(separator: " ") }
                ?? "no graphics line"
        return "free \(freePercent().map(String.init) ?? "?")%, swap used \(swapUsedMB()) MB; helper \(graphics)"
    }

    @Test(.enabled(if: QwenResidentProbeTests.enabled, "set JARVIS_QWEN_RESIDENT=1 to run the real helper"),
          arguments: [true, false])
    func idleAfterPressureWithAndWithoutResident(resident: Bool) async throws {
        let name = resident ? "resident-on" : "resident-off"
        let say: @Sendable (String) -> Void = { line in print("resident probe: \(name): \(line)") }
        let out = try TempFolder()
        let logs = try TempFolder()
        let tools = try TempFolder()
        defer {
            out.remove()
            logs.remove()
            tools.remove()
        }
        let helper = Self.environment["JARVIS_QWEN_HELPER"].map { URL(fileURLWithPath: $0) } ?? QwenLiveTests.defaultHelper
        let helperPath = helper.path(percentEncoded: false)
        let helperLog = logs.url.appending(path: "jarvis-voice-qwen.log")
        let setup = QwenHelperSetup(
            executable: helper,
            assets: Self.environment["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VoiceHelperSetup.installedAssets,
            outDirectory: out.url, log: helperLog)
        try #require(setup.isInstalled())
        let pressureMB = Self.number("JARVIS_QWEN_RESIDENT_PRESSURE_MB", 2048)
        let holdSeconds = Self.number("JARVIS_QWEN_RESIDENT_HOLD_S", 60)
        let idleSeconds = Self.number("JARVIS_QWEN_RESIDENT_IDLE_S", 200)

        // The pressure tool, compiled once per run.
        let source = tools.url.appending(path: "pressure.swift")
        let pressureTool = tools.url.appending(path: "pressure")
        try Self.pressureSource.write(to: source, atomically: true, encoding: .utf8)
        _ = Self.run("/usr/bin/xcrun", ["swiftc", "-O", source.path(percentEncoded: false), "-o",
                                        pressureTool.path(percentEncoded: false)])
        try #require(FileManager.default.isExecutableFile(atPath: pressureTool.path(percentEncoded: false)))

        let qwen = QwenEngine(launcher: setup)
        await qwen.setResident(resident)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: EnginePlayer.sampleRate, channels: 2))
        let engine = try EnginePlayer(offline: output)
        let player = TeePlayer(base: engine)
        let queue = SpeechQueue(engine: qwen, fallback: SayEngine(), player: player,
                                helperFootprintMB: { qwen.lastFootprintMB }, log: { _ in })

        // The app's guard, at 5 s instead of 30, with resident on only (off stays off).
        let guardLines = Mutex<[String]>([])
        let residency: QwenResidency? = resident ? await QwenResidency(.init(
            usesQwen: { true }, muted: { false }, memoryFreePercent: { Self.freePercent() },
            setResident: { await qwen.setResident($0) },
            log: { line in say("guard: \(line)"); guardLines.withLock { $0.append(line) } })) : nil

        func speak(_ text: String) async throws -> (first: Double?, report: StreamReport?) {
            player.reset()
            let sent = ContinuousClock.now
            let firstSound = Mutex<ContinuousClock.Instant?>(nil)
            let head = Task {
                var rendered = 0
                var quiet = 0
                let start = ContinuousClock.now
                while !Task.isCancelled {
                    let due = Int((ContinuousClock.now - start) / .seconds(1) * EnginePlayer.sampleRate)
                    while rendered < due {
                        let frames = AVAudioFrameCount(min(Int(EnginePlayer.offlineFrames), due - rendered))
                        let next = try await engine.renderOffline(frames: frames)
                        if next.isEmpty { rendered = due; break }
                        rendered += next[0].count
                        if next[0].contains(where: { abs($0) >= 1e-7 }) {
                            firstSound.withLock { if $0 == nil { $0 = .now } }
                            quiet = 0
                        } else {
                            quiet += next[0].count
                        }
                    }
                    if player.ended, quiet > Int(EnginePlayer.sampleRate) {
                        await engine.stop()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            await queue.say(text, turn: UUID())
            await queue.idle()
            head.cancel()
            _ = try? await head.value
            return (firstSound.withLock { $0 }.map { ($0 - sent) / .seconds(1) }, await player.lastStream())
        }

        _ = try await speak("Good evening, sir.")
        say("loaded; " + Self.system(helperPath))

        // Pressure, sampled every 10 s; the guard looks every 5 s.
        let pressure = Process()
        pressure.executableURL = pressureTool
        pressure.arguments = [String(pressureMB), String(holdSeconds)]
        let pipe = Pipe()
        pressure.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") { say(String(line)) }
        }
        try pressure.run()
        defer { if pressure.isRunning { pressure.terminate() } }
        let started = ContinuousClock.now
        var lowest = 100
        while pressure.isRunning, ContinuousClock.now - started < .seconds(holdSeconds + 40) {
            for _ in 0..<2 {
                if let residency { await residency.check() }
                try await Task.sleep(for: .seconds(5))
            }
            lowest = min(lowest, Self.freePercent() ?? 100)
            say(String(format: "pressure +%.0f s: ", (ContinuousClock.now - started) / .seconds(1)) + Self.system(helperPath))
        }
        if pressure.isRunning { pressure.terminate() }
        pressure.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        say("pressure process exited (\(pressure.terminationStatus)); lowest free \(lowest)%")

        // Recovery and idle, sampled every 30 s.
        let freed = ContinuousClock.now
        while ContinuousClock.now - freed < .seconds(idleSeconds) {
            for _ in 0..<6 {
                if let residency { await residency.check() }
                try await Task.sleep(for: .seconds(5))
            }
            say(String(format: "idle +%.0f s: ", (ContinuousClock.now - freed) / .seconds(1)) + Self.system(helperPath))
        }

        let (first, report) = try await speak(QwenSpeakEarlyProbeTests.reply)
        say("reply: first audio " + (first.map { String(format: "%.2f s", $0) } ?? "none")
            + "; pre-roll " + (report.map { String(format: "%.2f s", $0.preroll) } ?? "n/a")
            + "; underruns \(report?.dry ?? -1), \(report?.dryMilliseconds ?? -1) ms"
            + "; delivered " + (report?.deliveryRate.map { String(format: "x%.2f", $0) } ?? "n/a"))
        let helperLines = (try? String(contentsOf: helperLog, encoding: .utf8)) ?? ""
        for line in helperLines.split(separator: "\n") where line.contains("resident") || line.contains("reply done") {
            say("helper: \(line)")
        }
        say("guard: " + (guardLines.withLock { $0 }.isEmpty ? "no change" : guardLines.withLock { $0 }.joined(separator: " | ")))
        await qwen.release()
    }
}
