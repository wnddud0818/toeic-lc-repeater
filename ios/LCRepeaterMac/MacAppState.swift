import AppKit
import Foundation
import Speech
import UniformTypeIdentifiers

extension UTType {
    static let lcrLesson = UTType(exportedAs: "com.firstghrn.lcrepeater.lesson", conformingTo: .data)
}

/// What the source-text card shows. It starts hidden for every new sentence.
enum CardFace: Equatable {
    case hidden, source, korean
    var next: CardFace {
        switch self {
        case .hidden: return .source
        case .source: return .korean
        case .korean: return .hidden
        }
    }
}

/// Window-level state shared by the main window, menus and the keyboard handler.
@MainActor
final class MacAppState: ObservableObject {
    static let shared = MacAppState()

    @Published var selectedLessonID: UUID?
    @Published var showingNewLesson = false
    @Published var newLessonAudio: URL?
    @Published var showingImporter = false
    @Published var cardFace = CardFace.hidden
    @Published var message: String?
    /// Files opened from Finder, the Dock or by dragging; handled by the main window.
    @Published var openRequests: [URL] = []
    weak var mainWindow: NSWindow?

    func open(_ urls: [URL]) { openRequests.append(contentsOf: urls) }

    func startNewLesson(with audio: URL? = nil) {
        newLessonAudio = audio
        showingNewLesson = true
    }

    /// Saves a .lcrlesson for the iPhone app and shows it in Finder (ready for AirDrop).
    func export(_ entry: LibraryEntry, library: LessonLibrary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.lcrLesson]
        panel.canCreateDirectories = true
        let safe = entry.lesson.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = (safe.isEmpty ? "레슨" : safe) + ".lcrlesson"
        panel.message = "아이폰으로 옮길 레슨 파일을 저장해요. AirDrop이나 iCloud Drive로 보내 주세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportArchive(entry.id, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = "내보내지 못했어요: \(error.localizedDescription)"
        }
    }

    /// Copies lessons made by the previous (Python/web) Mac app, once each.
    func importPreviousAppLessons(into library: LessonLibrary) async {
        let data = Engine.supportDirectory.appendingPathComponent("data", isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var imported = 0, failed = 0, already = 0
        for folder in folders {
            let key = "legacyImported." + folder.lastPathComponent
            let status = (try? JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("status.json")))) as? [String: Any]
            guard status?["stage"] as? String == "done",
                  let json = try? Data(contentsOf: folder.appendingPathComponent("lesson.json")),
                  let lesson = try? JSONDecoder().decode(Lesson.self, from: json) else { continue }
            if UserDefaults.standard.bool(forKey: key) { already += 1; continue }
            let audio = folder.appendingPathComponent("master.wav")
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).lcrlesson")
            defer { try? FileManager.default.removeItem(at: archive) }
            do {
                // Packing validates the lesson and the WAV format, exactly like a file from the PC app.
                try await Task.detached { try LessonArchive.pack(lesson: lesson, audio: audio, to: archive) }.value
                library.error = nil
                await library.importArchive(at: archive)
                if library.error != nil { failed += 1; continue }
                UserDefaults.standard.set(true, forKey: key)
                imported += 1
            } catch {
                failed += 1
            }
        }
        library.error = nil
        if imported + failed + already == 0 {
            message = "이전 맥 앱에서 처리한 레슨을 찾지 못했어요.\n(\(data.path))"
        } else {
            message = "이전 맥 앱 레슨 \(imported)개를 가져왔어요."
                + (already > 0 ? " \(already)개는 이미 가져온 레슨이에요." : "")
                + (failed > 0 ? " \(failed)개는 가져오지 못했어요." : "")
        }
    }
}

/// Whisper model, Claude Code and Apple on-device support, as shown in Settings and the new-lesson sheet.
@MainActor
final class EngineStatus: ObservableObject {
    @Published private(set) var helperBundled = Engine.isBundled
    @Published private(set) var modelReady = FileManager.default.fileExists(atPath: Engine.modelURL.path)
    @Published private(set) var claudePath: String?
    @Published private(set) var claudeChecked = false
    @Published private(set) var appleSpeech: [StudyLanguage: Bool] = [:]
    @Published private(set) var appleTranslation: [StudyLanguage: Bool] = [:]
    @Published private(set) var downloading = false
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var downloadError: String?
    private var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        helperBundled = Engine.isBundled
        modelReady = FileManager.default.fileExists(atPath: Engine.modelURL.path)
        for language in StudyLanguage.allCases {
            var speech = false
            if SpeechTranscriber.isAvailable {
                speech = await AppleSpeechTranscription.locale(for: language) != nil
            }
            appleSpeech[language] = speech
            appleTranslation[language] = await AppleLessonTranslator.unsupportedError(for: language) == nil
        }
        if helperBundled {
            // Finding claude may consult the login shell (npm, nvm), which takes a moment.
            claudePath = (try? await Engine.run(["status"]))?.claude
        }
        claudeChecked = true
    }

    func downloadModel() async {
        guard !downloading, !modelReady else { return }
        downloading = true
        downloadError = nil
        downloadFraction = nil
        defer { downloading = false }
        do {
            _ = try await Engine.run(["download-model"]) { event in
                self.downloadFraction = event.fraction
            }
        } catch {
            downloadError = error.localizedDescription
        }
        modelReady = FileManager.default.fileExists(atPath: Engine.modelURL.path)
    }
}
