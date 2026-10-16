import SwiftUI

/// The application adapter provides storage values and serializes all actions.
@MainActor
struct EditorScreen: View {
    let state: EditorScreenState
    let actions: EditorScreenActions

    @StateObject private var commands = EditorCommandRouter()
    @State private var showsRecents = false
    @State private var showsSaveDetails = false
    @State private var showsSaveAs = false
    @State private var proposedName = ""
    @State private var showsReplacement = false
    @State private var showsMerge = false
    @State private var showsRecoveryManagement = false
    @State private var editorNotice: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var canPerformFileAction: Bool { !state.isBusy && !state.isEditorLocked && !commands.isComposing && !state.isComposing }
    private var hasDestination: Bool { state.hasDestination ?? (state.cloudState != .noDestination) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                fileHeader
                Divider()
                EditorSurface(configuration: state.configuration, router: commands, onSnapshot: actions.onSnapshot)
                Divider()
                statusFooter
                reviewControl
            }
            .navigationTitle("テキストエディタ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsRecents = true } label: {
                        Label("最近のファイル", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(!canPerformFileAction)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("検証用ファイルを開く", systemImage: "folder") { fileAction(actions.onOpenFiles) }
                            .disabled(!canPerformFileAction)
                        Button("Filesから開く（Macで検証待ち）", systemImage: "folder.badge.plus") {
                            if let open = actions.onOpenSystemFiles { fileAction(open) }
                        }.disabled(!state.isFilesPickerEnabled || actions.onOpenSystemFiles == nil || !canPerformFileAction)
                        Button("別のファイルに保存", systemImage: "doc.badge.plus", action: requestSaveAs)
                            .disabled(!canPerformFileAction)
                        Button("新しい下書き", systemImage: "square.and.pencil") { fileAction(actions.onNew) }
                            .disabled(!canPerformFileAction)
                        Button("一括置換", systemImage: "text.magnifyingglass") { showsReplacement = true }
                            .disabled(!canPerformFileAction)
                        Button("履歴と端末の容量", systemImage: "internaldrive") { showsRecoveryManagement = true }
                        if let setScenario = actions.onSetScenario {
                            Menu("検証シナリオ") {
                                ForEach(EditorTestScenario.allCases) { scenario in
                                    Button(scenario.label) { fileAction { setScenario(scenario) } }
                                }
                            }
                            .disabled(!canPerformFileAction)
                        }
                    } label: { Label("ファイル操作", systemImage: "ellipsis.circle") }
                    .disabled(state.isEditorLocked)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { commands.send(.undo) } label: { Label("元に戻す", systemImage: "arrow.uturn.backward") }
                        .disabled(!commands.canUndo || commands.isComposing || state.isEditorLocked)
                    Button { commands.send(.redo) } label: { Label("やり直す", systemImage: "arrow.uturn.forward") }
                        .disabled(!commands.canRedo || commands.isComposing || state.isEditorLocked)
                    Spacer()
                    Button("完了") { commands.send(.dismissKeyboard) }
                }
            }
            .sheet(isPresented: $showsRecents) { recentFiles }
            .sheet(isPresented: $showsSaveDetails) { saveDetails }
            .sheet(isPresented: $showsSaveAs) { saveAsSheet }
            .sheet(isPresented: $showsReplacement) {
                BulkReplacementSheet(sessionID: state.configuration.sessionID, commands: commands,
                    onSnapshot: actions.onSnapshot, isLocked: state.isEditorLocked)
            }
            .sheet(isPresented: $showsRecoveryManagement) {
                RecoveryManagementSheet(presentation: state.storageManagement, inspection: state.historyInspection,
                    restorePreview: state.historyRestorePreview, sessionID: state.configuration.sessionID,
                    commands: commands, canPerformAction: canPerformFileAction, actions: actions)
            }
            .sheet(isPresented: $showsMerge) {
                if let preview = state.mergePreview {
                    MergePreviewSheet(preview: preview, sessionID: state.configuration.sessionID, commands: commands,
                        canApply: canPerformFileAction && !state.isOutcomeUncertain, onSnapshot: actions.onSnapshot,
                        onResolve: actions.onResolveMergeConflict, onConfirm: actions.onConfirmMerge)
                } else { Text("比較候補が更新されました。閉じてもう一度確認してください。").padding() }
            }
            .onChange(of: reloadCandidateKey) { _, _ in applyCleanReload() }
            .onChange(of: state.configuration.sessionID) { _, _ in
                editorNotice = nil
                showsReplacement = false
                showsMerge = false
                showsRecoveryManagement = false
            }
        }
    }

    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.modeLabel).font(.caption).foregroundStyle(.orange)
            if state.isEditorLocked {
                Text("ファイル切替の前に下書きを保護しています")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(state.fileName.isEmpty ? "新しい下書き" : state.fileName)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            Text("保存先: " + state.destinationSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            HStack(spacing: 8) { saveButton; reloadButton }
            // Notices must not insert/remove space above the live text view.
            Text("状態のお知らせ\n状態のお知らせ")
                .font(.caption)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    Text(editorNotice ?? state.notice ?? "")
                        .font(.caption)
                        .foregroundStyle(editorNotice == nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusFooter: some View {
        Button { showsSaveDetails = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(state.quietDraftLabel, systemImage: draftHasProblem ? "exclamationmark.triangle" : "internaldrive")
                    .foregroundStyle(draftHasProblem ? Color.orange : Color.secondary)
                Label(state.quietFileLabel, systemImage: cloudHasProblem ? "exclamationmark.triangle" : "folder")
                    .foregroundStyle(cloudHasProblem ? Color.orange : Color.secondary)
            }
            .lineLimit(1, reservesSpace: true)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("保存状態の詳細を表示します")
    }

    private var draftHasProblem: Bool {
        if case .failed = state.draftState { return true }
        return false
    }

    private var cloudHasProblem: Bool {
        if state.isOutcomeUncertain || state.remoteIssue != nil { return true }
        if case .failed = state.cloudState { return true }
        return state.cloudState == .conflict
    }

    private var recentFiles: some View {
        NavigationStack {
            List {
                Section {
                    Button("検証用ファイルを開く", systemImage: "folder") {
                        showsRecents = false
                        fileAction(actions.onOpenFiles)
                    }
                    Button("新しい下書き", systemImage: "square.and.pencil") {
                        showsRecents = false
                        fileAction(actions.onNew)
                    }
                }
                Section("最近のファイル") {
                    if state.recents.isEmpty {
                        Text("ここには、開いたファイルと端末の下書きが表示されます。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.recents) { recent in
                        Button {
                            showsRecents = false
                            fileAction { actions.onOpenRecent(recent.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(recent.name).font(.headline).foregroundStyle(.primary)
                                Text(recent.destination).font(.subheadline).foregroundStyle(.secondary)
                                Text(recent.lastOpened, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                                if recent.hasLocalChanges {
                                    Label("端末の下書きに変更あり", systemImage: "pencil.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("開く")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsRecents = false } } }
        }
    }

    private var saveDetails: some View {
        NavigationStack {
            List {
                Section("ファイル") {
                    Text(state.fileName).textSelection(.enabled)
                    Text("保存先: " + state.destinationSummary).textSelection(.enabled)
                    Text(state.modeLabel).font(.caption).foregroundStyle(.orange)
                    if let notice = state.notice { Text(notice) }
                    if let editorNotice { Text(editorNotice).foregroundStyle(.orange) }
                    Button("履歴と端末の容量") {
                        showsSaveDetails = false
                        showsRecoveryManagement = true
                    }
                }
                Section("端末の下書き") {
                    if commands.isComposing || state.isComposing {
                        Text("変換を確定するとファイル操作ができます")
                    }
                    Text("端末の下書きは本文変更後に自動で保護します。保存先への自動保存とは別です。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(draftLabel)
                    Text("現在の版: \(state.currentRevision)").font(.caption).foregroundStyle(.secondary)
                    if case .protected(_, let revision) = state.draftState {
                        Text("端末に保護した版: \(revision)").font(.caption).foregroundStyle(.secondary)
                    }
                    if case .protected(let date, _) = state.draftState, let date {
                        Text(date, format: .dateTime.month().day().hour().minute().second()).foregroundStyle(.secondary)
                    }
                    if case .failed(let message) = state.draftState { Text(message) }
                }
                Section("保存先のファイル") {
                    Text(cloudLabel)
                    if case .providerAccepted(_, let revision) = state.cloudState {
                        Text("保存先が受け付けた版: \(revision) / 現在の版: \(state.currentRevision)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(state.cloudState.explanation).foregroundStyle(.secondary)
                    if let status = state.autosaveStatus { Text("保存先への自動保存: " + status) }
                    if let issue = state.remoteIssue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if state.isOutcomeUncertain {
                        Text("書き込みが完了したか不明です。もう一度書き込む前に保存先の内容を読み直してください。")
                            .foregroundStyle(.orange)
                    }
                    if case .providerAccepted(let date, _) = state.cloudState, let date {
                        Text(date, format: .dateTime.month().day().hour().minute().second()).foregroundStyle(.secondary)
                    }
                    if state.cloudState == .conflict {
                        Button("下書きを別のファイルに保存") {
                            showsSaveDetails = false
                            requestSaveAs()
                        }.disabled(!canPerformFileAction)
                    }
                }
                if let policy = state.storagePolicy {
                    Section("文字コードと改行") {
                        Text(policy)
                        Text("既存ファイルの文字コードや改行は確認せずに変えません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if state.isBusy, actions.onCancelSave != nil {
                    Section("処理中") { cancellationControl }
                }
            }
            .navigationTitle("保存状態")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsSaveDetails = false } } }
        }
    }

    private var draftLabel: String {
        if case .protected(_, let revision) = state.draftState {
            if revision < state.currentRevision { return "端末に前の版を保護済み · 最新の変更は保存待ち" }
            return "端末に最新の下書き保存済み"
        }
        return state.draftState.label
    }

    @ViewBuilder
    private var cancellationControl: some View {
        if state.isBusy, let cancel = actions.onCancelSave {
            VStack(alignment: .leading, spacing: 6) {
                Button("保存処理を中断", action: cancel)
                    .buttonStyle(.bordered)
                    .accessibilityHint("下書きを残して保存処理の中断を依頼します")
                Text("すでに保存先へ書き込まれた内容の取り消しは保証できません。下書きは残ります。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var cloudLabel: String {
        if state.isOutcomeUncertain { return "保存先への書込結果は不明・再読込が必要" }
        if case .providerAccepted(_, let revision) = state.cloudState, revision < state.currentRevision {
            return "保存先には前の版を書込済み · 最新の変更は未反映"
        }
        return state.cloudState.label
    }

    private func committedSnapshot() -> EditorSnapshot? {
        guard !state.isBusy, !state.isEditorLocked, let snapshot = commands.snapshot(for: state.configuration.sessionID) else { return nil }
        actions.onSnapshot(snapshot)
        guard !snapshot.isComposing else { return nil }
        return snapshot
    }

    private func fileAction(_ action: @MainActor () -> Void) {
        guard committedSnapshot() != nil else { return }
        action()
    }

    private func saveCurrent() {
        guard !state.isOutcomeUncertain, let snapshot = committedSnapshot(), state.cloudState != .conflict else { return }
        actions.onSave(snapshot)
    }

    private func requestSaveAs() {
        guard committedSnapshot() != nil else { return }
        proposedName = state.fileName.isEmpty ? "新しい文章.txt" : state.fileName
        actions.onValidateSaveAsName(proposedName)
        showsSaveAs = true
    }

    private var saveAsSheet: some View {
        NavigationStack {
            Form {
                Section("新しいファイル名") {
                    TextField("ファイル名", text: $proposedName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("新しいファイル名")
                    Text("検証用の偽保存先に作成します。実際の Files や Google ドライブへは保存しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let issue = state.saveAsIssue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("同名ファイルは上書きしません。別の名前を入力してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let policy = state.storagePolicy { Text(policy).font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Button("この名前で保存") {
                        guard let snapshot = committedSnapshot() else { return }
                        actions.onSaveAs(proposedName, snapshot)
                    }
                    .disabled(!canPerformFileAction || proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.saveAsIssue != nil)
                    if let notice = state.notice { Text(notice).font(.caption) }
                    Text(cloudLabel).font(.caption).foregroundStyle(.secondary)
                }
                if state.isBusy, actions.onCancelSave != nil {
                    Section("処理中") { cancellationControl }
                }
            }
            .onChange(of: proposedName) { _, name in actions.onValidateSaveAsName(name) }
            .navigationTitle("別のファイルに保存")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showsSaveAs = false } } }
        }
    }

    private var saveButton: some View {
        SaveIconButton(state: state, isComposing: commands.isComposing,
                       action: hasDestination ? saveCurrent : requestSaveAs)
    }

    @ViewBuilder
    private var reloadButton: some View {
        if actions.onReload != nil {
            ReloadIconButton(state: state, isComposing: commands.isComposing, action: reloadCurrent)
        }
    }

    private func reloadCurrent() {
        guard let onReload = actions.onReload, let snapshot = committedSnapshot() else { return }
        onReload(snapshot)
    }

    private var reloadCandidateKey: String? {
        guard let preview = state.mergePreview else { return nil }
        let ready = preview.canApply && canPerformFileAction && !state.isOutcomeUncertain
        return preview.id + (ready ? ":ready" : ":waiting")
    }

    private func applyCleanReload() {
        guard let preview = state.mergePreview, !preview.requiresConfirmation, preview.canApply,
              canPerformFileAction, !state.isOutcomeUncertain, let confirm = actions.onConfirmMerge else { return }
        let outcome = commands.applyText(.init(sessionID: state.configuration.sessionID,
            expectedText: preview.local, text: preview.candidate, actionName: "保存先から再読込"))
        switch outcome {
        case .applied(let snapshot):
            actions.onSnapshot(snapshot)
            confirm(preview.id, snapshot)
            editorNotice = nil
        case .rejected(let reason): editorNotice = reason
        }
    }

    @ViewBuilder
    private var reviewControl: some View {
        if state.mergePreview != nil || state.isOutcomeUncertain || state.remoteIssue != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let issue = state.remoteIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if state.mergePreview != nil {
                    Button("保護した本文と保存先の変更を比較") { showsMerge = true }
                        .disabled(!canPerformFileAction)
                }
                if state.isOutcomeUncertain, let reconcile = actions.onReconcileUnknown {
                    Button("書込結果を再読込して確認") { fileAction(reconcile) }
                        .disabled(!canPerformFileAction)
                    Text("完了したか不明な書き込みを、そのまま繰り返しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

/// Transient autosave activity must not flash the control. Busy taps are deliberately
/// ignored; the screen and core also recheck their guards before any write.
@MainActor
struct SaveIconButton: View {
    let state: EditorScreenState
    var isComposing: Bool = false
    let action: @MainActor () -> Void

    var isBlocked: Bool {
        state.isEditorLocked || state.cloudState == .conflict || state.isOutcomeUncertain
    }

    func activate() {
        guard !isBlocked, !state.isBusy, !state.isComposing, !isComposing else { return }
        action()
    }

    var body: some View {
        Button(action: activate) {
            Image(systemName: "square.and.arrow.down")
                .font(.body)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isBlocked ? Color.secondary : Color.accentColor)
        .disabled(isBlocked)
        .accessibilityLabel("保存")
        .accessibilityIdentifier("editor.save")
        .accessibilityHint((state.hasDestination ?? (state.cloudState != .noDestination))
            ? "現在の保存先に保存します。処理中や変換中のタップは追加の保存を開始しません。"
            : "最初の保存先を選びます。処理中や変換中は完了を待ってください。")
    }
}

@MainActor
struct ReloadIconButton: View {
    let state: EditorScreenState
    var isComposing: Bool = false
    let action: @MainActor () -> Void

    var isBlocked: Bool {
        state.isEditorLocked || !(state.hasDestination ?? (state.cloudState != .noDestination))
    }

    func activate() {
        guard !isBlocked, !state.isBusy, !state.isComposing, !isComposing else { return }
        action()
    }

    var body: some View {
        Button(action: activate) {
            Image(systemName: "arrow.clockwise")
                .font(.body)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isBlocked ? Color.secondary : Color.accentColor)
        .disabled(isBlocked)
        .accessibilityLabel("再読込")
        .accessibilityIdentifier("editor.reload")
        .accessibilityHint("保存先の内容を確認します。未保存の変更は既存の比較・保護手順で扱います。処理中や変換中は追加の再読込を開始しません。")
    }
}
