import Foundation

/// M0 stub: only `--version` is wired. `--selftest`, `--permissions` and the SwiftUI app
/// lifecycle (`JarvisSwiftUIApp.main()`) land with their own M0 tasks.
@main
@MainActor
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("--version") {
            print("JARVIS \(infoString("CFBundleShortVersionString")) (\(infoString("CFBundleVersion")))")
            exit(0)
        }
        FileHandle.standardError.write(Data("JARVIS: only --version is implemented in this build\n".utf8))
        exit(64)   // EX_USAGE
    }

    /// Unbundled builds (`swift run`) have no Info.plist, so the keys read as "unbundled".
    private static func infoString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unbundled"
    }
}
