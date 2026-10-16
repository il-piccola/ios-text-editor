import XCTest
import SwiftUI
import UIKit
@testable import IyoEditor

/// Source only on Windows. Run in the application-hosted iOS test target on Mac.
/// A synthetic marked range tests the safety guard, not Japanese keyboard quality.
@MainActor
final class EditorAdapterTests: XCTestCase {
    func testSnapshotDistinguishesCanonicalEquivalentUTF16() {
        let id = UUID()
        XCTAssertNotEqual(EditorSnapshot(sessionID: id, text: "é", isComposing: false),
                          EditorSnapshot(sessionID: id, text: "e\u{301}", isComposing: false))
    }

    func testDelegatePublishesNormalizationAndCompositionOnlyChanges() {
        let id = UUID()
        var received: [EditorSnapshot] = []
        let surface = UIKitEditorSurface(configuration: .init(sessionID: id, initialText: ""),
            router: EditorCommandRouter(), onSnapshot: { received.append($0) })
        let coordinator = UIKitEditorSurface.Coordinator(parent: surface)
        let view = GuardTestTextView()
        view.text = "é"
        coordinator.publish(view)
        view.text = "e\u{301}"
        coordinator.publish(view)
        view.syntheticMarkedRange = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
        coordinator.publish(view)
        view.syntheticMarkedRange = nil
        coordinator.publish(view)
        XCTAssertEqual(received.count, 4)
        XCTAssertEqual(received.map(\.isComposing), [false, false, true, false])
    }

    func testNativeFoundationBoundariesRejectPartialEmoji() throws {
        let planner = try ReplacementPlanner()
        let text = "文👩‍👩‍👧‍👦文\r\n"
        let preview = try planner.preview(text: text, selection: NSRange(location: 0, length: (text as NSString).length),
            request: .init(sessionID: UUID(), query: "👩", replacement: "人", scope: .document))
        XCTAssertEqual(preview.count, 0)
        XCTAssertTrue(preview.candidate.utf16.elementsEqual(text.utf16))
        let normalized = try planner.normalizedSelection(text: "e\u{301}", selection: .init(location: 1, length: 0))
        XCTAssertEqual(normalized, .init(location: 2, length: 0))
    }

