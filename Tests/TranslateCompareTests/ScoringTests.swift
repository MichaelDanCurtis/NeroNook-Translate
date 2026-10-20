import XCTest
@testable import TranslateCompare

final class ScoringTests: XCTestCase {
    func testEnglishNormalizationFoldsNumbersAndKeepsContractions() {
        // Digits are one token each by design (see Normalizer), so every expectation here is exploded.
        XCTAssertEqual(Normalizer.normalize("Forty-five people, on March twelfth.", language: "en"), "4 5 people on march 1 2 th")
        XCTAssertEqual(Normalizer.normalize("fourteen thousand", language: "en"), "1 4 0 0 0")
        XCTAssertEqual(Normalizer.normalize("I don't think so", language: "en"), "i don't think so")
        XCTAssertEqual(Normalizer.normalize("1,500 and 3.5", language: "en"), "1 5 0 0 and 3 . 5")
        XCTAssertEqual(Normalizer.normalize("one point five million", language: "en"), Normalizer.normalize("1.5 million", language: "en"), "words and digits meet in the same form")
        XCTAssertEqual(Normalizer.normalize("twenty percent", language: "en"), "2 0 %")
    }

    func testSpanishNormalizationFoldsNumbers() {
        XCTAssertEqual(Normalizer.normalize("cuarenta y cinco", language: "es"), "4 5")
        XCTAssertEqual(Normalizer.normalize("catorce mil", language: "es"), "1 4 0 0 0")
        XCTAssertEqual(Normalizer.normalize("el doce de marzo", language: "es"), "el 1 2 de marzo")
        XCTAssertEqual(Normalizer.normalize("dos millones", language: "es"), "2 0 0 0 0 0 0")
    }

    func testWordAndCharacterErrorRates() {
        XCTAssertEqual(Scoring.errorRate(reference: "the cat sat on the mat", hypothesis: "The cat sat on the mat.", language: "en").errors, 0)
        let one = Scoring.errorRate(reference: "the cat sat on the mat", hypothesis: "the cat sat on a mat", language: "en")
        XCTAssertEqual(one.errors, 1); XCTAssertEqual(one.total, 6)
        let zh = Scoring.errorRate(reference: "你好世界", hypothesis: "你好世间", language: "zh")
        XCTAssertEqual(zh.errors, 1); XCTAssertEqual(zh.total, 4)
        XCTAssertEqual(Scoring.errorRate(reference: "", hypothesis: "", language: "en").rate, 0)
        XCTAssertEqual(Scoring.errorRate(reference: "a b c", hypothesis: "", language: "en").rate, 1)
    }

    func testChecksAcceptAnyFormAndIgnoreDiacritics() {
        let checks = [Check(category: "name", sentence: 1, accept: ["ana beltrán"]),
                      Check(category: "number", sentence: 2, accept: ["1.5 million", "one point five million"]),
                      Check(category: "date", sentence: 3, accept: ["march 12th", "the twelfth of march"]),
                      Check(category: "negation", sentence: 4, accept: ["not before friday"])]
        let reference = "I spoke with Ana Beltrán.\nWe need one point five million.\nBy March twelfth.\nDefinitely not before Friday."
        let outcomes = Scoring.runChecks(checks, reference: reference, hypothesis: "I spoke with Ana Beltran. We need one point five million by March twelfth, and definitely before Friday.", language: "en")
        XCTAssertEqual(outcomes.map(\.passed), [true, true, true, false])
        XCTAssertEqual(outcomes[0].matched, "ana beltrán")
        XCTAssertEqual(outcomes[1].matched, "1.5 million", "digits and words normalize to the same form")
    }

    func testWordsAndDigitsMeetInTheSameTokens() {
        let pairs: [(String, String, String)] = [
            ("ten thirty", "10:30", "en"), ("ten thirty", "1030", "en"), ("zero seven five five", "0755", "en"), ("nineteen eighty", "1980", "en"),
            ("twenty-third", "23rd", "en"), ("forty-five percent", "45%", "en"), ("twelve dollars", "$12", "en"), ("minus four degrees", "-4 degrees", "en"),
            ("two hundred and five", "205", "en"), ("fourteen thousand", "14,000", "en"), ("three point five", "3.5", "en"), ("eleven fifteen", "11 15", "en"),
            ("cuarenta y cinco por ciento", "45%", "es"), ("doscientos cinco", "205", "es"), ("las diez treinta", "las 10:30", "es"), ("doce dólares", "$12", "es"),
            ("十点半", "10点半", "zh"), ("一万四千", "14000", "zh"), ("三月十二日", "3月12日", "zh"), ("一二一", "121", "zh"), ("二百零五", "205", "zh"),
        ]
        for (words, digits, language) in pairs {
            XCTAssertEqual(Normalizer.tokens(words, language: language), Normalizer.tokens(digits, language: language), "\(words) vs \(digits)")
        }
        XCTAssertEqual(Normalizer.normalize("nine eight", language: "en"), "9 8", "two numbers in a row are not added")
        XCTAssertEqual(Normalizer.normalize("six fifty-five", language: "en"), "6 5 5")
        XCTAssertEqual(Scoring.errorRate(reference: "at ten thirty", hypothesis: "at 10:30", language: "en").errors, 0)
        XCTAssertEqual(Scoring.errorRate(reference: "call 0755 121", hypothesis: "call 0755 131", language: "en").errors, 1, "one wrong digit is one error")
    }

    func testChecksMustMatchInsideTheirOwnSentence() {
        let reference = "Meet me at gate B twelve.\nIt costs twelve dollars.\nThe temperature is minus four."
        let checks = [Check(category: "number", sentence: 2, accept: ["$12"]), Check(category: "number", sentence: 1, accept: ["12"]),
                      Check(category: "number", sentence: 3, accept: ["-4"]), Check(category: "number", sentence: nil, accept: ["12"])]
        let outcomes = Scoring.runChecks(checks, reference: reference, hypothesis: "Meet me at gate B twelve. It costs nine dollars. The temperature is four.", language: "en")
        XCTAssertEqual(outcomes.map(\.passed), [false, true, false, true], "a form elsewhere in the transcript does not satisfy a sentence-scoped check; the sign counts")
        let dropped = Scoring.runChecks(checks, reference: reference, hypothesis: "Meet me at gate B twelve. The temperature is minus four.", language: "en")
        XCTAssertEqual(dropped.map(\.passed), [false, true, true, true], "a sentence the transcript skipped fails its checks")
    }
}
