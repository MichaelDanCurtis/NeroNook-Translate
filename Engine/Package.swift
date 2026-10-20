// swift-tools-version: 6.2
import PackageDescription

// Separate package for the MLX helper, pinned to the same mlx-audio-swift revision Voice uses.
// Built independently and copied into the plugin bundle as Contents/Helpers/TranslateEngine.
let package = Package(
    name: "TranslateEngine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TranslateEngine", targets: ["TranslateEngine"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb")
    ],
    targets: [
        .executableTarget(
            name: "TranslateEngine",
            dependencies: [
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
