import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Present the document picker directly, rather than embedding it as a child of
/// a SwiftUI sheet. UIKit owns its modal lifecycle and the delegate stays alive
/// until dismissal completes.
struct AudioFilePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var initialDirectory: URL? = nil
    let onSelection: (URL?) -> Void

    func makeUIViewController(context: Context) -> Presenter { Presenter() }

    func updateUIViewController(_ controller: Presenter, context: Context) {
        controller.onSelection = { url in
            isPresented = false
            onSelection(url)
        }
        controller.initialDirectory = initialDirectory
        controller.requestPresentation(isPresented)
    }

    static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
        controller.dismissPicker()
    }

    final class Presenter: UIViewController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        var onSelection: ((URL?) -> Void)?
        var initialDirectory: URL?
        private var requested = false
        private var finishing = false
        private var picker: UIDocumentPickerViewController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            showIfReady()
        }

        func requestPresentation(_ value: Bool) {
            requested = value
            if value { showIfReady() }
            else if picker != nil, !finishing { finish(nil) }
        }

        private func showIfReady() {
            guard requested, picker == nil, !finishing, viewIfLoaded?.window != nil else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            picker.directoryURL = initialDirectory
            picker.modalPresentationStyle = .formSheet
            picker.delegate = self
            self.picker = picker
            present(picker, animated: true)
            picker.presentationController?.delegate = self
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            #if DEBUG
            print("Audio picker selection callback: \(urls.count) file(s)")
            #endif
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish(nil)
        }

        private func finish(_ url: URL?) {
            guard !finishing, let picker else { return }
            finishing = true
            requested = false
            let completion = {
                self.picker = nil
                self.onSelection?(url)
                self.finishing = false
            }
            if picker.presentingViewController != nil { picker.dismiss(animated: true, completion: completion) }
            else { completion() }
        }

        func dismissPicker() {
            requested = false
            onSelection = nil
            picker?.dismiss(animated: false)
            picker = nil
        }
    }
}
