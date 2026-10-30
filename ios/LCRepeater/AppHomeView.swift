import SwiftUI
import AVFoundation

struct AppHomeView: View {
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var player: RepeaterPlayer
    @State private var showingLibrary = false
    @State private var showingDevice = false
    @State private var openLessonID: UUID?

    var body: some View {
        Group {
            if showingLibrary {
                LibraryView(openLessonID: openLessonID, onStart: {
                    openLessonID = nil
                    showingLibrary = false
                })
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Image(systemName: "headphones")
                                .font(.system(size: 48, weight: .medium)).foregroundStyle(.tint)
                                .padding(.top, 28).accessibilityHidden(true)
                            Text("어디에서 시작할까요?").font(.largeTitle.bold())
                            Text("영어를 듣고, 한 문장씩 내 속도로 반복해요.")
                                .foregroundStyle(.secondary)
                            choice("컴퓨터에서 불러오기", subtitle: "PC에서 준비한 .lcrlesson 파일 가져오기",
                                   icon: "desktopcomputer.and.arrow.down") {
                                openLessonID = nil
                                showingLibrary = true
                            }
                            choice("기기에서 시작하기", subtitle: "음원을 선택하고 영어 전사·한국어 번역하기",
                                   icon: "iphone.gen3") { showingDevice = true }
                            if !library.entries.isEmpty {
                                Button("내 레슨 \(library.entries.count)개 보기", systemImage: "books.vertical") {
                                    openLessonID = nil
                                    showingLibrary = true
                                }.padding(.top, 4)
                            }
                            Text("기기에서 시작하기는 iOS 26 이상과 전사 지원 기기가 필요해요.")
                                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                        }
                        .frame(maxWidth: 580, alignment: .leading)
                        .padding(24).frame(maxWidth: .infinity)
                    }
                    .navigationTitle("LC Repeater").navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .sheet(isPresented: $showingDevice) {
            if #available(iOS 26.0, *) {
                LocalLessonView { id in
                    openLessonID = id
                    showingDevice = false
                    showingLibrary = true
                }
            } else {
                NavigationStack {
                    ContentUnavailableView("iOS 26 이상이 필요해요", systemImage: "iphone.badge.exclamationmark",
                        description: Text("기기에서 전사·번역하려면 iOS를 업데이트해 주세요. 컴퓨터에서 준비한 레슨은 지금도 가져올 수 있어요."))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { showingDevice = false } } }
                }
            }
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            guard !showingDevice else {
                library.error = "기기에서 만들기 화면을 닫은 뒤 레슨 파일을 다시 열어 주세요."
                return
            }
            showingLibrary = true
            Task { await library.importArchive(at: url) }
        }
        .alert("알림", isPresented: Binding(get: { !showingLibrary && !showingDevice && library.error != nil },
                                          set: { if !$0 { library.error = nil } })) {
            Button("확인", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .onChange(of: player.sentenceID) { _, value in
            library.savePosition(lessonID: player.lessonID, sentenceID: value)
        }
        .onChange(of: player.lessonID) { _, value in
            library.savePosition(lessonID: value, sentenceID: player.sentenceID)
        }
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("--smoke-test") { showingLibrary = true }
            if CommandLine.arguments.contains("--smoke-device-screen") { showingDevice = true }
            if CommandLine.arguments.contains("--smoke-local-test") { await runLocalFixtureSmokeTest() }
            #endif
        }
    }

    private func choice(_ title: String, subtitle: String, icon: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).frame(width: 36)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    #if DEBUG
    /// Tests real audio conversion/storage with deterministic text. No model inference is mocked as a success.
    private func runLocalFixtureSmokeTest() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let id = UUID()
        var staging: URL?
        var report: [String: Any] = ["source": "fixture", "created": false]
        do {
            guard let source = library.entries.first else { throw LessonError.invalidLesson }
            let folder = try library.localStagingArea(for: id)
            staging = folder
            let audio = try await LocalAudioPreparer().prepare(source: library.audioURL(for: source.id), folder: folder) { _ in }
            var sentences = try TranscriptSegmenter.sentences(from: [
                .init(text: "Hello, world.", start: 0.1, end: 0.8),
                .init(text: "Please try again.", start: 1.0, end: 1.8)
            ], duration: audio.duration)
            sentences[0].ko = "안녕하세요."
            sentences[1].ko = "다시 해 보세요."
            let lesson = Lesson(id: id.uuidString, title: "기기 처리 확인 레슨", duration: audio.duration,
                                created: Date().timeIntervalSince1970, sentences: sentences)
            let entry = try library.finishLocalLesson(lesson, id: id, staging: folder)
            staging = nil
            let file = try AVAudioFile(forReading: library.audioURL(for: entry.id))
            report["created"] = true
            report["sentences"] = entry.lesson.sentences.count
            report["sample_rate"] = Int(file.processingFormat.sampleRate)
            report["channels"] = Int(file.processingFormat.channelCount)
            report["frames"] = Int(file.length)
            // Position saving must work while the start screen, not LibraryView, is mounted.
            player.load(entry, audioURL: library.audioURL(for: entry.id), savedSentence: 2)
            if let error = player.error {
                throw NSError(domain: "LocalSmokePlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            for _ in 0..<20 {
                if library.savedSentence(for: entry.id) == 2 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            report["saved_sentence"] = library.savedSentence(for: entry.id) ?? 0
            openLessonID = entry.id
            showingLibrary = true
        } catch {
            report["error"] = error.localizedDescription
            report["diagnostic"] = String(reflecting: error)
        }
        if let staging { try? FileManager.default.removeItem(at: staging) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: documents.appendingPathComponent("local-smoke-result.json"), options: .atomic)
        }
    }
    #endif
}
