import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let lcrLesson = UTType(exportedAs: "com.firstghrn.lcrepeater.lesson", conformingTo: .data)
}

@main
@MainActor
struct LCRepeaterApp: App {
    @StateObject private var library = LessonLibrary()
    @StateObject private var player = RepeaterPlayer()

    var body: some Scene {
        WindowGroup {
            rootView
                .environmentObject(library)
                .environmentObject(player)
        }
    }

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if CommandLine.arguments.contains("--smoke-audio-picker") { AudioFilePickerSmokeView() }
        else { AppHomeView() }
        #else
        AppHomeView()
        #endif
    }
}
