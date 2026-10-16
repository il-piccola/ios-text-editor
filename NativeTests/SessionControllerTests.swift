import XCTest
@testable import IyoEditor

/// Integration regressions found by parent review; authored but NOT run on Windows.
@MainActor
final class SessionControllerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IyoControllerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Native integration did not reach the expected protected state")
        throw NSError(domain: "IyoNativeTest", code: 1)
    }

    func testTypingWhileSaveProtectsNewerDraftAndRestartsWithOlderAcceptedRevision() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftDirectory = root.appendingPathComponent("drafts")
        let fakeDirectory = root.appendingPathComponent("fake")
        let controller = try SessionController(draftDirectory: draftDirectory, fakeDirectory: fakeDirectory)
        await controller.start()
        let session = controller.state.sessionID
        let first = EditorSnapshot(sessionID: session, text: "保存開始時の本文", isComposing: false)
        controller.snapshot(first)
        controller.saveAs(name: "本文.txt", snapshot: first)
        // No await: WRITE cannot start before the local protection barrier completes.
        controller.snapshot(EditorSnapshot(sessionID: session, text: "保存開始時の本文と追記", isComposing: false))
        try await waitFor {
            if case .protected = controller.screenState.draftState {
                return controller.state.operation == nil && controller.state.acceptedRevision == 1
            }
            return false
        }
        XCTAssertEqual(controller.state.text, "保存開始時の本文と追記")
        XCTAssertEqual(controller.state.revision, 2)
        let provider = try FakeFileProvider(directory: fakeDirectory)
        let saved = try await provider.sample()
        XCTAssertEqual(saved.text, "保存開始時の本文")
        let restarted = try SessionController(draftDirectory: draftDirectory, fakeDirectory: fakeDirectory)
        await restarted.start()
        XCTAssertEqual(restarted.state.text, "保存開始時の本文と追記")
        XCTAssertEqual(restarted.state.acceptedRevision, 1)
        XCTAssertNotEqual(restarted.state.sessionID, session)
    }

    func testQueuedOldSessionInputDuringTransitionIsProtectedInsteadOfDropped() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftDirectory = root.appendingPathComponent("drafts")
        let controller = try SessionController(draftDirectory: draftDirectory,
                                               fakeDirectory: root.appendingPathComponent("fake"))
        await controller.start()
        let oldID = controller.state.id
        let oldSession = controller.state.sessionID
        controller.snapshot(EditorSnapshot(sessionID: oldSession, text: "切替前", isComposing: false))
        controller.newDraft()
        XCTAssertTrue(controller.isTransitioning)
        // Simulate a delegate notification already queued before UIKit applied its lock.
        controller.snapshot(EditorSnapshot(sessionID: oldSession, text: "切替前の最後の入力", isComposing: false))
        try await waitFor { !controller.isTransitioning && controller.state.id != oldID }
        let store = try DraftStore(directory: draftDirectory)
        let oldDraft = try await store.loadEnvelope(oldID)
        XCTAssertEqual(oldDraft.text, "切替前の最後の入力")
        XCTAssertEqual(controller.state.text, "")
        controller.snapshot(EditorSnapshot(sessionID: oldSession, text: "遅い古い通知", isComposing: false))
        XCTAssertEqual(controller.state.text, "")
    }

    func testCanonicalEquivalentEditStillReceivesANewDurableDraft() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftDirectory = root.appendingPathComponent("drafts")
        let controller = try SessionController(draftDirectory: draftDirectory,
                                               fakeDirectory: root.appendingPathComponent("fake"))
        await controller.start()
        let session = controller.state.sessionID
        controller.snapshot(EditorSnapshot(sessionID: session, text: "か\u{3099}", isComposing: false))
        try await waitFor { controller.state.protectedRevision == 1 }
        controller.snapshot(EditorSnapshot(sessionID: session, text: "が", isComposing: false))
        try await waitFor { controller.state.protectedRevision == 2 }
        let store = try DraftStore(directory: draftDirectory)
        let loaded = try await store.loadEnvelope(controller.state.id)
        XCTAssertEqual(Array(loaded.text.utf16), Array("が".utf16))
    }

    func testBurstTypingEventuallyProtectsLatestRawTextAcrossRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftDirectory = root.appendingPathComponent("drafts")
        let fakeDirectory = root.appendingPathComponent("fake")
        let controller = try SessionController(draftDirectory: draftDirectory, fakeDirectory: fakeDirectory)
        await controller.start()
        let session = controller.state.sessionID
        for index in 1...125 {
            controller.snapshot(EditorSnapshot(sessionID: session, text: "入力\(index)\r\nか\u{3099}😀", isComposing: false))
        }
        try await waitFor { controller.state.protectedRevision == 125 }
        let restarted = try SessionController(draftDirectory: draftDirectory, fakeDirectory: fakeDirectory)
        await restarted.start()
        XCTAssertEqual(Array(restarted.state.text.utf16), Array("入力125\r\nか\u{3099}😀".utf16))
        XCTAssertEqual(restarted.state.revision, 125)
    }

    private func controllerWithHistory(_ root: URL) async throws -> SessionController {
        let fakeDirectory = root.appendingPathComponent("fake")
        let provider = try FakeFileProvider(directory: fakeDirectory)
        let sample = try await provider.sample()
        var envelope = CoreEnvelope(id: UUID(), name: sample.target.name, text: sample.text, format: sample.format,
                                    revision: 0, epoch: 1, target: sample.target, acceptedRevision: 0)
        envelope.retainedEvidence = [CoreRemoteCandidate(token: "history-seed", text: sample.text, format: sample.format,
            target: sample.target, observedRevision: 0, snapshotRevision: 0, localText: "復元する原文\r\nか\u{3099}", baseText: "比較基準\n")]
        let store = try DraftStore(directory: root.appendingPathComponent("drafts"))
        try await store.persist(envelope)
        let controller = try SessionController(draftDirectory: root.appendingPathComponent("drafts"), fakeDirectory: fakeDirectory)
        await controller.start()
        return controller
    }

    func testHistoryRestoreWaitsForLiveInputProtectionAndAcceptsNativePublishBeforeCompletion() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try await controllerWithHistory(root)
        let entry = try XCTUnwrap(controller.screenState.storageManagement?.entries.first)
        let session = controller.state.sessionID
        let live = EditorSnapshot(sessionID: session, text: "復元直前の未保護入力", isComposing: false)
        controller.prepareHistoryRestore(entry.id, source: .local, snapshot: live)
        try await waitFor { controller.screenState.historyRestorePreview?.canApply == true }
        let preview = try XCTUnwrap(controller.screenState.historyRestorePreview)
        XCTAssertEqual(preview.expectedText, live.text)
        let nativeResult = EditorSnapshot(sessionID: session, text: preview.candidate, isComposing: false)
        // UIKit publishes the mutation before returning .applied. The UI also echoes this snapshot.
        controller.snapshot(nativeResult)
        controller.snapshot(nativeResult)
        controller.confirmHistoryRestore(preview.id, snapshot: nativeResult)
        XCTAssertNil(controller.screenState.historyRestorePreview)
        XCTAssertEqual(controller.state.text, "復元する原文\r\nか\u{3099}")
        XCTAssertFalse(controller.autosaveStatus.contains("履歴操作の確認待ち"))
        try await waitFor { controller.state.protectedRevision == controller.state.revision }
        let store = try DraftStore(directory: root.appendingPathComponent("drafts"))
        let envelope = try await store.loadEnvelope(controller.state.id)
        XCTAssertEqual(Array(envelope.text.utf16), Array(preview.candidate.utf16))
        XCTAssertEqual(envelope.retainedEvidence.count, 1)
    }

    func testClosingHistoryDuringPreparationCancelsRestoreCandidate() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try await controllerWithHistory(root)
        let entry = try XCTUnwrap(controller.screenState.storageManagement?.entries.first)
        let original = controller.state.text
        controller.prepareHistoryRestore(entry.id, source: .local,
            snapshot: EditorSnapshot(sessionID: controller.state.sessionID, text: original, isComposing: false))
        controller.closeStorageManagement()
        try await waitFor { !controller.screenState.isBusy }
        XCTAssertNil(controller.screenState.historyRestorePreview)
        XCTAssertEqual(Array(controller.state.text.utf16), Array(original.utf16))
        XCTAssertFalse(controller.autosaveStatus.contains("履歴操作の確認待ち"))
    }

    func testCancelledOldWriteCannotShowFailureDuringNewSameSessionSave() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try SessionController(draftDirectory: root.appendingPathComponent("drafts"),
                                               fakeDirectory: root.appendingPathComponent("fake"))
        await controller.start()
        controller.setScenario(.delayed)
        // Allow the app-private actor to receive its scenario selection before issuing writes.
        try await Task.sleep(nanoseconds: 20_000_000)
        let snapshot = EditorSnapshot(sessionID: controller.state.sessionID, text: "保護する本文", isComposing: false)
        controller.saveAs(name: "最初.txt", snapshot: snapshot)
        try await waitFor { controller.state.operation?.phase == "writing" }
        let oldToken = controller.state.operation?.token
        controller.cancelSave()
        controller.saveAs(name: "次の保存.txt", snapshot: snapshot)
        try await waitFor {
            controller.state.operation?.phase == "writing" && controller.state.operation?.token != oldToken
        }
        // The cancelled delayed task has time to deliver its error while the new write remains pending.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.state.operation?.name, "次の保存.txt")
        XCTAssertFalse(controller.autosaveStatus.contains("保存に失敗"))
        XCTAssertNil(controller.saveAsIssue)
        XCTAssertEqual(controller.state.text, snapshot.text)
        controller.cancelSave()
        try await waitFor {
            if case .protected = controller.screenState.draftState { return controller.state.operation == nil }
            return false
        }
    }
}

