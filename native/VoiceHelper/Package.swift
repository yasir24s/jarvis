// swift-tools-version: 6.2
// jarvis-voice, the F5-TTS helper process JARVIS speaks through (plan D-54). A package of its
// own, so the main package (native/Package.swift) never depends on MLX: its tests never compile
// MLX and never load a model. build-app.sh builds this package in release and copies the helper
// with its resource bundles into JARVIS.app/Contents/Helpers/.
// F5TTS and Vocos are vendored from lucasnewman/f5-tts-swift and vocos-swift with the voice
// spike's patches (see each folder's README.md); they keep their own Swift 5 language mode.
import PackageDescription

let package = Package(
    name: "VoiceHelper",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "jarvis-voice", targets: ["jarvis-voice"]),
    ],
    dependencies: [
        // The two packages the user approved for the voice (D-53), pinned to the spike's tags.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
        .package(url: "https://github.com/apple/swift-numerics", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "Vocos",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/Vocos",
            exclude: ["LICENSE", "README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "F5TTS",
            dependencies: [
                "Vocos",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXLinalg", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/F5TTS",
            exclude: ["LICENSE", "README.md"],
            resources: [.copy("Resources/mel_filters.npy")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "jarvis-voice",
            dependencies: [
                "F5TTS",
                "Vocos",
                .product(name: "MLX", package: "mlx-swift"),
                // mlx-swift needs swift-numerics from 1.0.0; listing it pins the spike's 1.1.1.
                .product(name: "Numerics", package: "swift-numerics"),
            ],
            // MLXArray and the F5 modules are not Sendable; the helper is single-threaded.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
