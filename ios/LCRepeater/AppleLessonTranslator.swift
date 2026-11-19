import Foundation
import Translation

/// Apple's on-device translation of a lesson's missing translations, shared by iPhone and Mac.
@available(iOS 26.0, macOS 26.0, *)
enum AppleLessonTranslator {
    static func configuration(for language: StudyLanguage) -> TranslationSession.Configuration {
        let source = Locale.Language(identifier: language.rawValue)
        let target = Locale.Language(identifier: "ko")
        if #available(iOS 26.4, macOS 26.4, *) {
            return .init(source: source, target: target, preferredStrategy: .lowLatency)
        }
        // Prior to 26.4, TranslationSession only uses traditional models.
        return .init(source: source, target: target)
    }

    /// nil when the language pair can be translated on this device.
    static func unsupportedError(for language: StudyLanguage) async -> LocalLessonError? {
        let availability: LanguageAvailability
        if #available(iOS 26.4, macOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
        else { availability = LanguageAvailability() }
        let status = await availability.status(from: Locale.Language(identifier: language.rawValue),
                                               to: Locale.Language(identifier: "ko"))
        return status == .unsupported ? .unsupportedTranslation(language) : nil
    }

    /// Translates sentences whose translation is empty, 20 at a time. `update` receives each
    /// completed batch so a cancelled or failed run keeps the batches that already finished.
    @MainActor
    static func translateMissing(in lesson: Lesson, session: TranslationSession,
                                 update: @MainActor (Lesson) -> Void) async throws -> Lesson {
        var lesson = lesson
        let pending = lesson.sentences.indices.filter {
            lesson.sentences[$0].ko.isEmpty && !lesson.sentences[$0].en.trimmingCharacters(in: .whitespaces).isEmpty
        }
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
            update(lesson)
        }
        return lesson
    }
}
