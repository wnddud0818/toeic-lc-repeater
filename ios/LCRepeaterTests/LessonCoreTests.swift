import XCTest
import Foundation
import CryptoKit
@testable import LessonCore

final class LessonCoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testPythonExportImportsWithoutChangingAudioOrKorean() throws {
        guard let path = ProcessInfo.processInfo.environment["LCR_TEST_FIXTURE"] else {
            throw XCTSkip("Set LCR_TEST_FIXTURE to the output of tests/make_fixture.py")
        }
        let source = URL(fileURLWithPath: path)
        let lesson = try LessonArchive.unpack(from: source, into: folder.appendingPathComponent("imported"))
        XCTAssertEqual(lesson.title, "전달 확인 레슨")
        XCTAssertEqual(lesson.sentences[1].ko, "안녕하세요.")
        XCTAssertEqual(lesson.sentences[1].start, 0.5)
        let original = try Data(contentsOf: source)
        let size = Int(LessonArchive.littleEndian(original.subdata(in: 8..<16)))
        let audio = try Data(contentsOf: folder.appendingPathComponent("imported/master.wav"))
        XCTAssertEqual(audio, original.suffix(from: 16 + size))
    }

    func testRejectsTruncationAndUnexpectedTrailingBytes() throws {
        let valid = try archive()
        for bytes in [valid.prefix(6), valid.dropLast(), valid + Data([0])] {
            let file = folder.appendingPathComponent(UUID().uuidString)
            try Data(bytes).write(to: file)
            XCTAssertThrowsError(try LessonArchive.unpack(from: file, into: folder.appendingPathComponent(UUID().uuidString)))
        }
    }

    func testRejectsChangedAudio() throws {
        var changed = try archive()
        changed[changed.count - 1] ^= 1
        let file = folder.appendingPathComponent("changed.lcrlesson")
        try changed.write(to: file)
        XCTAssertThrowsError(try LessonArchive.unpack(from: file, into: folder.appendingPathComponent("out"))) { error in
            guard case LessonError.checksumMismatch = error else {
                return XCTFail("Expected checksum failure, got \(error)")
            }
        }
    }

    func testRejectsWrongAudioFormatEvenWithValidHash() throws {
        let file = folder.appendingPathComponent("bad-audio.lcrlesson")
        try archive(audio: Data(repeating: 0, count: 128)).write(to: file)
        XCTAssertThrowsError(try LessonArchive.unpack(from: file, into: folder.appendingPathComponent("out")))
    }

    func testRejectsUnsupportedVersionAndOversizedManifest() throws {
        let file = folder.appendingPathComponent("version.lcrlesson")
        try archive(version: 2).write(to: file)
        XCTAssertThrowsError(try LessonArchive.unpack(from: file, into: folder.appendingPathComponent("out")))
        var header = LessonArchive.magic
        header.appendLE(UInt64.max)
        try header.write(to: file)
        XCTAssertThrowsError(try LessonArchive.unpack(from: file, into: folder.appendingPathComponent("out")))
    }

    func testRejectsDuplicateIDsAndOutOfBoundsRanges() throws {
        var lesson = sample()
        lesson.sentences[1] = Sentence(i: 1, start: 0.5, end: 1.5, en: "Hello.", ko: "안녕.", kind: "content")
        XCTAssertThrowsError(try lesson.validate())
        lesson = sample()
        lesson.sentences[0].end = 3
        XCTAssertThrowsError(try lesson.validate())
    }

    func testExternalLessonIDIsNeverUsedAsAPath() throws {
        let original = sample()
        let lesson = Lesson(id: "../../outside", title: original.title, duration: original.duration,
                            created: original.created, sentences: original.sentences)
        let file = folder.appendingPathComponent("path.lcrlesson")
        try archive(lesson: lesson).write(to: file)
        let destination = folder.appendingPathComponent("safe")
        _ = try LessonArchive.unpack(from: file, into: destination)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)),
                       Set(["master.wav", "lesson.json"]))
    }

    func testRepeatCountAndNoGapAfterFinalRepetition() {
        var settings = StudySettings()
        settings.repetitions = 3
        var cursor = PlaybackCursor(lesson: sample(), settings: settings, sentenceID: 2)
        let steps = (0..<3).compactMap { _ in cursor.next() }
        XCTAssertEqual(steps.map(\.repetition), [1, 2, 3])
        XCTAssertEqual(steps.map(\.gapSeconds), [0.6, 0.6, 0])
        XCTAssertTrue(steps.last!.isFinal)
        XCTAssertNil(cursor.next())
    }

    func testAdvanceAndInstructionFiltering() {
        var settings = StudySettings()
        settings.repetitions = 2
        settings.advance = true
        settings.hideDirections = false
        var cursor = PlaybackCursor(lesson: sample(), settings: settings, sentenceID: 1)
        let steps = (0..<4).compactMap { _ in cursor.next() }
        XCTAssertEqual(steps.map { $0.sentence.i }, [1, 1, 2, 2])
        XCTAssertEqual(steps.map(\.gapSeconds), [0.6, 0.9, 0.6, 0])
        settings.hideDirections = true
        var filtered = PlaybackCursor(lesson: sample(), settings: settings, sentenceID: 1)
        XCTAssertEqual(filtered.next()?.sentence.i, 2)
    }

    func testInfiniteRepeatAndShadowingAtChangedSpeed() {
        var settings = StudySettings()
        settings.repetitions = 0
        settings.gap = -1
        settings.speed = 1.3
        settings.advance = true
        var cursor = PlaybackCursor(lesson: sample(), settings: settings, sentenceID: 2)
        for repetition in 1...1000 {
            let step = cursor.next()!
            XCTAssertEqual(step.sentence.i, 2)
            XCTAssertEqual(step.repetition, repetition)
            XCTAssertEqual(step.gapSeconds, 1 / 1.3, accuracy: 0.00001)
            XCTAssertFalse(step.isFinal)
        }
    }

    private func sample() -> Lesson {
        Lesson(id: "test", title: "테스트", duration: 2, created: 1700000000, sentences: [
            Sentence(i: 1, start: 0, end: 0.4, en: "Directions.", ko: "안내입니다.", kind: "direction"),
            Sentence(i: 2, start: 0.5, end: 1.5, en: "Hello, world.", ko: "안녕하세요.", kind: "content")
        ])
    }

    private func archive(lesson: Lesson? = nil, version: Int = 1, audio supplied: Data? = nil) throws -> Data {
        let audio = supplied ?? wav()
        let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let manifest = ArchiveManifest(format: "toeic-lc-repeater.lesson", version: version, lesson: lesson ?? sample(),
                                       audio: .init(format: "wav", byteCount: UInt64(audio.count), sha256: digest,
                                                    sampleRate: 32000, channels: 1, sampleWidth: 2))
        let json = try JSONEncoder().encode(manifest)
        var result = LessonArchive.magic
        result.appendLE(UInt64(json.count))
        result.append(json)
        result.append(audio)
        return result
    }

    private func wav() -> Data {
        var result = Data("RIFF".utf8)
        result.appendLE(UInt32(128_036))
        result.append(Data("WAVEfmt ".utf8))
        result.appendLE(UInt32(16)); result.appendLE(UInt16(1)); result.appendLE(UInt16(1))
        result.appendLE(UInt32(32_000)); result.appendLE(UInt32(64_000))
        result.appendLE(UInt16(2)); result.appendLE(UInt16(16))
        result.append(Data("data".utf8)); result.appendLE(UInt32(128_000))
        result.append(Data(repeating: 0, count: 128_000))
        return result
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
