import AVFAudio
import CoreAudio
import Foundation
import JarvisCore

/// What the hub's engine runs (plan M08-M13 §3.3).
public enum HubMode: Sendable, Equatable {
    /// Speech and chimes only, on an engine whose input node was never touched: nothing holds the
    /// microphone and macOS shows no microphone indicator.
    case output
    /// The microphone as well, on the same engine. With voice processing the input has his own
    /// voice cancelled out of it (echo cancelling), other apps' audio is ducked as little as it
    /// can be (`.min`) and the input's AGC is off; without it (`JARVIS_AEC=0`) the input is the
    /// raw microphone.
    case duplex(voiceProcessing: Bool)

    public var hasInput: Bool { self != .output }
}

/// The hub's players: his speech (24 kHz, both channels equal) and effects such as the chime.
public enum HubPlayer: Sendable, CaseIterable {
    case speech, effect
}

/// Audio for one of the hub's players: one array per channel, at the player's rate. A single
/// channel is played on both.
public struct HubAudio: Sendable {
    public let channels: [[Float]]
    public let sampleRate: Double

    public init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    public var frames: Int { channels.first?.count ?? 0 }
}

/// Hands device changes from the engine to the hub. The engine is built before the hub exists,
/// so the hub sets the handler afterwards.
final class DeviceChangeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (_ force: Bool) -> Void)?

    func set(_ handler: @escaping @Sendable (_ force: Bool) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// `force`: the default input device changed, which an engine built on the old one does not follow.
    func fire(force: Bool) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(force)
    }
}

/// The engine under `AudioHub`. The app's is `SystemHubEngine`, over AVAudioEngine; tests drive
/// the hub's mode logic with a fake, so no test opens the microphone. The hub calls it only
/// while holding its lock.
protocol HubEngine: AnyObject {
    /// Stops the engine and builds the graph for `mode`, stopped. In duplex mode `tap` gets every
    /// input buffer, on a thread of the engine's.
    func build(_ mode: HubMode, tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError)
    var isRunning: Bool { get }
    func start() throws(MicError)
    func stop()
    /// The input's format as built, in duplex mode; nil in output mode.
    var inputFormat: AVAudioFormat? { get }
    /// The input's format now, which a device change can move away from `inputFormat`.
    var currentInputFormat: AVAudioFormat? { get }
    func format(of player: HubPlayer) -> AVAudioFormat
    /// Schedules `buffer` on `player` and plays it; `played` is called once it has been heard.
    func schedule(_ buffer: AVAudioPCMBuffer, on player: HubPlayer, played: @escaping @Sendable () -> Void)
    func stop(_ player: HubPlayer)
    /// Fires when the devices change under the engine.
    var deviceChanges: DeviceChangeRelay { get }
    /// With voice processing on, bypasses its processing of the input (the raw microphone with
    /// his voice in it), for `--selftest-aec`'s comparison.
    func setVoiceProcessingBypassed(_ bypassed: Bool)
}

