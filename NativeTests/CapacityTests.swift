import XCTest
@testable import IyoEditor

/// Authored on Windows; requires the Mac/iOS runner and bundled CapacityPolicy.js. NOT executed here.
final class CapacityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IyoCapacityTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func cleanup(_ directory: URL) {
        guard directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("IyoCapacityTests-") else { return }
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: directory)
    }
    private func envelope(_ id: UUID, text: String, revision: Int = 0, epoch: Int = 1) -> CoreEnvelope {
        CoreEnvelope(id: id, name: "容量検証.txt", text: text, format: "utf8", revision: revision,
                     epoch: epoch, target: nil, acceptedRevision: nil)
    }

    func testSharedJavaScriptCountsReplacementPeakAndDiskReserve() throws {
        let bridge = try CapacityPolicyBridge()
        let policy = DraftCapacityConfiguration(budgetBytes: 100, maxIncomingBytes: 100, reserveBytes: 5)
        let peak = try bridge.plan(incomingBytes: 60, previousBytes: 40, existingBytes: 80, availableBytes: 1000, configuration: policy)
        XCTAssertFalse(peak.allowed); XCTAssertEqual(peak.reason, "budgetPeak")
        XCTAssertEqual(peak.finalBytes, 100); XCTAssertEqual(peak.replacementPeakBytes, 140)
        let unknown = try bridge.plan(incomingBytes: 10, previousBytes: 0, existingBytes: 0, availableBytes: nil, configuration: policy)
        XCTAssertFalse(unknown.allowed); XCTAssertEqual(unknown.reason, "availableUnknown")
        let reserve = try bridge.plan(incomingBytes: 10, previousBytes: 0, existingBytes: 0, availableBytes: 14, configuration: policy)
        XCTAssertFalse(reserve.allowed); XCTAssertEqual(reserve.reason, "diskReserve")
    }

    func testDeniedReplacementKeepsExistingJSONAndOtherDocumentByteExact() async throws {
        let root = try temporaryDirectory(); defer { cleanup(root) }
        let id = UUID(), otherID = UUID(), original = envelope(id, text: "か\u{3099}\r\n👨‍👩‍👧‍👦")
        let source = try JSONEncoder().encode(original)
        let file = root.appendingPathComponent(id.uuidString + ".json")
        let other = root.appendingPathComponent(otherID.uuidString + ".json")
        try source.write(to: file); let otherBytes = Data("他の安全記録".utf8); try otherBytes.write(to: other)
        let limited = DraftCapacityConfiguration(budgetBytes: source.count + otherBytes.count, maxIncomingBytes: 100_000, reserveBytes: 0)
        let store = try DraftStore(directory: root, capacity: limited, availableBytes: { _ in 1_000_000 })
        do { try await store.persist(envelope(id, text: "追記", revision: 1, epoch: 2)); XCTFail("Old + temporary must exceed budget") }
        catch { XCTAssertTrue(error is DraftCapacityError) }
        XCTAssertEqual(try Data(contentsOf: file), source); XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        let status = try await store.capacityStatus()
        XCTAssertEqual(status.usedBytes, source.count + otherBytes.count); XCTAssertEqual(status.remainingBytes, 0)
    }

    func testInjectedPreCommitFailuresPreserveRawOriginalAcrossRestart() async throws {
        let root = try temporaryDirectory(); defer { cleanup(root) }
        let id = UUID(), original = envelope(id, text: "か\u{3099}\r\n😀\n")
        let store = try DraftStore(directory: root, capacity: .init(reserveBytes: 0), availableBytes: { _ in 1_000_000_000 })
        try await store.persist(original)
        let file = root.appendingPathComponent(id.uuidString + ".json"), source = try Data(contentsOf: file)
        for failure in [DraftStore.WriteFailureInjection.beforeAtomicWrite, .afterTemporaryWrite] {
            await store.injectNextWriteFailureForTesting(failure)
            do { try await store.persist(envelope(id, text: "変更後", revision: 1, epoch: 2)); XCTFail("Injected write must fail") }
            catch { XCTAssertTrue(error is DraftCapacityError) }
            XCTAssertEqual(try Data(contentsOf: file), source)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 1)
        }
        let reopened = try DraftStore(directory: root, availableBytes: { _ in 1_000_000_000 })
        let loaded = try await reopened.loadEnvelope(id)
        XCTAssertTrue(loaded.text.utf16.elementsEqual(original.text.utf16))
    }

    func testUnknownDiskAvailabilityFailsClosedAndDoesNotMigrateLegacyBytes() async throws {
        let root = try temporaryDirectory(); defer { cleanup(root) }
        let id = UUID(), legacy = DraftRecord(id: id, name: "旧下書き.txt", text: "原本\r\nか\u{3099}", format: .utf8,
                                             revision: 0, updatedAt: Date(timeIntervalSince1970: 0), remote: nil)
        let file = root.appendingPathComponent(id.uuidString + ".json"), source = try JSONEncoder().encode(legacy)
        try source.write(to: file)
        let store = try DraftStore(directory: root, availableBytes: { _ in nil })
        let loaded = try await store.loadEnvelope(id)
        XCTAssertTrue(loaded.text.utf16.elementsEqual(legacy.text.utf16))
        do { try await store.persist(envelope(id, text: "新しい下書き", revision: 1, epoch: 2)); XCTFail("Unknown free capacity must fail closed") }
        catch { XCTAssertTrue(error is DraftCapacityError) }
        XCTAssertEqual(try Data(contentsOf: file), source)
        let status = try await store.capacityStatus()
        XCTAssertEqual(status.status, "availableUnknown")
    }

    func testCapacityUsesEncodedWholeEnvelopeIncludingHistoryAndJSONEscapes() async throws {
        let root = try temporaryDirectory(); defer { cleanup(root) }
        let id = UUID(), text = String(repeating: "\"\\\nか\u{3099}", count: 40)
        var input = envelope(id, text: text)
        let remote = "外部\r\nか\u{3099}", target = CoreTarget(identity: UUID().uuidString, name: "履歴.txt", location: "検証用",
            baseline: .make(try TextFileFormat.utf8.encode(remote)), baseText: remote, format: "utf8", lineEnding: "preserve")
        input.retainedEvidence = [CoreRemoteCandidate(token: "serialized-history", text: remote, format: "utf8", target: target,
            observedRevision: 0, snapshotRevision: 0, localText: "端末\n😀", baseText: "基準\r\n")]
        let serialized = try JSONEncoder().encode(input)
        XCTAssertGreaterThan(serialized.count, text.utf8.count)
        let store = try DraftStore(directory: root,
            capacity: .init(budgetBytes: 100_000, maxIncomingBytes: text.utf8.count, reserveBytes: 0), availableBytes: { _ in 1_000_000 })
        do { try await store.persist(input); XCTFail("Whole JSON record exceeds text-only allowance") }
        catch { XCTAssertTrue(error is DraftCapacityError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }
}
