import SwiftUI
import UIKit

/// An immutable inspection surface; it never owns or modifies the live document.
@MainActor
struct EditorTextInspectionSurface: UIViewRepresentable {
    let text: String
    let accessibilityName: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.text = text
        view.accessibilityLabel = accessibilityName
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if !view.text.utf16.elementsEqual(text.utf16) { view.text = text }
        view.accessibilityLabel = accessibilityName
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
    }
}
