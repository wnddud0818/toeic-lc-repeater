import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct MacRootView: View {
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var player: RepeaterPlayer
    @EnvironmentObject private var state: MacAppState
    @EnvironmentObject private var engine: EngineStatus
    @State private var deleting: LibraryEntry?
    @State private var keyMonitor = PlayerKeyMonitor()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            if let id = state.selectedLessonID, let entry = library.entry(for: id) {
                // A new identity per lesson reloads the player when switching lessons.
                MacPlayerView(entry: entry).id(id)
            } else {
                welcome
            }
        }
        .background(WindowReader { state.mainWindow = $0 })
        .sheet(isPresented: $state.showingNewLesson) {
            MacNewLessonView(initialAudio: state.newLessonAudio) { id in
                state.showingNewLesson = false
                state.selectedLessonID = id
            }
            .environmentObject(library)
            .environmentObject(engine)
        }
        .fileImporter(isPresented: $state.showingImporter, allowedContentTypes: [.lcrLesson],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importArchives(urls)
            case .failure(let error): state.message = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            state.open(urls)
            return true
        }
        .overlay {
            if library.isImporting {
                ProgressView("레슨을 가져오는 중이에요")
                    .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .confirmationDialog("‘\(deleting?.lesson.title ?? "")’ 레슨을 삭제할까요?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { entry in
            Button("삭제", role: .destructive) { delete(entry) }
        } message: { _ in
            Text("음원과 문장, 고친 구간이 이 Mac에서 지워져요.")
        }
        .alert("알림", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { clearAlerts() } })) {
            Button("확인", role: .cancel) { clearAlerts() }
        } message: { Text(alertText ?? "") }
        .onChange(of: player.sentenceID) { _, value in
            library.savePosition(lessonID: player.lessonID, sentenceID: value)
        }
        .onChange(of: player.lessonID) { _, value in
            library.savePosition(lessonID: value, sentenceID: player.sentenceID)
        }
        .onChange(of: state.openRequests) { _, _ in handleOpenRequests() }
        .onAppear {
            keyMonitor.install(state: state, player: player)
            if state.selectedLessonID == nil { state.selectedLessonID = library.entries.first?.id }
            handleOpenRequests()
        }
        .onDisappear { keyMonitor.remove() }
        .task {
            await smokeTestIfRequested()
            await engine.refresh()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if library.entries.isEmpty {
                ContentUnavailableView {
                    Label("아직 레슨이 없어요", systemImage: "headphones")
                } description: {
                    Text("영어·일본어 음원으로 새 레슨을 만들거나\nPC·아이폰에서 만든 레슨 파일을 가져오세요.")
                } actions: {
                    Button("새 레슨 만들기") { state.startNewLesson() }.buttonStyle(.borderedProminent)
                    Button("레슨 파일 가져오기") { state.showingImporter = true }
                }
            } else {
                List(selection: $state.selectedLessonID) {
                    Section("내 레슨") {
                        ForEach(library.entries) { entry in
                            row(entry).tag(entry.id)
                                .contextMenu {
                                    Button("아이폰용으로 내보내기…") { state.export(entry, library: library) }
                                    Divider()
                                    Button("삭제…", role: .destructive) { deleting = entry }
                                }
                        }
                    }
                }
                .onDeleteCommand {
                    if let id = state.selectedLessonID { deleting = library.entry(for: id) }
                }
            }
        }
        .navigationTitle("LC Repeater")
        .toolbar {
            ToolbarItemGroup {
                Button("가져오기", systemImage: "square.and.arrow.down") { state.showingImporter = true }
                    .help("PC·아이폰에서 만든 .lcrlesson 파일 가져오기")
                    .disabled(library.isImporting)
                Button("새 레슨", systemImage: "plus") { state.startNewLesson() }
                    .help("음원으로 새 레슨 만들기 (⌘N)")
            }
        }
    }

    private func row(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: player.lessonID == entry.id && player.isPlaying ? "waveform" : "headphones")
                .foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.lesson.title).lineLimit(2)
                Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func subtitle(_ entry: LibraryEntry) -> String {
        let lesson = entry.lesson
        let missing = lesson.sentences.filter { $0.ko.isEmpty }.count
        var parts = [lesson.language.name, "\(lesson.sentences.count)문장", "\(Int(lesson.duration / 60))분"]
        if missing > 0 { parts.append("번역 없음 \(missing)") }
        return parts.joined(separator: " · ")
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("레슨을 고르세요", systemImage: "headphones")
        } description: {
            Text("영어·일본어 음원을 끌어다 놓으면 새 레슨을 만들어요.\n전사는 Apple 기기 내 처리 또는 Whisper, 번역은 Apple 또는 Claude로 할 수 있어요.")
        } actions: {
            Button("새 레슨 만들기") { state.startNewLesson() }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private var alertText: String? {
        // While the new-lesson sheet is open it shows its own errors.
        state.message ?? (state.showingNewLesson ? nil : (library.error ?? player.error))
    }

    private func clearAlerts() {
        state.message = nil
        library.error = nil
        player.error = nil
    }

    private func delete(_ entry: LibraryEntry) {
        if player.lessonID == entry.id { player.unload() }
        if state.selectedLessonID == entry.id { state.selectedLessonID = nil }
        library.delete(entry.id)
        if state.selectedLessonID == nil { state.selectedLessonID = library.entries.first?.id }
    }

    private func importArchives(_ urls: [URL]) {
        Task {
            for url in urls {
                let before = Set(library.entries.map(\.id))
                await library.importArchive(at: url)
                if let added = library.entries.first(where: { !before.contains($0.id) }) {
                    state.selectedLessonID = added.id
                }
            }
        }
    }

    private func handleOpenRequests() {
        guard !state.openRequests.isEmpty else { return }
        let urls = state.openRequests
        state.openRequests.removeAll()
        let lessons = urls.filter { $0.pathExtension.lowercased() == "lcrlesson" }
        if !lessons.isEmpty { importArchives(lessons) }
        let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
        if let first = audio.first {
            if state.showingNewLesson {
                state.message = "지금 만들고 있는 레슨을 끝내거나 닫은 뒤 다시 열어 주세요."
            } else {
                state.startNewLesson(with: first)
            }
        }
        if lessons.isEmpty && audio.isEmpty {
            state.message = "MP3·M4A·WAV 같은 음원이나 .lcrlesson 파일을 열어 주세요."
        }
    }

    /// `--smoke-test <report.json>`: checks that the app starts with its library and engine, then quits.
    private func smokeTestIfRequested() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--smoke-test"), index + 1 < arguments.count else { return }
        var report: [String: Any] = [
            "lessons": library.entries.count,
            "engine_bundled": Engine.isBundled,
            "apple_speech_available": SpeechTranscriber.isAvailable,
            "window": state.mainWindow != nil || NSApp.windows.contains { $0.isVisible },
        ]
        if Engine.isBundled {
            do {
                let status = try await Engine.run(["status"])
                report["engine_whisper"] = status.whisper ?? false
            } catch {
                report["engine_error"] = error.localizedDescription
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        NSApp.terminate(nil)
    }
}
