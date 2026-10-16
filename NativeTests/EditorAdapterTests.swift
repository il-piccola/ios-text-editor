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

    func testRealUITextInputReplaceAndUndoRedoAreOneOperation() throws {
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
        // End the test event's outer automatic group, if one is still open.
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
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
    func testTwentyThousandReplacementsPreserveEarlierNativeTypingUndoAndRedo() throws {
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
        // Close the test event's outer automatic group so bulk replacement is a separate action.
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
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
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
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
