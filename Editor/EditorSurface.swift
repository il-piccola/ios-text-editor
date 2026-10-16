import Foundation
import Combine
import SwiftUI

struct EditorSurfaceConfiguration: Equatable {
    let sessionID: UUID
    let initialText: String
    var isEditable: Bool = true
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.isEditable == rhs.isEditable
            && lhs.initialText.utf16.elementsEqual(rhs.initialText.utf16)
    }
}

struct EditorSnapshot: Equatable {
    let sessionID: UUID
    let text: String
    let isComposing: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.isComposing == rhs.isComposing
            && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }
}

struct EditorUTF16Range: Codable, Equatable {
    let location: Int
    let length: Int
    var nsRange: NSRange { NSRange(location: location, length: length) }
}

enum EditorReplacementScope: String, CaseIterable, Identifiable {
    case document, selection
    var id: String { rawValue }
    var label: String { self == .document ? "本文全体" : "選択範囲のみ" }
}

struct EditorReplacementRequest {
    let sessionID: UUID
    let query: String
    let replacement: String
    let scope: EditorReplacementScope
}

struct EditorReplacementPreview {
    let id: UUID
    let sessionID: UUID
    let originalText: String
    let originalSelection: EditorUTF16Range
    let candidate: String
    let selection: EditorUTF16Range
    let count: Int
    let isNoOp: Bool
}

struct EditorTextApplication {
    let sessionID: UUID
    let expectedText: String
    let text: String
    let actionName: String
}

enum EditorMutationResult {
    case applied(EditorSnapshot)
    case rejected(String)
}

enum EditorCommand {
    case undo
    case redo
    case dismissKeyboard
}

/// The single selection point for the native editor implementation.
/// Replace this body to adopt another core without editing the screen.
@MainActor
struct EditorSurface: View {
    let configuration: EditorSurfaceConfiguration
    let router: EditorCommandRouter
    let onSnapshot: @MainActor (EditorSnapshot) -> Void

    var body: some View {
        UIKitEditorSurface(configuration: configuration, router: router, onSnapshot: onSnapshot)
            .id(configuration.sessionID)
    }
}

/// A toolkit-neutral command boundary. UI never retains a UITextView.
@MainActor
final class EditorCommandRouter: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isComposing = false
    private var activeSessionID: UUID?
    private var handler: (@MainActor (EditorCommand) -> Void)?
    private var snapshotProvider: (@MainActor () -> EditorSnapshot?)?
    private var previewProvider: (@MainActor (EditorReplacementRequest) throws -> EditorReplacementPreview)?
    private var replacementHandler: (@MainActor (EditorReplacementPreview) -> EditorMutationResult)?
    private var textApplicationHandler: (@MainActor (EditorTextApplication) -> EditorMutationResult)?

    func install(sessionID: UUID, handler: @escaping @MainActor (EditorCommand) -> Void,
                 snapshotProvider: @escaping @MainActor () -> EditorSnapshot?,
                 previewProvider: (@MainActor (EditorReplacementRequest) throws -> EditorReplacementPreview)? = nil,
                 replacementHandler: (@MainActor (EditorReplacementPreview) -> EditorMutationResult)? = nil,
                 textApplicationHandler: (@MainActor (EditorTextApplication) -> EditorMutationResult)? = nil) {
        activeSessionID = sessionID
        self.handler = handler
        self.snapshotProvider = snapshotProvider
        self.previewProvider = previewProvider
        self.replacementHandler = replacementHandler
        self.textApplicationHandler = textApplicationHandler
    }

    func uninstall(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        handler = nil
        snapshotProvider = nil
        previewProvider = nil
        replacementHandler = nil
        textApplicationHandler = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeSessionID == nil else { return }
            self.canUndo = false
            self.canRedo = false
            self.isComposing = false
        }
    }

    func updateCapabilities(sessionID: UUID, canUndo: Bool, canRedo: Bool, isComposing: Bool) {
        guard activeSessionID == sessionID else { return }
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.isComposing = isComposing
    }

    func snapshot(for sessionID: UUID) -> EditorSnapshot? {
        guard activeSessionID == sessionID,
              let value = snapshotProvider?(), value.sessionID == sessionID else { return nil }
        return value
    }

    func send(_ command: EditorCommand) {
        guard let sessionID = activeSessionID, let value = snapshotProvider?(), value.sessionID == sessionID else { return }
        if value.isComposing {
            if case .dismissKeyboard = command { handler?(command) }
            return
        }
        handler?(command)
    }

    func previewReplacement(_ request: EditorReplacementRequest) throws -> EditorReplacementPreview {
        guard request.sessionID == activeSessionID, let previewProvider else {
            throw EditorPlannerError.unavailable
        }
        return try previewProvider(request)
    }

    func applyReplacement(_ preview: EditorReplacementPreview) -> EditorMutationResult {
        guard preview.sessionID == activeSessionID, let replacementHandler else {
            return .rejected("編集セッションが変わりました。プレビューを作り直してください。")
        }
        return replacementHandler(preview)
    }

    func applyText(_ request: EditorTextApplication) -> EditorMutationResult {
        guard request.sessionID == activeSessionID, let textApplicationHandler else {
            return .rejected("編集セッションが変わりました。内容を再確認してください。")
        }
        return textApplicationHandler(request)
    }
}
