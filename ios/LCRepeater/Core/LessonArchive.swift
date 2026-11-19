import Foundation
import CryptoKit

struct ArchiveManifest: Codable {
    let format: String
    let version: Int
    let lesson: Lesson
    let audio: Audio

    struct Audio: Codable {
        let format: String
        let byteCount: UInt64
        let sha256: String
        let sampleRate: Int
        let channels: Int
        let sampleWidth: Int
        enum CodingKeys: String, CodingKey {
            case format, sha256, channels
            case byteCount = "byte_count", sampleRate = "sample_rate", sampleWidth = "sample_width"
        }
    }
}

enum LessonArchive {
    /// Lesson files are `.lrlesson` (Listen & Repeat). Files saved before the rename, `.lcrlesson`,
    /// keep the same contents and still open. The internal format name stays unchanged so that
    /// older app versions can read new files.
    static let fileExtension = "lrlesson"
    static let fileExtensions: Set<String> = ["lrlesson", "lcrlesson"]
    static func isLessonFile(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

    static let magic = Data("LCRLESS1".utf8)
    static let maxManifest: UInt64 = 8 * 1024 * 1024
    static let maxAudio: UInt64 = 2 * 1024 * 1024 * 1024

    /// The caller owns the staging directory and removes it on failure.
    /// No archive-provided path is ever used as a filesystem path.
    static func unpack(from source: URL, into staging: URL) throws -> Lesson {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        try input.seek(toOffset: 0)
        guard try readExactly(input, count: 8) == magic else { throw LessonError.invalidArchive }
        let sizeData = try readExactly(input, count: 8)
        let manifestSize = littleEndian(sizeData)
        guard manifestSize > 0, manifestSize <= maxManifest,
              fileSize >= 16 + manifestSize else { throw LessonError.invalidArchive }
        let encoded = try readExactly(input, count: Int(manifestSize))
        let manifest: ArchiveManifest
        do {
            manifest = try JSONDecoder().decode(ArchiveManifest.self, from: encoded)
        } catch {
            throw LessonError.invalidArchive
        }
        guard manifest.format == "toeic-lc-repeater.lesson", manifest.version == 1 else {
            throw LessonError.unsupportedVersion
        }
        let audio = manifest.audio
        guard audio.format == "wav", audio.byteCount >= 44, audio.byteCount <= maxAudio,
              audio.sampleRate == 32_000, audio.channels == 1, audio.sampleWidth == 2,
              audio.sha256.count == 64,
              audio.sha256.allSatisfy({ $0.isHexDigit }),
              fileSize == 16 + manifestSize + audio.byteCount else { throw LessonError.invalidArchive }
        try manifest.lesson.validate()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let audioURL = staging.appendingPathComponent("master.wav")
        guard FileManager.default.createFile(atPath: audioURL.path, contents: nil) else {
            throw LessonError.invalidArchive
        }
        let output = try FileHandle(forWritingTo: audioURL)
        defer { try? output.close() }
        var hasher = SHA256()
        var remaining = audio.byteCount
        while remaining > 0 {
            let chunk = try readExactly(input, count: Int(min(remaining, 1024 * 1024)))
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        try output.synchronize()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == audio.sha256.lowercased() else { throw LessonError.checksumMismatch }
        let duration = try wavDuration(at: audioURL)
        guard abs(duration - manifest.lesson.duration) <= 0.05 else { throw LessonError.invalidAudio }
        try JSONEncoder().encode(manifest.lesson).write(
            to: staging.appendingPathComponent("lesson.json"), options: .atomic)
        return manifest.lesson
    }

    /// Writes the same format as export_lesson.py, so a lesson made on the Mac opens on iPhone.
    /// The destination is replaced only after the whole file has been written.
    static func pack(lesson: Lesson, audio audioURL: URL, to destination: URL) throws {
        try lesson.validate()
        let duration = try wavDuration(at: audioURL)
        guard abs(duration - lesson.duration) <= 0.05 else { throw LessonError.invalidAudio }
        let size = (try FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= 44, size <= maxAudio else { throw LessonError.invalidAudio }
        var hasher = SHA256()
        do {
            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let manifest = ArchiveManifest(format: "toeic-lc-repeater.lesson", version: 1, lesson: lesson,
                                       audio: .init(format: "wav", byteCount: size, sha256: digest,
                                                    sampleRate: 32_000, channels: 1, sampleWidth: 2))
        let encoded = try JSONEncoder().encode(manifest)
        guard UInt64(encoded.count) <= maxManifest else { throw LessonError.invalidLesson }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent("." + UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw LessonError.invalidArchive }
        do {
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            var header = magic
            withUnsafeBytes(of: UInt64(encoded.count).littleEndian) { header.append(contentsOf: $0) }
            try output.write(contentsOf: header + encoded)
            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            var written: UInt64 = 0
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                written += UInt64(chunk.count)
            }
            guard written == size else { throw LessonError.invalidAudio }
            try output.synchronize()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw LessonError.invalidArchive
            }
            data.append(chunk)
        }
        return data
    }

    static func littleEndian(_ bytes: Data) -> UInt64 {
        bytes.enumerated().reduce(0) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }

    /// Supports ordinary RIFF PCM WAV, including afconvert's extra RIFF chunks.
    private static func wavDuration(at url: URL) throws -> Double {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try readExactly(handle, count: 12)
        guard header.prefix(4) == Data("RIFF".utf8),
              header.suffix(4) == Data("WAVE".utf8),
              littleEndian(header.subdata(in: 4..<8)) + 8 <= size else { throw LessonError.invalidAudio }
        let riffEnd = littleEndian(header.subdata(in: 4..<8)) + 8
        var position: UInt64 = 12
        var validFormat = false
        var frames: UInt64?
        while position + 8 <= riffEnd {
            try handle.seek(toOffset: position)
            let chunk = try readExactly(handle, count: 8)
            let count = littleEndian(chunk.subdata(in: 4..<8))
            let start = position + 8
            guard start + count <= riffEnd else { throw LessonError.invalidAudio }
            if chunk.prefix(4) == Data("fmt ".utf8) {
                guard count >= 16 else { throw LessonError.invalidAudio }
                let fmt = try readExactly(handle, count: 16)
                guard littleEndian(fmt.subdata(in: 0..<2)) == 1,
                      littleEndian(fmt.subdata(in: 2..<4)) == 1,
                      littleEndian(fmt.subdata(in: 4..<8)) == 32_000,
                      littleEndian(fmt.subdata(in: 8..<12)) == 64_000,
                      littleEndian(fmt.subdata(in: 12..<14)) == 2,
                      littleEndian(fmt.subdata(in: 14..<16)) == 16 else { throw LessonError.invalidAudio }
                validFormat = true
            } else if chunk.prefix(4) == Data("data".utf8) {
                guard count > 0, count % 2 == 0, frames == nil else { throw LessonError.invalidAudio }
                frames = count / 2
            }
            position = start + count + count % 2
        }
        guard validFormat, let frames, position == riffEnd else { throw LessonError.invalidAudio }
        return Double(frames) / 32_000
    }
}
