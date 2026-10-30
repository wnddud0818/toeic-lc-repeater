import SwiftUI
import Translation
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct LocalLessonView: View {
    @EnvironmentObject private var library: LessonLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var processor = LocalLessonProcessor()
    @State private var showingPicker = false
    @State private var checking = true
    @State private var availabilityError: String?
    @State private var configuration: TranslationSession.Configuration?
    let onComplete: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("기기에서 시작하기", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.title2.bold()).padding(.vertical, 8)
                    Text("영어 음원에서 문장을 나누고 한국어 번역까지 이 기기에서 처리해요.")
                    Text("처음에는 영어 전사·영한 번역 모델을 내려받아요. 준비된 뒤에는 오프라인으로 처리할 수 있어요.")
                        .font(.subheadline).foregroundStyle(.secondary)
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
                        Button(processor.sourceURL == nil ? "음원 선택하기" : "다른 음원 선택하기",
                               systemImage: "doc.badge.plus") { showingPicker = true }
                            .disabled(processor.isBusy)
                    } footer: {
                        Text("MP3·M4A·WAV 등의 영어 음원을 ‘파일’ 앱에서 선택해 주세요.")
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
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): processor.select(url); start()
            case .failure: break // Cancelling the system picker does not start a job.
            }
        }
        .translationTask(configuration) { session in
            if let id = await processor.run(session: session, library: library) { onComplete(id) }
        }
        .task { await checkAvailability() }
        .onChange(of: processor.isBusy) { _, busy in UIApplication.shared.isIdleTimerDisabled = busy }
        .onDisappear {
            processor.stopAndDiscard()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func start() {
        if configuration == nil { configuration = LocalLessonProcessor.configuration() }
        else { configuration?.invalidate() }
    }

    private func checkAvailability() async {
        checking = true
        availabilityError = await LocalLessonProcessor.availabilityError()
        checking = false
    }
}
