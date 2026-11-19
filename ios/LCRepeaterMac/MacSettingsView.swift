import AppKit
import SwiftUI

struct MacSettingsView: View {
    @EnvironmentObject private var engine: EngineStatus
    @AppStorage("mac.language") private var language = StudyLanguage.english
    @AppStorage("mac.transcription") private var transcription = TranscriptionChoice.apple
    @AppStorage("mac.translation") private var translation = TranslationChoice.apple

    var body: some View {
        Form {
            Section("새 레슨 기본값") {
                Picker("음원 언어", selection: $language) {
                    ForEach(StudyLanguage.allCases) { Text($0.name).tag($0) }
                }
                Picker("전사", selection: $transcription) {
                    ForEach(TranscriptionChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("번역", selection: $translation) {
                    ForEach(TranslationChoice.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Apple 기기 내 처리") {
                ForEach(StudyLanguage.allCases) { language in
                    LabeledContent(language.name) {
                        Text("전사 \(mark(engine.appleSpeech[language])) · 한국어 번역 \(mark(engine.appleTranslation[language]))")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("처음 쓸 때 언어 모델을 내려받으며, 그 뒤에는 인터넷 없이 처리해요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Whisper 음성 인식") {
                if !engine.helperBundled {
                    Text(EngineError.missingHelper.message).foregroundStyle(.secondary)
                } else if engine.modelReady {
                    LabeledContent("모델", value: "\(Engine.modelName) · 준비됨")
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([Engine.modelURL]) }
                } else {
                    LabeledContent("모델", value: "없음 (547MB)")
                    if engine.downloading {
                        if let fraction = engine.downloadFraction {
                            ProgressView(value: fraction) { Text("내려받는 중 \(Int(fraction * 100))%") }
                        } else {
                            ProgressView("내려받는 중")
                        }
                    } else {
                        Button("모델 내려받기") { Task { await engine.downloadModel() } }
                    }
                    if let error = engine.downloadError { Text(error).foregroundStyle(.red).font(.caption) }
                    Text("중간에 끊겨도 받은 데까지 이어서 받아요. 이전 맥 앱에서 받은 모델이 있으면 그대로 써요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Claude Code 번역") {
                if !engine.helperBundled {
                    Text(EngineError.missingHelper.message).foregroundStyle(.secondary)
                } else if !engine.claudeChecked {
                    ProgressView("확인하는 중").controlSize(.small)
                } else if let path = engine.claudePath {
                    LabeledContent("claude", value: path)
                    Text("로그인되어 있지 않으면 번역할 때 알려 드려요. 터미널에서 claude를 실행해 /login 해 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("claude 명령을 찾지 못했어요. Claude Code를 설치하고 터미널에서 claude를 실행해 /login 해 주세요.")
                        .foregroundStyle(.secondary)
                }
                Button("다시 확인") { Task { await engine.refresh() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await engine.refresh() }
    }

    private func mark(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "가능"
        case .some(false): return "지원 안 함"
        case .none: return "확인 중"
        }
    }
}
