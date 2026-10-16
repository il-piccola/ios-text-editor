import XCTest
@testable import IyoEditor

/// Mac/iOS only: exercises JavaScriptCore and the actual Swift JSON boundary.
/// These tests have NOT been compiled or run in the Windows environment.
@MainActor
final class CoreBridgeTests: XCTestCase {
    func testExplicitNullsSurviveSwiftEnvelopeAndJavaScriptRestore() throws {
        let envelope = CoreEnvelope(id: UUID(), name: "本文.txt", text: "が\r\n👨‍👩‍👧‍👦", format: "utf8",
                                    revision: 2, epoch: 5, target: nil, acceptedRevision: nil)
        let dictionary = try SessionCoreBridge.dictionary(envelope)
        XCTAssertTrue(dictionary["target"] is NSNull)
        XCTAssertTrue(dictionary["acceptedRevision"] is NSNull)
        let bridge = try SessionCoreBridge()
        var restored = try bridge.invoke("restore", dictionary)
        XCTAssertTrue(restored["sessionID"] is NSNull)
        restored["sessionID"] = UUID().uuidString
        let decoded = try SessionCoreBridge.decode(CoreStateCodable.self, from: restored)
        XCTAssertEqual(decoded.protectedRevision, 2)
        XCTAssertNil(decoded.acceptedRevision)
        XCTAssertNil(decoded.operation)
        XCTAssertEqual(Array(decoded.text.unicodeScalars), Array(envelope.text.unicodeScalars))
    }

