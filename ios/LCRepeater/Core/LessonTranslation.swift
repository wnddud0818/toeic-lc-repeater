import Foundation

struct TranslatedSentence: Sendable {
    let id: Int
    let text: String
}

enum LessonTranslation {
    /// Responses may arrive out of order. Reject incomplete batches before changing a draft.
    static func applying(_ translations: [TranslatedSentence], to lesson: Lesson, ids: [Int]) throws -> Lesson {
        guard Set(ids).count == ids.count, translations.count == ids.count,
              Set(translations.map(\.id)) == Set(ids) else { throw LocalLessonError.incompleteTranslation }
        var byID: [Int: String] = [:]
        for translation in translations {
            let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard byID[translation.id] == nil, !text.isEmpty else { throw LocalLessonError.incompleteTranslation }
            byID[translation.id] = text
        }
        var result = lesson
        for id in ids {
            guard let index = result.sentences.firstIndex(where: { $0.i == id }), let text = byID[id]
            else { throw LocalLessonError.incompleteTranslation }
            result.sentences[index].ko = text
        }
        return result
    }
}
