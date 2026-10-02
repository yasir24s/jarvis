import Foundation
import Testing
@testable import JarvisVoice

/// V1 part 3: `voiceReference` picks the reference the clone speaks with, read at each launch;
/// another reference than the default is paced to the default's speed.
@Suite("V1 voice reference setting")
struct VoiceReferenceTests {
    /// An assets folder with the default reference (102,720 samples, 65 bytes of text, as
    /// installed) and, when `dry`, references/dry (111,840 samples, 83 bytes, as the dry cut).
    static func assets(dry: Bool) throws -> TempFolder {
        let folder = try TempFolder()
        func reference(_ path: String, samples: Int, text: String) throws {
            let dir = folder.url.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try AcknowledgementTests.writeFloatWAV([Float](repeating: 0, count: samples), rate: 24_000,
                                                   to: dir.appending(path: "reference.wav"))
            try (text + "\n").write(to: dir.appending(path: "reference.txt"), atomically: true, encoding: .utf8)
        }
        try reference("reference", samples: 102_720,
                      text: "But we were friends by that point and he's so lovely to work for.")
        if dry {
            try reference("references/dry", samples: 111_840,
                          text: "I loved creating that, and I had a brilliant makeup artist called Veronica McAleer.")
        }
        return folder
    }

    /// V2: unset (or empty) is `dry`, the user's choice by ear; an explicit "default" is still the
    /// installed `reference/`.
    @Test func theSettingIsReadFromTheDefaultsWithDryWhenUnset() throws {
        let name = "jarvis-voice-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(VoiceHelperSetup.reference(in: defaults) == "dry")
        defaults.set("dry-wpe", forKey: VoiceHelperSetup.referenceKey)
        #expect(VoiceHelperSetup.reference(in: defaults) == "dry-wpe")
        defaults.set("default", forKey: VoiceHelperSetup.referenceKey)
        #expect(VoiceHelperSetup.reference(in: defaults) == "default")
        defaults.set("  ", forKey: VoiceHelperSetup.referenceKey)
        #expect(VoiceHelperSetup.reference(in: defaults) == "dry")
        #expect(VoiceHelperSetup.reference(in: nil) == "dry")
        #expect(VoiceHelperSetup.referenceKey == "voiceReference")
        #expect(VoiceHelperSetup.preferredReference == "dry")
        #expect(VoiceHelperSetup.defaultReference == "default")
    }

    /// The helper gets `--reference` only for an installed reference other than the default; a
    /// name that is not installed, or not a plain name, speaks with the default.
    @Test func eachLaunchGetsTheReferenceAsItIsThen() throws {
        let folder = try Self.assets(dry: true)
        defer { folder.remove() }
        let choice = LiveVoiceSettingsTests.Setting("default")
        let setup = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"), assets: folder.url,
                                     outDirectory: folder.url, log: nil, speed: { 1.25 }, reference: { choice.current })
        func reference(_ args: [String]) -> String? { args.firstIndex(of: "--reference").map { args[$0 + 1] } }
        #expect(reference(setup.arguments) == nil)
        choice.set("dry")
        #expect(setup.reference == "dry")
        let dry = try #require(reference(setup.arguments))
        #expect(dry.hasPrefix(folder.url.path(percentEncoded: false)) && dry.hasSuffix("/references/dry/"), "\(dry)")
        for missing in ["dry-wpe", "../reference", "Dry", ""] {
            choice.set(missing)
            #expect(setup.reference == "default", "\(missing)")
            #expect(reference(setup.arguments) == nil)
        }
        // The installed check still needs only the six default files.
        #expect(VoiceHelperSetup.assetFiles.contains("reference/reference.wav"))
        #expect(!VoiceHelperSetup.assetFiles.contains { $0.hasPrefix("references/") })
    }

    /// With the dry reference, 600 bytes still get the default's 2961 frames of speech at 1.25
    /// (the pace is the default's), plus the dry reference's own 436.
    @Test func anotherReferenceIsPacedToTheDefaultsSpeed() throws {
        let folder = try Self.assets(dry: true)
        defer { folder.remove() }
        let choice = LiveVoiceSettingsTests.Setting("default")
        let setup = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"), assets: folder.url,
                                     outDirectory: folder.url, log: nil, speed: { 1.25 }, reference: { choice.current })
        let text = String(repeating: "a", count: 600)
        #expect(setup.frames(forSpokenText: text) == 3362)
        choice.set("dry")
        #expect(setup.frames(forSpokenText: text) == 3397)
        let paced = VoiceHelperSetup.pacedSpeed(1.25, frames: 436, bytes: 83, homeFrames: 401, homeBytes: 65)
        #expect(abs(paced - 1.0644) < 0.0001)
        #expect(VoiceHelperSetup.pacedSpeed(1.25, frames: 401, bytes: 65, homeFrames: 401, homeBytes: 65) == 1.25)
    }

    /// A new reference releases the voice once, so the next reply starts the helper with it.
    @Test func aNewReferenceReleasesTheVoiceOnce() async {
        let f5 = FakeEngine(.f5, respond: LiveVoiceSettingsTests.quick)
        let choice = LiveVoiceSettingsTests.Setting("default")
        let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: LiveVoiceSettingsTests.quick),
                                 player: FakePlayer(), speed: { 1.25 }, reference: { choice.current }, log: { _ in })
        await speech.say("Good evening, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 0)
        choice.set("dry")
        await speech.say("Drier now, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 1)
        await speech.say("Still dry, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 1)
    }

    @Test func theInstallScriptInstallsBothReferencesAndRendersForEach() throws {
        let text = try String(contentsOf: AcknowledgementTests.script, encoding: .utf8)
        for reference in ["dry", "dry-wpe"] {
            #expect(text.contains("\"references/\(reference)/reference.wav|"))
            #expect(text.contains("\"references/\(reference)/reference.txt|"))
            #expect(text.contains("render_acknowledgements \(reference) \"$DEST/references/\(reference)\""))
        }
    }
}
