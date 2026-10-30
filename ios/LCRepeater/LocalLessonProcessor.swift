import Foundation
import Combine
import Speech
import Translation

@available(iOS 26.0, *)
@MainActor
final class LocalLessonProcessor: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var status = "영어 음원을 선택해 주세요"
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sentenceCount = 0
    private var job: Task<UUID, Error>?
    private var id = UUID()
    private var staging: URL?
    private var prepared: PreparedLocalAudio?
    private var draft: Lesson?
    private var discardWhenFinished = false
    private var activeSession: TranslationSession?

    var canRetryTranslation: Bool { !isBusy && draft != nil }

    static func configuration() -> TranslationSession.Configuration {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ko")
        if #available(iOS 26.4, *) {
            return .init(source: source, target: target, preferredStrategy: .lowLatency)
        }
        // Prior to iOS 26.4, TranslationSession only uses traditional models.
        return .init(source: source, target: target)
    }

    static func availabilityError() async -> String? {
        guard SpeechTranscriber.isAvailable else { return LocalLessonError.unsupportedDevice.localizedDescription }
        guard await AppleSpeechTranscription.englishLocale() != nil else {
            return LocalLessonError.unsupportedEnglish.localizedDescription
        }
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
        else { availability = LanguageAvailability() }
        let status = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko"))
        return status == .unsupported ? LocalLessonError.unsupportedTranslation.localizedDescription : nil
    }

    func select(_ url: URL) {
        guard !isBusy else { return }
        discard()
        sourceURL = url
        error = nil
        status = "음원을 준비하고 있어요"
    }

    func run(session: TranslationSession, library: LessonLibrary) async -> UUID? {
        guard job == nil, sourceURL != nil else { return nil }
        isBusy = true
        error = nil
        activeSession = session
        let operation = Task { try await self.process(session: session, library: library) }
        job = operation
        defer {
            job = nil; activeSession = nil; isBusy = false; progress = nil
            if discardWhenFinished { discardWhenFinished = false; discard() }
        }
        do {
            return try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
        } catch is CancellationError {
            status = "처리를 취소했어요"
        } catch {
            self.error = error.localizedDescription
            status = draft == nil ? "레슨을 만들지 못했어요" : "번역을 마치지 못했어요"
        }
        return nil
    }

    private func process(session: TranslationSession, library: LessonLibrary) async throws -> UUID {
        guard let sourceURL else { throw LocalLessonError.invalidAudio }
        if let message = await Self.availabilityError() {
            throw NSError(domain: "LocalLesson", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        status = "영어·한국어 번역 모델을 준비하는 중이에요"
        progress = nil
        try await session.prepareTranslation()
        try Task.checkCancellation()
        if staging == nil { staging = try library.localStagingArea(for: id) }
        guard let staging else { throw LocalLessonError.invalidAudio }
        if prepared == nil {
            status = "음원을 준비하는 중이에요"
            prepared = try await LocalAudioPreparer().prepare(source: sourceURL, folder: staging) { fraction in
                await self.setProgress(fraction)
            }
        }
        guard let prepared else { throw LocalLessonError.invalidAudio }
        if draft == nil {
            status = "영어 전사 모델 준비·전사 중이에요"
            progress = nil
            let pieces = try await AppleSpeechTranscription().transcribe(audioURL: prepared.url, duration: prepared.duration) { fraction in
                await self.setTranscriptionProgress(fraction)
            }
            try Task.checkCancellation()
            let sentences = try TranscriptSegmenter.sentences(from: pieces, duration: prepared.duration)
            let name = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = Lesson(id: id.uuidString, title: name.isEmpty ? "새 레슨" : name,
                           duration: prepared.duration, created: Date().timeIntervalSince1970, sentences: sentences)
            sentenceCount = sentences.count
        }
        guard var lesson = draft else { throw LocalLessonError.noSpeech }
        status = "한국어로 번역하는 중이에요"
        let pending = lesson.sentences.indices.filter { lesson.sentences[$0].ko.isEmpty }
        for offset in stride(from: 0, to: pending.count, by: 20) {
            try Task.checkCancellation()
            let indices = Array(pending[offset..<min(offset + 20, pending.count)])
            let requests = indices.map { TranslationSession.Request(sourceText: lesson.sentences[$0].en,
                                                                      clientIdentifier: String(lesson.sentences[$0].i)) }
            let responses = try await session.translations(from: requests)
            let translations = try responses.map { response -> TranslatedSentence in
                guard let key = response.clientIdentifier, let id = Int(key) else {
                    throw LocalLessonError.incompleteTranslation
                }
                return .init(id: id, text: response.targetText)
            }
            lesson = try LessonTranslation.applying(translations, to: lesson, ids: indices.map { lesson.sentences[$0].i })
            draft = lesson
            progress = Double(lesson.sentences.filter { !$0.ko.isEmpty }.count) / Double(lesson.sentences.count)
        }
        try Task.checkCancellation()
        status = "레슨을 저장하는 중이에요"
        let entry = try library.finishLocalLesson(lesson, id: id, staging: staging)
        self.staging = nil
        self.draft = nil
        self.prepared = nil
        status = "레슨을 만들었어요"
        return entry.id
    }

    private func setProgress(_ fraction: Double) { progress = max(0, min(1, fraction)) }
    private func setTranscriptionProgress(_ fraction: Double) {
        status = "영어를 전사하는 중이에요"
        setProgress(fraction)
    }

    func cancel() {
        status = "취소하는 중이에요"
        progress = nil
        job?.cancel()
        activeSession?.cancel()
    }

    func stopAndDiscard() {
        if isBusy { discardWhenFinished = true; cancel() }
        else { discard() }
    }

    func discard() {
        guard !isBusy else { return }
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
        prepared = nil
        draft = nil
        sentenceCount = 0
        sourceURL = nil
        id = UUID()
    }
}
