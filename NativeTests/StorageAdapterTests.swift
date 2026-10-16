import XCTest
@testable import IyoEditor

/// Written for the Mac/iOS test runner. These tests have NOT run on Windows.
final class StorageAdapterTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IyoAdapterTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDraftRestartRejectsStaleAndEqualEpochDifferentContents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = try DraftStore(directory: root)
        let original = CoreEnvelope(id: id, name: "本文.txt", text: "が\r\n👨‍👩‍👧‍👦", format: "utf8",
                                    revision: 2, epoch: 5, target: nil, acceptedRevision: nil)
        try await store.persist(original)
        try await store.persist(original) // Idempotent receipt.
        let different = CoreEnvelope(id: id, name: "本文.txt", text: "別の内容", format: "utf8",
                                     revision: 2, epoch: 5, target: nil, acceptedRevision: nil)
        do {
            try await store.persist(different)
            XCTFail("Equal epoch must not overwrite different contents")
        } catch { XCTAssertTrue(error is StorageError) }
        let stale = CoreEnvelope(id: id, name: "本文.txt", text: "古い内容", format: "utf8",
                                 revision: 1, epoch: 4, target: nil, acceptedRevision: nil)
        do {
            try await store.persist(stale)
            XCTFail("Stale draft must not overwrite newer contents")
        } catch { XCTAssertTrue(error is StorageError) }
        let reopened = try DraftStore(directory: root)
        let loaded = try await reopened.loadEnvelope(id)
        XCTAssertEqual(loaded, original)
    }

    func testBOMUnicodeAndLineEndingsRoundTripWithoutNormalization() throws {
        let text = "が é 𠮷 👨‍👩‍👧‍👦 👍🏽 🇯🇵\r\n次の行\n最終改行なし"
        for format in [TextFileFormat.utf8, .utf8BOM, .utf16LE, .utf16BE] {
            let encoded = try format.encode(text)
            let (decoded, detected) = try TextFileFormat.decode(encoded)
            XCTAssertEqual(detected, format)
            // Compare scalar sequences; Swift String equality is canonically equivalent.
            XCTAssertEqual(Array(decoded.unicodeScalars), Array(text.unicodeScalars))
            XCTAssertEqual(try detected.encode(decoded), encoded)
        }
        XCTAssertThrowsError(try TextFileFormat.decode(Data([0x80, 0xFF])))
    }

    func testCanonicallyEquivalentRawTextCannotOverwriteTheSameEpoch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = try DraftStore(directory: root)
        let decomposed = CoreEnvelope(id: id, name: "本文.txt", text: "か\u{3099}", format: "utf8",
                                      revision: 1, epoch: 2, target: nil, acceptedRevision: nil)
        let composed = CoreEnvelope(id: id, name: "本文.txt", text: "が", format: "utf8",
                                    revision: 1, epoch: 2, target: nil, acceptedRevision: nil)
        try await store.persist(decomposed)
        do {
            try await store.persist(composed)
            XCTFail("Swift canonical String equality must not hide different original bytes")
        } catch { XCTAssertTrue(error is StorageError) }
        let preserved = try await store.loadEnvelope(id)
        XCTAssertEqual(Array(preserved.text.utf16), Array(decomposed.text.utf16))
    }

    func testMalformedUTF8AndBOMUTF16AreRejectedRatherThanRepaired() throws {
        let malformed: [[UInt8]] = [
            [0xC0, 0xAF],                         // Overlong UTF-8.
            [0xF0, 0x9F, 0x98],                   // Truncated UTF-8 scalar.
            [0xEF, 0xBB, 0xBF, 0xED, 0xA0, 0x80], // UTF-8 encoding of a surrogate.
            [0xFF, 0xFE, 0x00, 0xD8],             // Lone LE high surrogate.
            [0xFF, 0xFE, 0x00, 0xDC],             // Lone LE low surrogate.
            [0xFE, 0xFF, 0xD8, 0x00],             // Lone BE high surrogate.
            [0xFE, 0xFF, 0xDC, 0x00],             // Lone BE low surrogate.
            [0xFF, 0xFE, 0x61], [0xFE, 0xFF, 0x00] // Odd UTF-16 byte count.
        ]
        for bytes in malformed { XCTAssertThrowsError(try TextFileFormat.decode(Data(bytes)), "Invalid bytes: \(bytes)") }
        // An intentionally encoded replacement character is valid, distinct from an implicit repair.
        for format in [TextFileFormat.utf8, .utf8BOM, .utf16LE, .utf16BE] {
            let original = try format.encode("\u{FFFD}\r\n")
            let (text, detected) = try TextFileFormat.decode(original)
            XCTAssertEqual(try detected.encode(text), original)
        }
    }

    func testFakeConflictKeepsExternalOriginalAndLocalSnapshotSeparate() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try FakeFileProvider(directory: root)
        let sample = try await provider.sample()
        let snapshot = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: sample.target.name,
                                         text: "端末の編集", format: sample.format, revision: 3, target: sample.target)
        await provider.setScenario(.conflict)
        do {
            _ = try await provider.write(kind: "existing", snapshot: snapshot, name: nil)
            XCTFail("External modification must reject stale write")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.code, "conflict")
        }
        let restarted = try FakeFileProvider(directory: root)
        let external = try await restarted.sample()
        XCTAssertTrue(external.text.contains("別端末"))
        XCTAssertFalse(external.text.contains(snapshot.text))
        XCTAssertEqual(snapshot.text, "端末の編集")
        XCTAssertEqual(external.target.identity, sample.target.identity)
        XCTAssertNotEqual(external.target.baseline, sample.target.baseline)
    }

    func testFakeNameCollisionDoesNotReplaceOrCreateAnotherFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try FakeFileProvider(directory: root)
        let sample = try await provider.sample()
        let snapshot = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: sample.target.name,
                                         text: "上書きしてはいけない", format: "utf8", revision: 1, target: nil)
        do {
            _ = try await provider.write(kind: "saveAs", snapshot: snapshot, name: sample.target.name)
            XCTFail("Name collision must require a different user-selected name")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.code, "nameCollision")
        }
        let after = try await provider.sample()
        XCTAssertEqual(after.text, sample.text)
        XCTAssertEqual(after.target, sample.target)
    }

    func testOfflineReadAndWriteRetainProtectedDraftAndRemoteOriginal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try FakeFileProvider(directory: root.appendingPathComponent("provider"))
        let drafts = try DraftStore(directory: root.appendingPathComponent("drafts"))
        let sample = try await provider.sample()
        let id = UUID()
        let local = "未反映の日本語下書き\r\n"
        let envelope = CoreEnvelope(id: id, name: sample.target.name, text: local, format: sample.format,
                                    revision: 1, epoch: 1, target: sample.target, acceptedRevision: 0)
        try await drafts.persist(envelope)
        let snapshot = CoreWriteSnapshot(id: id, sessionID: UUID(), name: sample.target.name,
                                         text: local, format: sample.format, revision: 1, target: sample.target)
        await provider.setScenario(.offline)
        do { _ = try await provider.read(identity: sample.target.identity); XCTFail("Offline read must fail") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "offline") }
        do { _ = try await provider.write(kind: "existing", snapshot: snapshot, name: nil); XCTFail("Offline write must fail") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "offline") }
        let reopenedDrafts = try DraftStore(directory: root.appendingPathComponent("drafts"))
        let retained = try await reopenedDrafts.loadEnvelope(id)
        XCTAssertEqual(Array(retained.text.utf16), Array(local.utf16))
        await provider.setScenario(.normal)
        let original = try await provider.read(identity: sample.target.identity)
        XCTAssertEqual(original.baseline, sample.target.baseline)
        XCTAssertEqual(Array((original.baseText ?? "").utf16), Array(sample.text.utf16))
    }

    func testSaveNamePreservesRawWhitespaceAndNFDWhileCollisionRemainsCanonical() async throws {
        let raw = " か\u{3099}.txt "
        XCTAssertEqual(Array(try SaveName.validate(raw).utf16), Array(raw.utf16))
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = try FakeFileProvider(directory: root)
        let nfdName = "か\u{3099}.txt"
        let first = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: nfdName,
                                      text: "原文", format: "utf8", revision: 0, target: nil)
        let receipt = try await provider.write(kind: "saveAs", snapshot: first, name: nfdName)
        XCTAssertEqual(Array(receipt.name.utf16), Array(nfdName.utf16))
        let available = try await provider.nameIsAvailable("が.txt")
        XCTAssertFalse(available)
        let second = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: "が.txt",
                                       text: "上書き禁止", format: "utf8", revision: 0, target: nil)
        do { _ = try await provider.write(kind: "saveAs", snapshot: second, name: "が.txt"); XCTFail("Canonical collision must be rejected") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "nameCollision") }
        let preserved = try await provider.read(identity: receipt.identity)
        XCTAssertEqual(preserved.baseline, receipt.baseline)
    }

    func testInvalidLegacyDraftIsReportedWithoutHidingHealthyEntries() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DraftStore(directory: root)
        let validID = UUID()
        try await store.persist(CoreEnvelope(id: validID, name: "正常.txt", text: "保存した下書き", format: "utf8",
                                            revision: 1, epoch: 1, target: nil, acceptedRevision: nil))
        for badValue in [(-1, 0), (0, -1)] {
            let invalid = DraftRecord(id: UUID(), name: "不正な旧草稿.txt", text: "削除しない原文",
                                      revision: badValue.0, epoch: badValue.1)
            let fixture = root.appendingPathComponent(invalid.id.uuidString).appendingPathExtension("json")
            try JSONEncoder().encode(invalid).write(to: fixture, options: .atomic)
        }
        let result = try await store.scan()
        XCTAssertEqual(result.records.map(\.id), [validID])
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 3)
    }
}
