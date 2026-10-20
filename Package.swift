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
        // Client side of the helper protocol: process supervision, framing, audio decoding; engine and recognizer clients.
        .target(name: "TranslateEngineClient"),
        // Milestone 1c comparison: corpus, scoring, candidate adapters (Apple, helpers, Hy-MT2), receipts.
        .target(name: "TranslateCompare", dependencies: ["TranslateEngineClient"]),
        // Host-free checks that exercise the real SDK validators, Core replay and the engine receipts.
        .executableTarget(
            name: "TranslateCheck",
            dependencies: ["TranslateCore", "TranslateEngineClient", "TranslateCompare", .product(name: "NookPluginSDK", package: "NookPluginSDK")],
            // SwiftPM 6.4's Swift Build system stamps LC_BUILD_VERSION's SDK field with the deployment target
            // (its link step never receives -target-sdk-version). Apple Translation then reports installed
            // language packs as `supported` / notInstalled. Stamp the real SDK until SwiftPM fixes it; any
            // executable that uses Translation needs the same (`swift build --build-system native` stamps correctly).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "26.0", "-Xlinker", "27.0"])]
        ),
        .testTarget(name: "TranslateCoreTests", dependencies: ["TranslateCore"]),
        .testTarget(name: "TranslateEngineClientTests", dependencies: ["TranslateEngineClient"]),
        .testTarget(name: "TranslateCompareTests", dependencies: ["TranslateCompare", "TranslateEngineClient"]),
        .testTarget(
            name: "TranslatePluginTests",
            dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]
        )
    ],
    swiftLanguageModes: [.v5]
)
