import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Makes lessons from one or more audio files with the same language, transcriber, translator and folder.
struct MacNewLessonView: View {
    /// Files opened or dropped elsewhere; moved into the queue as they arrive.
    @Binding var incoming: [URL]
    let initialFolderID: UUID?
    let onComplete: ([UUID], UUID?) -> Void
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var engine: EngineStatus
    @Environment(\.dismiss) private var dismiss
    @StateObject private var queue = LessonQueue()
    @AppStorage("mac.language") private var language = StudyLanguage.english
    @AppStorage("mac.transcription") private var transcription = TranscriptionChoice.apple
    @AppStorage("mac.translation") private var translation = TranslationChoice.apple
    @State private var folderID: UUID?
    @State private var showingPicker = false
    @State private var dropTargeted = false
    @State private var configuration: TranslationSession.Configuration?
    @State private var configurationLanguage: StudyLanguage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 레슨 만들기").font(.title2.bold())
            fileList
            Form {
                Picker("음원 언어", selection: $language) {
                    ForEach(StudyLanguage.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("전사", selection: $transcription) {
                    ForEach(TranscriptionChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(transcription.detail).font(.caption).foregroundStyle(.secondary)
                Picker("번역", selection: $translation) {
                    ForEach(TranslationChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(translation.detail).font(.caption).foregroundStyle(.secondary)
                Picker("저장할 폴더", selection: $folderID) {
                    Text("폴더 없음").tag(UUID?.none)
                    ForEach(library.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            .formStyle(.grouped)
            .disabled(queue.isRunning)
            notices
            buttons
        }
        .padding(24)
        .frame(width: 640)
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .translationTask(configuration) { session in
            await queue.run(translation: .apple, session: session, library: library, folderID: folderID)
            finishIfDone()
        }
        .onChange(of: language) { _, _ in configureQueue() }
        .onChange(of: transcription) { _, _ in configureQueue() }
        .onChange(of: incoming) { _, _ in takeIncoming() }
        .onAppear {
            folderID = library.folder(for: initialFolderID)?.id
            takeIncoming()
        }
        .task { await engine.refresh() }
        .onDisappear {
            queue.cancel()
            queue.discardAll()
        }
        .interactiveDismissDisabled(queue.isRunning)
    }

    // MARK: - Files

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if queue.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.plus").font(.largeTitle).foregroundStyle(.tint)
                    Text("음원 파일을 여기로 끌어다 놓거나 골라 주세요")
                    Text("MP3 · M4A · WAV 등 · 여러 개를 한꺼번에 넣으면 차례로 처리해요")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("파일 선택…") { showingPicker = true }.padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(queue.items) { item in
                            QueueRow(item: item, builder: item.builder, canRemove: !queue.isRunning) {
                                queue.remove(item)
                            }
                            Divider()
                        }
                    }
                }
                .frame(height: min(CGFloat(queue.items.count) * 58, 240))
                HStack {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if queue.items.contains(where: { $0.lessonID != nil }) && !queue.isRunning {
                        Button("완료된 항목 지우기") { queue.clearFinished() }.controlSize(.small)
                    }
                    Button("파일 추가…") { showingPicker = true }.controlSize(.small).disabled(queue.isRunning)
                }
                .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                          style: StrokeStyle(lineWidth: 1, dash: queue.items.isEmpty ? [5] : [])))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: URL.self) { urls, _ in
            guard !queue.isRunning else { return false }
            add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var summary: String {
        let done = queue.finishedIDs.count
        var parts = ["파일 \(queue.items.count)개"]
        if done > 0 { parts.append("완료 \(done)") }
        if queue.failedCount > 0 { parts.append("실패 \(queue.failedCount)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Notices

    /// Problems that stop the chosen options from working.
    private var blockers: [String] {
        var result: [String] = []
        switch transcription {
        case .apple:
            if engine.appleSpeech[language] == false {
                result.append(MacProcessingError.speechUnavailable(language).localizedDescription)
            }
        case .whisper:
            if !engine.helperBundled { result.append(EngineError.missingHelper.message) }
        }
        if translation == .apple, engine.appleTranslation[language] == false {
            result.append(MacProcessingError.translationUnavailable(language).localizedDescription)
        }
        if translation == .claude, !engine.helperBundled, transcription != .whisper {
            result.append(EngineError.missingHelper.message)
        }
        return result
    }

    private var needsModel: Bool { transcription == .whisper && engine.helperBundled && !engine.modelReady }

    @ViewBuilder
    private var notices: some View {
        ForEach(blockers, id: \.self) { text in
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
        if needsModel {
            HStack {
                Label("Whisper 음성 인식 모델(547MB)을 한 번 내려받아야 해요.", systemImage: "arrow.down.circle")
                    .font(.callout)
                Spacer()
                if engine.downloading {
                    if let fraction = engine.downloadFraction {
                        ProgressView(value: fraction).frame(width: 120)
                        Text("\(Int(fraction * 100))%").monospacedDigit().font(.caption)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button("내려받기") { Task { await engine.downloadModel() } }
                }
            }
            if let error = engine.downloadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        if translation == .claude, engine.helperBundled, engine.claudeChecked, engine.claudePath == nil {
            Label("Claude Code를 찾지 못했어요. 설치한 뒤 터미널에서 claude를 실행해 /login 해 주세요. 번역이 안 되면 번역 없이 저장할 수 있어요.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            if queue.isRunning {
                Text("처리하는 동안 이 창을 열어 두세요.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("처리 중지", role: .cancel) { queue.cancel() }
            } else {
                Button("닫기") {
                    let ids = queue.finishedIDs
                    queue.discardAll()
                    if ids.isEmpty { dismiss() } else { onComplete(ids, folderID) }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if !queue.draftsAwaitingTranslation.isEmpty {
                    Button("번역 없이 저장 (\(queue.draftsAwaitingTranslation.count))") {
                        queue.saveDraftsWithoutTranslation(library: library, folderID: folderID)
                        finishIfDone()
                    }
                }
                let remaining = queue.remaining.count
                Button(queue.failedCount > 0 && queue.failedCount == remaining
                       ? "실패한 파일 다시 시도" : remaining > 1 ? "레슨 \(remaining)개 만들기" : "만들기") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(remaining == 0 || !blockers.isEmpty || needsModel)
            }
        }
    }

    // MARK: - Actions

    private func add(_ urls: [URL]) {
        let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
        queue.add(audio, language: language, transcription: transcription)
    }

    private func takeIncoming() {
        guard !incoming.isEmpty, !queue.isRunning else { return }
        add(incoming)
        incoming = []
    }

    private func configureQueue() {
        queue.configure(language: language, transcription: transcription)
    }

    private func start() {
        configureQueue()
        switch translation {
        case .apple:
            // Apple's TranslationSession is only handed out through `.translationTask`; one session
            // serves every file in the queue.
            if configuration == nil || configurationLanguage != language {
                configuration = AppleLessonTranslator.configuration(for: language)
                configurationLanguage = language
            } else {
                configuration?.invalidate()
            }
        case .claude:
            Task {
                await queue.run(translation: .claude, session: nil, library: library, folderID: folderID)
                finishIfDone()
            }
        }
    }

    /// Closes when every file became a lesson; otherwise stays open to show what failed.
    private func finishIfDone() {
        takeIncoming()
        if queue.allDone { onComplete(queue.finishedIDs, folderID) }
    }
}

private struct QueueRow: View {
    @ObservedObject var item: LessonQueue.Item
    @ObservedObject var builder: LessonBuilder
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.outcome {
                case .waiting:
                    Text(builder.hasDraft ? "받아쓰기 완료 · 번역 대기" : "대기 중")
                        .font(.caption).foregroundStyle(.secondary)
                case .running:
                    Text(builder.status).font(.caption).foregroundStyle(.secondary)
                    if let fraction = builder.progress { ProgressView(value: fraction) }
                    else { ProgressView().progressViewStyle(.linear) }
                case .done:
                    Text(builder.sentenceCount > 0 ? "완료 · \(builder.sentenceCount)문장" : "완료")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text((builder.hasDraft ? "번역 실패 · " : "") + message)
                        .font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if canRemove, item.lessonID == nil {
                Button { onRemove() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("목록에서 빼기")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.outcome {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
