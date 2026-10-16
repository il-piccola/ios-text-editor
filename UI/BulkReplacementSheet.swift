import SwiftUI

@MainActor
struct BulkReplacementSheet: View {
    let sessionID: UUID
    @ObservedObject var commands: EditorCommandRouter
    let onSnapshot: @MainActor (EditorSnapshot) -> Void
    let isLocked: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var replacement = ""
    @State private var scope: EditorReplacementScope = .document
    @State private var preview: EditorReplacementPreview?
    @State private var problem: String?
    @State private var confirmsReplacement = false

    var body: some View {
        NavigationStack {
            Form {
                Section("文字列をそのまま検索") {
                    TextField("検索する文字列", text: $query, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("置換後の文字列（空欄なら削除）", text: $replacement, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("範囲", selection: $scope) {
                        ForEach(EditorReplacementScope.allCases) { Text($0.label).tag($0) }
                    }
                    Text("正規表現は使いません。絵文字や結合文字の途中に一致する箇所は置換しません。選択範囲は本文で指定します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("置換件数を確認", action: makePreview)
                        .disabled(query.isEmpty || isLocked || commands.isComposing)
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if let preview {
                        Text("一致: \(preview.count) 件")
                        NavigationLink("置換後の全文を確認") {
                            EditorTextInspectionSurface(text: preview.candidate, accessibilityName: "置換後の候補")
                                .navigationTitle("置換後の候補")
                        }
                        Button("\(preview.count) 件を一括置換") { confirmsReplacement = true }
                            .disabled(preview.count == 0 || preview.isNoOp || isLocked || commands.isComposing)
                        Text("確定後は本文の「元に戻す」で一括置換をまとめて戻せます。確認後に本文や選択範囲が変わった場合は適用を中止します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("一括置換")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onChange(of: query) { _, _ in invalidate() }
            .onChange(of: replacement) { _, _ in invalidate() }
            .onChange(of: scope) { _, _ in invalidate() }
            .onDisappear { preview = nil; problem = nil; confirmsReplacement = false }
            .alert("本文を一括置換しますか？", isPresented: $confirmsReplacement) {
                Button("取消", role: .cancel) {}
                Button("置換する", action: applyPreview)
            } message: { Text("\(preview?.count ?? 0) 件を置換します。保存先への反映には保存が必要です。") }
        }
    }

    private func invalidate() { preview = nil; problem = nil }
    private func makePreview() {
        do {
            preview = try commands.previewReplacement(.init(sessionID: sessionID, query: query, replacement: replacement, scope: scope))
            problem = nil
        } catch { preview = nil; problem = error.localizedDescription }
    }
    private func applyPreview() {
        guard let preview, !isLocked else { return }
        switch commands.applyReplacement(preview) {
        case .applied(let snapshot): onSnapshot(snapshot); dismiss()
        case .rejected(let reason): self.preview = nil; problem = reason
        }
    }
}
