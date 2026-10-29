import Foundation

struct Sentence: Codable, Equatable, Identifiable, Sendable {
    let i: Int
    var start: Double
    var end: Double
    var en: String
    var ko: String
    let kind: String
    var id: Int { i }
    var duration: Double { end - start }
}

struct Lesson: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    let duration: Double
    let created: Double
    var sentences: [Sentence]

    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite, duration > 0, created.isFinite,
              !sentences.isEmpty, sentences.count <= 50_000 else {
            throw LessonError.invalidLesson
        }
        var ids = Set<Int>()
        for sentence in sentences {
            guard sentence.i > 0, ids.insert(sentence.i).inserted,
                  sentence.start.isFinite, sentence.end.isFinite,
                  sentence.start >= 0, sentence.end > sentence.start,
                  sentence.end <= duration + 0.001, sentence.duration <= 120,
                  ["content", "direction"].contains(sentence.kind) else {
                throw LessonError.invalidSentence(sentence.i)
            }
        }
    }
}

enum LessonError: LocalizedError {
    case invalidLesson
    case invalidSentence(Int)
    case invalidArchive
    case unsupportedVersion
    case checksumMismatch
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .invalidLesson: return "레슨 정보가 올바르지 않아요. PC에서 다시 내보내 주세요."
        case .invalidSentence(let i): return "문장 \(i)의 구간이나 번호가 올바르지 않아요."
        case .invalidArchive: return "레슨 파일이 손상되었거나 지원하지 않는 형식이에요."
        case .unsupportedVersion: return "이 레슨 파일을 열려면 앱 업데이트가 필요해요."
        case .checksumMismatch: return "음원이 완전히 전달되지 않았어요. 파일을 다시 옮겨 주세요."
        case .invalidAudio: return "레슨과 음원이 일치하지 않아요. PC에서 다시 내보내 주세요."
        }
    }
}

struct StudySettings: Codable, Equatable, Sendable {
    var repetitions = 20  // 0 = infinite
    var gap = 0.6         // -1 = shadowing, otherwise seconds at the selected speed
    var speed = 1.0
    var advance = false
    var hideDirections = true

    var isValid: Bool {
        (0...100).contains(repetitions) && speed.isFinite && (0.7...1.3).contains(speed)
            && gap.isFinite && (gap == -1 || (0...3).contains(gap))
    }

    func sentences(in lesson: Lesson) -> [Sentence] {
        let filtered = lesson.sentences.filter { !hideDirections || $0.kind != "direction" }
        return filtered.isEmpty ? lesson.sentences : filtered
    }
}

struct PlaybackStep: Equatable {
    let sentence: Sentence
    let repetition: Int
    let gapSeconds: Double
    let isFinal: Bool
}

/// A deterministic plan. Actual audio and silence are scheduled on AVAudioPlayerNode;
/// a UI timer is never responsible for advancing the audio.
struct PlaybackCursor {
    private let sentences: [Sentence]
    private let settings: StudySettings
    private var position: Int
    private var repetition = 1
    private var finished = false

    init(lesson: Lesson, settings: StudySettings, sentenceID: Int?) {
        self.settings = settings
        sentences = settings.sentences(in: lesson)
        position = sentences.firstIndex { $0.i == sentenceID } ?? 0
    }

    mutating func next() -> PlaybackStep? {
        guard !finished, sentences.indices.contains(position), settings.isValid else { return nil }
        let sentence = sentences[position]
        let repeatAgain = settings.repetitions == 0 || repetition < settings.repetitions
        let nextSentence = !repeatAgain && settings.advance && position + 1 < sentences.count
        let gap = repeatAgain ? (settings.gap < 0 ? sentence.duration / settings.speed : settings.gap)
            : (nextSentence ? 0.9 : 0)
        let step = PlaybackStep(sentence: sentence, repetition: repetition,
                                gapSeconds: gap, isFinal: !repeatAgain && !nextSentence)
        if repeatAgain {
            repetition += 1
        } else if nextSentence {
            position += 1
            repetition = 1
        } else {
            finished = true
        }
        return step
    }
}
