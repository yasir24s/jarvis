import Foundation
import Testing
@testable import JarvisVoice

/// V3: the voice is the `dry-short` reference at 8 steps, the user's choice by ear, 2026-10-03
/// (V2: `dry`, 2026-10-02), over
/// V1's transcription-based default (the installed `reference/` at 4). `voiceSteps` is read at
/// each launch; unset or invalid, the steps are those of the reference in use (8 for `dry-short`,
/// `dry` and `dry-wpe`, 4 for the installed default), and the acknowledgement clips are that reference's.
/// The assets are temporary folders and the settings a defaults suite of the test's own: nothing
/// reads the installed assets or the app's defaults.
@Suite("V3 the voice is dry-short at 8 steps")
struct VoiceStepsTests {
    /// A defaults suite of one test's own.
    struct OwnDefaults {
        let name: String
        let defaults: UserDefaults

        init() throws {
            let name = "jarvis-voice-tests-\(UUID().uuidString)"
            self.name = name
            defaults = try #require(UserDefaults(suiteName: name))
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    /// The value after `flag` in the helper's arguments.
    static func value(of flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    /// Installs `references/<name>/` in `assets` (the installed check needs only the two files).
    static func install(_ name: String, in assets: TempFolder) throws {
        let folder = assets.url.appending(path: "references/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["reference.wav", "reference.txt"] {
            try Data("x".utf8).write(to: folder.appending(path: file))
        }
    }

    /// The app's setup over `assets` and `defaults`, as AppVoice makes it.
    static func app(_ assets: TempFolder, _ own: OwnDefaults) -> VoiceHelperSetup {
        VoiceHelperSetup.inApp(bundle: .main, log: nil, defaults: own.defaults, assets: assets.url)
    }

    /// Nothing set and `dry-short` installed: the voice is dry-short at 8 steps, at the speed it had.
    @Test func theDefaultIsDryShortAt8Steps() throws {
        let folder = try VoiceReferenceTests.assets(dry: true, dryShort: true)
        let own = try OwnDefaults()
        defer {
            folder.remove()
            own.remove()
        }
        let setup = Self.app(folder, own)
        #expect(setup.reference == "dry-short")
        #expect(setup.steps == 8)
        let arguments = setup.arguments
        #expect(Self.value(of: "--steps", in: arguments) == "8")
        #expect(Self.value(of: "--speed", in: arguments) == "1.2")
        let reference = try #require(Self.value(of: "--reference", in: arguments))
        #expect(reference.hasPrefix(folder.url.path(percentEncoded: false))
                && reference.hasSuffix("/references/dry-short/"), "\(reference)")
    }

    /// `dry-short` not installed: `dry` speaks, at 8 steps; with `dry` missing too, the installed
    /// default, at 4 and without `--reference`.
    @Test func theFallbackIsDryAt8StepsThenTheInstalledDefaultAt4() throws {
        let withDry = try VoiceReferenceTests.assets(dry: true)
        let bare = try VoiceReferenceTests.assets(dry: false)
        let own = try OwnDefaults()
        defer {
            withDry.remove()
            bare.remove()
            own.remove()
        }
        let dry = Self.app(withDry, own)
        #expect(dry.reference == "dry")
        #expect(dry.steps == 8)
        #expect(Self.value(of: "--steps", in: dry.arguments) == "8")
        let reference = try #require(Self.value(of: "--reference", in: dry.arguments))
        #expect(reference.hasSuffix("/references/dry/"), "\(reference)")
        let installedDefault = Self.app(bare, own)
        #expect(installedDefault.reference == "default")
        #expect(installedDefault.steps == 4)
        #expect(Self.value(of: "--steps", in: installedDefault.arguments) == "4")
        #expect(!installedDefault.arguments.contains("--reference"))
    }

    /// `dry` not installed: the installed default reference speaks, at 4 steps, without
    /// `--reference`. So does a reference the setting names that is not installed.
    @Test func withoutTheDryReferenceTheInstalledDefaultSpeaksAt4Steps() throws {
        let folder = try VoiceReferenceTests.assets(dry: false)
        let own = try OwnDefaults()
        defer {
            folder.remove()
            own.remove()
        }
        let setup = Self.app(folder, own)
        #expect(setup.reference == "default")
        #expect(setup.steps == 4)
        #expect(Self.value(of: "--steps", in: setup.arguments) == "4")
        #expect(!setup.arguments.contains("--reference"))
        own.defaults.set("dry-wpe", forKey: VoiceHelperSetup.referenceKey)
        #expect(setup.reference == "default")
        #expect(Self.value(of: "--steps", in: setup.arguments) == "4")
        #expect(!setup.arguments.contains("--reference"))
    }

    /// An explicit `voiceReference` still wins, and its steps follow it: 8 for `dry-wpe`, 4 for an
    /// explicit "default" even with `dry` installed.
    @Test func anExplicitReferenceWinsAndTheStepsFollowIt() throws {
        let folder = try VoiceReferenceTests.assets(dry: true)
        try Self.install("dry-wpe", in: folder)
        let own = try OwnDefaults()
        defer {
            folder.remove()
            own.remove()
        }
        let setup = Self.app(folder, own)
        own.defaults.set("dry-wpe", forKey: VoiceHelperSetup.referenceKey)
        #expect(setup.reference == "dry-wpe")
        #expect(Self.value(of: "--steps", in: setup.arguments) == "8")
        let wpe = try #require(Self.value(of: "--reference", in: setup.arguments))
        #expect(wpe.hasSuffix("/references/dry-wpe/"), "\(wpe)")
        own.defaults.set("default", forKey: VoiceHelperSetup.referenceKey)
        #expect(setup.reference == "default")
        #expect(Self.value(of: "--steps", in: setup.arguments) == "4")
        #expect(!setup.arguments.contains("--reference"))
    }

    /// `voiceSteps` beats the default of every reference, for whole numbers from 2 to 32 (a whole
    /// number stored as a real counts), and is read afresh at each launch.
    @Test func anExplicitVoiceStepsWinsAndIsReadAtEachLaunch() throws {
        let folder = try VoiceReferenceTests.assets(dry: true)
        let own = try OwnDefaults()
        defer {
            folder.remove()
            own.remove()
        }
        let setup = Self.app(folder, own)
        for steps in [2, 5, 16, 32] {
            own.defaults.set(steps, forKey: VoiceHelperSetup.stepsKey)
            #expect(VoiceHelperSetup.steps(in: own.defaults) == steps)
            #expect(setup.steps == steps)
            #expect(Self.value(of: "--steps", in: setup.arguments) == String(steps), "dry")
        }
        own.defaults.set(16.0, forKey: VoiceHelperSetup.stepsKey)
        #expect(VoiceHelperSetup.steps(in: own.defaults) == 16)
        own.defaults.set("default", forKey: VoiceHelperSetup.referenceKey)
        own.defaults.set(12, forKey: VoiceHelperSetup.stepsKey)
        #expect(Self.value(of: "--steps", in: setup.arguments) == "12", "the installed default as well")
        own.defaults.removeObject(forKey: VoiceHelperSetup.stepsKey)
        #expect(Self.value(of: "--steps", in: setup.arguments) == "4", "unset again: the installed default's")
        #expect(VoiceHelperSetup.stepsKey == "voiceSteps")
        #expect(VoiceHelperSetup.stepsRange == 2...32)
    }

    /// Anything but a whole number from 2 to 32 is not clamped: it leaves the default of the
    /// reference in use.
    @Test func anInvalidVoiceStepsLeavesTheReferencesDefault() throws {
        let withDry = try VoiceReferenceTests.assets(dry: true)
        let withoutDry = try VoiceReferenceTests.assets(dry: false)
        let own = try OwnDefaults()
        defer {
            withDry.remove()
            withoutDry.remove()
            own.remove()
        }
        let dry = Self.app(withDry, own)
        let installedDefault = Self.app(withoutDry, own)
        let invalid: [Any] = [1, 0, -4, 33, 1000, 8.5, "8", "eight", true, false]
        for value in invalid {
            own.defaults.set(value, forKey: VoiceHelperSetup.stepsKey)
            #expect(VoiceHelperSetup.steps(in: own.defaults) == nil, "\(value)")
            #expect(Self.value(of: "--steps", in: dry.arguments) == "8", "\(value), dry")
            #expect(Self.value(of: "--steps", in: installedDefault.arguments) == "4", "\(value), installed default")
        }
        own.defaults.removeObject(forKey: VoiceHelperSetup.stepsKey)
        #expect(VoiceHelperSetup.steps(in: own.defaults) == nil)
        #expect(VoiceHelperSetup.steps(in: nil) == nil)
    }

    @Test func theStepsDefaultByReference() {
        #expect(VoiceHelperSetup.defaultSteps(for: "dry-short") == 8)
        #expect(VoiceHelperSetup.defaultSteps(for: "dry") == 8)
        #expect(VoiceHelperSetup.defaultSteps(for: "dry-wpe") == 8)
        #expect(VoiceHelperSetup.defaultSteps(for: VoiceHelperSetup.defaultReference) == 4)
    }

    /// The injected seam, as the other settings have: each launch asks for the steps, and a call
    /// site with none gets the reference's default.
    @Test func eachLaunchGetsTheStepsAsTheyAreThen() throws {
        let folder = try VoiceReferenceTests.assets(dry: true)
        defer { folder.remove() }
        let choice = LiveVoiceSettingsTests.Setting("dry")
        let steps = LiveVoiceSettingsTests.Setting<Int?>(nil)
        let setup = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"), assets: folder.url,
                                     outDirectory: folder.url, log: nil, speed: { 1.2 },
                                     reference: { choice.current }, steps: { steps.current })
        #expect(Self.value(of: "--steps", in: setup.arguments) == "8")
        steps.set(6)
        #expect(setup.steps == 6)
        #expect(Self.value(of: "--steps", in: setup.arguments) == "6", "the next launch gets the new steps")
        steps.set(nil)
        choice.set("default")
        #expect(Self.value(of: "--steps", in: setup.arguments) == "4", "a new reference brings its own default")
        let plain = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"), assets: folder.url,
                                     outDirectory: folder.url, log: nil)
        #expect(Self.value(of: "--steps", in: plain.arguments) == "4")
    }

