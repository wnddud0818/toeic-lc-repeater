import SwiftUI
import Translation
import UniformTypeIdentifiers

struct MacNewLessonView: View {
    let initialAudio: URL?
    let onComplete: (UUID) -> Void
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var engine: EngineStatus
    @Environment(\.dismiss) private var dismiss
    @StateObject private var builder = LessonBuilder()
    @AppStorage("mac.language") private var language = StudyLanguage.english
    @AppStorage("mac.transcription") private var transcription = TranscriptionChoice.apple
    @AppStorage("mac.translation") private var translation = TranslationChoice.apple
    @State private var showingPicker = false
    @State private var dropTargeted = false
    @State private var configuration: TranslationSession.Configuration?
    @State private var configurationLanguage: StudyLanguage?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("새 레슨 만들기").font(.title2.bold())
            sourcePicker
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
            }
            .formStyle(.grouped)
            .disabled(builder.isBusy)
            notices
            if builder.sourceURL != nil || builder.isBusy || builder.error != nil { progressArea }
            buttons
        }
        .padding(24)
        .frame(width: 600)
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { builder.select(url) }
        }
        .translationTask(configuration) { session in
            if let id = await builder.run(translation: .apple, session: session, library: library) {
                onComplete(id)
            }
        }
        .onChange(of: language) { _, _ in configureBuilder() }
        .onChange(of: transcription) { _, _ in configureBuilder() }
        .onAppear {
            configureBuilder()
            if let initialAudio { builder.select(initialAudio) }
        }
        .task { await engine.refresh() }
        .onDisappear { builder.stopAndDiscard() }
        .interactiveDismissDisabled(builder.isBusy)
    }

    // MARK: - Parts

    private var sourcePicker: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(builder.sourceURL?.lastPathComponent ?? "음원 파일을 고르거나 여기로 끌어다 놓으세요")
                    .lineLimit(1).truncationMode(.middle)
                Text("MP3 · M4A · WAV 등").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(builder.sourceURL == nil ? "파일 선택…" : "다른 파일…") { showingPicker = true }
                .disabled(builder.isBusy)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                          style: StrokeStyle(lineWidth: 1, dash: builder.sourceURL == nil ? [5] : [])))
        .dropDestination(for: URL.self) { urls, _ in
            guard !builder.isBusy,
                  let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true })
            else { return false }
            builder.select(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// Problems that stop the chosen options from working, and softer warnings.
    private var blockers: [String] {
        var result: [String] = []
        switch transcription {
        case .apple:
            if engine.appleSpeech[language] == false { result.append(MacProcessingError.speechUnavailable(language).localizedDescription) }
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

    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(builder.status).font(.headline)
            if builder.isBusy {
                if let fraction = builder.progress { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            }
            if builder.sentenceCount > 0 {
                Text("\(builder.sentenceCount)문장").font(.caption).foregroundStyle(.secondary)
            }
            if let error = builder.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private var buttons: some View {
        HStack {
            if builder.isBusy {
                Text("처리하는 동안 이 창을 열어 두세요.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("처리 취소", role: .cancel) { builder.cancel() }
            } else {
                Button("닫기") { builder.discard(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if builder.hasDraft {
                    Button("번역 없이 저장") {
                        if let id = builder.saveWithoutTranslation(library: library) { onComplete(id) }
                    }
                    Button("번역 다시 시도") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!blockers.isEmpty)
                } else {
                    Button("만들기") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(builder.sourceURL == nil || !blockers.isEmpty || needsModel)
                }
            }
        }
    }

    // MARK: - Actions

    private func configureBuilder() {
        builder.configure(language: language, transcription: transcription)
    }

    private func start() {
        configureBuilder()
        switch translation {
        case .apple:
            // Apple's TranslationSession is only handed out through `.translationTask`.
            if configuration == nil || configurationLanguage != language {
                configuration = AppleLessonTranslator.configuration(for: language)
                configurationLanguage = language
            } else {
                configuration?.invalidate()
            }
        case .claude:
            Task {
                if let id = await builder.run(translation: .claude, session: nil, library: library) { onComplete(id) }
            }
        }
    }
}
