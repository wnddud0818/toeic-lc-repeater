import Foundation

struct TimedTranscriptPiece: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// Keep Apple's audio times; only interpolate when one timed run contains several words.
/// This module has no model/network dependency and is shared with the contract tests.
enum TranscriptSegmenter {
    static func sentences(from pieces: [TimedTranscriptPiece], duration: Double) throws -> [Sentence] {
        guard duration.isFinite, duration > 0 else { throw LessonError.invalidAudio }
        let expression = try NSRegularExpression(pattern: #"\S+"#)
        var words: [TimedTranscriptPiece] = []
        for piece in pieces {
            guard piece.start.isFinite, piece.end.isFinite,
                  piece.start >= 0, piece.end > piece.start, piece.start < duration else { continue }
            let ns = piece.text as NSString
            let matches = expression.matches(in: piece.text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let start = piece.start + (piece.end - piece.start) * Double(match.range.location) / Double(max(1, ns.length))
                let end = piece.start + (piece.end - piece.start) * Double(NSMaxRange(match.range)) / Double(max(1, ns.length))
                if min(duration, end) > start {
                    words.append(.init(text: ns.substring(with: match.range), start: start, end: min(duration, end)))
                }
            }
        }
        words.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var groups: [[TimedTranscriptPiece]] = []
        var current: [TimedTranscriptPiece] = []
        for word in words {
            if let first = current.first, let last = current.last,
               word.end - first.start > 10 || word.start - last.end >= 0.65 {
                groups.append(current)
                current = []
            }
            current.append(word)
            if endsSentence(word.text), current.count > 1 || !isChoice(word.text) {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        var result: [Sentence] = []
        for (index, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let previousEnd = index > 0 ? (groups[index - 1].last?.end ?? 0) : 0
            let nextStart = index + 1 < groups.count ? (groups[index + 1].first?.start ?? duration) : duration
            let start = max(0, max(first.start - 0.08, min(first.start, previousEnd)))
            let end = min(duration, min(last.end + 0.12, max(last.end, nextStart)))
            guard end > start else { continue }
            let text = group.map(\.text).joined(separator: " ")
            result.append(.init(i: result.count + 1, start: start, end: end, en: text, ko: "",
                                kind: isDirection(text) ? "direction" : "content"))
        }
        guard !result.isEmpty else { throw LocalLessonError.noSpeech }
        guard result.count <= 50_000 else { throw LessonError.invalidLesson }
        return result
    }

    private static func isChoice(_ text: String) -> Bool {
        text.range(of: #"^\(?[A-D][.)]$"#, options: .regularExpression) != nil
    }

    private static func endsSentence(_ text: String) -> Bool {
        let abbreviations = ["mr.", "mrs.", "ms.", "dr.", "st.", "jr.", "sr.", "a.m.", "p.m.", "e.g.", "i.e.", "no."]
        return !abbreviations.contains(text.lowercased()) && !isChoice(text)
            && text.range(of: #"[.!?][\"')\]]*$"#, options: .regularExpression) != nil
    }

    private static func isDirection(_ text: String) -> Bool {
        text.lowercased().range(of: #"^(directions\b|part\s+(one|two|three|four|[1-4])\b|number\s+\d+\b|questions?\s+\d+.*(through|refer)|listen\s+to\s+the\s+(following|conversation|talk)|look\s+at\s+the\s+(picture|photograph))"#,
                               options: .regularExpression) != nil
    }
}

enum LocalLessonError: LocalizedError {
    case unsupportedDevice, unsupportedEnglish, unsupportedTranslation, noSpeech, invalidAudio, audioTooLarge
    case incompleteTranslation

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice: return "이 기기는 애플의 기기 내 전사 기능을 지원하지 않아요. 컴퓨터에서 준비한 레슨을 가져와 주세요."
        case .unsupportedEnglish: return "이 기기에서 영어 전사 모델을 사용할 수 없어요."
        case .unsupportedTranslation: return "이 기기에서 영어→한국어 번역 모델을 사용할 수 없어요."
        case .noSpeech: return "영어 음성을 찾지 못했어요. 다른 음원으로 다시 시도해 주세요."
        case .invalidAudio: return "이 음원을 읽을 수 없어요. MP3, M4A, WAV 파일로 다시 선택해 주세요."
        case .audioTooLarge: return "처리할 음원이 너무 커요. 원본은 1GB, 변환된 음원은 2GB 이하여야 해요."
        case .incompleteTranslation: return "일부 문장의 번역을 받지 못했어요. 번역을 다시 시도해 주세요."
        }
    }
}
