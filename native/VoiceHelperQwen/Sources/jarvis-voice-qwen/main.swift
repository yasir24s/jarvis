import Darwin
import Foundation
import MLX
import MLXLMCommon
import MLXAudioCore
import MLXAudioTTS

// jarvis-voice-qwen: the Qwen3-TTS helper JARVIS speaks through (V6), with F5's jarvis-voice as
// the fallback. The user's choice by ear, 2026-10-03: Qwen3-TTS 12 Hz 0.6B Base, 4-bit, cloned
// from the long dry reference, at 1.5x with the pitch kept, streamed.
//
//   jarvis-voice-qwen --model <dir> --reference <dir> --out-dir <dir> [--rate 1.5]
//                     [--interval 0.32] [--cache-limit-mb 512] [--idle-exit 600]
//                     [--resident on|off] [--selftest] [--render <list>]
//
// Protocol: one JSON object per line on stdin, one per line on stdout. jarvis-voice's, with the
// audio streamed:
//   {"id": "<uuid>", "text": "<clean text>"}
//     -> {"id", "ok": true, "chunk": n, "path", "samples", "rate": 24000}, for n = 1, 2, ...: one
//        per piece of audio as it is generated, in order. path is a raw float32 little-endian
//        mono file in --out-dir (the caller deletes it).
//     -> then {"id", "ok": true, "done": true, "chunks", "samples", "rate", "first_ms", "gen_ms",
//        "footprint_mb"}, the last line for the request: samples is the total over the chunks,
//        first_ms the time to the first chunk.
//     -> or {"id", "ok": false, "error"} as its last line, with or without chunks before it;
//        "cancelled": true when a cancel stopped it.
//   {"cmd": "cancel", "id": "<uuid>"}: stops that request's generation at the next token (about
//     80 ms). Read between tokens while a request runs; at any other time it is answered
//     {"cmd": "cancel", "ok": true} and does nothing.
//   {"cmd": "ping"} -> {"cmd": "ping", "ok": true, "loaded", "footprint_mb"}
//   {"cmd": "load"} -> {"cmd": "load", "ok": true, "loaded": true, "footprint_mb"}, or ok false
// Requests that arrive while one runs wait their turn.
//
// --rate speeds the voice up with its pitch kept (Stretcher: AVAudioUnitTimePitch over the
// stream), so every chunk, rendered line and self-test comes out at that rate. --interval is how
// much audio (in seconds before the rate) the model generates between chunks; 0.32 s gave the
// first audio after 0.25 to 0.38 s warm in the scratch test.
//
// The model loads on the first request or load and stays loaded; the reference is encoded once,
// at load, and one short line is generated and thrown away, so the first reply does not pay for
// MLX compiling its kernels. After each reply MLX's buffer cache is cleared, and stderr logs the
// footprint. The helper exits on stdin EOF, or after --idle-exit seconds with no request.
//
// --render <list>: each line of <list> is "<name>\t<text>"; the text is generated (streamed, as
// the app hears it, at --rate) and written to <out-dir>/<name>.wav (32-bit float, 24 kHz mono),
// then the helper exits, 0 when every line was rendered. Each line's report gives the time to
// its first audio and the whole time. install-voice-assets.sh renders the acknowledgements so.
//
// --resident on (the default) keeps the model's weights wired in memory once loaded, so an idle
// spell cannot swap them out (Resident.swift); {"cmd": "resident", "on": true|false} switches it
// while the helper runs, and {"cmd": "ping"} reports it with the resident and swapped MB.
//
// <model> is the Qwen3-TTS folder (config.json, model.safetensors, tokenizer files and
// speech_tokenizer/); <reference> holds reference.wav and reference.txt.

// MARK: - Arguments

