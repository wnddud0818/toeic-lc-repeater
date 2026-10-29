import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var player: RepeaterPlayer
    @State private var showingImporter = false
    @State private var showingHelp = false

    var body: some View {
        NavigationStack {
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
                } else {
                    List {
                        Section {
                            ForEach(library.entries) { entry in
                                NavigationLink(value: entry.id) {
                                    HStack(spacing: 14) {
                                        Image(systemName: player.lessonID == entry.id && player.isPlaying
                                              ? "waveform" : "headphones")
                                            .font(.title2).foregroundStyle(.tint)
                                            .frame(width: 36)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.lesson.title).font(.headline).lineLimit(2)
                                            Text("\(entry.lesson.sentences.count)문장 · \(Int(entry.lesson.duration / 60))분 · 오프라인")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 6)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                let ids = offsets.map { library.entries[$0].id }
                                for id in ids {
                                    if player.lessonID == id { player.unload() }
                                    library.delete(id)
                                }
                            }
                        } header: {
                            Text("내 레슨")
                        } footer: {
                            Text("원본 레슨 파일은 iCloud Drive나 PC에 보관해 주세요.")
                        }
                    }
                }
            }
            .navigationTitle("LC Repeater")
            .navigationDestination(for: UUID.self) { id in
                if let entry = library.entry(for: id) {
                    PlayerView(entry: entry)
                } else {
                    ContentUnavailableView("레슨이 없어요", systemImage: "doc.questionmark")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("옮기는 방법", systemImage: "questionmark.circle") { showingHelp = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("가져오기", systemImage: "plus") { showingImporter = true }
                        .disabled(library.isImporting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let id = player.lessonID, library.entry(for: id) != nil {
                    HStack(spacing: 16) {
                        NavigationLink(value: id) {
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
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.lcrLesson], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { for url in urls { await library.importArchive(at: url) } }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingHelp) { TransferHelpView() }
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
        .onChange(of: player.sentenceID) { _, value in
            library.savePosition(lessonID: player.lessonID, sentenceID: value)
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
                    Text("LC Repeater의 ‘가져오기’에서 .lcrlesson 파일을 선택하세요. ‘파일’ 앱의 공유 메뉴에서 LC Repeater로 열어도 돼요.")
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
