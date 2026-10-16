import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Only open-in-place. No export/new-file picker is implemented. The application feature flag is disabled by default.
@MainActor
struct FilesDocumentPicker: UIViewControllerRepresentable {
    let onPick: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .text], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: @MainActor (URL) -> Void
        private let onCancel: @MainActor () -> Void
        private var finished = false
        init(onPick: @escaping @MainActor (URL) -> Void, onCancel: @escaping @MainActor () -> Void) { self.onPick = onPick; self.onCancel = onCancel }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !finished else { return }; finished = true
            guard urls.count == 1, let url = urls.first, url.isFileURL else { onCancel(); return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !finished else { return }; finished = true; onCancel()
        }
    }
}
