import SwiftUI
import Translation

@available(iOS 26.0, *)
struct LocalLessonView: View {
    @EnvironmentObject private var library: LessonLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var processor = LocalLessonProcessor()
    @State private var showingPicker = false
    @State private var checking = true
    @State private var availabilityError: String?
    @State private var configuration: TranslationSession.Configuration?
    @AppStorage("lcr.localLessonLanguage") private var languageCode = StudyLanguage.english.rawValue
    @AppStorage("lcr.localLessonFolder") private var folderCode = ""
    /// Files chosen together that wait behind the one being processed.
    @State private var pending: [URL] = []
    @State private var completed: [UUID] = []
    @Binding var incomingAudio: URL?
    @Binding var incomingError: String?
    let onBusyChange: (Bool) -> Void
    let onComplete: (UUID) -> Void

    private var language: StudyLanguage { StudyLanguage(rawValue: languageCode) ?? .english }
    private var folderID: UUID? { library.folder(for: UUID(uuidString: folderCode))?.id }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("기기에서 시작하기", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.title2.bold()).padding(.vertical, 8)
                    Text("\(language.name) 음원에서 문장을 나누고 한국어 번역까지 이 기기에서 처리해요.")
                    Text("처음에는 \(language.name) 전사·한국어 번역 모델을 내려받아요. 준비된 뒤에는 오프라인으로 처리할 수 있어요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("음원 언어") {
                    Picker("음원 언어", selection: Binding(get: { language }, set: { languageCode = $0.rawValue })) {
                        ForEach(StudyLanguage.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(processor.isBusy)
                }
                if !library.folders.isEmpty {
                    Section("저장할 폴더") {
                        Picker("저장할 폴더", selection: Binding(get: { folderID }, set: { folderCode = $0?.uuidString ?? "" })) {
                            Text("폴더 없음").tag(UUID?.none)
                            ForEach(library.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                        .disabled(processor.isBusy)
                    }
                }
                if checking {
                    Section { HStack { ProgressView(); Text("이 기기의 지원 여부를 확인하고 있어요") } }
                } else if let availabilityError {
                    Section {
                        Label(availabilityError, systemImage: "info.circle")
                        Button("다시 확인") { Task { await checkAvailability() } }
                        Button("시작 화면으로") { dismiss() }
                    }
                } else {
                    Section {
                        if let url = processor.sourceURL {
                            Label(url.lastPathComponent, systemImage: "waveform").lineLimit(2)
                        }
                        if !pending.isEmpty || !completed.isEmpty {
                            Text(queueSummary).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(processor.sourceURL == nil ? "음원 선택하기" : "다른 음원 선택하기",
                               systemImage: "doc.badge.plus") { showingPicker = true }
                            .disabled(processor.isBusy)
                    } footer: {
                        Text("MP3·M4A·WAV 등의 \(language.name) 음원을 ‘파일’ 앱에서 선택해 주세요. 여러 개를 고르면 차례로 처리해요.")
                    }
                    if processor.sourceURL != nil {
                        Section {
                            Text(processor.status).font(.headline)
                            if processor.isBusy {
                                if let fraction = processor.progress {
                                    ProgressView(value: fraction)
                                } else { ProgressView() }
                                Button("처리 취소", role: .destructive) { processor.cancel() }
                            }
                            if processor.sentenceCount > 0 {
                                Text("\(processor.sentenceCount)문장").font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = processor.error {
                                Text(error).foregroundStyle(.red)
                            }
                            if !processor.isBusy {
                                Button(processor.canRetryTranslation ? "번역 다시 시도" : "다시 시도") { start() }
                                if !pending.isEmpty {
                                    Button("이 파일 건너뛰고 다음 파일 처리") { skipCurrent() }
                                }
                            }
                        } footer: {
                            Text("처리하는 동안 앱을 열어 두세요. 완료되면 내 레슨에 저장돼요.")
                        }
                    }
                }
                Section {
                    Text("전사와 번역은 애플의 기기 내 모델로 처리해요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("기기에서 레슨 만들기").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { processor.discard(); dismiss() }.disabled(processor.isBusy)
                }
            }
        }
        .interactiveDismissDisabled(processor.isBusy)
        .background {
            AudioFilePicker(isPresented: $showingPicker, allowsMultipleSelection: true) { urls in
                // The picker finishes dismissing before invoking this callback.
                guard let first = urls.first else { return }
                completed = []
                pending = Array(urls.dropFirst())
                processor.select(first)
                start()
            }.frame(width: 0, height: 0)
        }
        .translationTask(configuration) { session in
            await runQueue(session)
        }
        .task {
            processor.setLanguage(language)
            await checkAvailability()
        }
        .onChange(of: languageCode) { _, _ in
            guard !processor.isBusy else { return }
            processor.setLanguage(language)
            pending = []
            completed = []
            configuration = nil  // The next start builds a session for the new language pair.
            Task { await checkAvailability() }
        }
        .onChange(of: incomingAudio) { _, _ in acceptIncomingAudio() }
        .onChange(of: processor.isBusy) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy
            onBusyChange(busy)
        }
        .alert("알림", isPresented: Binding(get: { incomingError != nil },
                                           set: { if !$0 { incomingError = nil } })) {
            Button("확인", role: .cancel) { incomingError = nil }
        } message: { Text(incomingError ?? "") }
        .onDisappear {
            processor.stopAndDiscard()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var queueSummary: String {
        var parts: [String] = []
        if !completed.isEmpty { parts.append("완료 \(completed.count)개") }
        if !pending.isEmpty { parts.append("이어서 처리할 파일 \(pending.count)개") }
        return parts.joined(separator: " · ")
    }

    /// Processes the current file, then the rest with the same translation session.
    /// Stops at a failure so it can be retried or skipped.
    private func runQueue(_ session: TranslationSession) async {
        while true {
            guard let id = await processor.run(session: session, library: library, folderID: folderID) else { return }
            completed.append(id)
            guard !pending.isEmpty else { break }
            processor.select(pending.removeFirst())
        }
        if let last = completed.last { onComplete(last) }
    }

    private func skipCurrent() {
        guard !processor.isBusy, !pending.isEmpty else { return }
        processor.select(pending.removeFirst())
        start()
    }

    private func start() {
        if configuration == nil { configuration = LocalLessonProcessor.configuration(for: processor.language) }
        else { configuration?.invalidate() }
    }

    private func checkAvailability() async {
        checking = true
        let checked = language
        let message = await LocalLessonProcessor.availabilityError(for: checked)
        guard checked == language else { return }  // The language changed while checking.
        availabilityError = message
        checking = false
        acceptIncomingAudio()
    }

    private func acceptIncomingAudio() {
        guard !checking, let url = incomingAudio else { return }
        incomingAudio = nil
        guard availabilityError == nil else { return }
        guard !processor.isBusy else {
            incomingError = "현재 음원의 처리를 완료하거나 취소한 뒤 다시 열어 주세요."
            return
        }
        pending = []
        completed = []
        processor.select(url)
        start()
    }
}
