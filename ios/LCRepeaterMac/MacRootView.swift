import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Folders | lessons in the folder | player.
struct MacRootView: View {
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var player: RepeaterPlayer
    @EnvironmentObject private var state: MacAppState
    @EnvironmentObject private var engine: EngineStatus
    @State private var keyMonitor = PlayerKeyMonitor()

    private var visibleEntries: [LibraryEntry] { library.entries(in: state.scope) }
    private var selectedEntries: [LibraryEntry] { library.entries.filter { state.selection.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            folderSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } content: {
            lessonList
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
        } detail: {
            detail
        }
        .background(WindowReader { state.mainWindow = $0 })
        .sheet(isPresented: $state.showingNewLesson) {
            MacNewLessonView(incoming: $state.newLessonAudio, initialFolderID: state.scope.folderID) { ids, folderID in
                state.showingNewLesson = false
                lessonsCreated(ids, in: folderID)
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
        .alert(folderPromptTitle, isPresented: Binding(get: { state.folderPrompt != nil },
                                                       set: { if !$0 { state.folderPrompt = nil } })) {
            TextField("폴더 이름", text: $state.folderName)
            Button(folderPromptButton) { state.commitFolderPrompt(library: library) }
                .keyboardShortcut(.defaultAction)
            Button("취소", role: .cancel) { state.folderPrompt = nil }
        }
        .confirmationDialog(deleteLessonsTitle,
                            isPresented: Binding(get: { !state.deletingLessons.isEmpty },
                                                 set: { if !$0 { state.deletingLessons = [] } })) {
            Button("삭제", role: .destructive) { deleteLessons(state.deletingLessons) }
        } message: {
            Text("음원과 문장, 고친 구간이 이 Mac에서 지워져요.")
        }
        .confirmationDialog("‘\(state.deletingFolder?.name ?? "")’ 폴더를 삭제할까요?",
                            isPresented: Binding(get: { state.deletingFolder != nil },
                                                 set: { if !$0 { state.deletingFolder = nil } }),
                            presenting: state.deletingFolder) { folder in
            Button("폴더 삭제", role: .destructive) { state.deleteFolder(folder, library: library) }
        } message: { folder in
            Text("안에 있는 레슨 \(library.entries(in: .folder(folder.id)).count)개는 지워지지 않고 ‘폴더 없음’으로 옮겨져요.")
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
        .onChange(of: state.scope) { _, _ in
            let visible = Set(visibleEntries.map(\.id))
            state.selection = state.selection.filter(visible.contains)
            if state.selection.isEmpty, let first = visibleEntries.first { state.select(first.id) }
        }
        .onChange(of: library.folders) { _, folders in
            if case .folder(let id) = state.scope, !folders.contains(where: { $0.id == id }) { state.scope = .all }
        }
        .onAppear {
            keyMonitor.install(state: state, player: player)
            if case .folder(let id) = state.scope, library.folder(for: id) == nil { state.scope = .all }
            if state.selection.isEmpty, let first = visibleEntries.first { state.select(first.id) }
            handleOpenRequests()
        }
        .onDisappear { keyMonitor.remove() }
        .task {
            await smokeTestIfRequested()
            await engine.refresh()
        }
    }

    // MARK: - Folders

    private var folderSidebar: some View {
        List(selection: Binding<LibraryScope?>(get: { state.scope }, set: { if let scope = $0 { state.scope = scope } })) {
            Section("보관함") {
                scopeRow("모든 레슨", systemImage: "tray.full", scope: .all)
                scopeRow("폴더 없음", systemImage: "tray", scope: .unfiled)
            }
            Section("폴더") {
                ForEach(library.folders) { folder in
                    scopeRow(folder.name, systemImage: "folder", scope: .folder(folder.id))
                        .contextMenu {
                            Button("이름 바꾸기…") { state.promptRename(folder) }
                            Button("폴더의 레슨 모두 내보내기…") {
                                state.export(library.entries(in: .folder(folder.id)), library: library)
                            }
                            .disabled(library.entries(in: .folder(folder.id)).isEmpty)
                            Divider()
                            Button("폴더 삭제…", role: .destructive) { state.deletingFolder = folder }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { state.promptNewFolder() } label: {
                Label("새 폴더", systemImage: "folder.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .help("새 폴더 만들기 (⇧⌘N)")
        }
        .navigationTitle("LC Repeater")
    }

    /// A folder row that also accepts lessons dragged from the lesson list.
    private func scopeRow(_ title: String, systemImage: String, scope: LibraryScope) -> some View {
        Label(title, systemImage: systemImage)
            .badge(library.entries(in: scope).count)
            .tag(scope)
            .dropDestination(for: String.self) { ids, _ in
                guard scope != .all else { return false }
                let dragged = ids.compactMap(UUID.init(uuidString:))
                // Dragging one of several selected lessons moves the whole selection.
                let moving = dragged.contains(where: state.selection.contains) ? Array(state.selection) : dragged
                state.move(moving, to: scope.folderID, library: library)
                return !moving.isEmpty
            }
    }

    // MARK: - Lessons

    private var scopeTitle: String {
        switch state.scope {
        case .all: return "모든 레슨"
        case .unfiled: return "폴더 없음"
        case .folder(let id): return library.folder(for: id)?.name ?? "폴더"
        }
    }

    private var lessonList: some View {
        Group {
            if visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label(library.entries.isEmpty ? "아직 레슨이 없어요" : "레슨이 없는 폴더예요", systemImage: "headphones")
                } description: {
                    Text(library.entries.isEmpty
                         ? "영어·일본어 음원으로 새 레슨을 만들거나\nPC·아이폰에서 만든 레슨 파일을 가져오세요."
                         : "새 레슨을 만들거나, 다른 폴더의 레슨을 이 폴더로 끌어다 놓으세요.")
                } actions: {
                    Button("새 레슨 만들기") { state.startNewLesson() }.buttonStyle(.borderedProminent)
                    Button("레슨 파일 가져오기") { state.showingImporter = true }
                }
            } else {
                List(selection: $state.selection) {
                    ForEach(visibleEntries) { entry in
                        row(entry)
                            .tag(entry.id)
                            .draggable(entry.id.uuidString)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    lessonMenu(for: Array(ids))
                }
                .onDeleteCommand { state.deletingLessons = selectedEntries }
            }
        }
        .navigationTitle(scopeTitle)
        .navigationSubtitle("레슨 \(visibleEntries.count)개")
        .toolbar {
            ToolbarItemGroup {
                Button("가져오기", systemImage: "square.and.arrow.down") { state.showingImporter = true }
                    .help("PC·아이폰에서 만든 .\(LessonArchive.fileExtension) 파일을 이 폴더로 가져오기 (⌘O)")
                    .disabled(library.isImporting)
                Button("새 레슨", systemImage: "plus") { state.startNewLesson() }
                    .help("음원 여러 개로 새 레슨 만들기 (⌘N)")
            }
        }
    }

    @ViewBuilder
    private func lessonMenu(for ids: [UUID]) -> some View {
        if !ids.isEmpty {
            let entries = library.entries.filter { ids.contains($0.id) }
            Menu("폴더로 이동") {
                Button("폴더 없음") { state.move(ids, to: nil, library: library) }
                if !library.folders.isEmpty { Divider() }
                ForEach(library.folders) { folder in
                    Button(folder.name) { state.move(ids, to: folder.id, library: library) }
                }
                Divider()
                Button("새 폴더로 이동…") { state.promptNewFolder(moving: ids) }
            }
            Button(ids.count == 1 ? "아이폰용으로 내보내기…" : "레슨 \(ids.count)개 내보내기…") {
                state.export(entries, library: library)
            }
            Divider()
            Button(ids.count == 1 ? "삭제…" : "레슨 \(ids.count)개 삭제…", role: .destructive) {
                state.deletingLessons = entries
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
        var parts = [lesson.language.name, "\(lesson.sentences.count)문장", "\(Int(lesson.duration / 60))분"]
        if state.scope == .all, let folder = library.folder(for: entry.folderID) { parts.insert(folder.name, at: 0) }
        let missing = lesson.sentences.filter { $0.ko.isEmpty }.count
        if missing > 0 { parts.append("번역 없음 \(missing)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = state.selectedLessonID, let entry = library.entry(for: id) {
            // A new identity per lesson reloads the player when switching lessons.
            MacPlayerView(entry: entry).id(id)
        } else if state.selection.count > 1 {
            let entries = selectedEntries
            ContentUnavailableView {
                Label("레슨 \(entries.count)개 선택됨", systemImage: "square.stack")
            } description: {
                Text("폴더로 옮기거나 한꺼번에 내보낼 수 있어요. 왼쪽 폴더로 끌어다 놓아도 돼요.")
            } actions: {
                Menu("폴더로 이동") { lessonMenuMoveItems(entries.map(\.id)) }
                    .fixedSize()
                Button("레슨 \(entries.count)개 내보내기…") { state.export(entries, library: library) }
                Button("삭제…", role: .destructive) { state.deletingLessons = entries }
            }
        } else {
            ContentUnavailableView {
                Label("레슨을 고르세요", systemImage: "headphones")
            } description: {
                Text("영어·일본어 음원 여러 개를 창에 끌어다 놓으면 한꺼번에 레슨으로 만들어요.\n전사는 Apple 기기 내 처리 또는 Whisper, 번역은 Apple 또는 Claude로 할 수 있어요.")
            } actions: {
                Button("새 레슨 만들기") { state.startNewLesson() }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func lessonMenuMoveItems(_ ids: [UUID]) -> some View {
        Button("폴더 없음") { state.move(ids, to: nil, library: library) }
        ForEach(library.folders) { folder in
            Button(folder.name) { state.move(ids, to: folder.id, library: library) }
        }
        Divider()
        Button("새 폴더로 이동…") { state.promptNewFolder(moving: ids) }
    }

    // MARK: - Actions

    private var folderPromptTitle: String {
        if case .rename = state.folderPrompt { return "폴더 이름 바꾸기" }
        return "새 폴더"
    }

    private var folderPromptButton: String {
        if case .rename = state.folderPrompt { return "바꾸기" }
        return "만들기"
    }

    private var deleteLessonsTitle: String {
        state.deletingLessons.count == 1
            ? "‘\(state.deletingLessons[0].lesson.title)’ 레슨을 삭제할까요?"
            : "레슨 \(state.deletingLessons.count)개를 삭제할까요?"
    }

    private var alertText: String? {
        // While the new-lesson sheet is open it shows its own errors.
        state.message ?? (state.showingNewLesson ? nil : (library.error ?? player.error))
    }

    private func clearAlerts() {
        state.message = nil
        library.error = nil
        player.error = nil
    }

    private func deleteLessons(_ entries: [LibraryEntry]) {
        for entry in entries {
            if player.lessonID == entry.id { player.unload() }
            library.delete(entry.id)
        }
        state.deletingLessons = []
        state.selection.subtract(entries.map(\.id))
        if state.selection.isEmpty, let first = visibleEntries.first { state.select(first.id) }
    }

    private func lessonsCreated(_ ids: [UUID], in folderID: UUID?) {
        guard let last = ids.last else { return }
        if !state.scope.contains(folderID: folderID) {
            state.scope = folderID.map(LibraryScope.folder) ?? .unfiled
        }
        state.select(last)
    }

    /// Imports into the folder that is open, so a folder can be filled from Finder.
    private func importArchives(_ urls: [URL]) {
        let folderID = state.scope.folderID
        Task {
            for url in urls {
                let before = Set(library.entries.map(\.id))
                await library.importArchive(at: url, folderID: folderID)
                if let added = library.entries.first(where: { !before.contains($0.id) }) {
                    state.select(added.id)
                }
            }
        }
    }

    private func handleOpenRequests() {
        guard !state.openRequests.isEmpty else { return }
        let urls = state.openRequests
        state.openRequests.removeAll()
        let lessons = urls.filter(LessonArchive.isLessonFile)
        if !lessons.isEmpty { importArchives(lessons) }
        let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
        // Adds to the open new-lesson window, or opens it.
        if !audio.isEmpty { state.startNewLesson(with: audio) }
        if lessons.isEmpty && audio.isEmpty {
            state.message = "MP3·M4A·WAV 같은 음원이나 .\(LessonArchive.fileExtension) 레슨 파일을 열어 주세요."
        }
    }

    /// `--smoke-test <report.json>`: checks that the app starts with its library and engine, then quits.
    private func smokeTestIfRequested() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--smoke-test"), index + 1 < arguments.count else { return }
        var report: [String: Any] = [
            "lessons": library.entries.count,
            "folders": library.folders.count,
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
