import Foundation
import Speech
import Translation

/// How the audio is transcribed. Stored in UserDefaults by raw value.
enum TranscriptionChoice: String, CaseIterable, Identifiable {
    case apple, whisper
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple 기기 내 전사" : "Whisper" }
    var detail: String {
        self == .apple
            ? "macOS에 내장된 음성 인식. 빠르고 따로 받을 모델이 없어요(처음 한 번 언어 모델을 받아요)."
            : "기존 PC 버전과 같은 whisper.cpp 받아쓰기. 문장 경계가 더 정확한 편이고 음성 인식 모델(547MB)이 필요해요."
    }
}

/// How the sentences are translated into Korean.
enum TranslationChoice: String, CaseIterable, Identifiable {
    case apple, claude
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple 기기 내 번역" : "Claude (claude -p)" }
    var detail: String {
        self == .apple
            ? "인터넷 없이 이 Mac에서 번역해요. 처음 한 번 번역 언어를 내려받아요."
            : "Claude Code로 번역하면서 인식 오류를 고치고 시험 안내 문장을 구분해요. Claude Code 설치와 로그인이 필요해요."
    }
}

enum MacProcessingError: LocalizedError {
    case speechUnavailable(StudyLanguage)
    case translationUnavailable(StudyLanguage)

    var errorDescription: String? {
        switch self {
        case .speechUnavailable(let language):
            return "이 Mac에서는 \(language.name) Apple 기기 내 전사를 쓸 수 없어요. 전사 방식을 Whisper로 바꿔 주세요."
        case .translationUnavailable(let language):
            return "이 Mac에서는 \(language.name)→한국어 Apple 번역을 쓸 수 없어요. 번역 방식을 Claude로 바꿔 주세요."
        }
    }
}

/// `claude -p` translation through the engine. Sentence numbers and times never change.
enum ClaudeTranslator {
    static func translate(_ lesson: Lesson, onlyMissing: Bool,
                          onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Lesson {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lcr-translate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("lesson.json")
        try JSONEncoder().encode(lesson).write(to: file, options: .atomic)
        _ = try await Engine.run(["translate", file.path]) { event in
            if let fraction = event.fraction { onProgress(fraction) }
        }
        let translated = try JSONDecoder().decode(Lesson.self, from: Data(contentsOf: file))
        return merge(translated, into: lesson, onlyMissing: onlyMissing)
    }

    /// Takes Claude's text, translation and sentence kind; keeps everything else from the original.
    static func merge(_ translated: Lesson, into lesson: Lesson, onlyMissing: Bool) -> Lesson {
        var result = lesson
        let byID = Dictionary(translated.sentences.map { ($0.i, $0) }, uniquingKeysWith: { first, _ in first })
        for index in result.sentences.indices {
            let original = result.sentences[index]
            guard let new = byID[original.i], !new.ko.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !onlyMissing || original.ko.isEmpty else { continue }
            let text = new.en.trimmingCharacters(in: .whitespacesAndNewlines)
            result.sentences[index] = Sentence(
                i: original.i, start: original.start, end: original.end,
                en: text.isEmpty ? original.en : text, ko: new.ko.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: ["content", "direction"].contains(new.kind) ? new.kind : original.kind)
        }
        return result
    }
}

/// Makes one lesson from an audio file: transcription (Apple or Whisper), then translation
/// (Apple or Claude). A transcribed draft survives a failed translation so it can be retried
/// with either translator or saved without translations.
@MainActor
final class LessonBuilder: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var status = "음원 파일을 골라 주세요"
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var sentenceCount = 0
    @Published private(set) var hasDraft = false

    private(set) var language = StudyLanguage.english
    private(set) var transcription = TranscriptionChoice.apple
    private var draft: Lesson? { didSet { hasDraft = draft != nil } }
    private var staging: URL?
    private var id = UUID()
    private var job: Task<UUID, Error>?
    private var activeSession: TranslationSession?
    private var discardWhenFinished = false

    func select(_ url: URL) {
        guard !isBusy else { return }
        discard()
        sourceURL = url
        error = nil
        status = "준비됐어요. ‘만들기’를 누르세요"
    }

    /// A different language or transcriber needs a new transcription, so the draft is dropped.
    func configure(language: StudyLanguage, transcription: TranscriptionChoice) {
        guard !isBusy else { return }
        if (language != self.language || transcription != self.transcription) && (draft != nil || staging != nil) {
            let source = sourceURL
            discard()
            sourceURL = source
            status = source == nil ? "음원 파일을 골라 주세요" : "준비됐어요. ‘만들기’를 누르세요"
        }
        self.language = language
        self.transcription = transcription
    }

