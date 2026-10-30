import XCTest
@testable import LessonCore

final class LocalLessonTests: XCTestCase {
    func testUsesAudioTimesAndKeepsEnglishWithPunctuation() throws {
        let sentences = try TranscriptSegmenter.sentences(from: [
            .init(text: "Would", start: 1, end: 1.2), .init(text: "you like", start: 1.2, end: 1.6),
            .init(text: "a window seat?", start: 1.6, end: 2.5),
            .init(text: "Yes, please.", start: 3, end: 3.6)
        ], duration: 5)
        XCTAssertEqual(sentences.map(\.en), ["Would you like a window seat?", "Yes, please."])
        XCTAssertEqual(sentences[0].start, 0.92, accuracy: 0.001)
        XCTAssertEqual(sentences[0].end, 2.62, accuracy: 0.001)
        XCTAssertEqual(sentences.map(\.i), [1, 2])
        XCTAssertTrue(sentences.allSatisfy { $0.ko.isEmpty && $0.kind == "content" })
    }

    func testChoiceLettersAndAbbreviationsStayWithTheirSentence() throws {
        let sentences = try TranscriptSegmenter.sentences(from: [
            .init(text: "A. Mr. Smith is waiting.", start: 0, end: 2),
            .init(text: "Directions.", start: 3, end: 4)
        ], duration: 4)
        XCTAssertEqual(sentences.map(\.en), ["A. Mr. Smith is waiting.", "Directions."])
        XCTAssertEqual(sentences[1].kind, "direction")
        XCTAssertEqual(sentences.last?.end, 4)
    }

    func testLongUnpunctuatedAudioSplitsAtWordBoundaries() throws {
        let pieces = (0..<35).map { TimedTranscriptPiece(text: "word\($0)", start: Double($0), end: Double($0) + 0.8) }
        let sentences = try TranscriptSegmenter.sentences(from: pieces, duration: 35)
        XCTAssertGreaterThan(sentences.count, 1)
        XCTAssertTrue(sentences.allSatisfy { $0.duration <= 10.2 })
        XCTAssertEqual(sentences.map(\.en).joined(separator: " "), pieces.map(\.text).joined(separator: " "))
    }

    func testSilenceSplitsUnpunctuatedSpeechAndInvalidTimesAreIgnored() throws {
        let sentences = try TranscriptSegmenter.sentences(from: [
            .init(text: "invalid", start: .nan, end: 1),
            .init(text: "Hello", start: 0, end: 0.4),
            .init(text: "world", start: 1.2, end: 1.8)
        ], duration: 2)
        XCTAssertEqual(sentences.map(\.en), ["Hello", "world"])
        XCTAssertThrowsError(try TranscriptSegmenter.sentences(from: [], duration: 2))
    }

    func testTranslationMatchesIDsWhenResponsesAreReordered() throws {
        let lesson = sample()
        let updated = try LessonTranslation.applying([.init(id: 2, text: "둘"), .init(id: 1, text: "하나")],
                                                     to: lesson, ids: [1, 2])
        XCTAssertEqual(updated.sentences.map(\.ko), ["하나", "둘"])
        XCTAssertEqual(updated.sentences.map(\.en), lesson.sentences.map(\.en))
        XCTAssertEqual(updated.sentences.map(\.start), lesson.sentences.map(\.start))
        XCTAssertTrue(lesson.sentences.allSatisfy { $0.ko.isEmpty })
    }

    func testMissingDuplicateOrBlankTranslationCannotPartiallyChangeDraft() throws {
        let lesson = sample()
        let batches: [[TranslatedSentence]] = [[], [.init(id: 1, text: "하나")],
            [.init(id: 1, text: "하나"), .init(id: 1, text: "둘")],
            [.init(id: 1, text: "하나"), .init(id: 2, text: " ")]]
        for batch in batches {
            XCTAssertThrowsError(try LessonTranslation.applying(batch, to: lesson, ids: [1, 2]))
        }
        XCTAssertTrue(lesson.sentences.allSatisfy { $0.ko.isEmpty })
    }

    private func sample() -> Lesson {
        .init(id: "local", title: "Local", duration: 3, created: 1, sentences: [
            .init(i: 1, start: 0, end: 1, en: "One.", ko: "", kind: "content"),
            .init(i: 2, start: 2, end: 3, en: "Two.", ko: "", kind: "content")])
    }
}
