import Foundation
import Speech
import AVFoundation

@available(iOS 26.0, *)
actor AppleSpeechTranscription {
    static func englishLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    func transcribe(audioURL: URL, duration: Double,
                    progress: @escaping @Sendable (Double) async -> Void) async throws -> [TimedTranscriptPiece] {
        guard SpeechTranscriber.isAvailable else { throw LocalLessonError.unsupportedDevice }
        guard let locale = await Self.englishLocale() else { throw LocalLessonError.unsupportedEnglish }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task { () throws -> [TimedTranscriptPiece] in
            var pieces: [TimedTranscriptPiece] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                var timed: [TimedTranscriptPiece] = []
                var needsFallback = false
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
                    else { needsFallback = true; break }
                    timed.append(.init(text: text, start: range.start.seconds,
                                       end: CMTimeRangeGetEnd(range).seconds))
                }
                if needsFallback || timed.isEmpty {
                    timed = [.init(text: String(result.text.characters), start: result.range.start.seconds,
                                   end: CMTimeRangeGetEnd(result.range).seconds)]
                }
                pieces.append(contentsOf: timed)
                await progress(min(1, CMTimeRangeGetEnd(result.range).seconds / duration))
            }
            return pieces
        }
        return try await withTaskCancellationHandler {
            do {
                let file = try AVAudioFile(forReading: audioURL)
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let pieces = try await resultTask.value
                try Task.checkCancellation()
                return pieces
            } catch {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await resultTask.value
                throw error
            }
        } onCancel: {
            resultTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
