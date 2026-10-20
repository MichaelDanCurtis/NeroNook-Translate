// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeroNookTranslate",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TranslateCheck", targets: ["TranslateCheck"])
    ],
    dependencies: [
        .package(path: "Vendor/NookPluginSDK")
    ],
    targets: [
        // Foundation-only session logic: schema, journal, revisions, scheduler, consent, captions, evidence.
        .target(name: "TranslateCore"),
        // Host-free checks that exercise the real SDK validators and Core replay.
        .executableTarget(
            name: "TranslateCheck",
            dependencies: ["TranslateCore", .product(name: "NookPluginSDK", package: "NookPluginSDK")]
        ),
        .testTarget(name: "TranslateCoreTests", dependencies: ["TranslateCore"]),
        .testTarget(
            name: "TranslatePluginTests",
            dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]
        )
    ],
    swiftLanguageModes: [.v5]
)
