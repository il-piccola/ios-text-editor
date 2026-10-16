import SwiftUI

/// All three protected inputs belong to the controller. Only the editor applies a candidate.
@MainActor
struct MergePreviewSheet: View {
    let preview: MergePreviewPresentation
    let sessionID: UUID
    @ObservedObject var commands: EditorCommandRouter
    let canApply: Bool
    let onSnapshot: @MainActor (EditorSnapshot) -> Void
    let onResolve: (@MainActor (String, MergeResolution) -> Void)?
    let onConfirm: (@MainActor (String, EditorSnapshot) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var confirmsApplication = false

    var body: some View {
        NavigationStack {
            List {
                Section("比較元（適用前に保護）") {
                    inspectionLink("前回の保存元", text: preview.base)
                    inspectionLink("この端末の本文", text: preview.local)
                    inspectionLink("保存先から読んだ本文", text: preview.remote)
                    Text("比較元の端末内保護が完了するまで適用はできません。本文が比較開始後に変わった場合は、古い候補を適用しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("同じ場所の変更: \(preview.conflicts.count) 件") {
                    if preview.conflicts.isEmpty { Text("同じ場所の変更はありません。候補を確認してから適用してください。") }
                    ForEach(preview.conflicts) { conflict in
                        MergeConflictRow(conflict: conflict, onResolve: onResolve)
                    }
                }
                Section("適用する候補") {
                    inspectionLink("候補の全文を確認", text: preview.candidate)
                    if hasUnresolvedConflicts {
                        Text("未確定の候補です。未選択の競合部分はこの端末の内容を仮表示します。採用を選ぶまで本文には適用できません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if normalizesNewlines {
                        Label("候補の適用で改行が LF に揃う場合があります。元の三つの本文と候補を確認してください。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if !preview.canApply {
                        Text(hasUnresolvedConflicts ? "各競合の採用内容を選んでください。未解決の本文は適用できません。" :
                            "比較元の保護完了と入力状態の確認を待っています。変換中や保存結果が不明な状態では適用できません。")
                            .foregroundStyle(.orange)
                    }
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Button("候補を本文に適用") { confirmsApplication = true }
                        .disabled(!canApply || !preview.canApply || commands.isComposing || onConfirm == nil)
                    Text("本文への適用を一回の「元に戻す」で戻せます。適用だけでは保存先への書き込みは行いません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("変更を比較")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .alert("確認した候補を本文に適用しますか？", isPresented: $confirmsApplication) {
                Button("取消", role: .cancel) {}
                Button("本文に適用", action: applyCandidate)
            } message: { Text("前回の保存元・この端末・保存先の内容を確認したうえで適用してください。" +
                (normalizesNewlines ? " 候補は改行を LF に揃える可能性があります。" : "")) }
        }
    }

    private func inspectionLink(_ title: String, text: String) -> some View {
        NavigationLink(title) {
            EditorTextInspectionSurface(text: text, accessibilityName: title).navigationTitle(title)
        }
    }
    private var normalizesNewlines: Bool {
        !preview.candidate.contains("\r") && [preview.base, preview.local, preview.remote].contains { $0.contains("\r") }
    }
    private var hasUnresolvedConflicts: Bool { preview.conflicts.contains { $0.resolution == nil } }
    private func applyCandidate() {
        guard canApply, preview.canApply, let onConfirm else { return }
        let request = EditorTextApplication(sessionID: sessionID, expectedText: preview.local,
            text: preview.candidate, actionName: "比較候補を適用")
        switch commands.applyText(request) {
        case .applied(let snapshot):
            onSnapshot(snapshot)
            onConfirm(preview.id, snapshot)
            dismiss()
        case .rejected(let reason): problem = reason
        }
    }
}

@MainActor
private struct MergeConflictRow: View {
    let conflict: MergeConflictPresentation
    let onResolve: (@MainActor (String, MergeResolution) -> Void)?
    @State private var manualText = ""
    @State private var showsManual = false
    @State private var confirmsManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            source("この端末", text: conflict.local)
            source("保存先", text: conflict.remote)
            DisclosureGroup("前回の保存元") { source("保存元", text: conflict.base) }
            ViewThatFits(in: .horizontal) {
                HStack { localButton; remoteButton }
                VStack(alignment: .leading) { localButton; remoteButton }
            }
            Button("手動で書き直す") {
                if case .manual(let text) = conflict.resolution { manualText = text }
                else { manualText = conflict.local }
                showsManual = true
            }.disabled(onResolve == nil)
            if let resolution = conflict.resolution {
                Text(resolutionLabel(resolution)).font(.caption).foregroundStyle(.secondary)
            } else { Text("未選択").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showsManual) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("この競合部分だけを書き直します。本文全体の変更は候補を確認してから適用します。")
                        .font(.caption).padding(.horizontal)
                    TextEditor(text: $manualText).font(.body).padding(.horizontal)
                    Button("この内容を候補に採用") { confirmsManual = true }.buttonStyle(.borderedProminent).padding()
                }
                .navigationTitle("競合部分を編集")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showsManual = false } } }
                .alert("手動で書いた内容を採用しますか？", isPresented: $confirmsManual) {
                    Button("取消", role: .cancel) {}
                    Button("候補に採用") { onResolve?(conflict.id, .manual(manualText)); showsManual = false }
                } message: { Text("この競合部分の候補を更新します。本文への適用は次の確認で行います。") }
            }
        }
    }
    private var localButton: some View { Button("この端末を採用") { onResolve?(conflict.id, .keepLocal) }.disabled(onResolve == nil) }
    private var remoteButton: some View { Button("保存先を採用") { onResolve?(conflict.id, .keepRemote) }.disabled(onResolve == nil) }
    private func source(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(text.isEmpty ? "（空）" : String(text.prefix(600))).textSelection(.enabled)
            NavigationLink("\(title)の全文") {
                EditorTextInspectionSurface(text: text, accessibilityName: title).navigationTitle(title)
            }.font(.caption)
        }
    }
    private func resolutionLabel(_ resolution: MergeResolution) -> String {
        switch resolution {
        case .keepLocal: return "この端末の内容を採用"
        case .keepRemote: return "保存先の内容を採用"
        case .manual: return "手動で書いた内容を採用"
        }
    }
}