    func testApplyRejectsStaleNormalizationLockedAndMarkedText() {
        let id = UUID()
        let surface = UIKitEditorSurface(configuration: .init(sessionID: id, initialText: ""),
            router: EditorCommandRouter(), onSnapshot: { _ in })
        let coordinator = UIKitEditorSurface.Coordinator(parent: surface)
        let view = GuardTestTextView()
        view.text = "e\u{301}"
        let request = EditorTextApplication(sessionID: id, expectedText: "é", text: "変更", actionName: "テスト")
        assertRejected(coordinator.apply(view, request: request, selection: .init(location: 0, length: 0)))
        let current = EditorTextApplication(sessionID: id, expectedText: view.text, text: "変更", actionName: "テスト")
        view.isEditable = false
        assertRejected(coordinator.apply(view, request: current, selection: .init(location: 0, length: 0)))
        view.isEditable = true
        view.syntheticMarkedRange = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument)
        assertRejected(coordinator.apply(view, request: current, selection: .init(location: 0, length: 0)))
        XCTAssertTrue(view.text.utf16.elementsEqual("e\u{301}".utf16))
    }

    func testRealUITextInputReplaceAndUndoRedoAreOneOperation() async throws {
        let id = UUID(), original = "文🍎文\r\n文"
        let surface = UIKitEditorSurface(configuration: .init(sessionID: id, initialText: original),
            router: EditorCommandRouter(), onSnapshot: { _ in })
        let coordinator = UIKitEditorSurface.Coordinator(parent: surface)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        let view = UITextView(frame: window.bounds)
        view.text = original
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        view.becomeFirstResponder()
        defer { view.resignFirstResponder(); window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.selectedRange = NSRange(location: 0, length: (original as NSString).length)
        let preview = try coordinator.preview(view,
            request: .init(sessionID: id, query: "文", replacement: "文字", scope: .document))
        let outcome = coordinator.apply(view,
            request: .init(sessionID: id, expectedText: original, text: preview.candidate, actionName: "一括置換"),
            selection: preview.selection)
        guard case .applied = outcome else { return XCTFail("Actual native replacement rejected") }
        XCTAssertTrue(view.text.utf16.elementsEqual("文字🍎文字\r\n文字".utf16))
        XCTAssertEqual(view.selectedRange, preview.selection.nsRange)
        // Let UIKit close its own event group; closing it manually leaves a pending close.
        try await waitForAutomaticUndoGroup(undo)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertTrue(view.text.utf16.elementsEqual(original.utf16))
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertTrue(view.text.utf16.elementsEqual(preview.candidate.utf16))
    }

    func testRouterDoesNotRouteOldSessionOrUndoWhileMarked() {
        let router = EditorCommandRouter(), old = UUID(), current = UUID()
        var calls = 0
        router.install(sessionID: old, handler: { _ in calls += 1 }, snapshotProvider: {
            .init(sessionID: old, text: "旧", isComposing: false)
        })
        router.install(sessionID: current, handler: { _ in calls += 1 }, snapshotProvider: {
            .init(sessionID: current, text: "新", isComposing: true)
        })
        router.uninstall(sessionID: old)
        XCTAssertNil(router.snapshot(for: old))
        XCTAssertNotNil(router.snapshot(for: current))
        router.send(.undo)
        XCTAssertEqual(calls, 0)
        router.send(.dismissKeyboard)
        XCTAssertEqual(calls, 1)
    }

    /// NOT compiled/run on Windows. This must use UIKit's real undo registration.
    /// Unlike the short test, do not remove or replace any existing undo actions.
    func testTwentyThousandReplacementsPreserveEarlierNativeTypingUndoAndRedo() async throws {
        let id = UUID()
        let beforeTyping = String(repeating: "文🍎か\u{3099}\r\n", count: 20_000)
        let typedSuffix = "先行入力\r\n"
        let afterTyping = beforeTyping + typedSuffix
        let expectedCandidate = String(repeating: "文章🍎か\u{3099}\r\n", count: 20_000) + typedSuffix
        let surface = UIKitEditorSurface(configuration: .init(sessionID: id, initialText: beforeTyping),
            router: EditorCommandRouter(), onSnapshot: { _ in })
        let coordinator = UIKitEditorSurface.Coordinator(parent: surface)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        let view = UITextView(frame: window.bounds)
        // Set the initial seed before attaching the responder. All subsequent edits use UITextInput.
        view.text = beforeTyping
        view.delegate = coordinator
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        XCTAssertTrue(view.becomeFirstResponder())
        defer { view.resignFirstResponder(); window.isHidden = true }
        let undo = try XCTUnwrap(view.undoManager)
        XCTAssertFalse(undo.canUndo, "The initial seed should not create an edit action")

        // Establish a real earlier editing action. No registerUndo/custom text assignment is allowed.
        let insertion = try XCTUnwrap(view.textRange(from: view.endOfDocument, to: view.endOfDocument))
        undo.beginUndoGrouping()
        view.replace(insertion, withText: typedSuffix)
        undo.setActionName("先行入力")
        undo.endUndoGrouping()
        // Let the typing event finish so bulk replacement is a separate action.
        try await waitForAutomaticUndoGroup(undo)
        XCTAssertTrue(view.text.utf16.elementsEqual(afterTyping.utf16))
        XCTAssertTrue(undo.canUndo, "Native typing must have registered its own undo action")

        view.selectedRange = NSRange(location: (afterTyping as NSString).length, length: 0)
        let preview = try coordinator.preview(view,
            request: .init(sessionID: id, query: "文", replacement: "文章", scope: .document))
        XCTAssertEqual(preview.count, 20_000)
        XCTAssertTrue(preview.candidate.utf16.elementsEqual(expectedCandidate.utf16))
        let outcome = coordinator.apply(view,
            request: .init(sessionID: id, expectedText: afterTyping, text: preview.candidate, actionName: "一括置換"),
            selection: preview.selection)
        guard case .applied = outcome else { return XCTFail("Actual long native replacement rejected") }
        try await waitForAutomaticUndoGroup(undo)
        XCTAssertTrue(view.text.utf16.elementsEqual(expectedCandidate.utf16))
        XCTAssertEqual(view.selectedRange, preview.selection.nsRange)

        undo.undo()
        XCTAssertTrue(view.text.utf16.elementsEqual(afterTyping.utf16), "One undo must restore the complete pre-replacement text")
        XCTAssertTrue(undo.canUndo, "Bulk replacement must preserve the earlier native typing action")
        undo.undo()
        XCTAssertTrue(view.text.utf16.elementsEqual(beforeTyping.utf16), "The next undo must remove only the earlier typing")
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertTrue(view.text.utf16.elementsEqual(afterTyping.utf16))
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertTrue(view.text.utf16.elementsEqual(expectedCandidate.utf16), "Two redos must restore the entire replacement candidate")
        XCTAssertFalse(undo.canRedo)
    }

    func testRefusedNativeReplacePublishesActualTextAndRejectsAcceptance() {
        let id = UUID()
        var received: [EditorSnapshot] = []
        let surface = UIKitEditorSurface(configuration: .init(sessionID: id, initialText: "元の本文"),
            router: EditorCommandRouter(), onSnapshot: { received.append($0) })
        let coordinator = UIKitEditorSurface.Coordinator(parent: surface)
        let view = RefusingTextView()
        view.text = "元の本文"
        assertRejected(coordinator.apply(view,
            request: .init(sessionID: id, expectedText: "元の本文", text: "新しい本文", actionName: "テスト"),
            selection: .init(location: 0, length: 0)))
        XCTAssertEqual(received.last?.text, "元の本文")
        XCTAssertEqual(view.text, "元の本文")
    }

    private func waitForAutomaticUndoGroup(_ undo: UndoManager) async throws {
        // Yield through a run-loop turn, including when UIKit has a deferred close pending.
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if undo.groupingLevel == 0 { return }
        }
        throw NSError(domain: "EditorAdapterTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "UIKit did not close its automatic undo group"])
    }

    private func assertRejected(_ outcome: EditorMutationResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .rejected = outcome else { return XCTFail("Expected guard rejection", file: file, line: line) }
    }

    /// Reduced ceilings exercise the actual Swift + bundled JS planner; source only on Windows.
    func testInjectedAdmissionLimitsRejectWithoutChangingTheLiveText() throws {
        let view = UITextView()
        view.text = "aaaa"
        let request = EditorReplacementRequest(sessionID: UUID(), query: "a", replacement: "bb", scope: .document)
        var inputCap = ReplacementPlannerLimits(); inputCap.maxInputUTF16 = 3
        var outputCap = ReplacementPlannerLimits(); outputCap.maxOutputUTF16 = 7
        var countCap = ReplacementPlannerLimits(); countCap.maxMatches = 3
        for limits in [inputCap, outputCap, countCap] {
            let planner = try ReplacementPlanner(limits: limits)
            XCTAssertThrowsError(try planner.preview(text: view.text, selection: .init(location: 0, length: 0), request: request))
            XCTAssertEqual(view.text, "aaaa")
        }
        var memoryCap = ReplacementPlannerLimits(); memoryCap.memoryBudgetBytes = 9 * 1024 * 1024
        let planner = try ReplacementPlanner(limits: memoryCap)
        let long = String(repeating: "a", count: 10_000)
        XCTAssertThrowsError(try planner.preview(text: long, selection: .init(location: 0, length: 0), request: request))
        XCTAssertEqual(view.text, "aaaa")
    }

    func testJointWholeTextMemoryGuardRejectsBeforeNativeMutation() {
        let id = UUID(), original = String(repeating: "あ", count: 900_000)
        let candidate = String(repeating: "い", count: 900_000)
        let surface = UIKitEditorSurface(configuration: .init(sessionID: id, initialText: original),
            router: EditorCommandRouter(), onSnapshot: { _ in })
        let coordinator = UIKitEditorSurface.Coordinator(parent: surface)
        let view = UITextView()
        view.text = original
        let outcome = coordinator.apply(view,
            request: .init(sessionID: id, expectedText: original, text: candidate, actionName: "履歴の復元"),
            selection: .init(location: 0, length: 0))
        guard case .rejected(let reason) = outcome else { return XCTFail("Expected joint-memory admission rejection") }
        XCTAssertTrue(reason.contains("推定メモリ"), "This test must fail at admission, before needing a native undo manager")
        XCTAssertTrue(view.text.utf16.elementsEqual(original.utf16))
    }
}