extension SessionControllerTests {
    func testRepeatedSaveDuringWriteKeepsSingleOperationAndAcceptedRevision() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeDirectory = root.appendingPathComponent("fake")
        let controller = try SessionController(draftDirectory: root.appendingPathComponent("drafts"),
                                               fakeDirectory: fakeDirectory)
        await controller.start()
        let first = EditorSnapshot(sessionID: controller.state.sessionID, text: "初回本文", isComposing: false)
        controller.saveAs(name: "重複防止.txt", snapshot: first)
        try await waitFor { controller.state.operation == nil && controller.state.target != nil }
        let accepted = controller.state.acceptedRevision
        controller.setScenario(.delayed)
        try await Task.sleep(nanoseconds: 20_000_000)
        let next = EditorSnapshot(sessionID: controller.state.sessionID, text: "初回本文と追記", isComposing: false)
        controller.save(next)
        try await waitFor { controller.state.operation?.phase == "writing" }
        let operation = try XCTUnwrap(controller.state.operation)
        for _ in 0..<8 {
            controller.save(next)
            XCTAssertEqual(controller.state.operation, operation)
            XCTAssertEqual(controller.state.acceptedRevision, accepted)
        }
        try await waitFor { controller.state.operation == nil && controller.state.acceptedRevision == controller.state.revision }
        XCTAssertEqual(controller.state.text, next.text)
        let provider = try FakeFileProvider(directory: fakeDirectory)
        let stored = try await provider.sample()
        XCTAssertEqual(stored.text, next.text)
    }
}
