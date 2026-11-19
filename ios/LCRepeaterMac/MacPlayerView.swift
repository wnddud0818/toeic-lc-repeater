import AppKit
import SwiftUI
import Translation

struct MacPlayerView: View {
    let entry: LibraryEntry
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var player: RepeaterPlayer
    @EnvironmentObject private var state: MacAppState
    @EnvironmentObject private var engine: EngineStatus
    @AppStorage("mac.showSentenceList") private var showingList = true

    // Translating again from the player (Apple needs a session from `.translationTask`).
    @State private var translating = false
    @State private var translationStatus = ""
    @State private var translationProgress: Double?
    @State private var translationError: String?
    @State private var pendingTranslation: Lesson?
    @State private var pendingOnlyMissing = true
    @State private var appleConfiguration: TranslationSession.Configuration?
    @State private var appleConfigurationLanguage: StudyLanguage?
    @State private var claudeTask: Task<Void, Never>?

    private var language: StudyLanguage { entry.lesson.language }
    private var missingTranslations: Int { entry.lesson.sentences.filter { $0.ko.isEmpty }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                translationBanner
                if let sentence = player.currentSentence, player.lessonID == entry.id {
                    card(sentence)
                    counter
                    controls
                    settings
                    trim(sentence)
                    Text("Space 재생/정지 · ← → 이전/다음 문장 · T 원문 공개/한국어/가리기 · R 처음부터")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ProgressView().padding(60)
                }
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(entry.lesson.title)
        .navigationSubtitle([library.folder(for: entry.folderID)?.name, language.name,
                             "\(entry.lesson.sentences.count)문장"].compactMap { $0 }.joined(separator: " · "))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Apple 기기 내 번역으로 다시 번역") { translate(with: .apple, onlyMissing: false) }
                    Button("Claude로 다시 번역") { translate(with: .claude, onlyMissing: false) }
                } label: {
                    Label("다시 번역", systemImage: "character.bubble")
                }
                .help("이 레슨의 한국어 번역을 다시 만들어요")
                .disabled(translating)
                Button("아이폰용으로 내보내기", systemImage: "square.and.arrow.up") {
                    state.export(entry, library: library)
                }
                .help("아이폰 앱에서 가져올 .lrlesson 파일로 저장 (⌘E)")
                Button("문장 목록", systemImage: "sidebar.right") { showingList.toggle() }
                    .help("문장 목록 보기/숨기기")
            }
        }
        .inspector(isPresented: $showingList) {
            sentenceList
                .inspectorColumnWidth(min: 260, ideal: 340, max: 480)
        }
        .onAppear {
            state.cardFace = .hidden
            player.load(entry, audioURL: library.audioURL(for: entry.id), savedSentence: library.savedSentence(for: entry.id))
        }
        .onChange(of: entry.lesson) { _, _ in
            let wasPlaying = player.isPlaying
            let keep = player.sentenceID
            player.load(entry, audioURL: library.audioURL(for: entry.id), savedSentence: keep)
            if wasPlaying { player.play(sentenceID: keep) }
        }
        .onChange(of: player.sentenceID) { _, _ in state.cardFace = .hidden }
        .translationTask(appleConfiguration) { session in
            await translateWithApple(session)
        }
        .onDisappear { claudeTask?.cancel() }
    }

    // MARK: - Card

    private func card(_ sentence: Sentence) -> some View {
        let face = state.cardFace
        let text = face == .korean ? (sentence.ko.isEmpty ? "번역이 아직 없어요" : sentence.ko) : sentence.en
        let hint: String = switch face {
        case .hidden: "클릭하면 \(language.name) 공개"
        case .source: "클릭하면 한국어"
        case .korean: "클릭하면 \(language.name) 가리기"
        }
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { state.cardFace = face.next }
        } label: {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("\(player.position + 1) / \(player.visibleSentences.count)")
                    Spacer()
                    Text(face == .korean ? "KO" : language.badge).fontWeight(.bold)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(face == .korean && sentence.ko.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .blur(radius: face == .hidden ? 9 : 0)
                    .accessibilityHidden(face == .hidden)
                HStack {
                    if sentence.kind == "direction" { Text("시험 안내").foregroundStyle(.orange) }
                    Spacer()
                    Text(hint)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .background(face == .korean ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(face == .hidden ? "\(language.name)가 가려진 문장. \(hint)" : "\(text). \(hint)")
    }

    private var counter: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(player.repetition)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text("/ \(player.settings.repetitions == 0 ? "∞" : String(player.settings.repetitions))회")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(player.phase).font(.callout).foregroundStyle(.secondary)
            }
            ProgressView(value: player.progress).accessibilityLabel("현재 문장 재생 진행률")
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            control("처음부터 (R)", symbol: "arrow.counterclockwise") { player.play(sentenceID: player.sentenceID) }
            control("이전 문장 (←)", symbol: "backward.end.fill", disabled: player.position == 0) { player.move(-1) }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title).frame(width: 56, height: 56)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            .help(player.isPlaying ? "일시정지 (Space)" : "재생 (Space)")
            control("다음 문장 (→)", symbol: "forward.end.fill",
                    disabled: player.position + 1 >= player.visibleSentences.count) { player.move(1) }
            control("원문 공개/한국어/가리기 (T)", symbol: "eye") { state.cardFace = state.cardFace.next }
        }
    }

    private func control(_ title: String, symbol: String, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3).frame(width: 40, height: 40) }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .disabled(disabled).help(title).accessibilityLabel(title)
    }

    private var settings: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Picker("반복 횟수", selection: $player.settings.repetitions) {
                        ForEach([1, 3, 5, 10, 15, 20, 30, 50, 100], id: \.self) { Text("\($0)회").tag($0) }
                        Text("무한").tag(0)
                    }
                    Picker("속도", selection: $player.settings.speed) {
                        ForEach([0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3], id: \.self) {
                            Text("\($0, specifier: "%.1f")×").tag($0)
                        }
                    }
                }
                GridRow {
                    Picker("반복 사이 쉼", selection: $player.settings.gap) {
                        Text("없음").tag(0.0)
                        ForEach([0.3, 0.6, 1.0, 1.5, 2.0, 3.0], id: \.self) { Text("\($0, specifier: "%g")초").tag($0) }
                        Text("문장 길이만큼(섀도잉)").tag(-1.0)
                    }
                    Toggle("다 들으면 다음 문장으로", isOn: $player.settings.advance)
                }
                GridRow {
                    Toggle("시험 안내 문장 건너뛰기", isOn: $player.settings.hideDirections)
                        .gridCellColumns(2)
                }
            }
            .padding(6)
        }
    }

    private func trim(_ sentence: Sentence) -> some View {
        HStack(spacing: 10) {
            Text("구간").foregroundStyle(.secondary)
            Text("\(clock(sentence.start)) – \(clock(sentence.end)) (\(sentence.duration, specifier: "%.1f")초)")
                .monospacedDigit()
            Spacer()
            Text("시작").foregroundStyle(.secondary)
            Button("−0.1") { nudge(sentence, start: -0.1) }
            Button("+0.1") { nudge(sentence, start: 0.1) }
            Text("끝").foregroundStyle(.secondary).padding(.leading, 6)
            Button("−0.1") { nudge(sentence, end: -0.1) }
            Button("+0.1") { nudge(sentence, end: 0.1) }
        }
        .font(.callout)
        .controlSize(.small)
        .help("문장 앞뒤가 잘리거나 다음 문장이 섞이면 0.1초씩 고쳐요. 고친 값은 저장돼요.")
    }

    private func nudge(_ sentence: Sentence, start: Double = 0, end: Double = 0) {
        let newStart = min(max(0, sentence.start + start), sentence.end - 0.2)
        let newEnd = max(min(entry.lesson.duration, sentence.end + end), newStart + 0.2)
        do { try library.updateRange(in: entry.id, sentenceID: sentence.i, start: newStart, end: newEnd) }
        catch { state.message = "구간을 고치지 못했어요: \(error.localizedDescription)" }
    }

    // MARK: - Sentence list

    private var sentenceList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { player.sentenceID },
                                    set: { if let id = $0, id != player.sentenceID { player.play(sentenceID: id) } })) {
                Section("문장 \(player.visibleSentences.count)개") {
                    ForEach(player.visibleSentences) { sentence in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sentence.en)
                                .foregroundStyle(sentence.kind == "direction" ? .secondary : .primary)
                            if !sentence.ko.isEmpty {
                                Text(sentence.ko).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(sentence.i)
                        .id(sentence.i)
                    }
                }
            }
            .onChange(of: player.sentenceID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: - Translation

    @ViewBuilder
    private var translationBanner: some View {
        if translating {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(translationStatus).font(.callout)
                        Spacer()
                        Button("취소") { cancelTranslation() }.controlSize(.small)
                    }
                    if let translationProgress { ProgressView(value: translationProgress) } else { ProgressView() }
                }
            }
        } else if let translationError {
            GroupBox {
                HStack(alignment: .top) {
                    Label(translationError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Spacer()
                    Button("닫기") { self.translationError = nil }.controlSize(.small)
                }
            }
        } else if missingTranslations > 0 {
            GroupBox {
                HStack {
                    Label("번역이 없는 문장 \(missingTranslations)개", systemImage: "character.bubble")
                    Spacer()
                    Button("Apple로 번역") { translate(with: .apple, onlyMissing: true) }
                    Button("Claude로 번역") { translate(with: .claude, onlyMissing: true) }
                }
                .controlSize(.small)
            }
        }
    }

    private func translate(with choice: TranslationChoice, onlyMissing: Bool) {
        guard !translating else { return }
        translationError = nil
        var lesson = entry.lesson
        if !onlyMissing {
            for index in lesson.sentences.indices { lesson.sentences[index].ko = "" }
        }
        pendingTranslation = lesson
        pendingOnlyMissing = onlyMissing
        switch choice {
        case .apple:
            if appleConfiguration == nil || appleConfigurationLanguage != language {
                appleConfiguration = AppleLessonTranslator.configuration(for: language)
                appleConfigurationLanguage = language
            } else {
                appleConfiguration?.invalidate()
            }
        case .claude:
            guard engine.helperBundled else { translationError = EngineError.missingHelper.message; return }
            translating = true
            translationStatus = "Claude로 번역하는 중이에요"
            translationProgress = 0
            claudeTask = Task {
                defer { translating = false; pendingTranslation = nil }
                do {
                    let result = try await ClaudeTranslator.translate(lesson, onlyMissing: false) { fraction in
                        translationProgress = fraction
                    }
                    try Task.checkCancellation()
                    try save(result, keepingExisting: onlyMissing)
                } catch is CancellationError {
                } catch {
                    translationError = "번역하지 못했어요: \(error.localizedDescription)"
                }
            }
        }
    }

    private func translateWithApple(_ session: TranslationSession) async {
        guard let lesson = pendingTranslation, !translating else { return }
        let onlyMissing = pendingOnlyMissing
        translating = true
        translationStatus = "\(language.name)→한국어 번역 모델을 준비하는 중이에요"
        translationProgress = nil
        defer { translating = false; pendingTranslation = nil }
        do {
            if await AppleLessonTranslator.unsupportedError(for: language) != nil {
                throw MacProcessingError.translationUnavailable(language)
            }
            try await session.prepareTranslation()
            translationStatus = "Apple 기기 내 번역 중이에요"
            let result = try await AppleLessonTranslator.translateMissing(in: lesson, session: session) { updated in
                translationProgress = Double(updated.sentences.filter { !$0.ko.isEmpty }.count)
                    / Double(max(1, updated.sentences.count))
            }
            try save(result, keepingExisting: onlyMissing)
        } catch is CancellationError {
        } catch {
            translationError = "번역하지 못했어요: \(error.localizedDescription)"
        }
    }

    /// Writes the translation to the current lesson (its trimmed ranges may have changed meanwhile).
    private func save(_ translated: Lesson, keepingExisting: Bool) throws {
        guard let current = library.entry(for: entry.id)?.lesson else { return }
        try library.updateLesson(entry.id, ClaudeTranslator.merge(translated, into: current, onlyMissing: keepingExisting))
    }

    private func cancelTranslation() {
        claudeTask?.cancel()
        appleConfiguration = nil
        appleConfigurationLanguage = nil
        translating = false
    }
}

private func clock(_ seconds: Double) -> String {
    String(format: "%d:%04.1f", Int(seconds / 60), seconds.truncatingRemainder(dividingBy: 60))
}