@MainActor
private final class GuardTestTextView: UITextView {
    var syntheticMarkedRange: UITextRange?
    override var markedTextRange: UITextRange? { syntheticMarkedRange ?? super.markedTextRange }
}

@MainActor
private final class RefusingTextView: UITextView {
    private let testUndo = UndoManager()
    override var undoManager: UndoManager? { testUndo }
    override func replace(_ range: UITextRange, withText text: String) { /* Synthetic OS refusal. */ }
}

/// Exercise the real SwiftUI -> UITextView layout without touching any draft store.
@MainActor
private final class SaveLayoutProbe: ObservableObject {
    @Published var state: EditorScreenState
    init(state: EditorScreenState) { self.state = state }
}

@MainActor
private struct SaveLayoutHost: View {
    @ObservedObject var probe: SaveLayoutProbe
    let typeSize: DynamicTypeSize
    var body: some View {
        EditorScreen(state: probe.state, actions: EditorScreenActions(
            onSnapshot: { _ in }, onSave: { _ in }, onSaveAs: { _, _ in },
            onValidateSaveAsName: { _ in }, onOpenRecent: { _ in }, onOpenFiles: {}, onNew: {},
            onCancelSave: {}, onReload: { _ in }))
            .environment(\.dynamicTypeSize, typeSize)
    }
}

