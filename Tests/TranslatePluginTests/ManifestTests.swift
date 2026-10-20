import Foundation
import NookPluginSDK
import XCTest

final class ManifestTests: XCTestCase {
    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/NookPlugin.json")
    }

    func testManifestPassesTheRealSDKValidator() throws {
        let data = try Data(contentsOf: manifestURL)
        XCTAssertLessThanOrEqual(data.count, 8192)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        XCTAssertEqual(manifest.id, "cafe.nero.plugin.translate")
        XCTAssertEqual(manifest.apiVersion, 1)
        XCTAssertEqual(manifest.launchMode, "application", "Translate owns microphone and capture permission through its own bundle")
        XCTAssertLessThanOrEqual(manifest.capabilities.count, 12)
    }
}
