import Darwin
import F5TTS
import Foundation
import MLX
import Vocos

// jarvis-voice: the F5-TTS helper JARVIS speaks through (plan D-54).
//
//   jarvis-voice --assets <dir> --out-dir <dir> [--cache-limit-mb 512] [--steps 8]
//                [--speed 1] [--idle-exit 300] [--selftest] [--render <list>]
//
// Protocol: one JSON object per line on stdin, one per line on stdout.
//   {"id": "<uuid>", "text": "<clean text>"}
//     -> {"id", "ok": true, "path", "samples", "rate": 24000, "gen_ms", "footprint_mb"}
//        where path is a raw float32 little-endian mono file in --out-dir (the caller deletes it)
//     -> {"id", "ok": false, "error"}
//   {"cmd": "ping"} -> {"cmd": "ping", "ok": true, "loaded", "footprint_mb"}
// The model loads on the first request and stays loaded. The helper exits on stdin EOF, or
// after --idle-exit seconds with no request, which hands its memory back to the system.
//
// --render <list> (V1 part 1): each line of <list> is "<name>\t<text>"; the text is rendered and
// written to <out-dir>/<name>.wav (32-bit float, 24 kHz mono), then the helper exits, 0 when
// every line was rendered. install-voice-assets.sh renders JARVIS's acknowledgements this way.
//
// <assets> holds f5/{model.safetensors,vocab.txt}, vocos/{model.safetensors,config.json} and
// reference/{reference.wav,reference.txt} (native/scripts/install-voice-assets.sh puts them there).

// MARK: - Arguments

struct Options {
    var assets: URL?
    var outDir: URL?
    var cacheLimitMB = 512
    var steps = 8
    var speed = 1.0
    var idleExitSeconds = 300.0
    var selftest = false
    var render: URL?
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data((
        "jarvis-voice: \(message)\n"
            + "usage: jarvis-voice --assets <dir> --out-dir <dir> [--cache-limit-mb N] [--steps N]"
            + " [--speed X] [--idle-exit S] [--selftest] [--render <list>]\n").utf8))
    exit(2)
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var i = 1
    func next(_ flag: String) -> String {
        i += 1
        guard i < args.count else { usage("\(flag) needs a value") }
        return args[i]
    }
    while i < args.count {
        let flag = args[i]
        switch flag {
        case "--assets": options.assets = URL(fileURLWithPath: next(flag), isDirectory: true)
        case "--out-dir": options.outDir = URL(fileURLWithPath: next(flag), isDirectory: true)
        case "--cache-limit-mb":
            guard let n = Int(next(flag)), n >= 0 else { usage("\(flag) takes a whole number") }
            options.cacheLimitMB = n
        case "--steps":
            guard let n = Int(next(flag)), n > 0 else { usage("\(flag) takes a positive number") }
            options.steps = n
        case "--speed":
            guard let s = Double(next(flag)), s > 0 else { usage("\(flag) takes a positive number") }
            options.speed = s
        case "--idle-exit":
            guard let s = Double(next(flag)), s > 0 else { usage("\(flag) takes seconds") }
            options.idleExitSeconds = s
        case "--selftest": options.selftest = true
        case "--render": options.render = URL(fileURLWithPath: next(flag), isDirectory: false)
        default: usage("unknown argument \(flag)")
        }
        i += 1
    }
    if options.assets == nil { usage("--assets is required") }
    if options.outDir == nil { usage("--out-dir is required") }
    return options
}

// MARK: - Memory

/// The process's physical footprint now and at its peak, in MB (task_info TASK_VM_INFO).
func footprintMB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (-1, -1) }
    let mb = 1.0 / 1_048_576.0
    return (Double(info.phys_footprint) * mb, Double(info.ledger_phys_footprint_peak) * mb)
}

// MARK: - Voice

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The loaded F5 model, vocoder and reference. Settings are F5's defaults (rk4, cfg 2,
/// sway -1) but for the step count and the speed, which are arguments. As in F5, the speed
/// only sets the duration: the text gets 1/speed of the reference's frames per byte.
final class Voice {
    static let maxFrames = 4096  // F5TTS.sample's maxDuration

    let f5: F5TTS
    let vocos: Vocos
    let refCond: MLXArray
    let refSamples: Int
    let refText: String
    let steps: Int
    let speed: Double