    func testSaveEffectEnvelopeDecodesWithoutInventingCloudSuccess() throws {
        let bridge = try SessionCoreBridge()
        let state = try bridge.invoke("create", ["id": UUID().uuidString, "sessionID": UUID().uuidString,
                                                  "text": "保存する本文"])
        let result = try bridge.invoke("reduce", ["state": state,
                                                   "event": ["type": "SAVE_AS", "token": UUID().uuidString, "name": "本文.txt"]])
        let updated = try XCTUnwrap(result["state"] as? [String: Any])
        let decoded = try SessionCoreBridge.decode(CoreStateCodable.self, from: updated)
        XCTAssertEqual(decoded.operation?.phase, "protecting")
        XCTAssertNil(decoded.acceptedRevision)
        XCTAssertEqual(decoded.cloudStatus, "unconfirmed")
        let effects = try XCTUnwrap(result["effects"] as? [[String: Any]])
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?["type"] as? String, "PERSIST")
        let persisted = try XCTUnwrap(effects.first?["envelope"] as? [String: Any])
        let envelope = try SessionCoreBridge.decode(CoreEnvelope.self, from: persisted)
        try envelope.validate()
        XCTAssertEqual(envelope.text, "保存する本文")
        XCTAssertNil(envelope.acceptedRevision)
    }

    func testPendingNewFileWriteSurvivesSwiftEncodingAsUncertain() throws {
        let bridge = try SessionCoreBridge()
        let state = try bridge.invoke("create", ["id": UUID().uuidString, "sessionID": UUID().uuidString,
                                                  "text": "再起動前の本文"])
        let result = try bridge.invoke("reduce", ["state": state,
            "event": ["type": "SAVE_AS", "token": UUID().uuidString, "name": "復元.txt"]])
        let effects = try XCTUnwrap(result["effects"] as? [[String: Any]])
        let raw = try XCTUnwrap(effects.first?["envelope"] as? [String: Any])
        let envelope = try SessionCoreBridge.decode(CoreEnvelope.self, from: raw)
        try envelope.validate()
        let encoded = try SessionCoreBridge.dictionary(envelope)
        let intent = try XCTUnwrap(encoded["pendingWrite"] as? [String: Any])
        let snapshot = try XCTUnwrap(intent["snapshot"] as? [String: Any])
        XCTAssertTrue(snapshot["target"] is NSNull)
        let restored = try bridge.invoke("restore", encoded)
        XCTAssertEqual(restored["uncertain"] as? Bool, true)
        XCTAssertNotNil(restored["unknownOperation"] as? [String: Any])
        XCTAssertTrue(restored["operation"] is NSNull)
        XCTAssertEqual(restored["text"] as? String, "再起動前の本文")
    }

    func testRetainedComparisonHistoryPreservesAllThreeRawTextsAcrossRestoreAndPersist() throws {
        let base = "基準-か\u{3099}\r\n😀\n"
        let local = "端末-が\n👩‍💻\r\n"
        let remote = "外部-か\u{3099}\r\n🇯🇵\n"
        let historicTarget = CoreTarget(identity: UUID().uuidString, name: "過去の保存先.txt", location: "検証用",
                                        baseline: .make(try TextFileFormat.utf8.encode(remote)),
                                        baseText: remote, format: "utf8", lineEnding: "preserve")
        let history = CoreRemoteCandidate(token: "previous-comparison", text: remote, format: "utf8", target: historicTarget,
                                         observedRevision: 2, snapshotRevision: 1, localText: local, baseText: base)
        var envelope = CoreEnvelope(id: UUID(), name: "現在の下書き.txt", text: "現在の本文", format: "utf8",
                                    revision: 3, epoch: 7, target: nil, acceptedRevision: nil)
        envelope.retainedEvidence = [history] // Historical target intentionally differs from the current destination.
        try envelope.validate()
        let encoded = try SessionCoreBridge.dictionary(envelope)
        let nativeRoundTrip = try SessionCoreBridge.decode(CoreEnvelope.self, from: encoded)
        XCTAssertEqual(nativeRoundTrip.retainedEvidence.count, 1)
        let bridge = try SessionCoreBridge()
        var restored = try bridge.invoke("restore", encoded)
        restored["sessionID"] = UUID().uuidString
        let result = try bridge.invoke("reduce", ["state": restored, "event": ["type": "PROTECT", "token": UUID().uuidString]])
        let effects = try XCTUnwrap(result["effects"] as? [[String: Any]])
        let persisted = try XCTUnwrap(effects.first?["envelope"] as? [String: Any])
        let preserved = try SessionCoreBridge.decode(CoreEnvelope.self, from: persisted)
        try preserved.validate()
        let evidence = try XCTUnwrap(preserved.retainedEvidence.first)
        XCTAssertEqual(Array((evidence.baseText ?? "").utf16), Array(base.utf16))
        XCTAssertEqual(Array(evidence.localText.utf16), Array(local.utf16))
        XCTAssertEqual(Array(evidence.text.utf16), Array(remote.utf16))
        XCTAssertEqual(evidence.target.identity, historicTarget.identity)
        let reencoded = try SessionCoreBridge.dictionary(preserved)
        XCTAssertEqual((reencoded["retainedEvidence"] as? [[String: Any]])?.count, 1)
    }

    func testMalformedCurrentEvidenceIsReportedByDraftScanWithoutChangingRawFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IyoCurrentEvidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = "原文\r\nか\u{3099}", id = UUID()
        let target = CoreTarget(identity: UUID().uuidString, name: "原本.txt", location: "検証用",
            baseline: .make(try TextFileFormat.utf8.encode(remote)), baseText: remote, format: "utf8", lineEnding: "preserve")
        var envelope = CoreEnvelope(id: id, name: target.name, text: "端末本文", format: "utf8",
                                    revision: 3, epoch: 5, target: target, acceptedRevision: 0)
        envelope.remoteCandidate = CoreRemoteCandidate(token: "candidate", text: remote, format: "utf8", target: target,
            observedRevision: 2, snapshotRevision: 1, localText: "端末本文", baseText: "基準")
        try envelope.validate()
        let raw = try SessionCoreBridge.dictionary(envelope)
        let original = try XCTUnwrap(raw["remoteCandidate"] as? [String: Any])
        var invalid = [original, original, original, original]
        invalid[0]["text"] = "指紋に一致しない原文"
        invalid[1]["token"] = ""
        invalid[2]["snapshotRevision"] = 3
        var mismatchedTarget = try XCTUnwrap(original["target"] as? [String: Any])
        mismatchedTarget["baseText"] = "別の原文"
        invalid[3]["target"] = mismatchedTarget
        let file = root.appendingPathComponent(id.uuidString + ".json")
        let store = try DraftStore(directory: root)
        for candidate in invalid {
            var malformed = raw; malformed["remoteCandidate"] = candidate
            let bytes = try JSONSerialization.data(withJSONObject: malformed)
            try bytes.write(to: file)
            let result = try await store.scan()
            XCTAssertTrue(result.records.isEmpty)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
}