/// AVAudioEngine with the speech and effect players into the main mixer and, in duplex mode, a
/// tap on the input node (§3.3):
///
///     inputNode [VP] ─tap→ every MicCapture's converter → 16 kHz mono Int16 → 1280-sample frames
///     speech (24 kHz stereo f32) ┐
///     effect (48 kHz stereo f32) ┴→ mainMixerNode → outputNode [VP]
///
/// Every build makes a fresh AVAudioEngine. An engine whose input node has been touched keeps the
/// microphone, so going back to output only needs a new one; it costs a few milliseconds.
final class SystemHubEngine: HubEngine {
    static let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2,
                                            interleaved: false)!
    static let effectFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                                            interleaved: false)!
    /// The plan's tap size (§3.3): about 43 ms at 48 kHz, 21 ms at the 96 kHz voice processing runs at.
    static let tapFrames: AVAudioFrameCount = 2048
    static let offlineFrames: AVAudioFrameCount = 4096

    let deviceChanges = DeviceChangeRelay()
    private var engine = AVAudioEngine()
    private var players: [HubPlayer: AVAudioPlayerNode] = [:]
    private(set) var inputFormat: AVAudioFormat?
    private let offline: AVAudioFormat?
    private var observer: (any NSObjectProtocol)?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    init() {
        offline = nil
        wire()
        listenForDefaultInput()
    }

    /// For tests: offline manual rendering to `output`, so nothing reaches a device and
    /// `renderOffline` pulls what the players play. Output mode only.
    init(offline output: AVAudioFormat) throws {
        offline = output
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: Self.offlineFrames)
        wire()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let block = defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                   Self.listenerQueue, block)
        }
    }

    func format(of player: HubPlayer) -> AVAudioFormat {
        switch player {
        case .speech: Self.speechFormat
        case .effect: Self.effectFormat
        }
    }

    var isRunning: Bool { engine.isRunning }

    var currentInputFormat: AVAudioFormat? {
        inputFormat == nil ? nil : engine.inputNode.outputFormat(forBus: 0)
    }

    func build(_ mode: HubMode, tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError) {
        stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine = AVAudioEngine()
        inputFormat = nil
        if let offline {
            do {
                try engine.enableManualRenderingMode(.offline, format: offline, maximumFrameCount: Self.offlineFrames)
            } catch {
                throw .cannotStart("offline rendering (\(error))")
            }
        }
        wire()
        guard case .duplex(let voiceProcessing) = mode else { return }
        guard offline == nil else { throw .noInputDevice("offline rendering has no input") }
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                throw .cannotStart("voice processing would not turn on (\(error))")
            }
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            input.isVoiceProcessingAGCEnabled = false
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw .noInputDevice("\(format)") }
        input.installTap(onBus: 0, bufferSize: Self.tapFrames, format: format) { buffer, when in
            tap(buffer, when.hostTime)
        }
        inputFormat = format
    }

    func start() throws(MicError) {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw .cannotStart("\(error)")
        }
    }

    func stop() {
        if inputFormat != nil { engine.inputNode.removeTap(onBus: 0) }
        if engine.isRunning { engine.stop() }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, on player: HubPlayer, played: @escaping @Sendable () -> Void) {
        guard let node = players[player] else { return played() }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
        node.play()
    }

    func stop(_ player: HubPlayer) {
        players[player]?.stop()
    }

    func setVoiceProcessingBypassed(_ bypassed: Bool) {
        guard inputFormat != nil, engine.inputNode.isVoiceProcessingEnabled else { return }
        engine.inputNode.isVoiceProcessingBypassed = bypassed
    }

    /// For tests: the next `frames` (at most `offlineFrames`) of an offline engine's output, one
    /// array per channel; nothing while nothing has started the engine.
    func renderOffline(frames: AVAudioFrameCount) throws -> [[Float]] {
        guard engine.isRunning else { return [] }
        let output = engine.manualRenderingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw SpeechEngineError(.error, "cannot allocate \(frames) frames")
        }
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else {
            throw SpeechEngineError(.error, "offline rendering returned \(status.rawValue)")
        }
        return (0..<Int(output.channelCount)).map {
            Array(UnsafeBufferPointer(start: channels[$0], count: Int(buffer.frameLength)))
        }
    }

    /// The players and the main mixer are made first, before voice processing is turned on: an
    /// engine whose main mixer is first made after `setVoiceProcessingEnabled(true)` does not
    /// start (kAUInitialize fails on the output node, -10875; seen on a MacBook Pro, M11 part 1).
    private func wire() {
        var nodes: [HubPlayer: AVAudioPlayerNode] = [:]
        for player in HubPlayer.allCases {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format(of: player))
            nodes[player] = node
        }
        players = nodes
        guard offline == nil else { return }
        let relay = deviceChanges
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { _ in relay.fire(force: false) }
    }

    private static let listenerQueue = DispatchQueue.global(qos: .utility)

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// An engine stays on the input device it was built on; a new default input means a rebuild.
    private func listenForDefaultInput() {
        var address = Self.defaultInputAddress
        let relay = deviceChanges
        let block: AudioObjectPropertyListenerBlock = { _, _ in relay.fire(force: true) }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                         Self.listenerQueue, block)
        if status == noErr { defaultInputListener = block }
    }
}

