import XCTest
@testable import LessonCore

final class LessonFolderTests: XCTestCase {
    private let jlpt = LessonFolder(id: UUID(), name: "JLPT N3", created: Date(timeIntervalSince1970: 1))

    func testNamesAreTrimmedAndDuplicatesIgnoreCaseAndWidth() throws {
        XCTAssertEqual(try LessonFolders.validatedName("  토익 Part 2 \n", among: [jlpt]), "토익 Part 2")
        XCTAssertThrowsError(try LessonFolders.validatedName("jlpt n3", among: [jlpt])) {
            XCTAssertEqual($0 as? FolderError, .duplicateName("jlpt n3"))
        }
        XCTAssertThrowsError(try LessonFolders.validatedName("ＪＬＰＴ Ｎ3", among: [jlpt]))
        XCTAssertThrowsError(try LessonFolders.validatedName("   ", among: [])) {
            XCTAssertEqual($0 as? FolderError, .emptyName)
        }
        XCTAssertThrowsError(try LessonFolders.validatedName(String(repeating: "가", count: 61), among: []))
        // Renaming a folder to its own name (or a different case of it) is allowed.
        XCTAssertEqual(try LessonFolders.validatedName("Jlpt N3", among: [jlpt], excluding: jlpt.id), "Jlpt N3")
    }

    func testFoldersSortLikeFinder() {
        let names = ["10과", "2과", "JLPT", "가나다"].enumerated().map {
            LessonFolder(id: UUID(), name: $0.element, created: Date(timeIntervalSince1970: Double($0.offset)))
        }
        XCTAssertEqual(LessonFolders.sorted(names).map(\.name).prefix(2), ["2과", "10과"])
    }

    func testScopeRoundTripsAndFilters() {
        let id = UUID()
        for scope in [LibraryScope.all, .unfiled, .folder(id)] {
            XCTAssertEqual(LibraryScope(rawValue: scope.rawValue), scope)
        }
        XCTAssertNil(LibraryScope(rawValue: "folder:not-a-uuid"))
        XCTAssertTrue(LibraryScope.all.contains(folderID: id))
        XCTAssertTrue(LibraryScope.unfiled.contains(folderID: nil))
        XCTAssertFalse(LibraryScope.unfiled.contains(folderID: id))
        XCTAssertTrue(LibraryScope.folder(id).contains(folderID: id))
        XCTAssertFalse(LibraryScope.folder(id).contains(folderID: nil))
        XCTAssertEqual(LibraryScope.folder(id).folderID, id)
        XCTAssertNil(LibraryScope.all.folderID)
    }

    func testLessonFileExtensionsIncludeTheOldName() {
        XCTAssertEqual(LessonArchive.fileExtension, "lrlesson")
        XCTAssertTrue(LessonArchive.isLessonFile(URL(fileURLWithPath: "/tmp/a.LRLESSON")))
        XCTAssertTrue(LessonArchive.isLessonFile(URL(fileURLWithPath: "/tmp/old.lcrlesson")))
        XCTAssertFalse(LessonArchive.isLessonFile(URL(fileURLWithPath: "/tmp/a.mp3")))
    }
}
