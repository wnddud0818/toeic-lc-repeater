import XCTest
import AVFoundation
@testable import LessonCore

final class LocalAudioTests: XCTestCase {
    func testStereo48kWavBecomesPCM16Mono32kIncludingRightChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-음원")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("입력.wav")
        try makeAudio(at: source, aac: false)
        let folder = root.appendingPathComponent("converted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prepared = try await LocalAudioPreparer().prepare(source: source, folder: folder) { _ in }
        let output = try AVAudioFile(forReading: prepared.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(output.processingFormat.sampleRate, 32_000)
        XCTAssertEqual(output.processingFormat.channelCount, 1)
        XCTAssertEqual(output.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(Double(output.length), 64_000, accuracy: 1)
        XCTAssertEqual(prepared.duration, 2, accuracy: 0.001)
        let samples = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 4096)!
        try output.read(into: samples)
        let values = UnsafeBufferPointer(start: samples.floatChannelData![0], count: Int(samples.frameLength))
        XCTAssertGreaterThan(values.map { abs($0) }.max() ?? 0, 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("source.wav").path))
    }

    func testM4AAlsoDecodesToThePlayerFormat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input.m4a")
        try makeAudio(at: source, aac: true)
        let folder = root.appendingPathComponent("converted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prepared = try await LocalAudioPreparer().prepare(source: source, folder: folder) { _ in }
        let output = try AVAudioFile(forReading: prepared.url)
        XCTAssertEqual(output.processingFormat.sampleRate, 32_000)
        XCTAssertEqual(output.processingFormat.channelCount, 1)
        XCTAssertEqual(output.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(prepared.duration, 2, accuracy: 0.1)
    }

    func testMP3DecodesWithKoreanUppercaseAndGenericFilenames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "mp3", subdirectory: "Fixtures"))
        for name in ["토익 음원.mp3", "토익 음원.MP3", "일반 파일.bin"] {
            // macOS test volumes can be case-insensitive; isolate each case.
            let sourceFolder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            let source = sourceFolder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixture, to: source)
            let folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let prepared = try await LocalAudioPreparer().prepare(source: source, folder: folder) { _ in }
            let output = try AVAudioFile(forReading: prepared.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            XCTAssertEqual(output.processingFormat.sampleRate, 32_000, name)
            XCTAssertEqual(output.processingFormat.channelCount, 1, name)
            XCTAssertEqual(output.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16, name)
            XCTAssertEqual(prepared.duration, 1, accuracy: 0.1, name)
            let samples = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 4096)!
            try output.read(into: samples)
            let values = UnsafeBufferPointer(start: samples.floatChannelData![0], count: Int(samples.frameLength))
            XCTAssertGreaterThan(values.map { abs($0) }.max() ?? 0, 0.01, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("source").appendingPathExtension(source.pathExtension).path), name)
        }
    }

    func testNonAudioAndCorruptMP3HaveReadableErrorAndCleanUpCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["notes.txt", "broken.mp3"] {
            let source = root.appendingPathComponent(name)
            try Data("This is not audio.".utf8).write(to: source)
            let folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                _ = try await LocalAudioPreparer().prepare(source: source, folder: folder) { _ in }
                XCTFail("Non-audio file should be rejected: \(name)")
            } catch LocalLessonError.invalidAudio { }
            catch { XCTFail("Unexpected error for \(name): \(error)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }
    }

    func testDirectoryIsRejectedWithoutCopyingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("folder.mp3", isDirectory: true)
        let folder = root.appendingPathComponent("converted", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            _ = try await LocalAudioPreparer().prepare(source: source, folder: folder) { _ in }
            XCTFail("Directory should be rejected")
        } catch LocalLessonError.invalidAudio { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testCancellationDoesNotLeaveProviderCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input.wav")
        try makeAudio(at: source, aac: false)
        let folder = root.appendingPathComponent("converted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalAudioPreparer().prepare(source: source, folder: folder) { _ in }
        }
        do { _ = try await operation.value; XCTFail("Cancelled conversion should stop") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("source.wav").path))
    }

    private func makeAudio(at url: URL, aac: Bool) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for index in 0..<96_000 {
            buffer.floatChannelData![0][index] = 0
            buffer.floatChannelData![1][index] = Float(0.5 * sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        var settings: [String: Any] = [AVFormatIDKey: aac ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM,
                                      AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]
        if aac { settings[AVEncoderBitRateKey] = 128_000 }
        else {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
