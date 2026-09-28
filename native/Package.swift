// swift-tools-version: 6.2
// Native JARVIS — see ROADMAP.md. Targets are added as their milestone lands.
// Target split (plan/README.md D-13): pure-logic targets (JarvisCore, JarvisToolsCore) are
// Foundation-only, so every golden test runs headless. Platform targets may import Apple
// frameworks: JarvisTools uses AppKit services (NSWorkspace, NSPasteboard), EventKit,
// Contacts, Vision, etc.; JarvisBrain and JarvisVoice never import AppKit/SwiftUI. No target
// but JarvisApp imports SwiftUI or owns the app lifecycle — only JarvisApp owns UI and the run loop.
import PackageDescription

let package = Package(
    name: "JARVIS",
    platforms: [
        .macOS("26.0")   // SpeechAnalyzer, FoundationModels
    ],
    products: [
        .executable(name: "JARVIS", targets: ["JarvisApp"]),
    ],
    targets: [
        // State, persona, emotions, prompt, dataset, security, routing. Foundation only.
        .target(name: "JarvisCore"),

        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore"]
        ),

        // Golden fixtures live in Tests/Fixtures and are located via #filePath, not
        // bundled as resources — they are produced by tools/golden.py from Python JARVIS.
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
    ]
)
