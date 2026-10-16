import Foundation

/// UI-only values. Storage decides these states; the view never infers cloud success.
enum DraftPresentation: Equatable {
    case protecting
    case protected(date: Date?, revision: Int)
    case failed(String)

    var label: String {
        switch self {
        case .protecting: return "端末の下書きを保存中"
        case .protected: return "端末に下書き保存済み"
        case .failed: return "端末の下書きを保存できません"
        }
    }
}

enum CloudPresentation: Equatable {
    case noDestination
    case changesPending
    case writing
    case providerAccepted(date: Date?, revision: Int)
    case failed(String)
    case conflict

    var label: String {
        switch self {
        case .noDestination: return "ファイルの保存先は未設定"
        case .changesPending: return "ファイルに未保存の変更あり"
        case .writing: return "ファイルへ書き込み中"
        case .providerAccepted: return "ファイルへ書込済み · クラウド反映未確認"
        case .failed: return "ファイルへの保存に失敗"
        case .conflict: return "保存先に別の変更があります"
        }
    }

    var explanation: String {
        switch self {
        case .noDestination:
            return "「保存先を選ぶ」で検証用の保存先とファイル名を選びます。現在の保存先は端末内の偽保存先です。Files と Google ドライブへの接続は無効です。"
        case .changesPending:
            return "保存ボタンで同じファイルへ書き込みます。端末の下書きと保存先のファイルは別々に管理します。"
        case .writing:
            return "書き込み完了を待っています。保存中に編集した内容は、次の保存が必要な場合があります。"
        case .providerAccepted:
            return "保存先が書き込みを受け付けました。検証中は端末内の偽保存先です。クラウドへの反映完了は確認していません。最新の変更と受け付けた版が異なる場合は、もう一度保存が必要です。"
        case .failed(let message):
            return message + " 下書きを残しています。通信状態や保存先を確認して、もう一度保存してください。"
        case .conflict:
            return "他の端末やアプリで更新された可能性があります。自動でマージや上書きはしません。下書きを別ファイルに保存するか、保存先の内容を確認してください。"
        }
    }

    var symbol: String {
        switch self {
        case .noDestination: return "folder"
        case .changesPending: return "pencil.circle"
        case .writing: return "arrow.triangle.2.circlepath"
        case .providerAccepted: return "questionmark.icloud"
        case .failed, .conflict: return "exclamationmark.triangle"
        }
    }
}

struct RecentFilePresentation: Identifiable, Equatable {
    let id: UUID
    let name: String
    let destination: String
    let lastOpened: Date
    let hasLocalChanges: Bool
}

struct EditorScreenState {
    let configuration: EditorSurfaceConfiguration
    let fileName: String
    let destinationSummary: String
    let currentRevision: Int
    let draftState: DraftPresentation
    let cloudState: CloudPresentation
    let recents: [RecentFilePresentation]
    let isBusy: Bool
    let modeLabel: String
    var saveAsIssue: String? = nil
    var notice: String? = nil
    var isComposing: Bool = false
    var isEditorLocked: Bool = false
    var autosaveStatus: String? = nil
    var storagePolicy: String? = nil
    var remoteIssue: String? = nil
    var isOutcomeUncertain: Bool = false
    var mergePreview: MergePreviewPresentation? = nil
    var hasDestination: Bool? = nil
    var storageManagement: StorageManagementPresentation? = nil
    var historyInspection: HistoryInspectionPresentation? = nil
    var historyRestorePreview: HistoryRestorePreviewPresentation? = nil
    var isFilesPickerEnabled: Bool = false
}

struct HistoryEntryPresentation: Identifiable {
    let id: String
    let name: String
    let date: Date?
    let baseBytes: Int
    let localBytes: Int
    let remoteBytes: Int
    let totalBytes: Int
    let canDelete: Bool
    var deleteBlockReason: String? = nil
}

struct StorageManagementPresentation {
    let budgetBytes: Int
    let usedBytes: Int
    let remainingBytes: Int
    let protectedSummary: String
    let entries: [HistoryEntryPresentation]
    var currentEvidenceSummary: String? = nil
    var pendingSummary: String? = nil
    var status: String? = nil
    var epoch: Int = 0
}

struct HistoryInspectionPresentation: Identifiable {
    let id: String
    let name: String
    let base: String
    let local: String
    let remote: String
    let canRestore: Bool
    var status: String? = nil
}

enum HistoryRestoreSource: String, CaseIterable, Identifiable {
    case base, local, remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .base: return "前回の保存元"
        case .local: return "その時点の端末本文"
        case .remote: return "その時点の保存先本文"
        }
    }
}

struct HistoryRestorePreviewPresentation: Identifiable {
    let id: String
    let historyID: String
    let source: HistoryRestoreSource
    let expectedText: String
    let candidate: String
    let canApply: Bool
}

enum MergeResolution: Equatable {
    case keepLocal
    case keepRemote
    case manual(String)
}

struct MergeConflictPresentation: Identifiable {
    let id: String
    let base: String
    let local: String
    let remote: String
    let resolution: MergeResolution?
}

struct MergePreviewPresentation: Identifiable {
    let id: String
    let base: String
    let local: String
    let remote: String
    let candidate: String
    let conflicts: [MergeConflictPresentation]
    let canApply: Bool
    var requiresConfirmation: Bool = true
}

enum EditorTestScenario: String, CaseIterable, Identifiable {
    case normal, delayed, permissionDenied, externalChange, cancelled, moved, deleted, unknownOutcome, offline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "通常"
        case .delayed: return "保存を遅延"
        case .permissionDenied: return "権限なし"
        case .externalChange: return "外部で変更"
        case .cancelled: return "途中でキャンセル"
        case .moved: return "保存先を移動"
        case .deleted: return "保存先を削除"
        case .unknownOutcome: return "書込後の結果不明"
        case .offline: return "オフライン（検証用）"
        }
    }
}

struct EditorScreenActions {
    let onSnapshot: @MainActor (EditorSnapshot) -> Void
    let onSave: @MainActor (EditorSnapshot) -> Void
    let onSaveAs: @MainActor (String, EditorSnapshot) -> Void
    let onValidateSaveAsName: @MainActor (String) -> Void
    let onOpenRecent: @MainActor (UUID) -> Void
    let onOpenFiles: @MainActor () -> Void
    let onNew: @MainActor () -> Void
    var onSetScenario: (@MainActor (EditorTestScenario) -> Void)? = nil
    var onCancelSave: (@MainActor () -> Void)? = nil
    var onReload: (@MainActor (EditorSnapshot) -> Void)? = nil
    var onReconcileUnknown: (@MainActor () -> Void)? = nil
    var onResolveMergeConflict: (@MainActor (String, MergeResolution) -> Void)? = nil
    var onConfirmMerge: (@MainActor (String, EditorSnapshot) -> Void)? = nil
    var onInspectHistory: (@MainActor (String) -> Void)? = nil
    var onDeleteHistory: (@MainActor ([String], String, Int) -> Void)? = nil
    var onPrepareHistoryRestore: (@MainActor (String, HistoryRestoreSource, EditorSnapshot) -> Void)? = nil
    var onConfirmHistoryRestore: (@MainActor (String, EditorSnapshot) -> Void)? = nil
    var onRefreshStorage: (@MainActor () -> Void)? = nil
    var onOpenSystemFiles: (@MainActor () -> Void)? = nil
    var onCloseStorageManagement: @MainActor () -> Void = {}
}
