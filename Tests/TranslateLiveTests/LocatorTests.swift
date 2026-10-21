import XCTest
@testable import TranslateLive

final class LocatorTests: XCTestCase {
    func testModelLocatorFindsOneRevisionAndRefusesTwo() throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("translate-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }
        let models = ModelLocator.models(in: storage)
        XCTAssertThrowsError(try ModelLocator.qwenBase(in: storage))
        try FileManager.default.createDirectory(at: models.appendingPathComponent("Qwen3-TTS-12Hz-1.7B-Base-8bit-aaaa"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models.appendingPathComponent("Qwen3-TTS-12Hz-1.7B-Base-bf16-cccc"), withIntermediateDirectories: true)
        XCTAssertEqual(try ModelLocator.qwenBase(in: storage).lastPathComponent, "Qwen3-TTS-12Hz-1.7B-Base-8bit-aaaa", "the bf16 folder has a different prefix")
        try FileManager.default.createDirectory(at: models.appendingPathComponent("Qwen3-TTS-12Hz-1.7B-Base-8bit-bbbb"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ModelLocator.qwenBase(in: storage))
    }

    func testHelperLocatorLooksNextToTheBuildFolder() {
        let fake = URL(fileURLWithPath: "/nowhere/pkg/.build/debug/TranslateApp")
        XCTAssertThrowsError(try HelperLocator.engine(executable: fake)) { error in
            XCTAssert("\(error)".contains("/nowhere/pkg/Engine/.build/release/TranslateEngine"), "\(error)")
        }
    }

    func testLanguagesSpellings() {
        XCTAssertEqual(Languages.speechLocale("es"), "es-MX")
        XCTAssertEqual(Languages.qwenName("zh"), "Chinese")
        XCTAssertEqual(Languages.name("en"), "English")
    }
}