    /// Returns the new library entry's ID, or nil when it failed or was cancelled.
    func run(translation: TranslationChoice, session: TranslationSession?, library: LessonLibrary,
             folderID: UUID? = nil) async -> UUID? {
        guard job == nil, sourceURL != nil else { return nil }
        isBusy = true
        error = nil
        activeSession = session
        let operation = Task {
            try await self.process(translation: translation, session: session, library: library, folderID: folderID)
        }
        job = operation
        defer {
            job = nil; activeSession = nil; isBusy = false; progress = nil
            if discardWhenFinished { discardWhenFinished = false; discard() }
        }
        do {
            return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        } catch is CancellationError {
            status = "처리를 취소했어요"
        } catch {
            self.error = error.localizedDescription
            status = draft == nil ? "레슨을 만들지 못했어요" : "받아쓰기는 끝났지만 번역을 마치지 못했어요"
        }
        return nil
    }

    func saveWithoutTranslation(library: LessonLibrary, folderID: UUID? = nil) -> UUID? {
        guard !isBusy, let draft else { return nil }
        do { return try finish(draft, library: library, folderID: folderID) }
        catch { self.error = error.localizedDescription; return nil }
    }

    func cancel() {
        status = "취소하는 중이에요"
        progress = nil
        job?.cancel()
        activeSession?.cancel()
    }

    func stopAndDiscard() {
        if isBusy { discardWhenFinished = true; cancel() } else { discard() }
    }

    func discard() {
        guard !isBusy else { return }
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
        draft = nil
        sentenceCount = 0
        sourceURL = nil
        id = UUID()
    }

    // MARK: - Steps

    private func process(translation: TranslationChoice, session: TranslationSession?,
                         library: LessonLibrary, folderID: UUID?) async throws -> UUID {
        guard let sourceURL else { throw LocalLessonError.invalidAudio }
        if staging == nil { staging = try library.localStagingArea(for: id) }
        guard let staging else { throw LocalLessonError.invalidAudio }
        if draft == nil {
            let made: Lesson
            switch transcription {
            case .apple: made = try await transcribeWithApple(sourceURL, staging: staging)
            case .whisper: made = try await transcribeWithWhisper(sourceURL, staging: staging)
            }
            try Task.checkCancellation()
            draft = made
            sentenceCount = made.sentences.count
        }
        guard var lesson = draft else { throw LocalLessonError.noSpeech }
        switch translation {
        case .apple:
            guard let session else { throw LocalLessonError.incompleteTranslation }
            if await AppleLessonTranslator.unsupportedError(for: language) != nil {
                throw MacProcessingError.translationUnavailable(language)
            }
            status = "\(language.name)→한국어 번역 모델을 준비하는 중이에요"
            progress = nil
            try await session.prepareTranslation()
            status = "Apple 기기 내 번역 중이에요"
            lesson = try await AppleLessonTranslator.translateMissing(in: lesson, session: session) { updated in
                self.draft = updated
                self.progress = Double(updated.sentences.filter { !$0.ko.isEmpty }.count) / Double(updated.sentences.count)
            }
        case .claude:
            status = "Claude로 번역하는 중이에요"
            progress = 0
            lesson = try await ClaudeTranslator.translate(lesson, onlyMissing: true) { fraction in
                self.progress = fraction
            }
            draft = lesson
        }
        try Task.checkCancellation()
        return try finish(lesson, library: library, folderID: folderID)
    }

    private func transcribeWithApple(_ source: URL, staging: URL) async throws -> Lesson {
        guard SpeechTranscriber.isAvailable, await AppleSpeechTranscription.locale(for: language) != nil else {
            throw MacProcessingError.speechUnavailable(language)
        }
        status = "음원을 준비하는 중이에요"
        let prepared = try await LocalAudioPreparer().prepare(source: source, folder: staging) { fraction in
            await self.setProgress(fraction)
        }
        status = "\(language.name) 전사 모델을 준비하는 중이에요"
        progress = nil
        let pieces = try await AppleSpeechTranscription().transcribe(audioURL: prepared.url, duration: prepared.duration,
                                                                     language: language) { fraction in
            await self.setTranscriptionProgress(fraction)
        }
        try Task.checkCancellation()
        let sentences = try TranscriptSegmenter.sentences(from: pieces, duration: prepared.duration, language: language)
        return Lesson(id: id.uuidString, title: title(for: source), duration: prepared.duration,
                      created: Date().timeIntervalSince1970, sentences: sentences, lang: language.rawValue)
    }

