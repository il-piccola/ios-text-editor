import Foundation
import Combine

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var state: CoreStateCodable
    @Published private(set) var recents: [DraftRecord] = []
    @Published private(set) var notice: String?
    @Published private(set) var saveAsIssue: String?
    @Published private(set) var isTransitioning = false
    private let bridge: SessionCoreBridge
    private let drafts: DraftStore
    private let fakeProvider: FakeFileProvider
    private let filesProvider: FilesProviderAdapter
    @Published var showsFilesPicker = false
    @Published private var storageCapacity: DraftCapacityStatus?
    @Published private var storageStatus: String?
    @Published private var inspectedHistory: HistoryInspectionPresentation?
    @Published private var restoreHistoryPreview: HistoryRestorePreviewPresentation?
    private var restoreHistoryContext: (token: String, sessionID: UUID, revision: Int, epoch: Int)?
    private var requestedHistoryRestoreToken: String?
    @Published private var preparingHistoryRestore = false
    private var observationGeneration = 0
    private var observationTail: Task<Void, Never>?
    @Published private var historyEntries: [HistoryEntryPresentation] = []
    private var historyListEpoch = -1
    private var storageManagementVisible = false
    // Keep ALL JS bookkeeping, including pendingDrafts/usedTokens. Codable is a read-only UI projection.
    private var rawState: [String: Any]
    private var effectTasks: [String: Task<Void, Never>] = [:]
    private var persistenceTail: Task<Void, Never>?
    private var protectedEpoch: Int = -1
    private var protectedAt: Date?
    private var acceptedAt: Date?
    private var hasStarted = false
    private var nameValidationGeneration = 0
    @Published private(set) var autosaveStatus = "自動保存は保存先の設定後に始まります"
    @Published private(set) var remoteIssue: String?
    private var autosaveTask: Task<Void, Never>?
    @Published private var observingRemote = false
    private var mergeContext: MergeContext?
    private struct MergeContext {
        let token: String
        let sessionID: UUID
        let target: CoreTarget
        let local: String
        var result: [String: Any]
        var choices: [Any?]
        var resolutions: [MergeResolution?]
        var candidate: String?
        var requiresConfirmation: Bool
        var verifiedObservation: Bool
    }
    private enum PreparedDocument {
        case created(name: String, text: String, format: String, target: CoreTarget?)
        case restored(CoreEnvelope)
    }

    init(bundle: Bundle = .main, draftDirectory: URL? = nil, fakeDirectory: URL? = nil) throws {
        bridge = try SessionCoreBridge(bundle: bundle)
        drafts = try DraftStore(directory: draftDirectory)
        let fake = try FakeFileProvider(directory: fakeDirectory)
        fakeProvider = fake
        filesProvider = try FilesProviderAdapter()
        let seed: [String: Any] = ["id": UUID().uuidString, "sessionID": UUID().uuidString,
                                   "name": "無題.txt", "text": "", "format": "utf8", "lineEnding": "crlf"]
        let created = try bridge.invoke("create", seed)
        rawState = created
        state = try SessionCoreBridge.decode(CoreStateCodable.self, from: created)
    }

    /// Parent startup keeps the editor hidden until this async restoration has finished.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            let scan = try await drafts.scan()
            recents = scan.records
            if !scan.failures.isEmpty {
                notice = "\(scan.failures.count) 件の下書きを読み取れません。原本は残しています。最近のファイルから正常な下書きを選んでください。\n" + scan.failures.joined(separator: "\n")
                // Do not silently substitute another draft for a possibly newer damaged draft.
                return
            }
            if let latest = recents.first { try restore(try await drafts.loadEnvelope(latest.id)) }
            protectNow()
            await drainEffects()
            if rawState["remoteCandidate"] is [String: Any] {
                dispatch(["type": "RELOAD", "token": UUID().uuidString])
                await drainEffects()
            }
            scheduleAutosave()
            await refreshStorage()
        } catch {
            notice = "下書きを復元できません。原本を残したまま処理を止めました。 " + error.localizedDescription
        }
    }

    func snapshot(_ snapshot: EditorSnapshot) {
        // Queued UIKit callbacks from before the transition lock still belong to this session.
        guard snapshot.sessionID == state.sessionID else { return }
        let changed = !snapshot.text.utf16.elementsEqual(state.text.utf16) || snapshot.isComposing != state.isComposing
        dispatch(["type": "EDIT", "sessionID": snapshot.sessionID.uuidString,
                  "text": snapshot.text, "isComposing": snapshot.isComposing])
        if changed { protectLatestIfNeeded() }
        if changed {
            if let context = mergeContext,
               !context.local.utf16.elementsEqual(snapshot.text.utf16),
               !(context.candidate?.utf16.elementsEqual(snapshot.text.utf16) ?? false) { mergeContext = nil }
            scheduleAutosave()
        }
    }

    func save(_ snapshot: EditorSnapshot) {
        self.snapshot(snapshot)
        guard snapshot.sessionID == state.sessionID, !snapshot.isComposing, !isTransitioning, !observingRemote, !hasEvidenceOperation else { return }
        dispatch(["type": "SAVE", "token": UUID().uuidString])
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        if state.draftError != nil { autosaveStatus = "端末下書きの保護に失敗・自動保存を停止"; return }
        if hasEvidenceOperation || requestedHistoryRestoreToken != nil { autosaveStatus = "履歴操作の確認待ち・自動保存を停止"; return }
        if state.uncertain { autosaveStatus = "書き込み結果不明・再確認まで自動保存停止"; return }
        if state.conflict { autosaveStatus = "外部変更の確認待ち・自動保存停止"; return }
        guard !state.isComposing, !isTransitioning, state.target != nil else {
            autosaveStatus = state.isComposing ? "日本語の変換確定を待っています" : "保存先未設定・端末下書きのみ"
            return
        }
        autosaveStatus = "入力後の自動保存を待っています"
        let session = state.sessionID
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, state.sessionID == session else { return }
            await validateAndAutosave()
        }
    }

    private func validateAndAutosave() async {
        guard !observingRemote, !isTransitioning, !hasEvidenceOperation, restoreHistoryPreview == nil, !state.isComposing, state.operation == nil,
              !state.uncertain, !state.conflict, let expected = state.target,
              state.acceptedRevision != state.revision else { return }
        observingRemote = true
        defer { observingRemote = false }
        let session = state.sessionID
        autosaveStatus = "保存先の最新内容を確認しています"
        do {
            let observed = try await adapter(for: expected).read(identity: expected.identity)
            guard session == state.sessionID, state.target?.identity == expected.identity,
                  !state.isComposing, !isTransitioning, state.operation == nil, !state.uncertain else { return }
            dispatch(["type": "REMOTE_OBSERVED", "sessionID": session.uuidString,
                      "target": try SessionCoreBridge.dictionary(observed)])
            if observed.baseline != expected.baseline {
                try prepareMerge(target: observed, token: UUID().uuidString, local: state.text, base: expected.baseText)
                autosaveStatus = "外部変更を確認してください・自動保存停止"
            } else {
                if observed.name != expected.name { remoteIssue = "保存先のファイル名が変更されました: " + observed.name }
                remoteIssue = observed.name == expected.name ? nil : remoteIssue
                dispatch(["type": "AUTO_SAVE", "token": UUID().uuidString])
                autosaveStatus = state.operation == nil ? "自動保存の待機中" : "自動保存しています"
            }
        } catch {
            guard session == state.sessionID else { return }
            remoteIssue = error.localizedDescription
            autosaveStatus = "保存先を確認できないため自動保存停止・下書き保持"
        }
    }

    func reload(_ snapshot: EditorSnapshot) {
        self.snapshot(snapshot)
        guard !isTransitioning, !observingRemote, !hasEvidenceOperation, snapshot.sessionID == state.sessionID, !snapshot.isComposing else { return }
        autosaveTask?.cancel()
        dispatch(["type": "RELOAD", "token": UUID().uuidString])
    }

    private func prepareMerge(target: CoreTarget, token: String, local: String, base: String?, allowAutoApply: Bool = false,
                              verifiedObservation: Bool = true) throws {
        guard let base, let remote = target.baseText else {
            remoteIssue = "比較の基準となる原文がありません。別名保存で下書きを残し、保存先を確認してください。"
            return
        }
        let result = try bridge.invoke("compare", ["base": base, "local": local, "remote": remote])
        let blocks = result["conflictBlocks"] as? [[String: Any]] ?? []
        mergeContext = MergeContext(token: token, sessionID: state.sessionID, target: target, local: local,
                                    result: result, choices: Array(repeating: nil, count: blocks.count),
                                    resolutions: Array(repeating: nil, count: blocks.count),
                                    candidate: candidateText(result["candidate"] as? String, local: local, remote: remote, base: base),
                                    requiresConfirmation: !(allowAutoApply && local.utf16.elementsEqual(base.utf16) && state.acceptedRevision == state.revision && blocks.isEmpty),
                                    verifiedObservation: verifiedObservation)
    }

    private func candidateText(_ candidate: String?, local: String, remote: String, base: String) -> String? {
        guard let candidate else { return nil }
        // Comparison uses LF; do not silently reformat an untouched remote document on a reload.
        func logical(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        if logical(local).utf16.elementsEqual(logical(base).utf16), logical(candidate).utf16.elementsEqual(logical(remote).utf16) { return remote }
        if state.lineEnding == "preserve", local.contains("\r\n"), !local.replacingOccurrences(of: "\r\n", with: "").contains("\n") {
            return candidate.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return candidate
    }

    func resolveMergeConflict(_ id: String, resolution: MergeResolution) {
        guard var context = mergeContext, let index = Int(id), context.choices.indices.contains(index) else { return }
        switch resolution {
        case .keepLocal: context.choices[index] = "local"
        case .keepRemote: context.choices[index] = "remote"
        case .manual(let text): context.choices[index] = ["kind": "manual", "text": text]
        }
        context.resolutions[index] = resolution
        if context.choices.allSatisfy({ $0 != nil }) {
            do {
                let resolved = try bridge.invoke("resolve", ["result": context.result, "choices": context.choices.compactMap { $0 }])["text"] as? String
                let raw = context.result["raw"] as? [String: String] ?? [:]
                context.candidate = candidateText(resolved, local: context.local, remote: raw["remote"] ?? "", base: raw["base"] ?? "")
            }
            catch { notice = error.localizedDescription; context.candidate = nil }
        }
        mergeContext = context
        objectWillChange.send()
    }

    func confirmMerge(_ token: String, snapshot: EditorSnapshot) {
        guard let context = mergeContext, context.verifiedObservation, context.token == token, context.sessionID == state.sessionID,
              snapshot.sessionID == state.sessionID, !snapshot.isComposing,
              let candidate = context.candidate, snapshot.text.utf16.elementsEqual(candidate.utf16),
              state.target?.identity == context.target.identity, !state.uncertain,
              !observingRemote, !hasEvidenceOperation, state.operation == nil, !isTransitioning else { return }
        self.snapshot(snapshot)
        let session = state.sessionID
        observingRemote = true
        // Validate again after confirmation. Another external edit must not turn a preview into an overwrite permission.
        Task { [weak self] in
            guard let self else { return }
            defer { observingRemote = false }
            do {
                await drainEffects()
                guard state.sessionID == session, state.draftError == nil, protectedEpoch == state.epoch,
                      state.protectedRevision == state.revision,
                      state.text.utf16.elementsEqual(candidate.utf16), !state.isComposing else { return }
                let latest = try await adapter(for: context.target).read(identity: context.target.identity)
                guard state.sessionID == session, !state.isComposing,
                      state.text.utf16.elementsEqual(candidate.utf16), !state.uncertain, state.operation == nil else { return }
                guard latest.baseline == context.target.baseline else {
                    var observation: [String: Any] = ["type": "REMOTE_OBSERVED", "sessionID": session.uuidString,
                        "target": try SessionCoreBridge.dictionary(latest)]
                    if let base = context.target.baseText { observation["comparisonBase"] = base }
                    dispatch(observation)
                    try prepareMerge(target: latest, token: UUID().uuidString, local: state.text, base: context.target.baseText)
                    remoteIssue = "確認中に保存先が再更新されました。新しい比較を確認してください。"
                    return
                }
                dispatch(["type": "USER_ACCEPT_TARGET", "sessionID": session.uuidString,
                          "token": UUID().uuidString, "target": try SessionCoreBridge.dictionary(latest),
                          "remoteTextAccepted": latest.baseText?.utf16.elementsEqual(snapshot.text.utf16) ?? false])
                mergeContext = nil; remoteIssue = nil; scheduleAutosave()
            } catch { if state.sessionID == session { remoteIssue = error.localizedDescription } }
        }
    }

    func reconcileUnknown() {
        guard state.uncertain, let unknown = state.unknownOperation, !observingRemote, !hasEvidenceOperation, state.operation == nil, !isTransitioning else { return }
        observingRemote = true
        let session = state.sessionID
        Task { [weak self] in
            guard let self else { return }
            defer { observingRemote = false }
            do {
                let observed: CoreTarget?
                if let identity = unknown.snapshot.target?.identity {
                    observed = try await adapter(for: unknown.snapshot.target).read(identity: identity)
                } else {
                    observed = try await adapter(for: nil).find(name: unknown.name ?? unknown.snapshot.name)
                }
                guard session == state.sessionID, state.unknownOperation?.token == unknown.token else { return }
                let fingerprint = CoreBaseline.make(try unknown.snapshot.encodedBytes())
                guard let observed, observed.baseline == fingerprint, observed.format == unknown.snapshot.format else {
                    remoteIssue = "書き込まれた内容との一致を確認できません。同じファイルへの再保存を止めています。別名保存で下書きを残してください。"
                    return
                }
                dispatch(["type": "RECONCILE_OK", "sessionID": session.uuidString, "token": UUID().uuidString,
                          "unknownToken": unknown.token, "revision": unknown.snapshot.revision,
                          "target": try SessionCoreBridge.dictionary(observed), "applied": true])
                acceptedAt = Date()
                remoteIssue = "書き込み内容の一致を再確認しました。クラウド反映は未確認です。"
                scheduleAutosave()
            } catch { if session == state.sessionID { remoteIssue = error.localizedDescription } }
        }
    }

    func saveAs(name: String, snapshot: EditorSnapshot) {
        self.snapshot(snapshot)
        guard snapshot.sessionID == state.sessionID, !snapshot.isComposing, !isTransitioning, !observingRemote, !hasEvidenceOperation else { return }
        guard state.target?.providerKind != "files" else {
            saveAsIssue = "Files 経由の新規・別名保存は未実装です。安全な保存先選択の確認後に対応します。"
            return
        }
        do {
            let checked = try SaveName.validate(name)
            saveAsIssue = nil
            dispatch(["type": "SAVE_AS", "token": UUID().uuidString, "name": checked])
        } catch { saveAsIssue = error.localizedDescription }
    }

    func validateSaveAsName(_ name: String) {
        nameValidationGeneration += 1
        guard state.target?.providerKind != "files" else {
            saveAsIssue = "Files 経由の新規・別名保存は未実装です。"
            return
        }
        let generation = nameValidationGeneration
        let validationSession = state.sessionID
        do {
            let checked = try SaveName.validate(name)
            saveAsIssue = "ファイル名を確認しています…"
            Task { [weak self] in
                guard let self else { return }
                do {
                    let available = try await fakeProvider.nameIsAvailable(checked)
                    guard generation == nameValidationGeneration, state.sessionID == validationSession else { return }
                    saveAsIssue = available ? nil : "同じ名前のファイルがあります。別の名前を入力してください。"
                } catch {
                    guard generation == nameValidationGeneration, state.sessionID == validationSession else { return }
                    saveAsIssue = error.localizedDescription
                }
            }
        } catch { saveAsIssue = error.localizedDescription }
    }

    func protectNow() {
        dispatch(["type": "PROTECT", "token": UUID().uuidString])
    }

    private func protectLatestIfNeeded() {
        let pending = rawState["pendingDrafts"] as? [[String: Any]] ?? []
        guard !(hasEvidenceOperation && !pending.isEmpty) else { return }
        guard !pending.contains(where: { $0["role"] as? String == "protect" }) else { return }
        // One automatic full-text snapshot at a time. Explicit save/reload barriers remain independent.
        protectNow()
    }

    func newDraft() {
        beginTransition { _ in
            .created(name: "無題.txt", text: "", format: "utf8", target: nil)
        }
    }

    func openRecent(_ id: UUID) {
        beginTransition { controller in
            .restored(try await controller.drafts.loadEnvelope(id))
        }
    }

    func openFakeSample() {
        beginTransition { controller in
            let sample = try await controller.fakeProvider.sample()
            return .created(name: sample.target.name, text: sample.text, format: sample.format, target: sample.target)
        }
    }

    private func adapter(for target: CoreTarget?) throws -> any ProviderAdapter {
        switch target?.providerKind {
        case nil, "fake": return fakeProvider
        case "files": return filesProvider
        default: throw ProviderFailure(code: "unsupportedProvider", message: "保存先の種類を確認できません。下書きは保持しています。")
        }
    }

    func requestFilesPicker() {
        guard FilesProviderAdapter.isEnabled, !state.isComposing, !isTransitioning,
              state.operation == nil, !hasEvidenceOperation, !preparingHistoryRestore, !observingRemote else {
            notice = "Files 接続はMacでの検証待ちのため無効です。端末下書きは保持しています。"
            return
        }
        showsFilesPicker = true
    }

    func pickedFilesURL(_ url: URL) {
        showsFilesPicker = false
        guard FilesProviderAdapter.isEnabled else { return }
        beginTransition { controller in
            let target = try await controller.filesProvider.registerPickedURL(url)
            guard let text = target.baseText, let format = target.format else { throw StorageError.invalidDraft }
            return .created(name: target.name, text: text, format: format, target: target)
        }
    }

    private func updateFilesObservation() {
        observationGeneration += 1
        let generation = observationGeneration
        let session = state.sessionID
        let target = state.target
        let predecessor = observationTail
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            await filesProvider.shutdownObservers()
            guard FilesProviderAdapter.isEnabled, generation == observationGeneration,
                  target?.providerKind == "files", let identity = target?.identity else { return }
            do {
                try await filesProvider.beginObserving(identity: identity) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.state.sessionID == session,
                              self.state.target?.identity == identity else { return }
                        switch event {
                        case .changed, .moved, .deleted:
                            self.dispatch(["type": "INVALIDATE_REMOTE", "sessionID": session.uuidString, "identity": identity])
                            self.remoteIssue = "保存先の変更通知を受け取りました。再読込で最新の内容を確認してください。"
                        case .failed(_, let message):
                            self.dispatch(["type": "INVALIDATE_REMOTE", "sessionID": session.uuidString, "identity": identity])
                            self.remoteIssue = message
                        }
                    }
                }
                if generation != observationGeneration { await filesProvider.stopObserving(identity: identity) }
            } catch {
                guard generation == observationGeneration, session == state.sessionID else { return }
                remoteIssue = "保存先の変更監視を開始できません。再読込で確認してください。 " + error.localizedDescription
            }
        }
        observationTail = task
    }

    func refreshStorage() async {
        do {
            storageCapacity = try await drafts.capacityStatus()
            switch storageCapacity?.status {
            case "availableUnknown": storageStatus = "端末の空き容量を確認できません。次の下書き保護は停止します。記録は残しています。"
            case "overBudget": storageStatus = "下書きの保管枠を超えています。自動削除は行いません。"
            default:
                storageStatus = storageCapacity?.availableBytes.map { "端末の空き容量（取得時点）: " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            }
            let result = try bridge.invoke("historyList", ["state": rawState])
            let projection = try SessionCoreBridge.decode(HistoryListProjection.self, from: result)
            historyEntries = projection.entries.map { entry in
                HistoryEntryPresentation(id: entry.id, name: entry.name, date: nil,
                    baseBytes: entry.baseBytes, localBytes: entry.localBytes, remoteBytes: entry.remoteBytes,
                    totalBytes: entry.totalBytes, canDelete: entry.canDelete, deleteBlockReason: entry.deleteBlockReason)
            }
            historyListEpoch = state.epoch
        } catch { storageStatus = "容量を確認できません。記録は削除していません。 " + error.localizedDescription }
    }

    private struct HistoryListProjection: Decodable {
        let entries: [Entry]
        struct Entry: Decodable {
            let id: String
            let name: String
            let baseBytes: Int
            let localBytes: Int
            let remoteBytes: Int
            let totalBytes: Int
            let canDelete: Bool
            let deleteBlockReason: String?
        }
    }

    private var hasEvidenceOperation: Bool {
        preparingHistoryRestore || rawState["pendingEvidenceDeletion"] is [String: Any] || rawState["pendingEvidenceRestore"] is [String: Any]
    }

    func inspectHistory(_ id: String) {
        do {
            let raw = try bridge.invoke("evidenceFor", ["state": rawState, "id": id])
            inspectedHistory = HistoryInspectionPresentation(id: id, name: (raw["target"] as? [String: Any])?["name"] as? String ?? "復旧履歴",
                base: raw["baseText"] as? String ?? "", local: raw["localText"] as? String ?? "", remote: raw["text"] as? String ?? "",
                canRestore: !isTransitioning && !observingRemote && !hasEvidenceOperation && state.operation == nil && !state.isComposing && !state.uncertain,
                status: "本文として復元します。現在の保存文字コードと改行方針は維持します。")
        } catch { storageStatus = "履歴を確認できません。表示を更新してください。 " + error.localizedDescription }
    }

    func deleteHistory(_ ids: [String], confirmation: String, expectedEpoch: Int) {
        guard confirmation == "削除", !isTransitioning, !observingRemote,
              state.operation == nil, !hasEvidenceOperation, !state.isComposing, state.draftError == nil,
              protectedEpoch == state.epoch, expectedEpoch == state.epoch else {
            storageStatus = "下書きの保護と最新一覧を確認してから削除してください。記録は削除していません。"
            return
        }
        dispatch(["type": "DELETE_EVIDENCE", "sessionID": state.sessionID.uuidString,
                  "token": UUID().uuidString, "ids": ids, "confirmed": true, "expectedEpoch": expectedEpoch])
        guard hasEvidenceOperation else { storageStatus = "履歴は削除できません。最新一覧と保護状況を確認してください。"; return }
        Task { [weak self] in
            guard let self else { return }
            await drainEffects()
            inspectedHistory = nil
            await refreshStorage()
        }
    }

    func prepareHistoryRestore(_ id: String, source: HistoryRestoreSource, snapshot: EditorSnapshot) {
        self.snapshot(snapshot)
        guard snapshot.sessionID == state.sessionID, !snapshot.isComposing, !isTransitioning,
              !observingRemote, !hasEvidenceOperation, state.operation == nil, !state.uncertain else { return }
        restoreHistoryPreview = nil
        let token = UUID().uuidString
        requestedHistoryRestoreToken = token
        preparingHistoryRestore = true
        autosaveTask?.cancel()
        let session = state.sessionID, revision = state.revision, expectedText = state.text
        Task { [weak self] in
            guard let self else { return }
            await drainEffects()
            guard requestedHistoryRestoreToken == token else { return }
            preparingHistoryRestore = false
            guard state.sessionID == session, state.revision == revision,
                  state.text.utf16.elementsEqual(expectedText.utf16), !state.isComposing,
                  !isTransitioning, !observingRemote, state.operation == nil, !state.uncertain,
                  !hasEvidenceOperation, state.draftError == nil, protectedEpoch == state.epoch else {
                requestedHistoryRestoreToken = nil
                storageStatus = "準備中に本文または保護状態が変わりました。最新の本文から候補を作り直してください。"
                scheduleAutosave()
                return
            }
            dispatch(["type": "RESTORE_EVIDENCE", "sessionID": session.uuidString,
                      "token": token, "ids": [id], "source": source.rawValue,
                      "confirmed": true, "expectedEpoch": state.epoch])
            if !hasEvidenceOperation { requestedHistoryRestoreToken = nil; storageStatus = "本文の保護を確認してから復元してください。" }
        }
    }

    func confirmHistoryRestore(_ token: String, snapshot: EditorSnapshot) {
        guard let context = restoreHistoryContext, let preview = restoreHistoryPreview,
              token == context.token, context.sessionID == state.sessionID,
              snapshot.sessionID == context.sessionID, !snapshot.isComposing,
              snapshot.text.utf16.elementsEqual(preview.candidate.utf16), !isTransitioning,
              !observingRemote, !hasEvidenceOperation, !state.uncertain, state.operation == nil, state.draftError == nil,
              protectedEpoch >= context.epoch, state.protectedRevision >= context.revision,
              ((context.revision == state.revision && state.text.utf16.elementsEqual(preview.expectedText.utf16)) ||
               (state.revision == context.revision + 1 && state.text.utf16.elementsEqual(preview.candidate.utf16))) else { return }
        self.snapshot(snapshot)
        restoreHistoryContext = nil
        requestedHistoryRestoreToken = nil
        restoreHistoryPreview = nil
        inspectedHistory = nil
        storageStatus = "復旧履歴の本文を編集欄へ適用しました。現在の下書きの保護状況を確認してください。"
        scheduleAutosave()
    }

    func closeStorageManagement() {
        storageManagementVisible = false
        preparingHistoryRestore = false
        inspectedHistory = nil
        restoreHistoryPreview = nil
        restoreHistoryContext = nil
        requestedHistoryRestoreToken = nil
        scheduleAutosave()
    }

    func setScenario(_ scenario: FakeScenario) {
        guard state.operation == nil, !hasEvidenceOperation, !isTransitioning, !observingRemote else {
            notice = "保存処理が終わってから検証条件を変更してください。"
            return
        }
        Task { await fakeProvider.setScenario(scenario) }
        notice = "検証条件: " + scenario.label + "。Google ドライブには接続していません。"
    }

    func cancelSave() {
        guard let operation = state.operation else { return }
        let session = state.sessionID.uuidString
        // Atomic local protection is allowed to finish. Only the provider operation is cancelled.
        effectTasks[session + ":" + operation.token + ":WRITE"]?.cancel()
        effectTasks[session + ":" + operation.token + ":READ"]?.cancel()
        dispatch(["type": "CANCEL", "sessionID": session, "token": operation.token])
        protectNow()
        notice = "保存処理の中断を要求しました。受付け済みの書き込みは取り消せない場合があります。端末の下書きは残します。"
    }

    private func beginTransition(_ prepare: @escaping @MainActor (SessionController) async throws -> PreparedDocument) {
        guard !isTransitioning, !state.isComposing, !hasEvidenceOperation, state.operation == nil, !observingRemote else {
            notice = "変換または保存処理が終わってからファイルを切り替えてください。"
            return
        }
        isTransitioning = true
        autosaveTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            defer { isTransitioning = false; scheduleAutosave() }
            // Drain metadata and earlier autosaves first; only then allocate the final protection epoch.
            await drainEffects()
            protectNow()
            await drainEffects()
            guard !state.isComposing, state.draftError == nil, state.protectedRevision == state.revision, protectedEpoch == state.epoch else {
                notice = "最新の下書きを端末に保存できないため、ファイルを切り替えません。本文は編集画面に残っています。"
                return
            }
            do {
                let previousSession = state.sessionID
                let protectedRevision = state.revision
                let finalEpoch = state.epoch
                let prepared = try await prepare(self)
                // Preparing a destination must not itself replace the live session. Check again after awaiting it.
                guard state.sessionID == previousSession, !state.isComposing,
                      state.revision == protectedRevision, state.epoch == finalEpoch,
                      state.draftError == nil, protectedEpoch == state.epoch else {
                    notice = "切替中に本文が更新されたため、切替を止めました。最新の下書きを残し、もう一度操作してください。"
                    return
                }
                switch prepared {
                case .created(let name, let text, let format, let target):
                    try create(name: name, text: text, format: format, target: target)
                case .restored(let envelope): try restore(envelope)
                }
                saveAsIssue = nil
                protectNow()
                await drainEffects()
                if rawState["remoteCandidate"] is [String: Any] {
                    dispatch(["type": "RELOAD", "token": UUID().uuidString])
                    await drainEffects()
                }
                await refreshRecents()
                await refreshStorage()
                scheduleAutosave()
            } catch {
                notice = "ファイルを開けません。現在の下書きは残しています。 " + error.localizedDescription
            }
        }
    }

    private func create(name: String, text: String, format: String, target: CoreTarget?) throws {
        var seed: [String: Any] = ["id": UUID().uuidString, "sessionID": UUID().uuidString,
                                  "name": name, "text": text, "format": format, "lineEnding": target == nil ? "crlf" : "preserve"]
        if let target {
            seed["target"] = try SessionCoreBridge.dictionary(target)
            seed["acceptedRevision"] = 0
        } else {
            seed["target"] = NSNull()
            seed["acceptedRevision"] = NSNull()
        }
        try replaceState(bridge.invoke("create", seed))
        mergeContext = nil
        remoteIssue = nil
        protectedEpoch = -1
        protectedAt = nil
        acceptedAt = nil
        inspectedHistory = nil
        restoreHistoryPreview = nil
        restoreHistoryContext = nil
        requestedHistoryRestoreToken = nil
        historyEntries = []
        historyListEpoch = -1
        updateFilesObservation()
    }

    private func restore(_ envelope: CoreEnvelope) throws {
        try envelope.validate()
        var restored = try bridge.invoke("restore", SessionCoreBridge.dictionary(envelope))
        restored["sessionID"] = UUID().uuidString
        try replaceState(restored)
        mergeContext = nil
        remoteIssue = nil
        protectedEpoch = envelope.epoch
        protectedAt = nil
        acceptedAt = nil
        if let candidate = envelope.remoteCandidate {
            // Offline restoration can show the protected originals; they are not a fresh permission to apply.
            try prepareMerge(target: candidate.target, token: UUID().uuidString, local: candidate.localText,
                             base: candidate.baseText, verifiedObservation: false)
            remoteIssue = "保存済みの三原文を復元しました。保存先の最新確認が済むまで適用できません。"
        }
        inspectedHistory = nil
        restoreHistoryPreview = nil
        restoreHistoryContext = nil
        requestedHistoryRestoreToken = nil
        historyEntries = []
        historyListEpoch = -1
        updateFilesObservation()
    }

    private func replaceState(_ value: [String: Any]) throws {
        let projection = try SessionCoreBridge.decode(CoreStateCodable.self, from: value)
        rawState = value
        state = projection
    }

    private func dispatch(_ event: [String: Any]) {
        do {
            let result = try bridge.invoke("reduce", ["state": rawState, "event": event])
            guard let value = result["state"] as? [String: Any], let effects = result["effects"] as? [[String: Any]]
            else { throw CoreBridgeError.invalidResult }
            try replaceState(value)
            for effect in effects { try schedule(effect) }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func schedule(_ effect: [String: Any]) throws {
        guard let type = effect["type"] as? String,
              let token = effect["token"] as? String,
              let session = effect["sessionID"] as? String,
              UUID(uuidString: session) != nil else { throw CoreBridgeError.invalidResult }
        let key = session + ":" + token + ":" + type
        guard effectTasks[key] == nil else { throw CoreBridgeError.invalidResult }
        if type == "PERSIST" {
            guard let object = effect["envelope"] as? [String: Any] else { throw CoreBridgeError.invalidResult }
            let envelope = try SessionCoreBridge.decode(CoreEnvelope.self, from: object)
            let predecessor = persistenceTail
            let task = Task { [weak self] in
                await predecessor?.value
                guard let self else { return }
                defer { effectTasks[key] = nil }
                do {
                    try Task.checkCancellation()
                    try await drafts.persist(envelope)
                    guard state.sessionID.uuidString == session else { return }
                    let wasEvidenceOperation = hasEvidenceOperation
                    dispatch(["type": "DRAFT_OK", "sessionID": session, "token": token,
                              "revision": envelope.revision, "epoch": envelope.epoch])
                    protectedEpoch = max(protectedEpoch, envelope.epoch)
                    protectedAt = Date()
                    if requestedHistoryRestoreToken == token, !hasEvidenceOperation, restoreHistoryPreview == nil {
                        requestedHistoryRestoreToken = nil
                        storageStatus = "保護中に本文または変換状態が変わったため復元候補を取り消しました。下書きは残しています。"
                        scheduleAutosave()
                    }
                    if state.protectedRevision < state.revision, state.draftError == nil { protectLatestIfNeeded() }
                    if wasEvidenceOperation && !hasEvidenceOperation && requestedHistoryRestoreToken == nil { scheduleAutosave() }
                    await refreshRecents()
                    if storageManagementVisible { await refreshStorage() }
                } catch {
                    dispatch(["type": "DRAFT_FAILED", "sessionID": session, "token": token,
                              "message": error.localizedDescription])
                    if state.sessionID.uuidString == session, requestedHistoryRestoreToken == token {
                        requestedHistoryRestoreToken = nil
                        restoreHistoryPreview = nil
                        restoreHistoryContext = nil
                        storageStatus = "下書きを保護できないため履歴復元を止めました。本文と履歴は残しています。"
                        scheduleAutosave()
                    }
                }
            }
            effectTasks[key] = task
            persistenceTail = task
        } else if type == "RESTORE_READY" {
            guard state.sessionID.uuidString == session, requestedHistoryRestoreToken == token, !state.isComposing, state.draftError == nil,
                  let historyID = effect["historyID"] as? String,
                  let sourceRaw = effect["source"] as? String, let source = HistoryRestoreSource(rawValue: sourceRaw),
                  let text = effect["text"] as? String, let expected = effect["expectedText"] as? String,
                  let revision = effect["revision"] as? Int, revision == state.revision,
                  state.text.utf16.elementsEqual(expected.utf16) else { return }
            restoreHistoryContext = (token, state.sessionID, revision, state.epoch)
            restoreHistoryPreview = HistoryRestorePreviewPresentation(id: token, historyID: historyID, source: source,
                expectedText: expected, candidate: text, canApply: true)
        } else if type == "READ" {
            guard let object = effect["snapshot"] as? [String: Any] else { throw CoreBridgeError.invalidResult }
            let captured = try SessionCoreBridge.decode(CoreWriteSnapshot.self, from: object)
            guard let identity = captured.target?.identity else { throw CoreBridgeError.invalidResult }
            effectTasks[key] = Task { [weak self] in
                guard let self else { return }
                defer { effectTasks[key] = nil }
                do {
                    let observed = try await adapter(for: captured.target).read(identity: identity)
                    guard state.sessionID.uuidString == session, state.operation?.token == token,
                          let text = observed.baseText, let format = observed.format else { return }
                    guard observed.identity == identity else {
                        throw ProviderFailure(code: "invalidReceipt", message: "読込の返答が選択したファイルと一致しません。下書きは保持しています。")
                    }
                    dispatch(["type": "READ_OK", "sessionID": session, "token": token,
                              "target": try SessionCoreBridge.dictionary(observed), "text": text, "format": format])
                    try prepareMerge(target: observed, token: token, local: state.text, base: captured.target?.baseText,
                                     allowAutoApply: captured.revision == state.revision)
                    autosaveStatus = "最新の保存先を読みました・候補を確認してください"
                } catch {
                    guard state.sessionID.uuidString == session, state.operation?.token == token,
                          state.operation?.kind == "reload", state.operation?.phase == "reading" else { return }
                    dispatch(["type": "READ_FAILED", "sessionID": session, "token": token,
                              "code": (error as? ProviderFailure)?.code ?? "read", "message": error.localizedDescription])
                    remoteIssue = error.localizedDescription
                }
            }
        } else if type == "WRITE" {
            guard let object = effect["snapshot"] as? [String: Any], let kind = effect["kind"] as? String
            else { throw CoreBridgeError.invalidResult }
            let snapshot = try SessionCoreBridge.decode(CoreWriteSnapshot.self, from: object)
            let proposedName = effect["name"] as? String
            effectTasks[key] = Task { [weak self] in
                guard let self else { return }
                defer { effectTasks[key] = nil }
                do {
                    let target = try await adapter(for: snapshot.target).write(kind: kind, snapshot: snapshot, name: proposedName)
                    guard state.sessionID.uuidString == session, state.operation?.token == token,
                          state.operation?.phase == "writing" else { return }
                    dispatch(["type": "WRITE_OK", "sessionID": session, "token": token,
                              "revision": snapshot.revision, "target": try SessionCoreBridge.dictionary(target)])
                    guard state.operation == nil, state.acceptedRevision == snapshot.revision, state.target == target else {
                        throw ProviderFailure(code: "unknownOutcome", message: "書込の返答が現在の保存処理と一致しません。再確認まで再送せず、下書きを保持します。")
                    }
                    acceptedAt = Date()
                    autosaveStatus = "保存先が書き込みを受付済み・クラウド反映未確認"
                    if state.acceptedRevision != state.revision { scheduleAutosave() }
                } catch {
                    guard state.sessionID.uuidString == session, state.operation?.token == token,
                          state.operation?.phase == "writing" else { return }
                    let failure = error as? ProviderFailure
                    let code = failure?.code ?? (error is CancellationError ? "interrupted" : "write")
                    dispatch(["type": "WRITE_FAILED", "sessionID": session, "token": token,
                              "code": code, "message": error.localizedDescription])
                    if code == "nameCollision" { saveAsIssue = error.localizedDescription }
                    autosaveStatus = code == "unknownOutcome" ? "書き込み結果不明・再確認まで自動保存停止" : "保存に失敗・端末下書き保持"
                }
            }
        } else { throw CoreBridgeError.invalidResult }
    }

    private func drainEffects() async {
        while !effectTasks.isEmpty {
            let running = Array(effectTasks.values)
            for task in running { await task.value }
        }
    }

    private func refreshRecents() async {
        do {
            let result = try await drafts.scan()
            recents = result.records
            if !result.failures.isEmpty {
                notice = "\(result.failures.count) 件の下書きを読み取れません。原本は残しています。\n" + result.failures.joined(separator: "\n")
            }
        } catch { notice = "最近の下書きを読み取れません。 " + error.localizedDescription }
    }
}

extension SessionController {
    private var noticeIncludingRecoveryHistory: String? {
        let count = (rawState["retainedEvidence"] as? [[String: Any]])?.count ?? 0
        guard count > 0 else { return notice }
        let history = protectedEpoch >= state.epoch && state.draftError == nil
            ? "復旧用の比較履歴を \(count) 件、端末下書きに保護しました。古い比較の原文も削除していません。"
            : "復旧用の比較履歴 \(count) 件の保護完了を待っています。"
        return notice.map { $0 + "\n" + history } ?? history
    }
    private var mergePresentation: MergePreviewPresentation? {
        guard let context = mergeContext, context.sessionID == state.sessionID else { return nil }
        let raw = context.result["raw"] as? [String: String] ?? [:]
        let blocks = context.result["conflictBlocks"] as? [[String: Any]] ?? []
        var displayedCandidate = context.candidate
        if displayedCandidate == nil, !blocks.isEmpty {
            // Read-only preview: unresolved blocks use local text provisionally, while actual application stays disabled.
            let provisionalChoices: [Any] = context.choices.map { $0 ?? "local" }
            if let resolved = try? bridge.invoke("resolve", ["result": context.result, "choices": provisionalChoices]),
               let text = resolved["text"] as? String {
                displayedCandidate = candidateText(text, local: context.local, remote: raw["remote"] ?? "", base: raw["base"] ?? "")
            }
        }
        return MergePreviewPresentation(id: context.token, base: raw["base"] ?? "", local: context.local,
                                        remote: raw["remote"] ?? "", candidate: displayedCandidate ?? "",
                                        conflicts: blocks.enumerated().map { index, block in
                                            MergeConflictPresentation(id: String(index), base: block["base"] as? String ?? "",
                                                                      local: block["local"] as? String ?? "", remote: block["remote"] as? String ?? "",
                                                                      resolution: context.resolutions[index])
                                        }, canApply: context.verifiedObservation && context.candidate != nil && !hasEvidenceOperation && !state.uncertain && !state.isComposing && state.operation == nil && !observingRemote && state.draftError == nil && protectedEpoch == state.epoch,
                                        requiresConfirmation: context.requiresConfirmation)
    }
    var screenState: EditorScreenState {
        let draftState: DraftPresentation
        if let error = state.draftError { draftState = .failed(error) }
        else if state.protectedRevision < state.revision || protectedEpoch < state.epoch { draftState = .protecting }
        else { draftState = .protected(date: protectedAt, revision: state.protectedRevision) }
        let cloudState: CloudPresentation
        if state.operation != nil { cloudState = .writing }
        else if state.conflict { cloudState = .conflict }
        else if let error = state.fileError { cloudState = .failed(error) }
        else if state.target == nil { cloudState = .noDestination }
        else if let revision = state.acceptedRevision { cloudState = .providerAccepted(date: acceptedAt, revision: revision) }
        else { cloudState = .changesPending }
        return EditorScreenState(
            configuration: EditorSurfaceConfiguration(sessionID: state.sessionID, initialText: state.text, isEditable: !isTransitioning),
            fileName: state.name, destinationSummary: state.target?.location ?? "未設定・端末の下書きのみ",
            currentRevision: state.revision, draftState: draftState, cloudState: cloudState,
            recents: recents.map { record in
                RecentFilePresentation(id: record.id, name: record.name,
                                       destination: record.coreTarget?.location ?? "端末の下書き", lastOpened: record.updatedAt,
                                       hasLocalChanges: record.acceptedRevision != record.revision)
            }, isBusy: state.operation != nil || hasEvidenceOperation || preparingHistoryRestore || isTransitioning || observingRemote,
            modeLabel: state.target?.providerKind == "files" ? "Files 接続の検証・クラウド反映は未確認" : "検証用の偽保存先・Google ドライブ未接続", saveAsIssue: saveAsIssue,
            notice: noticeIncludingRecoveryHistory, isComposing: state.isComposing, isEditorLocked: isTransitioning,
            autosaveStatus: autosaveStatus,
            storagePolicy: formatLabel + " / " + (state.lineEnding == "crlf" ? "保存時 CRLF" : "既存改行を保持"),
            remoteIssue: remoteIssue, isOutcomeUncertain: state.uncertain, mergePreview: mergePresentation,
            hasDestination: state.target != nil, storageManagement: storageManagementPresentation,
            historyInspection: safeHistoryInspection, historyRestorePreview: safeHistoryRestorePreview,
            isFilesPickerEnabled: FilesProviderAdapter.isEnabled)
    }

    var screenActions: EditorScreenActions {
        EditorScreenActions(onSnapshot: { [weak self] in self?.snapshot($0) },
                            onSave: { [weak self] in self?.save($0) },
                            onSaveAs: { [weak self] name, snapshot in self?.saveAs(name: name, snapshot: snapshot) },
                            onValidateSaveAsName: { [weak self] in self?.validateSaveAsName($0) },
                            onOpenRecent: { [weak self] in self?.openRecent($0) },
                            onOpenFiles: { [weak self] in self?.openFakeSample() },
                            onNew: { [weak self] in self?.newDraft() },
                            onSetScenario: { [weak self] value in
                                let scenario: FakeScenario
                                switch value {
                                case .normal: scenario = .normal
                                case .delayed: scenario = .delayed
                                case .permissionDenied: scenario = .accessRevoked
                                case .externalChange: scenario = .conflict
                                case .cancelled: scenario = .interrupted
                                case .moved: scenario = .moved
                                case .deleted: scenario = .deleted
                                case .unknownOutcome: scenario = .unknownOutcome
                                case .offline: scenario = .offline
                                }
                                self?.setScenario(scenario)
                            }, onCancelSave: state.operation == nil ? nil : { [weak self] in self?.cancelSave() },
                            onReload: { [weak self] snapshot in self?.reload(snapshot) },
                            onReconcileUnknown: { [weak self] in self?.reconcileUnknown() },
                            onResolveMergeConflict: { [weak self] id, resolution in self?.resolveMergeConflict(id, resolution: resolution) },
                            onConfirmMerge: { [weak self] token, snapshot in self?.confirmMerge(token, snapshot: snapshot) },
                            onInspectHistory: { [weak self] in self?.inspectHistory($0) },
                            onDeleteHistory: { [weak self] ids, confirmation, epoch in self?.deleteHistory(ids, confirmation: confirmation, expectedEpoch: epoch) },
                            onPrepareHistoryRestore: { [weak self] id, source, snapshot in self?.prepareHistoryRestore(id, source: source, snapshot: snapshot) },
                            onConfirmHistoryRestore: { [weak self] token, snapshot in self?.confirmHistoryRestore(token, snapshot: snapshot) },
                            onRefreshStorage: { [weak self] in
                                self?.storageManagementVisible = true
                                Task { await self?.refreshStorage() }
                            }, onOpenSystemFiles: { [weak self] in self?.requestFilesPicker() },
                            onCloseStorageManagement: { [weak self] in self?.closeStorageManagement() })
    }

    private var storageManagementPresentation: StorageManagementPresentation? {
        guard let capacity = storageCapacity else { return nil }
        let clean = state.acceptedRevision == state.revision && !state.conflict && !state.uncertain
            && state.operation == nil && !hasEvidenceOperation && !state.isComposing && !isTransitioning && !observingRemote
            && state.draftError == nil && protectedEpoch == state.epoch && historyListEpoch == state.epoch
        let entries = historyEntries.map { entry in
            HistoryEntryPresentation(id: entry.id, name: entry.name, date: entry.date, baseBytes: entry.baseBytes,
                localBytes: entry.localBytes, remoteBytes: entry.remoteBytes, totalBytes: entry.totalBytes,
                canDelete: entry.canDelete && clean,
                deleteBlockReason: clean ? entry.deleteBlockReason : "未保存・確認待ち、または一覧の更新待ちのため削除できません。")
        }
        return StorageManagementPresentation(budgetBytes: capacity.budgetBytes, usedBytes: capacity.usedBytes,
            remainingBytes: capacity.remainingBytes,
            protectedSummary: "未保存の下書き・現在の競合・保存結果不明の記録は、自動削除せず保持します。",
            entries: entries, currentEvidenceSummary: rawState["remoteCandidate"] is [String: Any] ? "現在の三原文は確認待ちのため削除対象にできません。" : nil,
            pendingSummary: hasEvidenceOperation ? "履歴操作の下書き保護を待っています。" : nil,
            status: storageStatus, epoch: state.epoch)
    }

    private var safeHistoryInspection: HistoryInspectionPresentation? {
        guard let value = inspectedHistory else { return nil }
        return HistoryInspectionPresentation(id: value.id, name: value.name, base: value.base, local: value.local,
            remote: value.remote, canRestore: value.canRestore && !hasEvidenceOperation && !preparingHistoryRestore && state.operation == nil
                && !state.isComposing && !state.uncertain && !observingRemote && !isTransitioning,
            status: value.status)
    }

    private var safeHistoryRestorePreview: HistoryRestorePreviewPresentation? {
        guard let value = restoreHistoryPreview, let context = restoreHistoryContext else { return nil }
        let ready = context.sessionID == state.sessionID && context.revision == state.revision
            && state.text.utf16.elementsEqual(value.expectedText.utf16) && !state.isComposing && !state.uncertain
            && state.operation == nil && !hasEvidenceOperation && !observingRemote && !isTransitioning
            && state.draftError == nil && protectedEpoch == state.epoch
        return HistoryRestorePreviewPresentation(id: value.id, historyID: value.historyID, source: value.source,
            expectedText: value.expectedText, candidate: value.candidate, canApply: ready)
    }

    private var formatLabel: String {
        switch state.format {
        case "utf8": return "UTF-8"
        case "utf8BOM": return "UTF-8（BOM 付き）"
        case "utf16LE": return "UTF-16 LE（BOM 付き）"
        case "utf16BE": return "UTF-16 BE（BOM 付き）"
        default: return state.format
        }
    }
}
