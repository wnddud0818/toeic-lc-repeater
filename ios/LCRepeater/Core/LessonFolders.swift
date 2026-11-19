import Foundation

/// A folder in the lesson library. Folders are one level deep; a lesson is in at most one folder.
struct LessonFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let created: Date
}

/// Which lessons a library list shows. Stored as a string (for example in AppStorage).
enum LibraryScope: Hashable, Sendable, RawRepresentable {
    case all
    case unfiled
    case folder(UUID)

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "unfiled": self = .unfiled
        default:
            guard rawValue.hasPrefix("folder:"), let id = UUID(uuidString: String(rawValue.dropFirst(7))) else { return nil }
            self = .folder(id)
        }
    }

    var rawValue: String {
        switch self {
        case .all: return "all"
        case .unfiled: return "unfiled"
        case .folder(let id): return "folder:" + id.uuidString
        }
    }

    /// The folder new or imported lessons go into while this scope is shown.
    var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }

    func contains(folderID: UUID?) -> Bool {
        switch self {
        case .all: return true
        case .unfiled: return folderID == nil
        case .folder(let id): return folderID == id
        }
    }
}

enum FolderError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong
    case duplicateName(String)
    case missing

    var errorDescription: String? {
        switch self {
        case .emptyName: return "폴더 이름을 입력해 주세요."
        case .nameTooLong: return "폴더 이름은 60자 이하로 해 주세요."
        case .duplicateName(let name): return "‘\(name)’ 폴더가 이미 있어요."
        case .missing: return "폴더를 찾을 수 없어요."
        }
    }
}

enum LessonFolders {
    /// Trims the name and rejects empty, very long or duplicate names (ignoring case and width).
    static func validatedName(_ raw: String, among folders: [LessonFolder], excluding id: UUID? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
        guard !name.isEmpty else { throw FolderError.emptyName }
        guard name.count <= 60 else { throw FolderError.nameTooLong }
        let key = comparisonKey(name)
        if folders.contains(where: { $0.id != id && comparisonKey($0.name) == key }) {
            throw FolderError.duplicateName(name)
        }
        return name
    }

    /// Folders in the order people expect to read them ("2과" before "10과").
    static func sorted(_ folders: [LessonFolder]) -> [LessonFolder] {
        folders.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.created < $1.created : order == .orderedAscending
        }
    }

    private static func comparisonKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