    init(assets: URL, steps: Int, speed: Double) throws {
        let files = [
            "f5/model.safetensors", "f5/vocab.txt", "vocos/model.safetensors", "vocos/config.json",
            "reference/reference.wav", "reference/reference.txt",
        ]
        for file in files where !FileManager.default.fileExists(atPath: assets.appendingPathComponent(file).path) {
            throw HelperError("missing voice asset \(file)")
        }
        f5 = try F5TTS.fromPretrained(modelDirectoryURL: assets.appendingPathComponent("f5"))
        vocos = try Vocos.fromPretrained(modelDirectoryURL: assets.appendingPathComponent("vocos"))
        // MLX modules start in training mode and f5-tts-swift never leaves it, so its
        // Dropout(p: 0.1) layers would fire on every call. Inference runs with them off.
        f5.train(false)
        vocos.train(false)
        // MLX loads lazily; evaluate so a loaded model means resident weights.
        MLX.eval(f5.parameters())
        MLX.eval(vocos.parameters())
        refText = try String(contentsOf: assets.appendingPathComponent("reference/reference.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refText.isEmpty else { throw HelperError("reference.txt is empty") }
        let refAudio = try F5TTS.loadAudioArray(url: assets.appendingPathComponent("reference/reference.wav"))
        refSamples = refAudio.shape[0]
        refCond = F5TTS.normalizeAudio(audio: refAudio).expandedDimensions(axis: 0)
        MLX.eval(refCond)
        self.steps = steps
        self.speed = speed
    }

    /// Duration in frames by F5's own rule (no duration model): reference frames plus
    /// reference frames per UTF-8 byte times the generated text's bytes, over speed.
    func frames(for text: String) -> Int {
        let refFrames = refSamples / F5TTS.hopLength
        return refFrames
            + Int(Double(refFrames) / Double(refText.utf8.count) * Double(text.utf8.count) / speed)
    }

    /// Text in, 24 kHz mono samples out (the reference part cut off).
    func synthesize(_ text: String) throws -> [Float] {
        let duration = frames(for: text)
        guard duration <= Voice.maxFrames else {
            throw HelperError("text too long: \(text.utf8.count) bytes needs \(duration) frames, F5 stops at \(Voice.maxFrames)")
        }
        let (out, _) = try f5.sample(
            cond: refCond,
            text: [refText + " " + text],
            duration: duration,
            steps: steps,
            method: .rk4,
            cfgStrength: 2.0,
            swayCoef: -1.0,
            vocoder: vocos.decode
        )
        let wave = out.reshaped([-1])
        guard wave.shape[0] > refSamples else { return [] }
        return wave[refSamples...].asArray(Float.self)
    }
}

// MARK: - Output files

func writeRawFloat32(_ samples: [Float], to url: URL) throws {
    // Apple silicon is little-endian, so the in-memory floats are the file format.
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: url, options: .atomic)
}

/// 32-bit float WAV (format 3), for rendered lines: nothing is clipped or rounded.
func writeFloatWAV(_ samples: [Float], rate: Int, to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let dataBytes = samples.count * 4
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
    append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(32))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
    samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }   // little-endian floats
    try data.write(to: url, options: .atomic)
}

/// 16-bit PCM WAV, for the self-test's file a person listens to.
func writeWAV(_ samples: [Float], rate: Int, to url: URL) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let dataBytes = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
    for s in samples { append(Int16((max(-1, min(1, s)) * 32767).rounded())) }
    try data.write(to: url, options: .atomic)
}

// MARK: - Protocol

struct Request: Decodable {
    let id: String?
    let text: String?
    let cmd: String?
}

struct Reply: Encodable {
    var id: String?
    var cmd: String?
    var ok: Bool
    var path: String?
    var samples: Int?
    var rate: Int?
    var genMs: Int?
    var footprintMb: Int?
    var loaded: Bool?
    var error: String?
}

let options = parseOptions(CommandLine.arguments)
let assets = options.assets!
let outDir = options.outDir!

// The protocol owns the real stdout. The vendored F5 code prints progress with print(), so
// fd 1 becomes stderr and replies go to a private copy of the original stdout.
signal(SIGPIPE, SIG_IGN)
let replyFD = dup(STDOUT_FILENO)
dup2(STDERR_FILENO, STDOUT_FILENO)
setvbuf(stdout, nil, _IOLBF, 0)

func writeLine(_ text: String) {
    var bytes = Array((text + "\n").utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeMutableBytes { write(replyFD, $0.baseAddress! + offset, $0.count - offset) }
        if n < 0 && errno == EINTR { continue }
        // The app has gone (EPIPE) or the pipe is broken: nobody is left to answer.
        guard n > 0 else { exit(0) }
        offset += n
    }
}

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.keyEncodingStrategy = .convertToSnakeCase
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}()

func send(_ reply: Reply) {
    let data = (try? encoder.encode(reply)) ?? Data(#"{"ok":false,"error":"reply encoding failed"}"#.utf8)
    writeLine(String(decoding: data, as: UTF8.self))
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("jarvis-voice: \(message)\n".utf8))
}

// The buffer cache is capped before anything loads (D-54: about 1 GB between calls and 2 GB
// at peak with 512 MB, against 4.7 to 5.2 GB uncapped).
MLX.GPU.set(cacheLimit: options.cacheLimitMB * 1_048_576)

var voice: Voice?