/// The one audio engine for his speech, the chimes and the microphone (plan M08-M13 §3.3, M11
/// part 1), so voice processing hears what he says and cancels it from the microphone.
///
/// - Output only until something opens the microphone (`HubMicInput`, which every MicCapture
///   uses): then the engine is rebuilt with its input tapped and voice processing on (unless
///   `JARVIS_AEC=0`), and when the last one closes it is rebuilt output only, so the microphone
///   is open only while something listens.
/// - One engine in the process: once a voice-processing engine starts, another engine's input
///   tap gets no more buffers, even after the first stops (seen on a MacBook Pro, M11 part 1).
///   Push-to-talk, the setup window's takes and hands-free listening all share this one.
/// - Rebuilding stops what is playing: a part being spoken when the microphone opens or closes,
///   or a device changes, ends there (logged), and the next part plays on the new engine.
/// - A device change (`AVAudioEngineConfigurationChange`, or a new default input) rebuilds the
///   engine in the same mode and restarts it, unless it is still running as built.
///
/// The engine and the players are touched only under `lock`. The tap reads the listeners under a
/// lock of its own, which a rebuild never holds while it waits on the engine.
public final class AudioHub: @unchecked Sendable {
    /// `JARVIS_AEC` (plan §3.3, a proposed variable): "0" turns voice processing off, so the
    /// microphone is the raw input Python listened to.
    public static func voiceProcessing(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["JARVIS_AEC"] != "0"
    }

    /// The app's hub. Everything in the process that plays or listens goes through it.
    public static let shared = AudioHub(log: { JarvisLog.log($0, category: .voice) })

    /// How long after a device change the hub looks at the engine again, so a burst of
    /// notifications is one rebuild.
    static let settle = DispatchTimeInterval.milliseconds(250)
    /// How often a rebuild that failed after a device change is tried again, and how many times.
    static let retry = DispatchTimeInterval.seconds(2)
    static let retries = 5

