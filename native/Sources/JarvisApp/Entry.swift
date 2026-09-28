import Foundation

/// Process entry (plan: M00 §3.9). Headless flags are handled here, before any AppKit/SwiftUI
/// object exists, so they may be exec'd from a terminal: they touch no TCC service and never
/// take the lock for longer than a probe. Everything else runs the menu-bar app.
@main
@MainActor
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--version") {
            print("JARVIS \(infoString("CFBundleShortVersionString")) (\(infoString("CFBundleVersion")))")
            exit(0)
        }
        if arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        if arguments.contains("--permissions") {
            // T0.11 is deferred to M15. Refuse rather than fall through to the GUI: exec'ing the
            // GUI from a terminal makes the terminal the TCC responsible process (§3.4 rule 3).
            FileHandle.standardError.write(Data("JARVIS: --permissions is not implemented in this build\n".utf8))
            exit(64)   // EX_USAGE
        }
        JarvisSwiftUIApp.main()
    }

    /// Unbundled builds (`swift run`) have no Info.plist, so the keys read as "unbundled".
    nonisolated static func infoString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unbundled"
    }
}
