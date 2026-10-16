import SwiftUI

/// Metadata is cheap; the three original texts are fetched only when inspecting one entry.
@MainActor
struct RecoveryManagementSheet: View {
    let presentation: StorageManagementPresentation?
    let inspection: HistoryInspectionPresentation?
    let restorePreview: HistoryRestorePreviewPresentation?
    let sessionID: UUID
    @ObservedObject var commands: EditorCommandRouter
    let canPerformAction: Bool
    let actions: EditorScreenActions
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var selectionEpoch: Int?
    @State private var deletionConfirmation = ""
    @State private var confirmsDeletion = false

    var body: some View {
        NavigationStack {
            List {
                if let presentation {
                    Section("端末の保全領域") {
                        Text("使用: \(bytes(presentation.usedBytes)) / 予算: \(bytes(presentation.budgetBytes))")
                        Text("保管枠の残り: \(bytes(presentation.remainingBytes))").foregroundStyle(.secondary)
                        ProgressView(value: Double(max(0, min(presentation.usedBytes, presentation.budgetBytes))),
                            total: Double(max(1, presentation.budgetBytes)))
                        Text(presentation.protectedSummary)
                        if let current = presentation.currentEvidenceSummary { Text(current).font(.caption) }
                        if let pending = presentation.pendingSummary { Text(pending).font(.caption) }
                        if let status = presentation.status { Text(status).foregroundStyle(.orange) }
                        Text("容量は端末内の下書き・比較原文・履歴用です。Drive の空き容量ではありません。未保存の下書きや現在の競合原文は削除できません。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let refresh = actions.onRefreshStorage { Button("容量と履歴を更新", action: refresh) }
                    }
                    Section("保護した変更履歴") {
                        if presentation.entries.isEmpty { Text("削除・復元する変更履歴はありません。").foregroundStyle(.secondary) }
                        ForEach(presentation.entries) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Button { toggle(entry, epoch: presentation.epoch) } label: {
                                    Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .disabled(!entry.canDelete || actions.onDeleteHistory == nil)
                                .accessibilityLabel(entry.name + "を削除対象に" + (selectedIDs.contains(entry.id) ? "選択済み" : "選択"))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.name).font(.headline)
                                    if let date = entry.date { Text(date, format: .dateTime.month().day().hour().minute()).font(.caption) }
                                    Text("合計 \(bytes(entry.totalBytes)) · 保存元 \(bytes(entry.baseBytes)) / 端末 \(bytes(entry.localBytes)) / 保存先 \(bytes(entry.remoteBytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let reason = entry.deleteBlockReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                                    NavigationLink("原文と復元候補を確認") {
                                        HistoryInspectionView(historyID: entry.id, name: entry.name,
                                            inspection: inspection, restorePreview: restorePreview, sessionID: sessionID,
                                            commands: commands, canPerformAction: canPerformAction, actions: actions)
                                    }.disabled(actions.onInspectHistory == nil)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    if !selectedIDs.isEmpty {
                        Section("選んだ履歴を削除") {
                            Text("\(selectedIDs.count) 件を選択しています。削除した履歴の原文は戻せません。現在の本文は削除しません。")
                            if selectionEpoch != presentation.epoch {
                                Label("一覧が更新されました。削除対象を選び直してください。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                Button("選択を解除", action: clearSelection)
                            }
                            TextField("確認のため「削除」と入力", text: $deletionConfirmation)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("選んだ履歴を削除", role: .destructive) { confirmsDeletion = true }
                                .disabled(!canDeleteSelection(presentation))
                        }
                    }
                } else {
                    Text("容量と履歴を確認しています。")
                    if let refresh = actions.onRefreshStorage { Button("再確認", action: refresh) }
                }
            }
            .navigationTitle("履歴と端末の容量")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { actions.onRefreshStorage?() }
            .alert("選んだ履歴を削除しますか？", isPresented: $confirmsDeletion) {
                Button("取消", role: .cancel) {}
                Button("\(selectedIDs.count) 件を削除", role: .destructive) {
                    guard let presentation, canDeleteSelection(presentation), let epoch = selectionEpoch else { return }
                    guard let snapshot = commands.snapshot(for: sessionID) else { return }
                    actions.onSnapshot(snapshot)
                    guard !snapshot.isComposing else { return }
                    actions.onDeleteHistory?(selectedIDs.sorted(), deletionConfirmation, epoch)
                    clearSelection()
                }
            } message: { Text("選んだ履歴の保存元・端末本文・保存先本文を削除します。この操作は取り消せません。") }
        }
        .onDisappear { actions.onCloseStorageManagement() }
    }

    private func toggle(_ entry: HistoryEntryPresentation, epoch: Int) {
        guard entry.canDelete else { return }
        if selectedIDs.isEmpty { selectionEpoch = epoch }
        if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) } else { selectedIDs.insert(entry.id) }
        if selectedIDs.isEmpty { clearSelection() }
    }
    private func clearSelection() { selectedIDs.removeAll(); selectionEpoch = nil; deletionConfirmation = "" }
    private func canDeleteSelection(_ presentation: StorageManagementPresentation) -> Bool {
        let allowed = Set(presentation.entries.filter(\.canDelete).map(\.id))
        return canPerformAction && !commands.isComposing && actions.onDeleteHistory != nil &&
            deletionConfirmation == "削除" && selectionEpoch == presentation.epoch && !selectedIDs.isEmpty && selectedIDs.isSubset(of: allowed)
    }
    private func bytes(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file) }
}

