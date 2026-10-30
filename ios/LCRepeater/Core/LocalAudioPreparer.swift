import Foundation
import AVFoundation

struct PreparedLocalAudio: Sendable {
    let url: URL
    let duration: Double
}

actor LocalAudioPreparer {
    /// Copy provider-backed files while access is held, then stream to the existing lesson format.
    func prepare(source: URL, folder: URL,
                 progress: @Sendable (Double) async -> Void) async throws -> PreparedLocalAudio {
        let accessed = source.startAccessingSecurityScopedResource()
        let copy = folder.appendingPathComponent("source").appendingPathExtension(source.pathExtension)
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: copy)
        }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: .withoutChanges,
                                                       error: &coordinationError) { url in
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_073_741_824 else { throw LocalLessonError.audioTooLarge }
                try FileManager.default.copyItem(at: url, to: copy)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: copy, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard input.length > 0, input.processingFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 32_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: target),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8_192)
        else { throw LocalLessonError.invalidAudio }
        let duration = Double(input.length) / input.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw LocalLessonError.invalidAudio }
        guard duration * 64_000 + 4_096 <= Double(2 * 1_024 * 1_024 * 1_024) else { throw LocalLessonError.audioTooLarge }
        if input.processingFormat.channelCount > 1 { converter.downmix = true }
        let destination = folder.appendingPathComponent("master.wav")
        // Write buffers in exactly the file's PCM16/interleaved format. No second
        // implicit conversion inside AVAudioFile is needed.
        var output: AVAudioFile? = try AVAudioFile(forWriting: destination, settings: target.settings,
                                                  commonFormat: .pcmFormatInt16, interleaved: true)
        var readError: Error?
        var eof = false
        var lastProgress = -1
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { count, state in
                if eof { state.pointee = .endOfStream; return nil }
                do {
                    try input.read(into: inputBuffer, frameCount: min(count, inputBuffer.frameCapacity))
                    if inputBuffer.frameLength == 0 {
                        eof = true
                        state.pointee = .endOfStream
                        return nil
                    }
                    state.pointee = .haveData
                    return inputBuffer
                } catch {
                    readError = error
                    eof = true
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 { try output?.write(from: outputBuffer) }
            let percent = Int(Double(input.framePosition) / Double(input.length) * 100)
            if percent != lastProgress {
                lastProgress = percent
                await progress(min(1, Double(percent) / 100))
            }
            if status == .endOfStream { break }
            if status == .error { throw LocalLessonError.invalidAudio }
        }
        output = nil // Finalize the WAV header before transcription or moving the folder.
        let completed = try AVAudioFile(forReading: destination)
        guard completed.length > 0 else { throw LocalLessonError.invalidAudio }
        return .init(url: destination, duration: Double(completed.length) / completed.processingFormat.sampleRate)
    }
}
