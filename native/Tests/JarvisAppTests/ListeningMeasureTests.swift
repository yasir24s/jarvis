import AVFAudio
import Darwin
import Foundation
@testable import JarvisApp
import JarvisChat
import JarvisCore
import JarvisTestSupport
import JarvisVoice
import Synchronization
import Testing

/// M9a: what push-to-talk costs, gated by JARVIS_MIC_MEASURE=1. It runs the app's own
/// composition (`AppListening`) with the real SpeechTranscriber, fed by a stand-in device that
/// plays a `say` clip at 48 kHz float in 2048-frame buffers at real-time pace, as the built-in
/// microphone delivers them. The microphone itself is never opened. Printed per phase: this
/// process's CPU and footprint, and the CPU time of the other processes that used the most.
@Suite("M9 listening cost", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["JARVIS_MIC_MEASURE"] == "1"))
struct ListeningMeasureTests {
    /// Plays `buffers` in a loop, one every 2048/48000 s, on a thread of its own until stopped.
    final class PacedInput: MicInput, @unchecked Sendable {
        let buffers: [AVAudioPCMBuffer]
        private let running = Mutex(false)

        init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }

        func inputFormat() throws(MicError) -> AVAudioFormat { buffers[0].format }

        func start(tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError) {
            running.withLock { $0 = true }
            let thread = Thread { self.play(tap) }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        private func play(_ tap: @Sendable (AVAudioPCMBuffer, UInt64) -> Void) {
            let period = Double(buffers[0].frameLength) / buffers[0].format.sampleRate
            var next = Date()
            var i = 0
            while running.withLock({ $0 }) {
                tap(buffers[i % buffers.count], mach_absolute_time())
                i += 1
                next += period
                let wait = next.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }

        func stop() { running.withLock { $0 = false } }
    }

    struct Allow: PermissionAsking {
        func microphone() -> PermissionStatus { .granted }
        func requestMicrophone() async -> Bool { true }
        func speechRecognition() -> PermissionStatus { .granted }
        func requestSpeechRecognition() async -> Bool { true }
    }

    final class Counter: ResearchCounting, @unchecked Sendable {
        func bump(_ key: String, by n: Int) {}
    }

    struct NoFront: FrontAppProviding {
        func frontmostAppName() async -> String { "" }
    }

    /// This process's user + system CPU seconds.
    static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// This process's physical footprint in MB (what Activity Monitor shows as Memory).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// The speech and audio services whose share is printed for every phase.
    static let tracked = ["com.apple.siri.embeddedspeech", "milod", "corespeechd", "speechmaintenanced", "coreaudiod"]

    /// Resident memory in MB of each tracked service now.
    static func trackedRSS() -> [String: Double] {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/ps")
        p.arguments = ["-Ao", "rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [String: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let kb = Double(parts[0]) else { continue }
            let name = URL(filePath: String(parts[1])).lastPathComponent
            if tracked.contains(name) { out[name, default: 0] += kb / 1024 }
        }
        return out
    }

    /// Every process's CPU seconds so far, by pid, with its name.
    static func processTimes() -> [Int32: (String, Double)] {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,time=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [Int32: (String, Double)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            // [[dd-]hh:]mm:ss.ss
            var seconds = 0.0
            var field = Substring(parts[1])
            if let dash = field.firstIndex(of: "-") {
                seconds += (Double(field[..<dash]) ?? 0) * 86_400
                field = field[field.index(after: dash)...]
            }
            for piece in field.split(separator: ":") { seconds = seconds * 60 + (Double(piece) ?? 0) }
            out[pid] = (URL(filePath: String(parts[2])).lastPathComponent, seconds)
        }
        return out
    }

    struct Phase {
        let name: String
        let seconds: Double
        let cpu: Double
        let footprint: Double
        let others: [(String, Double)]
        let rss: [String: Double]

        var line: String {
            let busiest = others.prefix(4).map { "\($0.0) \(String(format: "%.1f", $0.1 / seconds * 100))%" }
            let services = ListeningMeasureTests.tracked.map { name in
                let t = others.filter { $0.0 == name }.reduce(0) { $0 + $1.1 }
                return "\(name) \(String(format: "%.1f", t / seconds * 100))% \(String(format: "%.0f", rss[name] ?? 0)) MB"
            }
            return "MEASURE \(name): \(String(format: "%.1f", seconds)) s, this process "
                + "\(String(format: "%.2f", cpu / seconds * 100))% CPU, footprint \(String(format: "%.1f", footprint)) MB; "
                + "services: \(services.joined(separator: ", ")); busiest others: \(busiest.joined(separator: ", "))"
        }
    }

    static func measure(_ name: String, _ body: () async throws -> Void) async rethrows -> Phase {
        let me = getpid()
        let before = processTimes()
        let cpu0 = cpu()
        let t0 = ContinuousClock.now
        try await body()
        let elapsed = ContinuousClock.now - t0
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let cpu1 = cpu()
        let after = processTimes()
        var others: [(String, Double)] = []
        for (pid, (name, t)) in after where pid != me {
            let d = t - (before[pid]?.1 ?? 0)
            if d > 0.005 { others.append((name, d)) }
        }
        others.sort { $0.1 > $1.1 }
        return Phase(name: name, seconds: seconds, cpu: cpu1 - cpu0, footprint: footprintMB(), others: others,
                     rss: trackedRSS())
    }

    @Test func listeningCost() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jarvis-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "speech.wav")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Daniel", "-o", wav.path(percentEncoded: false), "--data-format=LEF32@48000",
                         "Jarvis, remind me to call the bank at four, then check the weather for tomorrow "
                         + "and turn the volume down a little."]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: wav)
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048)!
            try file.read(into: b, frameCount: 2048)
            if b.frameLength == 2048 { buffers.append(b) }
            if b.frameLength < 2048 { break }
        }
        print("MEASURE clip: \(buffers.count) buffers of 2048 at \(Int(file.processingFormat.sampleRate)) Hz "
              + "(\(String(format: "%.2f", Double(buffers.count * 2048) / file.processingFormat.sampleRate)) s), looped")

        let sb = try Sandbox()
        defer { sb.remove() }
        let clock = JarvisCore.ManualClock(1_790_582_400)
        let core = CoreState(store: try StateStore(root: sb.root.path(percentEncoded: false), lease: nil, clock: clock),
                             clock: clock, research: Counter(), frontApp: NoFront())
        let input = PacedInput(buffers)
        let listening = AppListening(core: core, research: Counter(), permissions: Allow(), makeInput: { input },
                                     log: { print("MEASURE log: \($0)") })
        var phases: [Phase] = []
        phases.append(await Self.measure("idle before, mic closed") { try? await Task.sleep(for: .seconds(10)) })
        let previews = Mutex(0)
        var outcome: HeardOutcome = .cancelled
        phases.append(try await Self.measure("listening (first session, model loads)") {
            try await listening.begin(level: { _ in }, preview: { _ in previews.withLock { $0 += 1 } })
            try await Task.sleep(for: .seconds(10))
            outcome = await listening.finish()
        })
        print("MEASURE first outcome: \(outcome); \(previews.withLock { $0 }) previews")
        phases.append(await Self.measure("idle after, mic closed (model lingering)") {
            try? await Task.sleep(for: .seconds(10))
        })
        phases.append(try await Self.measure("listening (second session)") {
            try await listening.begin(level: { _ in }, preview: { _ in previews.withLock { $0 += 1 } })
            try await Task.sleep(for: .seconds(10))
            outcome = await listening.finish()
        })
        print("MEASURE second outcome: \(outcome)")
        phases.append(await Self.measure("idle after the second, mic closed") {
            try? await Task.sleep(for: .seconds(30))
        })
        for p in phases { print(p.line) }
    }
}