extension EditorAdapterTests {
    func testSaveAndCompositionUpdatesKeepEditorGeometrySelectionAndScroll() async throws {
        try await verifySaveLayout(width: 390, typeSize: .large)
    }

    func testSaveUpdatesKeepNarrowAccessibilityLayoutStable() async throws {
        try await verifySaveLayout(width: 320, typeSize: .accessibility1)
    }

    private func verifySaveLayout(width: CGFloat, typeSize: DynamicTypeSize) async throws {
        let session = UUID()
        let text = String(repeating: "日本語の入力と下書き保護を確認します。🍎\n", count: 100)
        func state(_ draft: DraftPresentation, _ cloud: CloudPresentation, busy: Bool = false,
                   composing: Bool = false, notice: String? = nil, status: String? = nil) -> EditorScreenState {
            EditorScreenState(configuration: .init(sessionID: session, initialText: text),
                fileName: "画面試験.txt", destinationSummary: "検証用保存先", currentRevision: 2,
                draftState: draft, cloudState: cloud, recents: [], isBusy: busy,
                modeLabel: "検証用の偽保存先・Google ドライブ未接続", notice: notice,
                isComposing: composing, autosaveStatus: status)
        }
        let initial = state(.protected(date: nil, revision: 2), .providerAccepted(date: nil, revision: 2))
        let probe = SaveLayoutProbe(state: initial)
        let host = UIHostingController(rootView: SaveLayoutHost(probe: probe, typeSize: typeSize))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func settle() async throws {
            try await Task.sleep(nanoseconds: 50_000_000)
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
        }
        func editor(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView, textView.accessibilityLabel == "本文" { return textView }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        try await settle()
        let view = try XCTUnwrap(editor(in: host.view))
        XCTAssertGreaterThan(view.bounds.height, 0)
        view.selectedRange = NSRange(location: 12, length: 0)
        view.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        try await settle()
        let frame = view.convert(view.bounds, to: window)
        let selection = view.selectedRange
        let offset = view.contentOffset
        let updates = [
            state(.protecting, .changesPending, composing: true, status: "日本語の変換確定を待っています"),
            state(.protecting, .writing, busy: true, status: "自動保存しています"),
            state(.protected(date: nil, revision: 1), .providerAccepted(date: nil, revision: 1),
                  status: "入力後の自動保存を待っています"),
            state(.failed("容量不足のテスト"), .failed("オフラインのテスト"),
                  notice: "下書きを保護できません。本文を残しています。", status: "自動保存を停止"),
            initial
        ]
        for update in updates {
            probe.state = update
            try await settle()
            XCTAssertTrue(editor(in: host.view) === view, "Status updates must retain the live editor")
            let actual = view.convert(view.bounds, to: window)
            XCTAssertEqual(actual.minY, frame.minY, accuracy: 0.5)
            XCTAssertEqual(actual.height, frame.height, accuracy: 0.5)
            XCTAssertEqual(actual.width, frame.width, accuracy: 0.5)
            XCTAssertEqual(view.selectedRange, selection)
            XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.5)
            XCTAssertTrue(view.text.utf16.elementsEqual(text.utf16))
        }
    }
}

