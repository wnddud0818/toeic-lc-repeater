import Foundation
import Combine

struct LibraryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let importedAt: Date
    var lesson: Lesson
}

@MainActor
final class LessonLibrary: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var isImporting = false
    @Published var error: String?
    private let root: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = support.appendingPathComponent("LCRepeater/Lessons", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for folder in contents where folder.lastPathComponent.hasPrefix(".import-") {
                try? FileManager.default.removeItem(at: folder)
            }
            entries = contents.compactMap { folder in
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      let data = try? Data(contentsOf: folder.appendingPathComponent("entry.json")),
                      let entry = try? JSONDecoder().decode(LibraryEntry.self, from: data),
                      entry.id.uuidString == folder.lastPathComponent,
                      (try? entry.lesson.validate()) != nil,
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent("master.wav").path)
                else { return nil }
                return entry
            }.sorted { $0.importedAt > $1.importedAt }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            if let documents {
                try FileManager.default.createDirectory(
                    at: documents.appendingPathComponent("받은 레슨"), withIntermediateDirectories: true)
            }
        } catch {
            self.error = "레슨 보관함을 열지 못했어요: \(error.localizedDescription)"
        }
    }

    func audioURL(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("master.wav")
    }

    func entry(for id: UUID) -> LibraryEntry? { entries.first { $0.id == id } }

    func localStagingArea(for id: UUID) throws -> URL {
        let folder = root.appendingPathComponent(".import-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func finishLocalLesson(_ lesson: Lesson, id: UUID, staging: URL) throws -> LibraryEntry {
        // URL equality includes the directory/trailing-slash hint; compare path
        // components so the same folder stays valid before and after creation.
        guard staging.standardizedFileURL.pathComponents == root.appendingPathComponent(".import-" + id.uuidString, isDirectory: true).standardizedFileURL.pathComponents,
              FileManager.default.fileExists(atPath: staging.appendingPathComponent("master.wav").path)
        else { throw LessonError.invalidAudio }
        try lesson.validate()
        let entry = LibraryEntry(id: id, importedAt: Date(), lesson: lesson)
        try JSONEncoder().encode(entry).write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(id.uuidString))
        entries.insert(entry, at: 0)
        return entry
    }

    func importArchive(at url: URL) async {
        guard !isImporting else {
            error = "다른 레슨을 가져오는 중이에요. 완료 후 다시 열어 주세요."
            return
        }
        isImporting = true
        let id = UUID()
        let staging = root.appendingPathComponent(".import-" + id.uuidString)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: staging)
            isImporting = false
        }
        do {
            let lesson = try await Task.detached(priority: .userInitiated) {
                var coordinationError: NSError?
                var result: Result<Lesson, Error>?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges,
                                               error: &coordinationError) { coordinatedURL in
                    result = Result { try LessonArchive.unpack(from: coordinatedURL, into: staging) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw LessonError.invalidArchive }
                return try result.get()
            }.value
            let entry = LibraryEntry(id: id, importedAt: Date(), lesson: lesson)
            try JSONEncoder().encode(entry).write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(id.uuidString))
            entries.insert(entry, at: 0)
        } catch {
            self.error = "가져오지 못했어요: \(error.localizedDescription)"
        }
    }

    func updateRange(in id: UUID, sentenceID: Int, start: Double, end: Double) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let sentenceIndex = entries[index].lesson.sentences.firstIndex(where: { $0.i == sentenceID })
        else { throw LessonError.invalidLesson }
        var entry = entries[index]
        entry.lesson.sentences[sentenceIndex].start = (start * 1000).rounded() / 1000
        entry.lesson.sentences[sentenceIndex].end = (end * 1000).rounded() / 1000
        try entry.lesson.validate()
        try JSONEncoder().encode(entry).write(
            to: root.appendingPathComponent(id.uuidString).appendingPathComponent("entry.json"), options: .atomic)
        entries[index] = entry
    }

    func delete(_ id: UUID) {
        do {
            try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
            entries.removeAll { $0.id == id }
            UserDefaults.standard.removeObject(forKey: "sentence." + id.uuidString)
        } catch {
            self.error = "레슨을 삭제하지 못했어요: \(error.localizedDescription)"
        }
    }

    func savedSentence(for id: UUID) -> Int? {
        UserDefaults.standard.object(forKey: "sentence." + id.uuidString) as? Int
    }

    func savePosition(lessonID: UUID?, sentenceID: Int?) {
        guard let lessonID, let sentenceID else { return }
        UserDefaults.standard.set(sentenceID, forKey: "sentence." + lessonID.uuidString)
    }
}
