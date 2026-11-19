import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var player: RepeaterPlayer
    @State private var showingImporter = false
    @State private var showingHelp = false
    /// Selected lesson. On iPhone Duo's inner display (and iPad) the list and player sit side by side;
    /// on the outer display and other iPhones the split view collapses into a single push stack.
    @State private var selectedLessonID: UUID?
    /// Folder (or all/unfiled) shown in the list; imports go into this folder.
    @AppStorage("lcr.libraryScope") private var scopeRaw = LibraryScope.all.rawValue
    @State private var showingFolders = false
    @State private var folderPrompt: FolderPrompt?
    var openLessonID: UUID? = nil
    var onStart: (() -> Void)? = nil

    private var scope: LibraryScope {
        let saved = LibraryScope(rawValue: scopeRaw) ?? .all
        if case .folder(let id) = saved, library.folder(for: id) == nil { return .all }
        return saved
    }
    private var scopeBinding: Binding<LibraryScope> {
        Binding(get: { scope }, set: { scopeRaw = $0.rawValue })
    }
    private var scopedEntries: [LibraryEntry] { library.entries(in: scope) }
    private var scopeTitle: String {
        switch scope {
        case .all: return "모든 레슨"
        case .unfiled: return "폴더 없음"
        case .folder(let id): return library.folder(for: id)?.name ?? "폴더"
        }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if library.entries.isEmpty {
                    ContentUnavailableView {
                        Label("아직 레슨이 없어요", systemImage: "headphones")
                    } description: {
                        Text("PC에서 준비한 레슨을 가져오면\n인터넷 없이 문장별로 반복해 들을 수 있어요.")
                    } actions: {
                        Button("레슨 가져오기", systemImage: "square.and.arrow.down") {
                            showingImporter = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.isImporting)
                        Button("레슨 옮기는 방법") { showingHelp = true }
                    }
                } else if scopedEntries.isEmpty {
                    ContentUnavailableView {
                        Label("‘\(scopeTitle)’에 레슨이 없어요", systemImage: "folder")
                    } description: {
                        Text("레슨을 길게 눌러 ‘폴더로 이동’을 고르거나, 이 폴더를 연 채로 레슨을 가져오세요.")
                    } actions: {
                        Button("모든 레슨 보기") { scopeRaw = LibraryScope.all.rawValue }
                            .buttonStyle(.borderedProminent)
                        Button("레슨 가져오기") { showingImporter = true }.disabled(library.isImporting)
                    }
                } else {
                    List(selection: $selectedLessonID) {
                        Section {
                            ForEach(scopedEntries) { entry in
                                NavigationLink(value: entry.id) {
                                    HStack(spacing: 14) {
                                        Image(systemName: player.lessonID == entry.id && player.isPlaying
                                              ? "waveform" : "headphones")
                                            .font(.title2).foregroundStyle(.tint)
                                            .frame(width: 36)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.lesson.title).font(.headline).lineLimit(2)
                                            Text(subtitle(entry))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 6)
                                    }
                                }
                                .contextMenu { moveMenu(for: entry) }
                            }
                            .onDelete { offsets in
                                let ids = offsets.map { scopedEntries[$0].id }
                                for id in ids {
                                    if player.lessonID == id { player.unload() }
                                    if selectedLessonID == id { selectedLessonID = nil }
                                    library.delete(id)
                                }
                            }
                        } header: {
                            Text(scopeTitle)
                        } footer: {
                            Text("원본 음원과 PC 레슨 파일은 iCloud Drive나 PC에도 보관해 주세요.")
                        }
                    }
                }
            }
            .navigationTitle(scope == .all ? "LC Repeater" : scopeTitle)
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
            .modifier(FolderPromptAlert(prompt: $folderPrompt) { folder in scopeRaw = LibraryScope.folder(folder.id).rawValue })
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack {
                        if let onStart { Button("시작 화면", systemImage: "house") { onStart() } }
                        Button("옮기는 방법", systemImage: "questionmark.circle") { showingHelp = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("보기", selection: scopeBinding) {
                            Label("모든 레슨", systemImage: "tray.full").tag(LibraryScope.all)
                            Label("폴더 없음", systemImage: "tray").tag(LibraryScope.unfiled)
                            ForEach(library.folders) { folder in
                                Label(folder.name, systemImage: "folder").tag(LibraryScope.folder(folder.id))
                            }
                        }
                        Divider()
                        Button("새 폴더…", systemImage: "folder.badge.plus") { folderPrompt = .create(moving: []) }
                        Button("폴더 관리…", systemImage: "folder.badge.gearshape") { showingFolders = true }
                    } label: {
                        Label("폴더", systemImage: scope == .all ? "folder" : "folder.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("가져오기", systemImage: "plus") { showingImporter = true }
                        .disabled(library.isImporting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Hidden while that lesson is already on screen in the detail column.
                if let id = player.lessonID, id != selectedLessonID, library.entry(for: id) != nil {
                    HStack(spacing: 16) {
                        Button { selectedLessonID = id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(player.lesson?.title ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(player.currentSentence?.en ?? "레슨 열기").font(.subheadline).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button(player.isPlaying ? "일시정지" : "재생",
                               systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                            .labelStyle(.iconOnly).font(.title2).frame(width: 44, height: 44)
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.regularMaterial)
                }
            }
        } detail: {
            NavigationStack {
                if let id = selectedLessonID, let entry = library.entry(for: id) {
                    // A new identity per lesson so switching lessons side by side reloads the player.
                    PlayerView(entry: entry).id(id)
                } else if selectedLessonID != nil {
                    ContentUnavailableView("레슨이 없어요", systemImage: "doc.questionmark")
                } else {
                    ContentUnavailableView("레슨을 선택하세요", systemImage: "headphones",
                                           description: Text("왼쪽 목록에서 레슨을 고르면 여기서 반복해 들을 수 있어요."))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.lcrLesson], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let folderID = scope.folderID
                Task { for url in urls { await library.importArchive(at: url, folderID: folderID) } }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingHelp) { TransferHelpView() }
        .sheet(isPresented: $showingFolders) { FolderManagerView(scopeRaw: $scopeRaw) }
        .overlay {
            if library.isImporting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("레슨을 가져오는 중이에요").font(.headline)
                        Text("완료될 때까지 앱을 열어 두세요.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
        .alert("알림", isPresented: Binding(get: { library.error != nil || player.error != nil }, set: { visible in
            if !visible { library.error = nil; player.error = nil }
        })) {
            Button("확인", role: .cancel) { library.error = nil; player.error = nil }
        } message: {
            Text(library.error ?? player.error ?? "")
        }
        .task(id: openLessonID) {
            #if DEBUG
            if CommandLine.arguments.contains("--smoke-test") { await runImportSmokeTest(); return }
            #endif
            if let openLessonID {
                // Show the folder the new lesson went into.
                if let entry = library.entry(for: openLessonID), !scope.contains(folderID: entry.folderID) {
                    scopeRaw = (entry.folderID.map(LibraryScope.folder) ?? .unfiled).rawValue
                }
                selectedLessonID = openLessonID
            }
        }
    }

    #if DEBUG
    /// Used only by the simulator CI, with synthetic audio created by Python.
    private func runImportSmokeTest() async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        await library.importArchive(at: documents.appendingPathComponent("contract.lrlesson"))
        if let entry = library.entries.first {
            player.load(entry, audioURL: library.audioURL(for: entry.id), savedSentence: 2)
            selectedLessonID = entry.id
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let result: [String: Any] = [
            "imported": library.entries.count,
            "sentences": library.entries.first?.lesson.sentences.count ?? 0,
            "current_sentence": player.sentenceID ?? 0,
            "error": library.error ?? player.error ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: documents.appendingPathComponent("smoke-result.json"), options: .atomic)
        }
    }
    #endif
}

extension LibraryView {
    private func subtitle(_ entry: LibraryEntry) -> String {
        var parts: [String] = []
        if scope == .all, let folder = library.folder(for: entry.folderID) { parts.append(folder.name) }
        if entry.lesson.language != .english { parts.append(entry.lesson.language.name) }
        parts += ["\(entry.lesson.sentences.count)문장", "\(Int(entry.lesson.duration / 60))분", "오프라인"]
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func moveMenu(for entry: LibraryEntry) -> some View {
        Menu("폴더로 이동", systemImage: "folder") {
            Button("폴더 없음") { move(entry.id, to: nil) }
                .disabled(entry.folderID == nil)
            ForEach(library.folders) { folder in
                Button(folder.name) { move(entry.id, to: folder.id) }
                    .disabled(entry.folderID == folder.id)
            }
            Divider()
            Button("새 폴더로 이동…", systemImage: "folder.badge.plus") { folderPrompt = .create(moving: [entry.id]) }
        }
    }

    private func move(_ id: UUID, to folderID: UUID?) {
        do { try library.move([id], to: folderID) }
        catch { library.error = "옮기지 못했어요: \(error.localizedDescription)" }
    }
}

enum FolderPrompt: Equatable {
    case create(moving: [UUID])
    case rename(LessonFolder)
}

/// Asks for a folder name to create or rename a folder. Errors go to the library's alert.
struct FolderPromptAlert: ViewModifier {
    @Binding var prompt: FolderPrompt?
    var onCreated: (LessonFolder) -> Void = { _ in }
    @EnvironmentObject private var library: LessonLibrary
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(isRename ? "폴더 이름 바꾸기" : "새 폴더",
                   isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                TextField("폴더 이름", text: $name)
                Button(isRename ? "바꾸기" : "만들기") { commit() }
                Button("취소", role: .cancel) { prompt = nil }
            }
            .onChange(of: prompt) { _, value in
                if case .rename(let folder) = value { name = folder.name } else { name = "" }
            }
    }

    private var isRename: Bool {
        if case .rename = prompt { return true }
        return false
    }

    private func commit() {
        guard let current = prompt else { return }
        prompt = nil
        do {
            switch current {
            case .create(let ids):
                let folder = try library.createFolder(named: name)
                if !ids.isEmpty { try library.move(ids, to: folder.id) }
                onCreated(folder)
            case .rename(let folder):
                try library.renameFolder(folder.id, to: name)
            }
        } catch {
            library.error = error.localizedDescription
        }
    }
}

/// Create, rename and delete folders. Deleting a folder keeps its lessons (they become unfiled).
private struct FolderManagerView: View {
    @Binding var scopeRaw: String
    @EnvironmentObject private var library: LessonLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: FolderPrompt?
    @State private var deleting: LessonFolder?

    var body: some View {
        NavigationStack {
            List {
                if library.folders.isEmpty {
                    Text("아직 폴더가 없어요. 시험·교재·단원별로 폴더를 만들어 레슨을 정리해 보세요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.folders) { folder in
                    Button {
                        prompt = .rename(folder)
                    } label: {
                        LabeledContent {
                            Text("\(library.entries(in: .folder(folder.id)).count)개")
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("삭제", role: .destructive) { deleting = folder }
                        Button("이름 바꾸기") { prompt = .rename(folder) }.tint(.blue)
                    }
                }
                if let error = library.error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("폴더").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("새 폴더", systemImage: "folder.badge.plus") { prompt = .create(moving: []) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("완료") { library.error = nil; dismiss() } }
            }
            .modifier(FolderPromptAlert(prompt: $prompt))
            .confirmationDialog("‘\(deleting?.name ?? "")’ 폴더를 삭제할까요?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { folder in
                Button("폴더 삭제", role: .destructive) { delete(folder) }
            } message: { folder in
                Text("안에 있는 레슨 \(library.entries(in: .folder(folder.id)).count)개는 지워지지 않고 ‘폴더 없음’으로 옮겨져요.")
            }
        }
    }

    private func delete(_ folder: LessonFolder) {
        do {
            try library.deleteFolder(folder.id)
            if scopeRaw == LibraryScope.folder(folder.id).rawValue { scopeRaw = LibraryScope.all.rawValue }
        } catch {
            library.error = error.localizedDescription
        }
    }
}

private struct TransferHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("1. PC에서 레슨 준비") {
                    Text("음성 인식과 번역이 끝난 레슨을 열고 ‘아이폰용 레슨 내보내기’를 누르세요.")
                }
                Section("2. 아이폰으로 파일 옮기기") {
                    Text("Mac에서는 AirDrop으로 보내거나 iCloud Drive에 저장하세요. 다른 PC에서는 iCloud Drive 등으로 옮겨 ‘파일’ 앱에서 열 수 있게 해 주세요.")
                }
                Section("3. 레슨 가져오기") {
                    Text("LC Repeater의 ‘가져오기’에서 .lrlesson 파일(예전 .lcrlesson도 가능)을 선택하세요. ‘파일’ 앱의 공유 메뉴에서 LC Repeater로 열어도 돼요.")
                }
                Section("가져온 뒤에는") {
                    Text("음원과 문장이 아이폰에 복사돼요. 맥이나 인터넷 연결 없이 학습할 수 있고, 반복 횟수·쉼·속도를 앱에서 바꿀 수 있어요.")
                    Text("아이폰에서 고친 구간과 이어 듣기 위치는 이 앱에 저장돼요. PC와 자동 동기화되지는 않아요.")
                }
            }
            .navigationTitle("레슨 옮기기").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
    }
}