    /// The clips played are `acknowledgements/<the reference in use>/`: after the fallback that is
    /// `default`, the folder of the voice that then speaks. AppVoice asks for `setup.reference`.
    @Test func theAcknowledgementFolderFollowsTheReferenceInUse() throws {
        let withDry = try VoiceReferenceTests.assets(dry: true)
        try Self.install("dry-wpe", in: withDry)
        let withoutDry = try VoiceReferenceTests.assets(dry: false)
        let own = try OwnDefaults()
        defer {
            withDry.remove()
            withoutDry.remove()
            own.remove()
        }
        let withShort = try VoiceReferenceTests.assets(dry: true, dryShort: true)
        defer { withShort.remove() }
        let line = try #require(Acknowledgement.lines.first)
        func clip(_ setup: VoiceHelperSetup) -> [String] {
            let url = Acknowledgement.clipURL(line, assets: setup.assets, reference: setup.reference)
            return Array(url.pathComponents.suffix(3))
        }
        let installed = Self.app(withDry, own)
        let bare = Self.app(withoutDry, own)
        #expect(clip(Self.app(withShort, own)) == ["acknowledgements", "dry-short", "\(line.name).wav"],
                "unset, dry-short installed")
        #expect(clip(installed) == ["acknowledgements", "dry", "\(line.name).wav"], "unset, only dry installed")
        #expect(clip(bare) == ["acknowledgements", "default", "\(line.name).wav"], "unset, dry not installed")
        own.defaults.set("dry-wpe", forKey: VoiceHelperSetup.referenceKey)
        #expect(clip(installed) == ["acknowledgements", "dry-wpe", "\(line.name).wav"], "dry-wpe installed")
        #expect(clip(bare) == ["acknowledgements", "default", "\(line.name).wav"], "dry-wpe not installed")
        own.defaults.set("default", forKey: VoiceHelperSetup.referenceKey)
        #expect(clip(installed) == ["acknowledgements", "default", "\(line.name).wav"], "an explicit default")
        let url = Acknowledgement.clipURL(line, assets: installed.assets, reference: installed.reference)
        #expect(url.path(percentEncoded: false).hasPrefix(withDry.url.path(percentEncoded: false)))
    }
}