    private let engine: any HubEngine
    private let voiceProcessing: Bool
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "jarvis.audio-hub")
    private let lock = NSLock()
    private var mode = HubMode.output
    private var inputs: Set<UUID> = []
    private var waits: [HubPlayer: [PlaybackWait]] = [:]
    private var reconcilePending = false
    private let tapLock = NSLock()
    private var taps: [UUID: @Sendable (AVAudioPCMBuffer, UInt64) -> Void] = [:]

    init(engine: any HubEngine, voiceProcessing: Bool, log: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.voiceProcessing = voiceProcessing
        self.log = log
        engine.deviceChanges.set { [weak self] force in self?.devicesChanged(force: force) }
    }

    public convenience init(voiceProcessing: Bool = AudioHub.voiceProcessing(),
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(engine: SystemHubEngine(), voiceProcessing: voiceProcessing, log: log)
    }

    /// For tests: the real graph rendering offline to `output`; output only.
    convenience init(offline output: AVAudioFormat) throws {
        self.init(engine: try SystemHubEngine(offline: output), voiceProcessing: false, log: { _ in })
    }

    /// What the engine runs now.
    public var currentMode: HubMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    // MARK: output

    /// Plays `audio` on `player` and returns once it has been heard, or at once when `stop(player)`
    /// is called, the task is cancelled, the engine is rebuilt, or `limit` passes (a device change
    /// can drop scheduled buffers without calling back).
    public func play(_ audio: HubAudio, on player: HubPlayer, limit: Duration) async throws {
        guard audio.frames > 0, !Task.isCancelled else { return }
        let wait = PlaybackWait()
        let watchdog = Task {
            try? await Task.sleep(for: limit)
            wait.resume()
        }
        defer { watchdog.cancel() }
        let failure = FailureBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wait.set(continuation)
                do {
                    try schedule(audio, on: player, wait: wait)
                } catch {
                    failure.error = error
                    wait.resume()
                }
            }
        } onCancel: {
            wait.resume()
        }
        finished(wait, on: player)
        if let error = failure.error { throw error }
        // A cancelled part is silenced before the caller moves on.
        if Task.isCancelled { stop(player) }
    }

    /// Stops `player` and ends every `play` waiting on it.
    public func stop(_ player: HubPlayer) {
        lock.lock()
        defer { lock.unlock() }
        for wait in waits[player] ?? [] { wait.resume() }
        waits[player] = nil
        engine.stop(player)
    }

    private func schedule(_ audio: HubAudio, on player: HubPlayer, wait: PlaybackWait) throws {
        lock.lock()
        defer { lock.unlock() }
        let format = engine.format(of: player)
        guard audio.sampleRate == format.sampleRate, !audio.channels.isEmpty else {
            throw SpeechEngineError(.error, "the \(player) player takes \(Int(format.sampleRate)) Hz audio, "
                                    + "not \(audio.sampleRate) Hz")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.frames)),
              let channels = buffer.floatChannelData else {
            throw SpeechEngineError(.error, "cannot allocate \(audio.frames) frames")
        }
        buffer.frameLength = AVAudioFrameCount(audio.frames)
        for c in 0..<Int(format.channelCount) {
            let source = audio.channels[min(c, audio.channels.count - 1)]
            source.withUnsafeBufferPointer { channels[c].update(from: $0.baseAddress!, count: min($0.count, audio.frames)) }
        }
        do throws(MicError) {
            try engine.start()
        } catch {
            throw SpeechEngineError(.error, "the audio engine would not start (\(error))")
        }
        waits[player, default: []].append(wait)
        engine.schedule(buffer, on: player) { wait.resume() }
    }

    private func finished(_ wait: PlaybackWait, on player: HubPlayer) {
        lock.lock()
        defer { lock.unlock() }
        waits[player]?.removeAll { $0 === wait }
    }

    // MARK: input

    /// Opens the microphone for `id` and returns the input's format. The first opener rebuilds
    /// the engine with its input and starts it.
    func openInput(_ id: UUID) throws(MicError) -> AVAudioFormat {
        lock.lock()
        defer { lock.unlock() }
        inputs.insert(id)
        if !mode.hasInput {
            do throws(MicError) {
                try rebuild(.duplex(voiceProcessing: voiceProcessing), because: "the microphone opened")
            } catch {
                inputs.remove(id)
                log("audio: the microphone would not open (\(error))")
                try? rebuild(.output, because: "the microphone would not open")
                throw error
            }
        }
        guard let format = engine.inputFormat else { throw .noInputDevice("no input format") }
        return format
    }

    /// `id`'s tap: every input buffer from now until `closeInput(id)`.
    func setTap(_ id: UUID, _ tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) {
        tapLock.lock()
        taps[id] = tap
        tapLock.unlock()
    }

    /// Closes `id`'s microphone. The last one to close rebuilds the engine output only.
    func closeInput(_ id: UUID) {
        tapLock.lock()
        taps[id] = nil
        tapLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        guard inputs.remove(id) != nil, inputs.isEmpty, mode.hasInput else { return }
        do throws(MicError) {
            try rebuild(.output, because: "the microphone closed")
        } catch {
            log("audio: cannot rebuild the engine output only (\(error))")
        }
    }

    /// `--selftest-aec`: with the microphone open and voice processing on, bypass its input
    /// processing (true) or not.
    public func setVoiceProcessingBypassed(_ bypassed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        engine.setVoiceProcessingBypassed(bypassed)
    }

    /// Whether anything has the microphone open.
    public var isInputOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !inputs.isEmpty
    }

    /// Rebuilds the engine in its mode now: the dead-stream counter's remedy (J:1121), which a
    /// device that stops sending sound without saying so needs.
    public func rebind(reason: String) {
        queue.async { [weak self] in self?.reconcile(force: true, reason: reason, attempt: 0) }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) {
        tapLock.lock()
        let targets = Array(taps.values)
        tapLock.unlock()
        for tap in targets { tap(buffer, hostTime) }
    }

    // MARK: rebuilding

    /// Rebuilds the engine for `new`, under the lock. What is playing ends here.
    private func rebuild(_ new: HubMode, because reason: String) throws(MicError) {
        let began = ContinuousClock.now
        var cut = 0
        for (player, list) in waits {
            for wait in list { wait.resume() }
            if player == .speech { cut += list.count }
        }
        waits.removeAll()
        // The mode is what the engine should run, built or not: a failed rebuild after a device
        // change is tried again in it.
        mode = new
        try engine.build(new, tap: { [weak self] buffer, hostTime in self?.deliver(buffer, hostTime) })
        if new.hasInput { try engine.start() }
        let took = ContinuousClock.now - began
        let ms = Int(Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000)
        switch new {
        case .output:
            log("audio: output only (\(reason)), \(ms) ms")
        case .duplex(let voiceProcessing):
            let format = engine.inputFormat.map { "\($0.channelCount) ch \(Int($0.sampleRate)) Hz" } ?? "no input"
            log("audio: microphone open, voice processing \(voiceProcessing ? "on" : "off (JARVIS_AEC=0)"), "
                + "\(format) (\(reason)), \(ms) ms")
        }
        if cut > 0 { log("audio: rebuilding the engine cut \(cut) part\(cut == 1 ? "" : "s") of speech short") }
    }

    private func devicesChanged(force: Bool) {
        queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            self?.reconcile(force: force, reason: force ? "the default input changed" : "the audio devices changed",
                            attempt: 0)
        }
    }

    /// After a device change: rebuilds the engine in its mode, unless it is still running as built
    /// (so the notifications a rebuild itself sets off do not rebuild it again). Output only, it
    /// rebuilds when the change stopped the engine, and leaves it stopped: the next part starts it.
    func reconcile(force: Bool, reason: String, attempt: Int) {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .output:
            guard !force, !engine.isRunning else { return }
            try? rebuild(.output, because: reason)
        case .duplex:
            if !force, engine.isRunning, let built = engine.inputFormat, let now = engine.currentInputFormat,
               built.sampleRate == now.sampleRate, built.channelCount == now.channelCount {
                return
            }
            do throws(MicError) {
                try rebuild(mode, because: reason)
            } catch {
                log("audio: cannot reopen the microphone after \(reason) (\(error))")
                guard attempt < Self.retries else { return }
                queue.asyncAfter(deadline: .now() + Self.retry) { [weak self] in
                    self?.reconcile(force: true, reason: reason, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: tests

    /// For tests: the next `frames` of an offline hub's output, one array per channel.
    func renderOffline(frames: AVAudioFrameCount) throws -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        guard let system = engine as? SystemHubEngine else { return [] }
        return try system.renderOffline(frames: frames)
    }
}

/// The error a `play` ran into, carried out of its continuation.
private final class FailureBox: @unchecked Sendable {
    var error: (any Error)?
}

/// The microphone through `AudioHub.shared` (or a hub of the caller's): what every MicCapture in
/// the app opens. `inputFormat()` opens it, `start(tap:)` starts delivering, `stop()` closes it.
public final class HubMicInput: MicInput, @unchecked Sendable {
    private let hub: AudioHub
    private let id = UUID()

    public init(hub: AudioHub = .shared) {
        self.hub = hub
    }

    public func inputFormat() throws(MicError) -> AVAudioFormat {
        try hub.openInput(id)
    }

    public func start(tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError) {
        hub.setTap(id, tap)
    }

    public func stop() {
        hub.closeInput(id)
    }
}
