// swift-tools-version: 6.2
// jarvis-voice-qwen, the Qwen3-TTS helper process JARVIS speaks through (V6). A package of its
// own, apart from both the main package (native/Package.swift never depends on MLX) and the F5
// helper (native/VoiceHelper), which pins mlx-swift 0.29.1: Qwen3-TTS needs 0.31.4. build-app.sh
// builds this package in release and copies the helper into JARVIS.app/Contents/Helpers/.
// MLXAudioCore, MLXAudioCodecs and MLXAudioTTS are the parts of Blaizzy/mlx-audio-swift that
// Qwen3-TTS needs, vendored with JARVIS's patches (see Sources/MLXAudioTTS/README.md); they
// keep their own Swift 5 language mode.
import PackageDescription

let package = Package(
    name: "VoiceHelperQwen",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "jarvis-voice-qwen", targets: ["jarvis-voice-qwen"]),
    ],
    dependencies: [
        // The versions the Qwen scratch runner built and the user heard (2026-10-03), pinned exactly.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9"),
    ],
    targets: [
        .target(
            name: "MLXAudioCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Sources/MLXAudioCore",
            exclude: ["LICENSE"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MLXAudioCodecs",
            dependencies: [
                "MLXAudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/MLXAudioCodecs",
            exclude: ["LICENSE"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MLXAudioTTS",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/MLXAudioTTS",
            exclude: ["LICENSE", "README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "jarvis-voice-qwen",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioTTS",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),   // V10: the weights to keep resident
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            // MLXArray and the model are not Sendable; the helper is single-threaded.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // V7: the stretcher fed as a slow, uneven stream keeps its rate (no model is loaded).
        .testTarget(
            name: "jarvis-voice-qwen-tests",
            dependencies: ["jarvis-voice-qwen"],
            path: "Tests/jarvis-voice-qwen-tests"
        ),
    ]
)
