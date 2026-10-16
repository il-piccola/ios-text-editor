import SwiftUI
import UIKit

/// UITextView owns live text, marked text, selection, scrolling and undo.
@MainActor
struct UIKitEditorSurface: UIViewRepresentable {
    let configuration: EditorSurfaceConfiguration
    let router: EditorCommandRouter
    let onSnapshot: @MainActor (EditorSnapshot) -> Void
    // Injectable for observing actual UIKit writes in native regression tests.
    var makeTextView: @MainActor () -> UITextView = { UITextView() }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = makeTextView()
        // The ONLY text assignment: the seed for a new editing session.
        view.text = configuration.initialText
        view.isEditable = configuration.isEditable
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.alwaysBounceVertical = true
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.accessibilityLabel = "本文"
        view.accessibilityHint = "テキストを編集できます。端末の下書き保存状態は画面下部で確認できます。"

        let sessionID = configuration.sessionID
        let coordinator = context.coordinator
        view.delegate = coordinator
        router.install(sessionID: sessionID, handler: { [weak view, weak coordinator] command in
            guard let view else { return }
            switch command {
            case .undo:
                guard view.isEditable else { return }
                view.undoManager?.undo()
            case .redo:
                guard view.isEditable else { return }
                view.undoManager?.redo()
            case .dismissKeyboard: view.resignFirstResponder()
            }
            coordinator?.publish(view)
        }, snapshotProvider: { [weak view] in
            guard let view else { return nil }
            return EditorSnapshot(sessionID: sessionID, text: view.text ?? "", isComposing: view.markedTextRange != nil)
        }, previewProvider: { [weak view, weak coordinator] request in
            guard let view, let coordinator else { throw EditorPlannerError.unavailable }
            return try coordinator.preview(view, request: request)
        }, replacementHandler: { [weak view, weak coordinator] preview in
            guard let view, let coordinator else { return .rejected("編集欄を確認できません。") }
            guard preview.originalSelection.nsRange == view.selectedRange else {
                return .rejected("選択範囲が変わりました。プレビューを作り直してください。")
            }
            return coordinator.apply(view, request: EditorTextApplication(sessionID: preview.sessionID,
                expectedText: preview.originalText, text: preview.candidate, actionName: "一括置換"),
                selection: preview.selection)
        }, textApplicationHandler: { [weak view, weak coordinator] request in
            guard let view, let coordinator else { return .rejected("編集欄を確認できません。") }
            let end = (request.text as NSString).length
            return coordinator.apply(view, request: request, selection: EditorUTF16Range(location: end, length: 0))
        })
        coordinator.refreshCapabilities(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.isEditable != configuration.isEditable { view.isEditable = configuration.isEditable }
        // Status changes never assign text, selection or contentOffset.
        // A same-session seed change is deliberately ignored.
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.markedTextRange == nil, view.font != font { view.font = font }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.parent.router.uninstall(sessionID: coordinator.sessionID)
        view.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: UIKitEditorSurface
        let sessionID: UUID
        private var lastPublished: EditorSnapshot?
        private var cachedPlanner: ReplacementPlanner?

        init(parent: UIKitEditorSurface) {
            self.parent = parent
            sessionID = parent.configuration.sessionID
        }

        func textViewDidChange(_ view: UITextView) { publish(view) }
        func textViewDidChangeSelection(_ view: UITextView) { publish(view) }
        func textViewDidEndEditing(_ view: UITextView) { publish(view) }

        func publish(_ view: UITextView) {
            let value = EditorSnapshot(sessionID: sessionID, text: view.text ?? "", isComposing: view.markedTextRange != nil)
            if value != lastPublished {
                lastPublished = value
                parent.onSnapshot(value)
            }
            refreshCapabilities(view)
        }

        func refreshCapabilities(_ view: UITextView) {
            let id = sessionID
            let router = parent.router
            let undo = view.undoManager?.canUndo ?? false
            let redo = view.undoManager?.canRedo ?? false
            let composing = view.markedTextRange != nil
            DispatchQueue.main.async {
                router.updateCapabilities(sessionID: id, canUndo: undo, canRedo: redo, isComposing: composing)
            }
        }

        private func planner() throws -> ReplacementPlanner {
            if let cachedPlanner { return cachedPlanner }
            let value = try ReplacementPlanner()
            cachedPlanner = value
            return value
        }

        func preview(_ view: UITextView, request: EditorReplacementRequest) throws -> EditorReplacementPreview {
            guard request.sessionID == sessionID, view.isEditable, view.markedTextRange == nil else {
                throw EditorPlannerError.rejected("変換を確定し、編集できる状態でプレビューを作成してください。")
            }
            defer { cachedPlanner = nil } // Release the JS context and unreferenced output after the crossing.
            return try planner().preview(text: view.text ?? "", selection: view.selectedRange, request: request)
        }

        func apply(_ view: UITextView, request: EditorTextApplication,
                   selection: EditorUTF16Range) -> EditorMutationResult {
            guard request.sessionID == sessionID, view.isEditable, view.markedTextRange == nil else {
                return .rejected("変換中またはファイル切替中です。本文には適用していません。")
            }
            guard (view.text ?? "").utf16.elementsEqual(request.expectedText.utf16) else {
                return .rejected("プレビュー後に本文が変わりました。比較・プレビューを作り直してください。")
            }
            do {
                defer { cachedPlanner = nil }
                try planner().admitApplication(current: view.text ?? "", candidate: request.text)
                let safeSelection = try planner().normalizedSelection(text: request.text, selection: selection)
                if !request.text.utf16.elementsEqual(request.expectedText.utf16) {
                    guard let range = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument),
                          let undo = view.undoManager else {
                        return .rejected("Undo を利用できないため本文への適用を止めました。")
                    }
                    // One native text-input replacement, inside one explicit undo group.
                    // Never assign UITextView.text or write a model echo into the view.
                    undo.beginUndoGrouping()
                    view.replace(range, withText: request.text)
                    view.selectedRange = safeSelection.nsRange
                    undo.setActionName(request.actionName)
                    undo.endUndoGrouping()
                }
                publish(view)
                guard (view.text ?? "").utf16.elementsEqual(request.text.utf16) else {
                    return .rejected("編集面が候補の全文を適用できませんでした。実際の本文は下書き保護へ通知しています。保存元の更新は行いません。")
                }
                return .applied(EditorSnapshot(sessionID: sessionID, text: view.text ?? "",
                                               isComposing: view.markedTextRange != nil))
            } catch { return .rejected(error.localizedDescription) }
        }
    }
}
