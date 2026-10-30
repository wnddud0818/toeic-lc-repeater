#if DEBUG
import SwiftUI

/// Exercises the real system picker and decoder without requiring model support.
struct AudioFilePickerSmokeView: View {
    @State private var showingPicker = false
    @State private var selectedURL: URL?
    @State private var result = "선택 전"
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var body: some View {
        VStack(spacing: 24) {
            Button("음원 선택하기") { showingPicker = true }
                .accessibilityIdentifier("picker-smoke.open")
            Text(result).accessibilityIdentifier("picker-smoke.result")
        }
        .sheet(isPresented: $showingPicker, onDismiss: {
            guard let url = selectedURL else { return }
            selectedURL = nil
            Task { await verify(url) }
        }) {
            AudioFilePicker(initialDirectory: documents) { url in
                selectedURL = url
                showingPicker = false
            }
        }
    }

    private func verify(_ url: URL) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let prepared = try await LocalAudioPreparer().prepare(source: url, folder: folder) { _ in }
            guard prepared.duration > 0 else { throw LocalLessonError.invalidAudio }
            result = "가져오기 확인: \(url.lastPathComponent)"
        } catch { result = "가져오기 오류: \(error.localizedDescription)" }
    }
}
#endif
