import AppKit
import SwiftUI

@main
@MainActor
struct LCRepeaterMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = LessonLibrary()
    @StateObject private var player = RepeaterPlayer()
    @StateObject private var state = MacAppState.shared
    @StateObject private var engine = EngineStatus()

    var body: some Scene {
        Window("LC Repeater", id: "main") {
            MacRootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(state)
                .environmentObject(engine)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 820)
        .commands { LessonCommands(state: state, library: library, player: player) }

        Settings {
            MacSettingsView()
                .environmentObject(engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// .lcrlesson files and audio opened from Finder, the Dock or "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { MacAppState.shared.open(urls) }
    }
}

struct LessonCommands: Commands {
    @ObservedObject var state: MacAppState
    @ObservedObject var library: LessonLibrary
    @ObservedObject var player: RepeaterPlayer

    private var selected: LibraryEntry? { state.selectedLessonID.flatMap(library.entry(for:)) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 레슨 만들기…") { state.startNewLesson() }
                .keyboardShortcut("n")
            Button("레슨 파일 가져오기…") { state.showingImporter = true }
                .keyboardShortcut("o")
            Divider()
            Button("아이폰용으로 내보내기…") { if let selected { state.export(selected, library: library) } }
                .keyboardShortcut("e")
                .disabled(selected == nil)
            Button("이전 맥 앱 레슨 가져오기…") { Task { await state.importPreviousAppLessons(into: library) } }
        }
        CommandMenu("재생") {
            Button(player.isPlaying ? "일시정지 (Space)" : "재생 (Space)") { player.toggle() }
                .disabled(player.lesson == nil)
            Button("처음부터 (R)") { player.play(sentenceID: player.sentenceID) }
                .disabled(player.lesson == nil)
            Button("이전 문장 (←)") { player.move(-1) }
                .disabled(player.lesson == nil || player.position == 0)
            Button("다음 문장 (→)") { player.move(1) }
                .disabled(player.lesson == nil || player.position + 1 >= player.visibleSentences.count)
            Divider()
            Button("원문 공개 → 한국어 → 가리기 (T)") { state.cardFace = state.cardFace.next }
                .disabled(player.lesson == nil)
        }
    }
}

/// Space, ←/→, T and R work like the web player while a lesson is open, except when typing
/// in a text field, when a sheet is open, or with ⌘/⌥/⌃ held.
@MainActor
final class PlayerKeyMonitor {
    private var token: Any?

    func install(state: MacAppState, player: RepeaterPlayer) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state, weak player] event in
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let state, let player else { return false }
                return Self.handle(event, state: state, player: player)
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private static func handle(_ event: NSEvent, state: MacAppState, player: RepeaterPlayer) -> Bool {
        guard let window = event.window, window === state.mainWindow, window.attachedSheet == nil,
              !state.showingNewLesson, player.lesson != nil, player.lessonID == state.selectedLessonID,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !(window.firstResponder is NSText) else { return false }
        switch event.keyCode {
        case 49: player.toggle(); return true                 // Space
        case 123: player.move(-1); return true                // ←
        case 124: player.move(1); return true                 // →
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "t", "ㅅ": state.cardFace = state.cardFace.next; return true
        case "r", "ㄱ": player.play(sentenceID: player.sentenceID); return true
        default: return false
        }
    }
}

/// Reports the hosting NSWindow so the keyboard handler only acts on the main window.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
