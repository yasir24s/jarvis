import Foundation
import Testing
@testable import JarvisVoice

/// V1 lab: with JARVIS_V1_LAB=<folder>, each <folder>/raw-<setup>/<take>.wav (the helper's
/// `--render` output) goes through the player's chain, as EnginePlayer feeds each channel, into
/// <folder>/out/<setup>/<take>.wav: without the expander (gain, then limiter, as before V1) and
/// with it (<setup>+expander). The loudness before and after is printed. Skipped otherwise, so
/// the default `swift test` reads and writes nothing.
@Suite("V1 lab (JARVIS_V1_LAB=<folder>)")
struct VoiceLabTests {
    static let folder = ProcessInfo.processInfo.environment["JARVIS_V1_LAB"]

    @Test(.enabled(if: VoiceLabTests.folder != nil, "set JARVIS_V1_LAB to a folder of raw renders"))
    func thePlayersChainOverTheLabsRenders() throws {
        let root = URL(fileURLWithPath: try #require(Self.folder), isDirectory: true)
        let files = FileManager.default
        let setups = try files.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { $0.hasPrefix("raw-") }.sorted()
        try #require(!setups.isEmpty, "no raw-<setup> folders in \(root.path)")
        let rate = EnginePlayer.sampleRate
        let lift = EnginePlayer.outputLiftDB
        for setup in setups {
            let name = String(setup.dropFirst(4))
            let takes = try files.contentsOfDirectory(atPath: root.appending(path: setup).path(percentEncoded: false))
                .filter { $0.hasSuffix(".wav") }.sorted()
            for take in takes {
                let raw = try Acknowledgement.loadClip(root.appending(path: "\(setup)/\(take)")).samples
                let gain = Loudness.gain(for: raw, sampleRate: rate, lift: lift)
                let before = Loudness.limited(raw.map { $0 * gain }, sampleRate: rate)
                let after = Loudness.normalized(raw, sampleRate: rate, lift: lift)
                for (variant, samples) in [(name, before), (name + "+expander", after)] {
                    let dir = root.appending(path: "out/\(variant)", directoryHint: .isDirectory)
                    try files.createDirectory(at: dir, withIntermediateDirectories: true)
                    try AcknowledgementTests.writeFloatWAV(samples, rate: Int(rate), to: dir.appending(path: take))
                }
                func lufs(_ x: [Float]) -> String {
                    Loudness.integrated([x], sampleRate: rate).map { String(format: "%.2f", $0 + lift) } ?? "n/a"
                }
                print("V1 lab: \(name)/\(take): raw \(lufs(raw)) LUFS (as played), out \(lufs(before)), "
                      + "with expander \(lufs(after)); peak raw \(String(format: "%.2f", Loudness.samplePeak(raw)))")
            }
        }
    }
}
