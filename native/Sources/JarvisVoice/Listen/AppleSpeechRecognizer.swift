import AVFAudio
import CoreMedia
import Foundation
import JarvisCore
import Speech

/// Apple's on-device recogniser (plan M08-M13 §3.4): a SpeechAnalyzer with one SpeechTranscriber,
/// a new pair for each utterance. `.lingering` keeps the model loaded between them for a while.
/// Volatile results are on, for the composer's live text (the plan had them off; push-to-talk
/// shows them). Nothing here downloads a model: a missing one is reported by `readiness()`.
public struct AppleSpeechRecognizer: SpeechRecognizing {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: Transcriber.locale())) {
        self.locale = locale
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [.transcriptionConfidence, .audioTimeRange])
    }

    /// Ready when the locale's model is among `SpeechTranscriber.installedLocales`. That list, not
    /// `AssetInventory.status(forModules:)`, is the test: on this Mac (macOS 27.2) the status reads
    /// `.supported` for every transcriber set-up while en_GB is installed and transcribes.
    public func readiness() async -> TranscriberError? {
        guard SpeechTranscriber.isAvailable else { return .unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupportedLocale(locale.identifier)
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == supported.identifier(.bcp47) }) else {
            let status = await AssetInventory.status(forModules: [Self.makeTranscriber(supported)])
            return .assetMissing("\(supported.identifier): \(status)")
        }
        return nil
    }

    public func begin(contextualStrings: [String],
                      preview: @escaping @Sendable (String) -> Void) async throws -> any RecognitionSession {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        return try await AppleRecognitionSession.start(locale: supported, contextualStrings: contextualStrings,
                                                       preview: preview)
    }
}

/// One utterance through SpeechAnalyzer: frames go in through an `AsyncStream` of
/// `AnalyzerInput`, results come back on a task that keeps the finals and reports the live text.
actor AppleRecognitionSession: RecognitionSession {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let collector: Task<[RecognizedSegment], any Error>
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?

    static func start(locale: Locale, contextualStrings: [String],
                      preview: @escaping @Sendable (String) -> Void) async throws -> AppleRecognitionSession {
        let transcriber = AppleSpeechRecognizer.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .lingering))
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        try await analyzer.setContext(context)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.failed("no audio format for the transcriber")
        }
        try await analyzer.prepareToAnalyze(in: format)
        let collector = Task<[RecognizedSegment], any Error> {
            var finals: [RecognizedSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finals.append(RecognizedSegment(text: text, confidence: Self.confidence(of: result.text)))
                    preview(ConfidenceGuard.join(finals))
                } else {
                    preview(ConfidenceGuard.join(finals + [RecognizedSegment(text: text, confidence: nil)]))
                }
            }
            return finals
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish()
            collector.cancel()
            throw TranscriberError.failed("the analyzer would not start: \(error)")
        }
        return AppleRecognitionSession(analyzer: analyzer, input: input, collector: collector, format: format)
    }

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation,
                 collector: Task<[RecognizedSegment], any Error>, format: AVAudioFormat) {
        self.analyzer = analyzer
        self.input = input
        self.collector = collector
        self.format = format
        let same = format.commonFormat == .pcmFormatInt16 && format.sampleRate == MicFrame.sampleRate
            && format.channelCount == 1
        converter = same ? nil : AVAudioConverter(from: MicConverter.target, to: format)
    }

    func append(_ frame: MicFrame) {
        guard let pcm = Self.pcm(frame) else { return }
        guard let converter else {
            input.yield(AnalyzerInput(buffer: pcm))
            return
        }
        let ratio = format.sampleRate / MicFrame.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64)
        else { return }
        let feed = StreamingInput(pcm)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in feed.next(s) }
        if status != .error, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async throws -> [RecognizedSegment] {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw TranscriberError.failed("the analyzer did not finish: \(error)")
        }
        return try await collector.value
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        collector.cancel()
    }

    /// The frame as a 16 kHz mono Int16 buffer.
    static func pcm(_ frame: MicFrame) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: MicConverter.target,
                                       frameCapacity: AVAudioFrameCount(frame.samples.count)),
              let ch = b.int16ChannelData?[0] else { return nil }
        frame.samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { ch.update(from: base, count: src.count) }
        }
        b.frameLength = AVAudioFrameCount(frame.samples.count)
        return b
    }

    /// The duration-weighted mean of the runs' `transcriptionConfidence` (§3.4).
    static func confidence(of text: AttributedString) -> Double? {
        var runs: [(duration: Double, confidence: Double)] = []
        for run in text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let d = run.audioTimeRange.map { CMTimeGetSeconds($0.duration) } ?? 0
            runs.append((d.isFinite ? d : 0, c))
        }
        return ConfidenceGuard.weightedMean(runs)
    }
}