func loadedVoice() throws -> Voice {
    if let voice { return voice }
    let start = ContinuousClock.now
    let loaded = try Voice(assets: assets, steps: options.steps, speed: options.speed)
    voice = loaded
    log("model loaded in \(String(format: "%.2f", seconds(ContinuousClock.now - start))) s")
    return loaded
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func handle(line: Data) {
    guard let request = try? JSONDecoder().decode(Request.self, from: line) else {
        send(Reply(ok: false, error: "request is not a JSON object"))
        return
    }
    if let cmd = request.cmd {
        guard cmd == "ping" else {
            send(Reply(id: request.id, cmd: cmd, ok: false, error: "unknown cmd \(cmd)"))
            return
        }
        send(Reply(id: request.id, cmd: "ping", ok: true, footprintMb: Int(footprintMB().now.rounded()), loaded: voice != nil))
        return
    }
    guard let id = request.id, let uuid = UUID(uuidString: id) else {
        send(Reply(id: request.id, ok: false, error: "id must be a UUID"))
        return
    }
    guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        send(Reply(id: id, ok: false, error: "text is empty"))
        return
    }
    do {
        let voice = try loadedVoice()
        let start = ContinuousClock.now
        let samples = try voice.synthesize(text)
        let genMs = Int((seconds(ContinuousClock.now - start) * 1000).rounded())
        let file = outDir.appendingPathComponent("\(uuid.uuidString).f32")
        try writeRawFloat32(samples, to: file)
        send(Reply(
            id: id, ok: true, path: file.path, samples: samples.count, rate: F5TTS.sampleRate,
            genMs: genMs, footprintMb: Int(footprintMB().now.rounded())))
    } catch {
        send(Reply(id: id, ok: false, error: "\(error)"))
    }
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    usage("cannot create --out-dir: \(error)")
}

// MARK: - Self-test

if options.selftest {
    let text = "Good evening, sir."
    do {
        let l0 = ContinuousClock.now
        let voice = try loadedVoice()
        let load = seconds(ContinuousClock.now - l0)
        let g0 = ContinuousClock.now
        let samples = try voice.synthesize(text)
        let gen = seconds(ContinuousClock.now - g0)
        let file = outDir.appendingPathComponent("jarvis-voice-selftest.wav")
        try writeWAV(samples, rate: F5TTS.sampleRate, to: file)
        let audio = Double(samples.count) / Double(F5TTS.sampleRate)
        let memory = footprintMB()
        writeLine(String(
            format: "selftest: \"%@\" -> %.2f s of audio (%d samples) in %.2f s; load %.2f s; footprint %.0f MB, peak %.0f MB; %@",
            text, audio, samples.count, gen, load, memory.now, memory.peak, file.path))
        exit(samples.isEmpty ? 1 : 0)
    } catch {
        writeLine("selftest failed: \(error)")
        exit(1)
    }
}

// MARK: - Render

if let list = options.render {
    let lines: [Substring]
    do {
        lines = try String(contentsOf: list, encoding: .utf8).split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    } catch {
        writeLine("render failed: cannot read \(list.path): \(error)")
        exit(1)
    }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    do {
        let l0 = ContinuousClock.now
        let voice = try loadedVoice()
        writeLine(String(format: "render: model loaded in %.2f s", seconds(ContinuousClock.now - l0)))
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, !fields[0].isEmpty, fields[0].allSatisfy({ allowed.contains($0) }) else {
                throw HelperError("a render line is not \"<name>\\t<text>\" with a name of a-z, 0-9 and -: \(line)")
            }
            let name = String(fields[0]), text = String(fields[1])
            let g0 = ContinuousClock.now
            let samples = try voice.synthesize(text)
            guard !samples.isEmpty else { throw HelperError("no audio for \(name)") }
            try writeFloatWAV(samples, rate: F5TTS.sampleRate, to: outDir.appendingPathComponent("\(name).wav"))
            writeLine(String(format: "render: %@ \"%@\" -> %.2f s of audio in %.2f s", name, text,
                             Double(samples.count) / Double(F5TTS.sampleRate), seconds(ContinuousClock.now - g0)))
        }
        exit(0)
    } catch {
        writeLine("render failed: \(error)")
        exit(1)
    }
}

// MARK: - Request loop

/// Reads stdin in raw chunks, so the idle poll sees exactly what is still unread.
var pending = Data()
var lastRequest = ContinuousClock.now  // counts sleep: a Mac that slept past the idle limit exits on wake
let idleLimit = Duration.milliseconds(Int64(options.idleExitSeconds * 1000))
let maxLineBytes = 1 << 20
var chunk = [UInt8](repeating: 0, count: 65_536)

while true {
    while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
        handle(line: Data(line))
        lastRequest = ContinuousClock.now
    }
    if pending.count > maxLineBytes {
        pending.removeAll()
        send(Reply(ok: false, error: "request line longer than \(maxLineBytes) bytes"))
    }
    let idle = ContinuousClock.now - lastRequest
    if idle >= idleLimit {
        log("idle for \(Int(options.idleExitSeconds)) s, exiting")
        exit(0)
    }
    let waitMs = max(1, min(Int(Int32.max), Int(seconds(idleLimit - idle) * 1000)))
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, Int32(waitMs))
    if ready == 0 { continue }
    if ready < 0 {
        if errno == EINTR { continue }
        exit(1)
    }
    let n = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress!, $0.count) }
    if n < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        exit(1)
    }
    if n == 0 {
        // EOF: answer a last line that had no newline, then go.
        if !pending.isEmpty { handle(line: pending) }
        exit(0)
    }
    pending.append(contentsOf: chunk[0..<n])
}