@MainActor
private struct HistoryInspectionView: View {
    let historyID: String
    let name: String
    let inspection: HistoryInspectionPresentation?
    let restorePreview: HistoryRestorePreviewPresentation?
    let sessionID: UUID
    @ObservedObject var commands: EditorCommandRouter
    let canPerformAction: Bool
    let actions: EditorScreenActions
    @State private var source: HistoryRestoreSource = .local
    @State private var problem: String?
    @State private var confirmsRestore = false

    var body: some View {
        List {
            if let detail = inspection, detail.id == historyID {
                Section("保護した三つの原文") {
                    originalLink(.base, text: detail.base)
                    originalLink(.local, text: detail.local)
                    originalLink(.remote, text: detail.remote)
                    if let status = detail.status { Text(status).font(.caption).foregroundStyle(.orange) }
                }
                Section("本文へ復元する原文") {
                    Picker("原文", selection: $source) {
                        ForEach(HistoryRestoreSource.allCases) { Text($0.label).tag($0) }
                    }
                    Button("現在の下書きを保護して復元候補を作る", action: prepare)
                        .disabled(!canPerformAction || commands.isComposing || !detail.canRestore || actions.onPrepareHistoryRestore == nil)
                    Text("現在の下書きの保護完了後に候補を確認します。保存先のファイルをこの画面で直接変更することはありません。復元後の本文は自動保存の対象になる場合があります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("原文を読み込んでいます。")
            }
            if let preview = restorePreview, preview.historyID == historyID {
                Section("復元候補: " + preview.source.label) {
                    NavigationLink("候補の全文を確認") {
                        EditorTextInspectionSurface(text: preview.candidate, accessibilityName: "履歴からの復元候補")
                            .navigationTitle("復元候補")
                    }
                    Button("確認した候補を本文に戻す") { confirmsRestore = true }
                        .disabled(!preview.canApply || preview.source != source || !canPerformAction || commands.isComposing || actions.onConfirmHistoryRestore == nil)
                    if preview.source != source { Text("原文の選択が変わりました。復元候補を作り直してください。").font(.caption).foregroundStyle(.orange) }
                    Text("本文への適用は一回の Undo で戻せます。候補表示後に本文や session が変わった場合は適用を止めます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        .navigationTitle(name)
        .onAppear { actions.onInspectHistory?(historyID) }
        .alert("この原文を本文へ復元しますか？", isPresented: $confirmsRestore) {
            Button("取消", role: .cancel) {}
            Button("本文に復元", action: applyRestore)
        } message: { Text("現在の本文の保護と候補を確認したうえで復元します。") }
    }

    private func originalLink(_ source: HistoryRestoreSource, text: String) -> some View {
        NavigationLink(source.label) {
            EditorTextInspectionSurface(text: text, accessibilityName: source.label).navigationTitle(source.label)
        }
    }
    private func prepare() {
        guard canPerformAction, let snapshot = commands.snapshot(for: sessionID) else { return }
        actions.onSnapshot(snapshot)
        guard !snapshot.isComposing else { return }
        problem = nil
        actions.onPrepareHistoryRestore?(historyID, source, snapshot)
    }
    private func applyRestore() {
        guard canPerformAction, let preview = restorePreview, preview.historyID == historyID,
              preview.canApply, preview.source == source, let confirm = actions.onConfirmHistoryRestore else { return }
        let result = commands.applyText(.init(sessionID: sessionID, expectedText: preview.expectedText,
            text: preview.candidate, actionName: "履歴の原文を復元"))
        switch result {
        case .applied(let snapshot): actions.onSnapshot(snapshot); confirm(preview.id, snapshot); problem = nil
        case .rejected(let reason): problem = reason
        }
    }
}
