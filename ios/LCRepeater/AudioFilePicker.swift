import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Import a provider-managed audio file as a local copy. Keep the delegate alive
/// for the whole presentation, and report both selection and cancellation.
struct AudioFilePicker: UIViewControllerRepresentable {
    var initialDirectory: URL? = nil
    let onSelection: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.directoryURL = initialDirectory
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: (URL?) -> Void
        private var completed = false

        init(onSelection: @escaping (URL?) -> Void) { self.onSelection = onSelection }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

        private func finish(_ url: URL?) {
            guard !completed else { return }
            completed = true
            onSelection(url)
        }
    }
}