@MainActor
private final class MutationCountingTextView: UITextView {
    var textWrites = 0
    var attributedWrites = 0
    var selectionWrites = 0
    var offsetWrites = 0
    var focusCalls = 0
    var fontWrites = 0
    override var text: String! { didSet { textWrites += 1 } }
    override var attributedText: NSAttributedString! { didSet { attributedWrites += 1 } }
    override var selectedRange: NSRange { didSet { selectionWrites += 1 } }
    override var contentOffset: CGPoint { didSet { offsetWrites += 1 } }
    override var font: UIFont? { didSet { fontWrites += 1 } }
    override func becomeFirstResponder() -> Bool { focusCalls += 1; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { focusCalls += 1; return super.resignFirstResponder() }
    func resetWrites() {
        textWrites = 0; attributedWrites = 0; selectionWrites = 0
        offsetWrites = 0; focusCalls = 0; fontWrites = 0
    }
}

@MainActor
private struct NativeSaveUpdateHost: View {
    @ObservedObject var probe: SaveLayoutProbe
    let router: EditorCommandRouter
    let factory: @MainActor () -> UITextView
    var body: some View {
        UIKitEditorSurface(configuration: probe.state.configuration, router: router,
                           onSnapshot: { _ in }, makeTextView: factory)
            .id(probe.state.configuration.sessionID)
    }
}

extension EditorAdapterTests {
    private func quietState() -> EditorScreenState {
        EditorScreenState(configuration: .init(sessionID: UUID(), initialText: "日本語の本文🍎\n"),
            fileName: "テスト.txt", destinationSummary: "偽保存先", currentRevision: 2,
            draftState: .protecting, cloudState: .writing, recents: [], isBusy: true, modeLabel: "検証用")
    }

    func testNormalSaveLabelsStayQuietButProblemsRemainVisible() {
        var state = quietState()
        let normalDraft = state.quietDraftLabel, normalFile = state.quietFileLabel
        for draft in [DraftPresentation.protecting, .protected(date: nil, revision: 1), .protected(date: Date(), revision: 2)] {
            for cloud in [CloudPresentation.changesPending, .writing, .providerAccepted(date: nil, revision: 1), .providerAccepted(date: Date(), revision: 2)] {
                state = EditorScreenState(configuration: state.configuration, fileName: state.fileName,
                    destinationSummary: state.destinationSummary, currentRevision: 2, draftState: draft,
                    cloudState: cloud, recents: [], isBusy: false, modeLabel: "検証用")
                XCTAssertEqual(state.quietDraftLabel, normalDraft)
                XCTAssertEqual(state.quietFileLabel, normalFile)
            }
        }
        state.isOutcomeUncertain = true
        XCTAssertTrue(state.quietFileLabel.contains("不明"))
        state.isOutcomeUncertain = false
        state.remoteIssue = "権限の確認が必要"
        XCTAssertEqual(state.quietFileLabel, "保存先からのお知らせ・詳細を確認")
        let failed = EditorScreenState(configuration: state.configuration, fileName: state.fileName,
            destinationSummary: state.destinationSummary, currentRevision: 2, draftState: .failed("容量不足"),
            cloudState: .failed("書込失敗"), recents: [], isBusy: false, modeLabel: "検証用")
        XCTAssertTrue(failed.quietDraftLabel.contains("できません"))
        XCTAssertTrue(failed.quietFileLabel.contains("失敗"))
    }