    private func transcribeWithWhisper(_ source: URL, staging: URL) async throws -> Lesson {
        let work = staging.appendingPathComponent("whisper", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        status = "Whisper를 준비하는 중이에요"
        progress = 0
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let done = try await Engine.run(["transcribe", source.path, "--lang", language.rawValue,
                                         "--work", work.path, "--title", title(for: source)]) { event in
            if let label = event.label { self.status = "Whisper · " + label }
            if event.fraction != nil { self.progress = event.fraction }
        }
        guard let lessonPath = done.lesson, let audioPath = done.audio else { throw LocalLessonError.noSpeech }
        let made = try JSONDecoder().decode(Lesson.self, from: Data(contentsOf: URL(fileURLWithPath: lessonPath)))
        let master = staging.appendingPathComponent("master.wav")
        try? FileManager.default.removeItem(at: master)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: audioPath), to: master)
        return Lesson(id: id.uuidString, title: made.title, duration: made.duration,
                      created: Date().timeIntervalSince1970, sentences: made.sentences, lang: language.rawValue)
    }

    private func finish(_ lesson: Lesson, library: LessonLibrary, folderID: UUID?) throws -> UUID {
        guard let staging else { throw LocalLessonError.invalidAudio }
        status = "레슨을 저장하는 중이에요"
        // Only the player audio moves into the library folder.
        for item in (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent != "master.wav" {
            try? FileManager.default.removeItem(at: item)
        }
        let entry = try library.finishLocalLesson(lesson, id: id, staging: staging, folderID: folderID)
        self.staging = nil
        draft = nil
        sourceURL = nil
        id = UUID()
        status = "레슨을 만들었어요"
        return entry.id
    }

    private func title(for source: URL) -> String {
        let name = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "새 레슨" : name
    }

    private func setProgress(_ fraction: Double) { progress = max(0, min(1, fraction)) }
    private func setTranscriptionProgress(_ fraction: Double) {
        status = "\(language.name)를 전사하는 중이에요"
        setProgress(fraction)
    }
}

/// Several audio files made into lessons one after another with the same options.
/// A failed file does not stop the rest; it can be retried or saved without translations afterwards.
@MainActor
final class LessonQueue: ObservableObject {
    @MainActor
    final class Item: ObservableObject, Identifiable {
        enum Outcome: Equatable {
            case waiting, running, done(UUID), failed(String)
        }

        let id = UUID()
        let url: URL
        let builder = LessonBuilder()
        @Published fileprivate(set) var outcome = Outcome.waiting

        init(url: URL) {
            self.url = url
            builder.select(url)
        }

        var lessonID: UUID? {
            if case .done(let id) = outcome { return id }
            return nil
        }
        var isFailed: Bool {
            if case .failed = outcome { return true }
            return false
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    private var stopRequested = false
    private weak var current: Item?

    var finishedIDs: [UUID] { items.compactMap(\.lessonID) }
    var remaining: [Item] { items.filter { $0.outcome == .waiting || $0.isFailed } }
    var failedCount: Int { items.filter(\.isFailed).count }
    /// Failed after transcription: these can still be saved without translations.
    var draftsAwaitingTranslation: [Item] { items.filter { $0.isFailed && $0.builder.hasDraft } }
    var allDone: Bool { !items.isEmpty && items.allSatisfy { $0.lessonID != nil } }

    func add(_ urls: [URL], language: StudyLanguage, transcription: TranscriptionChoice) {
        guard !isRunning else { return }
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = Item(url: url)
            item.builder.configure(language: language, transcription: transcription)
            items.append(item)
        }
    }

    func remove(_ item: Item) {
        guard !isRunning || item !== current else { return }
        item.builder.discard()
        items.removeAll { $0 === item }
    }

    func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { $0.lessonID != nil }
    }

    /// New options apply to files not yet made; a changed language or transcriber drops their drafts.
    func configure(language: StudyLanguage, transcription: TranscriptionChoice) {
        guard !isRunning else { return }
        for item in items where item.lessonID == nil {
            item.builder.configure(language: language, transcription: transcription)
        }
    }

    func run(translation: TranslationChoice, session: TranslationSession?, library: LessonLibrary,
             folderID: UUID?) async {
        guard !isRunning else { return }
        isRunning = true
        stopRequested = false
        defer { isRunning = false; current = nil }
        for item in remaining {
            if stopRequested || Task.isCancelled { break }
            current = item
            item.outcome = .running
            if let id = await item.builder.run(translation: translation, session: session, library: library,
                                               folderID: folderID) {
                item.outcome = .done(id)
            } else if stopRequested || Task.isCancelled {
                item.outcome = .waiting   // Cancelled: a finished transcription is kept for next time.
                break
            } else {
                item.outcome = .failed(item.builder.error ?? "처리하지 못했어요")
            }
        }
    }

    func cancel() {
        stopRequested = true
        current?.builder.cancel()
    }

    func saveDraftsWithoutTranslation(library: LessonLibrary, folderID: UUID?) {
        guard !isRunning else { return }
        for item in draftsAwaitingTranslation {
            if let id = item.builder.saveWithoutTranslation(library: library, folderID: folderID) {
                item.outcome = .done(id)
            }
        }
    }

    func discardAll() {
        for item in items { item.builder.stopAndDiscard() }
    }
}
