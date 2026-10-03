#if DEBUG
import Darwin
import Foundation
import JarvisVoice
import Synchronization

/// `JARVIS --selftest-listen [<seconds>] [switch]` (M11 part 5, DEBUG builds only): what listening
/// for "Hey Jarvis" costs at idle. It opens the microphone through the AudioHub, voice processing
/// as `JARVIS_AEC` has it (M11b: off at idle by default), and scores every frame with the wake
/// word for `seconds` (default 60), playing nothing. One JSON line: the CPU it took over that time
/// (user and system, as a share of one core), its memory footprint before and while listening,
/// the frames scored, the top score, and how many frames were digital silence (a closed lid or no
/// microphone access gives only those). Nothing is kept.
///
/// With `switch` (M11b), every 5 s it tells the hub a reply started or ended, with nothing
/// played, so voice processing goes on and off; `switches` has the hub's lines about each switch
/// (how long the rebuild took, and how much sound the microphone missed).
enum ListenSelfTest {
    static let flag = "--selftest-listen"

    static func run(arguments: [String]) -> Int32 {
        let seconds = arguments.first.flatMap(Double.init) ?? 60
        let switching = arguments.contains("switch")
        let result = Mutex<[String: any Sendable]>([:])
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let report = await measure(seconds: seconds, switching: switching)
            result.withLock { $0 = report }
            done.signal()
        }
        done.wait()
        let report = result.withLock { $0 }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return (report["ok"] as? Bool) == true ? 0 : 1
    }

    /// The bundle's vendored files, or, run as `.build/debug/JARVIS`, the checkout's
    /// (native/Resources/vendor).
    static func assets() -> VendoredAssets {
        let bundled = VendoredAssets.appBundle()
        if FileManager.default.fileExists(atPath: bundled.onnxRuntime.path(percentEncoded: false)) { return bundled }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.resolvingSymlinksInPath()
        let products = executable.deletingLastPathComponent()
        // Up from the products folder to the first folder holding Resources/vendor: native/.
        var folder = products
        while folder.pathComponents.count > 1 {
            let vendor = folder.appending(path: "Resources/vendor", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: vendor.path(percentEncoded: false)) {
                return VendoredAssets.checkout(vendor: vendor, buildProducts: products)
            }
            folder = folder.deletingLastPathComponent()
        }
        return bundled
    }

    static func measure(seconds: Double, switching: Bool = false) async -> [String: any Sendable] {
        var report: [String: any Sendable] = ["seconds": seconds]
        let assets = Self.assets()
        let detector: WakeWordDetector
        do {
            detector = try WakeWordDetector(runtime: try OrtRuntime.load(dylib: assets.onnxRuntime), assets: assets)
        } catch {
            report["error"] = "wake models: \(error)"
            report["ok"] = false
            return report
        }
        let lines = Mutex<[String]>([])
        let hub = AudioHub(aec: AudioHub.aec(), log: { line in lines.withLock { $0.append(line) } })
        let mic = MicCapture(makeInput: { HubMicInput(hub: hub) })
        let frames = await mic.frames()
        report["footprint_before_mb"] = footprintMB()
        do {
            try await mic.start()
        } catch {
            report["error"] = "microphone: \(error)"
            report["ok"] = false
            return report
        }
        // A microphone that stops sending ends the run instead of hanging it.
        let limit = Task {
            try? await Task.sleep(for: .seconds(seconds + 10))
            if !Task.isCancelled { await mic.stop() }
        }
        defer { limit.cancel() }
        let switcher = Task {
            guard switching else { return }
            var on = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if on { hub.speechEnded() } else { hub.speechWillStart() }
                on.toggle()
            }
        }
        defer { switcher.cancel() }
        // The engine's first second (voice processing settling) is not counted.
        let settle = ContinuousClock.now + .seconds(1)
        var scored = 0
        var silent = 0
        var top: Float = 0
        var start: (cpu: Double, wall: ContinuousClock.Instant)?
        let end = ContinuousClock.now + .seconds(1 + seconds)
        for await frame in frames {
            if start == nil, ContinuousClock.now >= settle { start = (cpuSeconds(), .now) }
            let score = (try? detector.process(frame.samples)) ?? 0
            guard start != nil else { continue }
            scored += 1
            top = max(top, score)
            if frame.samples.allSatisfy({ $0 == 0 }) { silent += 1 }
            if ContinuousClock.now >= end { break }
        }
        let cpu = cpuSeconds() - (start?.cpu ?? 0)
        let wall = start.map { ContinuousClock.now - $0.wall } ?? .zero
        let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        report["footprint_listening_mb"] = footprintMB()
        report["voice_processing"] = hub.currentMode == .duplex(voiceProcessing: true)
        switcher.cancel()
        await mic.stop()
        if switching {
            report["switches"] = lines.withLock { $0 }.filter { $0.contains("missed") || $0.contains("speak") }
        }
        report["frames_scored"] = scored
        report["frames_silent"] = silent
        report["top_score"] = Double(top)
        report["cpu_percent_of_one_core"] = wallSeconds > 0 ? (cpu / wallSeconds * 1000).rounded() / 10 : 0
        report["aec"] = AudioHub.aec().rawValue
        report["ok"] = scored > 0
        return report
    }

    /// User and system CPU time of this process, in seconds.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// `phys_footprint`, as Activity Monitor's Memory column and `footprint` report it, in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}
#endif
