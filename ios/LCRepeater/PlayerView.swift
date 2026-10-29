import SwiftUI

struct PlayerView: View {
    let entry: LibraryEntry
    @EnvironmentObject private var library: LessonLibrary
    @EnvironmentObject private var player: RepeaterPlayer
    @State private var showingKorean = false
    @State private var showingSentences = false
    @State private var trimming: Sentence?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let sentence = player.currentSentence, player.lessonID == entry.id {
                    Button { showingKorean.toggle() } label: {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack {
                                Text("\(player.position + 1) / \(player.visibleSentences.count)")
                                Spacer()
                                Text(showingKorean ? "KO" : "EN").fontWeight(.bold)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            Text(showingKorean ? (sentence.ko.isEmpty ? "번역이 아직 없어요" : sentence.ko) : sentence.en)
                                .font(.title2.weight(.semibold)).foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                                .multilineTextAlignment(.leading)
                            HStack {
                                if sentence.kind == "direction" { Text("시험 안내").foregroundStyle(.orange) }
                                Spacer()
                                Text(showingKorean ? "탭하면 영어" : "탭하면 한국어")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(showingKorean ? Color.accentColor.opacity(0.09) : Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showingKorean ? "한국어 문장. 탭하면 영어" : "영어 문장. 탭하면 한국어")
                    .accessibilityValue(showingKorean ? sentence.ko : sentence.en)

                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(player.repetition)").font(.system(.largeTitle, design: .rounded).bold())
                            Text("/ \(player.settings.repetitions == 0 ? "∞" : String(player.settings.repetitions))회")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(player.phase).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        ProgressView(value: player.progress).accessibilityLabel("현재 문장 재생 진행률")
                    }

                    HStack(spacing: 22) {
                        control("처음부터", symbol: "arrow.counterclockwise") { player.play(sentenceID: sentence.i) }
                        control("이전 문장", symbol: "backward.end.fill", disabled: player.position == 0) { player.move(-1) }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title).frame(width: 64, height: 64)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
                        control("다음 문장", symbol: "forward.end.fill",
                                disabled: player.position + 1 >= player.visibleSentences.count) { player.move(1) }
                    }

                    GroupBox {
                        VStack(spacing: 8) {
                            settingRow("반복 횟수") {
                                Picker("반복 횟수", selection: $player.settings.repetitions) {
                                    ForEach([1, 3, 5, 10, 15, 20, 30, 50, 100], id: \.self) { Text("\($0)회").tag($0) }
                                    Text("무한").tag(0)
                                }
                            }
                            settingRow("반복 사이 쉼") {
                                Picker("반복 사이 쉼", selection: $player.settings.gap) {
                                    Text("없음").tag(0.0)
                                    ForEach([0.3, 0.6, 1.0, 1.5, 2.0, 3.0], id: \.self) {
                                        Text("\($0, specifier: "%g")초").tag($0)
                                    }
                                    Text("문장 길이만큼").tag(-1.0)
                                }
                            }
                            settingRow("속도") {
                                Picker("속도", selection: $player.settings.speed) {
                                    ForEach([0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3], id: \.self) {
                                        Text("\($0, specifier: "%.1f")×").tag($0)
                                    }
                                }
                            }
                            Divider()
                            Toggle("다 들으면 다음 문장으로", isOn: $player.settings.advance)
                            Toggle("시험 안내 문장 건너뛰기", isOn: $player.settings.hideDirections)
                        }
                        .font(.subheadline)
                    }

                    HStack {
                        Text("\(clock(sentence.start)) – \(clock(sentence.end))").monospacedDigit()
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("구간 조절", systemImage: "slider.horizontal.3") { trimming = sentence }
                            .font(.subheadline)
                    }
                } else {
                    ProgressView().padding(50)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(entry.lesson.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("문장 목록", systemImage: "list.bullet") { showingSentences = true }
            }
        }
        .onAppear { loadEntry() }
        .onChange(of: entry.lesson) { _, _ in
            let wasPlaying = player.isPlaying
            let keep = player.sentenceID
            player.load(entry, audioURL: library.audioURL(for: entry.id), savedSentence: keep)
            if wasPlaying { player.play(sentenceID: keep) }
        }
        .onChange(of: player.sentenceID) { _, _ in showingKorean = false }
        .sheet(isPresented: $showingSentences) {
            NavigationStack {
                List(player.visibleSentences) { sentence in
                    Button {
                        player.play(sentenceID: sentence.i)
                        showingSentences = false
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: player.sentenceID == sentence.i ? "speaker.wave.2.fill" : "circle")
                                .foregroundStyle(.tint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(sentence.en).foregroundStyle(.primary)
                                if !sentence.ko.isEmpty { Text(sentence.ko).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .navigationTitle("문장 목록").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { showingSentences = false } } }
            }
        }
        .sheet(item: $trimming) { sentence in
            TrimView(sentence: sentence, lessonDuration: entry.lesson.duration) { start, end in
                try library.updateRange(in: entry.id, sentenceID: sentence.i, start: start, end: end)
            }
        }
    }

    private func loadEntry() {
        player.load(entry, audioURL: library.audioURL(for: entry.id), savedSentence: library.savedSentence(for: entry.id))
    }

    private func control(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3).frame(width: 36, height: 44) }
            .disabled(disabled).accessibilityLabel(title)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack { Text(title); Spacer(); content().labelsHidden().pickerStyle(.menu) }
    }
}

private func clock(_ seconds: Double) -> String {
    String(format: "%d:%04.1f", Int(seconds / 60), seconds.truncatingRemainder(dividingBy: 60))
}

private struct TrimView: View {
    let sentence: Sentence
    let lessonDuration: Double
    let save: (Double, Double) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: Double
    @State private var end: Double
    @State private var error: String?

    init(sentence: Sentence, lessonDuration: Double, save: @escaping (Double, Double) throws -> Void) {
        self.sentence = sentence
        self.lessonDuration = lessonDuration
        self.save = save
        _start = State(initialValue: sentence.start)
        _end = State(initialValue: sentence.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(sentence.en) }
                Section("0.1초씩 조절") {
                    Stepper("시작 \(clock(start))", value: $start, in: max(0, end - 120)...max(0, end - 0.1), step: 0.1)
                    Stepper("끝 \(clock(end))", value: $end, in: (start + 0.1)...min(lessonDuration, start + 120), step: 0.1)
                }
                Section { Text("고친 구간은 아이폰에 저장돼요. PC의 레슨은 바뀌지 않아요.").font(.caption) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("구간 조절").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        do { try save(start, end); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