struct Options {
    var model: URL?
    var reference: URL?
    var outDir: URL?
    var rate = 1.5
    var interval = 0.32
    var cacheLimitMB = 512
    var idleExitSeconds = 600.0
    var resident = true
    var selftest = false
    var render: URL?
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data((
        "jarvis-voice-qwen: \(message)\n"
            + "usage: jarvis-voice-qwen --model <dir> --reference <dir> --out-dir <dir> [--rate X]"
            + " [--interval S] [--cache-limit-mb N] [--idle-exit S] [--resident on|off] [--selftest]"
            + " [--render <list>]\n").utf8))
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
        case "--model": options.model = URL(fileURLWithPath: next(flag), isDirectory: true)
        case "--reference": options.reference = URL(fileURLWithPath: next(flag), isDirectory: true)
        case "--out-dir": options.outDir = URL(fileURLWithPath: next(flag), isDirectory: true)
        case "--rate":
            guard let r = Double(next(flag)), r >= 0.5, r <= 2 else { usage("\(flag) takes a number from 0.5 to 2") }
            options.rate = r
        case "--interval":
            guard let s = Double(next(flag)), s >= 0.08, s <= 4 else { usage("\(flag) takes seconds from 0.08 to 4") }
            options.interval = s
        case "--cache-limit-mb":
            guard let n = Int(next(flag)), n >= 0 else { usage("\(flag) takes a whole number") }
            options.cacheLimitMB = n
        case "--idle-exit":
            guard let s = Double(next(flag)), s > 0 else { usage("\(flag) takes seconds") }
            options.idleExitSeconds = s
        case "--resident":
            switch next(flag) {
            case "on": options.resident = true
            case "off": options.resident = false
            default: usage("\(flag) takes on or off")
            }
        case "--selftest": options.selftest = true
        case "--render": options.render = URL(fileURLWithPath: next(flag), isDirectory: false)
        default: usage("unknown argument \(flag)")
        }
        i += 1
    }
    if options.model == nil { usage("--model is required") }
    if options.reference == nil { usage("--reference is required") }
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

/// V10: the resident size and the compressed or swapped size, in MB; the Metal (graphics) memory
/// MLX holds the model in, and how much of it the kernel reports compressed or swapped, in MB; and
/// the pages swapped back in so far (task_info TASK_VM_INFO). The graphics memory is not in the
/// resident size at all, and is reported "swapped" even straight after a load, so the swap-ins are
/// the figure that shows real paging.
func residencyMB() -> (resident: Int, swapped: Int, graphics: Int, graphicsSwapped: Int, swapins: Int) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (-1, -1, -1, -1, -1) }
    return (Int(info.resident_size / 1_048_576), Int(info.compressed / 1_048_576),
            Int(info.ledger_tag_graphics_footprint / 1_048_576),
            Int(info.ledger_tag_graphics_footprint_compressed / 1_048_576), Int(info.ledger_swapins))
}

// MARK: - Voice

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Raised inside a generation that a cancel line stopped.
struct Cancelled: Error {}

/// The loaded model and the reference, encoded once.
final class Voice {
    static let language = "English"

    let model: Qwen3TTSModel
    let conditioning: Qwen3TTSModel.Qwen3TTSReferenceConditioning
    let sampleRate: Int
    let parameters: GenerateParameters

