import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let lcrLesson = UTType(exportedAs: "com.firstghrn.lcrepeater.lesson", conformingTo: .data)
}

@main
struct LCRepeaterApp: App {
    @StateObject private var library = LessonLibrary()
    @StateObject private var player = RepeaterPlayer()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(player)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await library.importArchive(at: url) }
                }
        }
    }
}
