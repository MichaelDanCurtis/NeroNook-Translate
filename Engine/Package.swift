// swift-tools-version: 6.2
import PackageDescription

// Separate package for the MLX helpers, pinned to the same mlx-audio-swift revision Voice uses
// (Package.resolved is seeded from Voice's pins). Built independently and copied into the plugin
// bundle as Contents/Helpers/TranslateEngine and Contents/Helpers/TranslateASR.
let package = Package(
    name: "TranslateEngine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TranslateEngine", targets: ["TranslateEngine"]),
        .executable(name: "TranslateASR", targets: ["TranslateASR"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4")
    ],
    targets: [
        // Frame codec shared by both helpers.
        .target(name: "EngineProtocol"),
        // One resident Qwen3-TTS Base model, three voice slots, one generation at a time; plus the text translator.
        .executableTarget(
            name: "TranslateEngine",
            dependencies: [
                "EngineProtocol",
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm")
            ]
        ),
        // Recognition helper: Nemotron 3.5 streaming, Qwen3-ASR, Qwen3-ForcedAligner. Separate process so
        // captions never wait behind speech generation (plan §2.3).
        .executableTarget(
            name: "TranslateASR",
            dependencies: [
                "EngineProtocol",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