    init(model folder: URL, reference: URL) async throws {
        for file in ["config.json", "speech_tokenizer"]
        where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
            throw HelperError("missing \(file) in the model folder")
        }
        for file in ["reference.wav", "reference.txt"]
        where !FileManager.default.fileExists(atPath: reference.appendingPathComponent(file).path) {
            throw HelperError("missing \(file) in the --reference folder")
        }
        let refText = try String(contentsOf: reference.appendingPathComponent("reference.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refText.isEmpty else { throw HelperError("reference.txt is empty") }
        model = try await Qwen3TTSModel.fromModelDirectory(folder)
        sampleRate = model.sampleRate
        let (_, refAudio) = try loadAudioArray(from: reference.appendingPathComponent("reference.wav"),
                                               sampleRate: sampleRate)
        conditioning = try model.prepareReferenceConditioning(refAudio: refAudio, refText: refText,
                                                              language: Self.language)
        parameters = model.defaultGenerationParameters
    }

    /// Generates `text`, handing each piece of audio to `chunk` as it comes, at the model's rate
    /// (before any stretching). `stop` is asked between tokens; true ends the generation with
    /// `Cancelled`.
    func stream(_ text: String, interval: Double, stop: @escaping () -> Bool,
                chunk: @escaping ([Float]) -> Void) async throws {
        let p = parameters
        let model = self.model
        let conditioning = self.conditioning
        let task = Task {
            _ = try model.generateVoiceDesign(
                text: text, instruct: nil, language: conditioning.resolvedLanguage,
                conditioning: conditioning, refAudio: nil, refText: nil,
                temperature: p.temperature, topK: p.topK, topP: p.topP,
                repetitionPenalty: p.repetitionPenalty ?? 1.05, minP: p.minP,
                maxTokens: p.maxTokens ?? 4096, streamingInterval: interval,
                onToken: { _ in
                    // The generation checks for cancellation before each token.
                    if stop() { withUnsafeCurrentTask { $0?.cancel() } }
                },
                onAudioChunk: { audio in
                    chunk(audio.asArray(Float.self))
                    if stop() { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        do {
            try await task.value
        } catch is CancellationError {
            throw Cancelled()
        }
    }
}

/// One stream's way out: the model's chunks through the stretcher at `rate`, handed on in order.
final class Output {
    private let stretcher: Stretcher?
    private let send: ([Float]) throws -> Void
    private(set) var samples = 0

    init(rate: Double, sampleRate: Int, send: @escaping ([Float]) throws -> Void) throws {
        stretcher = abs(rate - 1) < 1e-9 ? nil : try Stretcher(rate: rate, sampleRate: Double(sampleRate))
        self.send = send
    }

    func push(_ audio: [Float]) throws {
        let out = try stretcher?.push(audio) ?? audio
        try emit(out)
    }

    func finish() throws {
        if let stretcher {
            try emit(try stretcher.finish())
            if stretcher.starved > 0 { log("stretcher ran short of input \(stretcher.starved) time(s)") }
        }
    }

    private func emit(_ out: [Float]) throws {
        guard !out.isEmpty else { return }
        samples += out.count
        try send(out)
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

// MARK: - Protocol

struct Request: Decodable {
    let id: String?
    let text: String?
    let cmd: String?
    /// V10: {"cmd": "resident", "on": true|false}.
    let on: Bool?
}

struct Reply: Encodable {
    var id: String?
    var cmd: String?
    var ok: Bool
    var chunk: Int?
    var done: Bool?
    var chunks: Int?
    var path: String?
    var samples: Int?
    var rate: Int?
    var firstMs: Int?
    var genMs: Int?
    var footprintMb: Int?
    /// V10: resident is on; the helper's resident and swapped (or compressed) MB.
    var resident: Bool?
    var rssMb: Int?
    var swappedMb: Int?
    var graphicsMb: Int?
    var graphicsSwappedMb: Int?
    var swapins: Int?
    var loaded: Bool?
    var cancelled: Bool?
    var error: String?
}

let options = parseOptions(CommandLine.arguments)
let modelFolder = options.model!
let referenceFolder = options.reference!
let outDir = options.outDir!

// The protocol owns the real stdout. The vendored code prints progress with print(), so fd 1
// becomes stderr and replies go to a private copy of the original stdout.
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
    FileHandle.standardError.write(Data("jarvis-voice-qwen: \(message)\n".utf8))
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func milliseconds(_ d: Duration) -> Int { Int((seconds(d) * 1000).rounded()) }

// The buffer cache is capped before anything loads.
Memory.cacheLimit = options.cacheLimitMB * 1_048_576

// Top-level state is used from the generation task too; the helper never runs two things at once.
nonisolated(unsafe) var voice: Voice?
/// V10: what the app asked for; applied once the model is loaded.
nonisolated(unsafe) var wantResident = options.resident

func applyResident() async {
    guard voice != nil, wantResident != Residency.isOn else { return }
    if let line = Residency.set(wantResident, model: voice?.model) { log(line) }
}

func loadedVoice() async throws -> Voice {
    if let voice { return voice }
    let start = ContinuousClock.now
    let loaded = try await Voice(model: modelFolder, reference: referenceFolder)
    // The first generation after a load compiles MLX's kernels: 2.4 s to the first audio of the
    // self-test cold, against 0.2 to 0.4 s warm. One short line, thrown away, does that now, so the
    // first reply streams as fast as the rest.
    let w0 = ContinuousClock.now
    try await loaded.stream("Very good.", interval: options.interval, stop: { false }, chunk: { _ in })
    Memory.clearCache()
    voice = loaded
    log(String(format: "model loaded in %.2f s and warmed up in %.2f s, footprint %d MB",
               seconds(w0 - start), seconds(ContinuousClock.now - w0), Int(footprintMB().now)))
    await applyResident()
    return loaded
}

/// Hands MLX's cached buffers back, logs the footprint before and after, and returns the
/// footprint after, in MB.
@discardableResult
func clearCache() -> Double {
    let before = footprintMB()
    Memory.clearCache()
    let after = footprintMB()
    let held = residencyMB()
    log(String(format: "reply done: footprint %.0f MB, %.0f MB after clearing the cache (peak %.0f MB)",
               before.now, after.now, after.peak)
        + "; graphics \(held.graphics) MB, \(held.graphicsSwapped) MB of it reported swapped; swap-ins \(held.swapins)"
        + (Residency.isOn ? "; resident \(Residency.residentBytes / 1_048_576) MB (\(Residency.mechanism?.rawValue ?? ""))" : "; not resident"))
    return after.now
}

// MARK: - Input

/// Reads stdin in raw chunks, so the idle poll sees exactly what is still unread.
var pending = Data()
let maxLineBytes = 1 << 20
var readBuffer = [UInt8](repeating: 0, count: 65_536)
var inputEnded = false

/// Reads what stdin has without waiting more than `waitMs`; false at EOF or on an error.
@discardableResult
func readInput(waitMs: Int32) -> Bool {
    guard !inputEnded else { return false }
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, waitMs)
    if ready <= 0 { return ready == 0 || errno == EINTR }
    let n = readBuffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress!, $0.count) }
    if n < 0 { return errno == EINTR || errno == EAGAIN }
    if n == 0 {
        inputEnded = true
        return false
    }
    pending.append(contentsOf: readBuffer[0..<n])
    return true
}

/// The next complete request line, if any, without its newline.
func nextLine() -> Data? {
    while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
        return Data(line)
    }
    return nil
}

/// Lines read while a request ran that were not its cancel: handled after it, in order.
var deferred: [Data] = []

/// While request `id` runs: reads stdin without waiting, keeps other lines for later, and says
/// whether a cancel for `id` (or the end of stdin) has come.
func cancelArrived(for id: String) -> Bool {
    readInput(waitMs: 0)
    if inputEnded { return true }
    var cancelled = false
    while let line = nextLine() {
        if let request = try? JSONDecoder().decode(Request.self, from: line), request.cmd == "cancel" {
            if request.id == id { cancelled = true }
            continue   // a cancel for another request has nothing left to stop
        }
        deferred.append(line)
    }
    return cancelled
}

// MARK: - Requests

func handle(line: Data) async {
    guard let request = try? JSONDecoder().decode(Request.self, from: line) else {
        send(Reply(ok: false, error: "request is not a JSON object"))
        return
    }
    if let cmd = request.cmd {
        switch cmd {
        case "ping":
            let held = residencyMB()
            send(Reply(id: request.id, cmd: "ping", ok: true, footprintMb: Int(footprintMB().now.rounded()),
                       resident: Residency.isOn, rssMb: held.resident, swappedMb: held.swapped, graphicsMb: held.graphics,
                       graphicsSwappedMb: held.graphicsSwapped, swapins: held.swapins, loaded: voice != nil))
        case "resident":
            guard let on = request.on else {
                send(Reply(id: request.id, cmd: "resident", ok: false, error: "resident needs \"on\": true or false"))
                return
            }
            wantResident = on
            await applyResident()
            send(Reply(id: request.id, cmd: "resident", ok: true, resident: Residency.isOn))
        case "load":
            do {
                _ = try await loadedVoice()
                send(Reply(id: request.id, cmd: "load", ok: true, footprintMb: Int(footprintMB().now.rounded()),
                           loaded: true))
            } catch {
                send(Reply(id: request.id, cmd: "load", ok: false, error: "\(error)"))
            }
        case "cancel":
            send(Reply(id: request.id, cmd: "cancel", ok: true))
        default:
            send(Reply(id: request.id, cmd: cmd, ok: false, error: "unknown cmd \(cmd)"))
        }
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
    var cancelled = false
    do {
        let voice = try await loadedVoice()
        let start = ContinuousClock.now
        var chunks = 0
        var first: Duration?
        let output = try Output(rate: options.rate, sampleRate: voice.sampleRate) { samples in
            chunks += 1
            if first == nil { first = ContinuousClock.now - start }
            let file = outDir.appendingPathComponent("\(uuid.uuidString)-\(chunks).f32")
            try writeRawFloat32(samples, to: file)
            send(Reply(id: id, ok: true, chunk: chunks, path: file.path, samples: samples.count,
                       rate: voice.sampleRate))
        }
        var failure: Error?
        try await voice.stream(text, interval: options.interval, stop: {
            if !cancelled { cancelled = cancelArrived(for: id) }
            return cancelled || failure != nil
        }, chunk: { audio in
            guard failure == nil else { return }
            do { try output.push(audio) } catch { failure = error }
        })
        if let failure { throw failure }
        try output.finish()
        let genMs = milliseconds(ContinuousClock.now - start)
        let after = clearCache()
        send(Reply(id: id, ok: true, done: true, chunks: chunks, samples: output.samples, rate: voice.sampleRate,
                   firstMs: first.map(milliseconds), genMs: genMs, footprintMb: Int(after.rounded())))
    } catch is Cancelled where cancelled {
        clearCache()
        log("request cancelled")
        send(Reply(id: id, ok: false, cancelled: true, error: "cancelled"))
    } catch {
        clearCache()
        send(Reply(id: id, ok: false, error: "\(error)"))
    }
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    usage("cannot create --out-dir: \(error)")
}

/// One line generated whole, streamed as the app hears it: the samples at --rate, and the times
/// to the first audio and to the end.
func renderWhole(_ text: String) async throws -> (samples: [Float], first: Double, total: Double) {
    let voice = try await loadedVoice()
    let start = ContinuousClock.now
    var all: [Float] = []
    var first: Double?
    let output = try Output(rate: options.rate, sampleRate: voice.sampleRate) { samples in
        if first == nil { first = seconds(ContinuousClock.now - start) }
        all += samples
    }
    try await voice.stream(text, interval: options.interval, stop: { false }, chunk: { audio in
        try? output.push(audio)
    })
    try output.finish()
    let total = seconds(ContinuousClock.now - start)
    Memory.clearCache()
    return (all, first ?? total, total)
}

// MARK: - Self-test

if options.selftest {
    let text = "Good evening, sir."
    do {
        let l0 = ContinuousClock.now
        let voice = try await loadedVoice()
        let load = seconds(ContinuousClock.now - l0)
        let (samples, first, total) = try await renderWhole(text)
        let file = outDir.appendingPathComponent("jarvis-voice-qwen-selftest.wav")
        try writeFloatWAV(samples, rate: voice.sampleRate, to: file)
        let memory = footprintMB()
        writeLine(String(
            format: "selftest: \"%@\" -> %.2f s of audio at rate %.2f, first audio %.2f s, all %.2f s; load %.2f s; footprint %.0f MB, peak %.0f MB; %@",
            text, Double(samples.count) / Double(voice.sampleRate), options.rate, first, total, load,
            memory.now, memory.peak, file.path))
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
        let voice = try await loadedVoice()
        writeLine(String(format: "render: model loaded in %.2f s", seconds(ContinuousClock.now - l0)))
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, !fields[0].isEmpty, fields[0].allSatisfy({ allowed.contains($0) }) else {
                throw HelperError("a render line is not \"<name>\\t<text>\" with a name of a-z, 0-9 and -: \(line)")
            }
            let name = String(fields[0]), text = String(fields[1])
            let (samples, first, total) = try await renderWhole(text)
            guard !samples.isEmpty else { throw HelperError("no audio for \(name)") }
            try writeFloatWAV(samples, rate: voice.sampleRate, to: outDir.appendingPathComponent("\(name).wav"))
            let memory = footprintMB()
            writeLine(String(format: "render: %@ (%d chars) \"%@\" -> %.2f s of audio; first audio %.2f s, all %.2f s; footprint %.0f MB, peak %.0f MB",
                             name, text.count, text, Double(samples.count) / Double(voice.sampleRate), first, total,
                             memory.now, memory.peak))
        }
        exit(0)
    } catch {
        writeLine("render failed: \(error)")
        exit(1)
    }
}

// MARK: - Request loop

var lastRequest = ContinuousClock.now  // counts sleep: a Mac that slept past the idle limit exits on wake
let idleLimit = Duration.milliseconds(Int64(options.idleExitSeconds * 1000))

while true {
    while !deferred.isEmpty || pending.contains(0x0A) {
        let line = deferred.isEmpty ? nextLine() : deferred.removeFirst()
        guard let line else { break }
        await handle(line: line)
        lastRequest = ContinuousClock.now
    }
    if inputEnded {
        // EOF: answer a last line that had no newline, then go.
        if !pending.isEmpty { await handle(line: pending) }
        exit(0)
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
    if !readInput(waitMs: Int32(waitMs)), !inputEnded { exit(1) }
}
