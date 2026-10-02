import Foundation
@testable import JarvisVoice

/// The vendored voice binaries in this checkout. scripts/vendor-voice-assets.sh fills
/// native/Resources/vendor; SwiftPM builds libpystubs.dylib beside the test bundle. A test that
/// needs one calls `Vendor.assets()`, which throws, naming the script, when a file is missing:
/// those tests fail, never skip.
enum Vendor {
    static let native: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // JarvisVoiceTests/
        .deletingLastPathComponent()        // Tests/
        .deletingLastPathComponent()        // native/
    static let folder = native.appending(path: "Resources/vendor", directoryHint: .isDirectory)

    /// The SwiftPM products folder this test bundle was built into (it holds libpystubs.dylib).
    static var buildProducts: URL { Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent() }

    struct Missing: Error, CustomStringConvertible {
        let files: [String]
        var description: String {
            "missing vendored voice files \(files): run scripts/vendor-voice-assets.sh "
                + "(libpystubs.dylib comes from `swift build --build-tests`)"
        }
    }

    /// The checkout's assets, after checking that `needed` are on disk.
    static func assets(needing needed: [KeyPath<VendoredAssets, URL>]) throws -> VendoredAssets {
        let assets = VendoredAssets.checkout(vendor: folder, buildProducts: buildProducts)
        let missing = needed.map { assets[keyPath: $0] }.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty { throw Missing(files: missing.map(\.lastPathComponent)) }
        return assets
    }

    /// webrtcvad's module, loaded with libpystubs first.
    static func webrtcvad() throws -> WebRTCVADLibrary {
        let assets = try assets(needing: [\.pyStubs, \.webrtcvad])
        return try WebRTCVADLibrary.load(stubs: assets.pyStubs, module: assets.webrtcvad)
    }
}

private final class BundleToken {}