    func testSaveOnlyUpdatesDoNotRecreateOrRewriteNativeEditor() async throws {
        let probe = SaveLayoutProbe(state: quietState())
        var creations = 0
        let view = MutationCountingTextView()
        let router = EditorCommandRouter()
        let host = UIHostingController(rootView: NativeSaveUpdateHost(probe: probe, router: router, factory: {
            creations += 1
            return view
        }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(creations, 1)
        view.selectedRange = NSRange(location: 3, length: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        let originalText = view.text!, selection = view.selectedRange, offset = view.contentOffset
        let wasFocused = view.isFirstResponder
        view.resetWrites()
        for index in 0..<8 {
            let old = probe.state
            probe.state = EditorScreenState(configuration: old.configuration, fileName: old.fileName,
                destinationSummary: old.destinationSummary, currentRevision: old.currentRevision,
                draftState: index.isMultiple(of: 2) ? .protecting : .protected(date: Date(), revision: 2),
                cloudState: index.isMultiple(of: 2) ? .writing : .providerAccepted(date: Date(), revision: 2),
                recents: [], isBusy: index.isMultiple(of: 2), modeLabel: "検証用")
            try await Task.sleep(nanoseconds: 50_000_000)
            window.layoutIfNeeded()
        }
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(view.textWrites, 0)
        XCTAssertEqual(view.attributedWrites, 0)
        XCTAssertEqual(view.selectionWrites, 0)
        XCTAssertEqual(view.offsetWrites, 0)
        XCTAssertEqual(view.focusCalls, 0)
        XCTAssertEqual(view.fontWrites, 0)
        XCTAssertEqual(view.text, originalText)
        XCTAssertEqual(view.selectedRange, selection)
        XCTAssertEqual(view.contentOffset, offset)
        XCTAssertEqual(view.isFirstResponder, wasFocused)
    }
}

extension EditorAdapterTests {
    func testSaveIconRemainsIdenticalDuringAutosaveAndIgnoresBusyTaps() throws {
        let session = UUID()
        var calls = 0
        func state(_ busy: Bool, _ cloud: CloudPresentation) -> EditorScreenState {
            EditorScreenState(configuration: .init(sessionID: session, initialText: "本文"),
                fileName: "本文.txt", destinationSummary: "検証用", currentRevision: 2,
                draftState: .protecting, cloudState: cloud, recents: [], isBusy: busy, modeLabel: "検証")
        }
        func pixels(_ button: SaveIconButton) throws -> Data {
            let renderer = ImageRenderer(content: button.environment(\.colorScheme, .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThanOrEqual(image.size.width, 44)
            XCTAssertGreaterThanOrEqual(image.size.height, 44)
            return try XCTUnwrap(image.pngData())
        }
        let idle = SaveIconButton(state: state(false, .changesPending), action: { calls += 1 })
        let expected = try pixels(idle)
        for cloud: CloudPresentation in [.changesPending, .writing, .providerAccepted(date: nil, revision: 1)] {
            let busy = SaveIconButton(state: state(true, cloud), action: { calls += 1 })
            XCTAssertFalse(busy.isBlocked)
            XCTAssertEqual(try pixels(busy), expected)
            for _ in 0..<8 { busy.activate() }
        }
        XCTAssertEqual(calls, 0)
        idle.activate()
        XCTAssertEqual(calls, 1)
    }

    func testSaveIconKeepsPersistentGuardsAndInitialDestinationAction() {
        var state = EditorScreenState(configuration: .init(sessionID: UUID(), initialText: "本文"),
            fileName: "", destinationSummary: "未設定", currentRevision: 1,
            draftState: .protecting, cloudState: .noDestination, recents: [], isBusy: false, modeLabel: "検証")
        var calls = 0
        let initial = SaveIconButton(state: state, action: { calls += 1 })
        XCTAssertFalse(initial.isBlocked)
        initial.activate()
        XCTAssertEqual(calls, 1)
        state.isComposing = true
        SaveIconButton(state: state, action: { calls += 1 }).activate()
        state.isComposing = false
        SaveIconButton(state: state, isComposing: true, action: { calls += 1 }).activate()
        state.isOutcomeUncertain = true
        let uncertain = SaveIconButton(state: state, action: { calls += 1 })
        XCTAssertTrue(uncertain.isBlocked)
        uncertain.activate()
        state.isOutcomeUncertain = false
        state.isEditorLocked = true
        let locked = SaveIconButton(state: state, action: { calls += 1 })
        XCTAssertTrue(locked.isBlocked)
        locked.activate()
        let conflict = EditorScreenState(configuration: state.configuration,
            fileName: "本文.txt", destinationSummary: "検証用", currentRevision: 1,
            draftState: .protecting, cloudState: .conflict, recents: [], isBusy: false, modeLabel: "検証")
        let blocked = SaveIconButton(state: conflict, action: { calls += 1 })
        XCTAssertTrue(blocked.isBlocked)
        blocked.activate()
        XCTAssertEqual(calls, 1)
    }
}


extension EditorAdapterTests {
    func testReloadIconStaysStableAndPreservesActionGuards() throws {
        let session = UUID()
        var calls = 0
        func state(_ busy: Bool, _ cloud: CloudPresentation) -> EditorScreenState {
            EditorScreenState(configuration: .init(sessionID: session, initialText: "未保存本文"),
                fileName: "本文.txt", destinationSummary: "検証用", currentRevision: 2,
                draftState: .protecting, cloudState: cloud, recents: [], isBusy: busy, modeLabel: "検証")
        }
        func pixels(_ button: ReloadIconButton) throws -> Data {
            let renderer = ImageRenderer(content: button.environment(\.colorScheme, .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThanOrEqual(image.size.width, 44)
            XCTAssertGreaterThanOrEqual(image.size.height, 44)
            return try XCTUnwrap(image.pngData())
        }
        let idle = ReloadIconButton(state: state(false, .changesPending), action: { calls += 1 })
        let expected = try pixels(idle)
        for cloud: CloudPresentation in [.changesPending, .writing, .providerAccepted(date: nil, revision: 1)] {
            let busy = ReloadIconButton(state: state(true, cloud), action: { calls += 1 })
            XCTAssertFalse(busy.isBlocked)
            XCTAssertEqual(try pixels(busy), expected)
            for _ in 0..<8 { busy.activate() }
        }
        var restricted = state(false, .changesPending)
        restricted.isComposing = true
        ReloadIconButton(state: restricted, action: { calls += 1 }).activate()
        restricted.isComposing = false
        ReloadIconButton(state: restricted, isComposing: true, action: { calls += 1 }).activate()
        restricted.isEditorLocked = true
        let locked = ReloadIconButton(state: restricted, action: { calls += 1 })
        XCTAssertTrue(locked.isBlocked)
        locked.activate()
        let missing = ReloadIconButton(state: state(false, .noDestination), action: { calls += 1 })
        XCTAssertTrue(missing.isBlocked)
        missing.activate()
        XCTAssertEqual(calls, 0)
        idle.activate()
        XCTAssertEqual(calls, 1)
        // Existing reload remains available to inspect a conflict/uncertain outcome.
        var review = state(false, .conflict)
        review.isOutcomeUncertain = true
        let recovery = ReloadIconButton(state: review, action: { calls += 1 })
        XCTAssertFalse(recovery.isBlocked)
        recovery.activate()
        XCTAssertEqual(calls, 2)
    }
}
