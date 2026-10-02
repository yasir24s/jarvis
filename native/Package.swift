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
        // State primitives + (from M1) persona, emotions, prompt, dataset, security, routing.
        .target(name: "JarvisCore"),

        // M2 security choke point. Tool bodies are registered here by later milestones;
        // callers can only execute them through ToolGateway.call(...).
        .target(
            name: "JarvisTools",
            dependencies: ["JarvisCore"]
        ),

        .executableTarget(
            name: "JarvisApp",
            dependencies: ["JarvisCore", "JarvisTools", "JarvisBrain", "JarvisChat", "JarvisVoice"]
        ),

        // M4 text chat (plan: M02-M04 §3.12): the chat window's logic, so it tests headless.
        // Foundation and Observation only, never SwiftUI or AppKit (D-13); the views stay in JarvisApp.
        .target(name: "JarvisChat", dependencies: ["JarvisCore", "JarvisTools", "JarvisBrain"]),
        .testTarget(name: "JarvisChatTests", dependencies: ["JarvisChat", "JarvisBrain", "JarvisTools", "JarvisCore"]),

        // M3 Claude driver. The JarvisTools dependency arrives in T3.3, once M2's target exists.
        .target(name: "JarvisBrain", dependencies: ["JarvisCore", "JarvisTools"]),
        .testTarget(name: "JarvisBrainTests", dependencies: ["JarvisBrain", "JarvisTools", "JarvisTestSupport"]),

        // M8 voice out (plan: M08-M13 §3.2, D-54): the F5 clone through the jarvis-voice helper,
        // `say` as the fallback, the speech queue and the one player. Foundation and AVFAudio only.
        // The helper is a package of its own (VoiceHelper/), so this package never depends on MLX.
        .target(name: "JarvisVoice", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisVoiceTests", dependencies: ["JarvisVoice", "JarvisCore", "JarvisTestSupport"]),

        // Sandbox + golden-fixture loader shared by every test target. Foundation only —
        // it must NOT import Testing (Testing.framework is only on the test targets' search path).
        .target(
            name: "JarvisTestSupport",
            dependencies: ["JarvisCore"],
            path: "Tests/JarvisTestSupport"
        ),

        // Golden fixtures live in Tests/Fixtures and are located via #filePath, not
        // bundled as resources — they are produced by tools/golden.py from Python JARVIS.
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore", "JarvisTestSupport"]
        ),

        .testTarget(
            name: "JarvisToolsTests",
            dependencies: ["JarvisTools"]
        ),

        // W1: the WebKit reader lives in JarvisApp (the one target that may import WebKit), so
        // its tests import the app. They load pages from a loopback server, never the network.
        // UI1: the chat snapshots drive the real ChatViewModel, and the HUD's player wraps the
        // voice's, so these tests import JarvisChat and JarvisVoice too.
        .testTarget(name: "JarvisAppTests", dependencies: ["JarvisApp", "JarvisBrain", "JarvisChat", "JarvisCore", "JarvisTools", "JarvisVoice", "JarvisTestSupport"]),
    ]
)
