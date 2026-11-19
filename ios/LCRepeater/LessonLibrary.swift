import Foundation
import Combine

struct LibraryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let importedAt: Date
    var lesson: Lesson
    /// nil = not in a folder (and every lesson saved before folders existed).
    var folderID: UUID? = nil
}

@MainActor
final class LessonLibrary: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var folders: [LessonFolder] = []
    @Published private(set) var isImporting = false
    @Published var error: String?
    private let root: URL
    private var foldersURL: URL { root.appendingPathComponent("folders.json") }

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
            if let data = try? Data(contentsOf: foldersURL),
               let saved = try? JSONDecoder().decode([LessonFolder].self, from: data) {
                folders = LessonFolders.sorted(saved)
            }
            // A lesson whose folder no longer exists shows up as "not in a folder".
            let known = Set(folders.map(\.id))
            for index in entries.indices where entries[index].folderID.map({ !known.contains($0) }) == true {
                entries[index].folderID = nil
            }
            #if os(iOS)
            // Shown in the Files app (UIFileSharingEnabled) as a place to drop lesson files.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            if let documents {
                try FileManager.default.createDirectory(
                    at: documents.appendingPathComponent("받은 레슨"), withIntermediateDirectories: true)
            }
            #endif
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

    func finishLocalLesson(_ lesson: Lesson, id: UUID, staging: URL, folderID: UUID? = nil) throws -> LibraryEntry {
        // URL equality includes the directory/trailing-slash hint; compare path
        // components so the same folder stays valid before and after creation.
        guard staging.standardizedFileURL.pathComponents == root.appendingPathComponent(".import-" + id.uuidString, isDirectory: true).standardizedFileURL.pathComponents,
              FileManager.default.fileExists(atPath: staging.appendingPathComponent("master.wav").path)
        else { throw LessonError.invalidAudio }
        try lesson.validate()
        let entry = LibraryEntry(id: id, importedAt: Date(), lesson: lesson, folderID: knownFolder(folderID))
        try JSONEncoder().encode(entry).write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(id.uuidString))
        entries.insert(entry, at: 0)
        return entry
    }

    func importArchive(at url: URL, folderID: UUID? = nil) async {
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
            let entry = LibraryEntry(id: id, importedAt: Date(), lesson: lesson, folderID: knownFolder(folderID))
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

    /// Replaces a lesson's text (for example after translating it again). Times and audio stay the same.
    func updateLesson(_ id: UUID, _ lesson: Lesson) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw LessonError.invalidLesson }
        try lesson.validate()
        var entry = entries[index]
        guard lesson.duration == entry.lesson.duration else { throw LessonError.invalidAudio }
        entry.lesson = lesson
        try JSONEncoder().encode(entry).write(
            to: root.appendingPathComponent(id.uuidString).appendingPathComponent("entry.json"), options: .atomic)
        entries[index] = entry
    }

    /// Writes a .lrlesson file that the iPhone app can import.
    func exportArchive(_ id: UUID, to destination: URL) throws {
        guard let entry = entry(for: id) else { throw LessonError.invalidLesson }
        try LessonArchive.pack(lesson: entry.lesson, audio: audioURL(for: id), to: destination)
    }

    // MARK: - Folders

    func entries(in scope: LibraryScope) -> [LibraryEntry] {
        entries.filter { scope.contains(folderID: $0.folderID) }
    }

    func folder(for id: UUID?) -> LessonFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    @discardableResult
    func createFolder(named name: String) throws -> LessonFolder {
        let folder = LessonFolder(id: UUID(), name: try LessonFolders.validatedName(name, among: folders), created: Date())
        try saveFolders(folders + [folder])
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw FolderError.missing }
        var updated = folders
        updated[index].name = try LessonFolders.validatedName(name, among: folders, excluding: id)
        try saveFolders(updated)
    }

    /// Removes the folder only; its lessons stay in the library, outside any folder.
    func deleteFolder(_ id: UUID) throws {
        try move(entries.filter { $0.folderID == id }.map(\.id), to: nil)
        try saveFolders(folders.filter { $0.id != id })
    }

    func move(_ ids: [UUID], to folderID: UUID?) throws {
        if let folderID, folder(for: folderID) == nil { throw FolderError.missing }
        for id in ids {
            guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].folderID != folderID else { continue }
            var entry = entries[index]
            entry.folderID = folderID
            try write(entry)
            entries[index] = entry
        }
    }

    private func knownFolder(_ id: UUID?) -> UUID? { folder(for: id)?.id }

    private func saveFolders(_ updated: [LessonFolder]) throws {
        try JSONEncoder().encode(updated).write(to: foldersURL, options: .atomic)
        folders = LessonFolders.sorted(updated)
    }

    private func write(_ entry: LibraryEntry) throws {
        try JSONEncoder().encode(entry).write(
            to: root.appendingPathComponent(entry.id.uuidString).appendingPathComponent("entry.json"), options: .atomic)
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
