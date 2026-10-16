import XCTest
@testable import IyoEditor

/// Source only. No Files UI, account, Google login, network, or provider upload is exercised here.
/// All tests require the future Mac/iOS runner and have NOT been compiled or run on Windows.
final class FilesAdapterTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IyoFilesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDisabledRouteCannotReadOrRegisterPickedURL() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: file)
        let adapter = try FilesProviderAdapter(directory: root.appendingPathComponent("registry"), testLocalRoot: root)
        do { _ = try await adapter.registerPickedURL(file); XCTFail("Default route must remain disabled") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "unavailable") }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testDisabledInitializationDoesNotDecodeOrModifyCorruptRegistry() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("bookmarks.json")
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: registryURL)
        let adapter = try FilesProviderAdapter(directory: root, enabled: false, testLocalRoot: root)
        let identity = UUID().uuidString
        let ownsIdentity = await adapter.owns(identity: identity)
        XCTAssertFalse(ownsIdentity)
        do { _ = try await adapter.read(identity: identity); XCTFail("Disabled read must reject") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "unavailable") }
        do { _ = try await adapter.find(name: "sample.txt"); XCTFail("Disabled lookup must reject") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "unavailable") }
        let snapshot = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: "sample.txt", text: "draft",
                                         format: "utf8", revision: 1, target: nil)
        do { _ = try await adapter.write(kind: "saveAs", snapshot: snapshot, name: "sample.txt"); XCTFail("Disabled write must reject") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "unavailable") }
        do { _ = try await adapter.registerPickedURL(root.appendingPathComponent("sample.txt")); XCTFail("Disabled picker route must reject") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "unavailable") }
        do { try await adapter.beginObserving(identity: identity, onChange: { _ in }); XCTFail("Disabled observation must reject") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "unavailable") }
        await adapter.shutdownObservers()
        XCTAssertEqual(try Data(contentsOf: registryURL), corrupt)
        XCTAssertThrowsError(try FilesProviderAdapter(directory: root, enabled: true, testLocalRoot: root))
    }

    func testDisabledInitializationDoesNotCreateRegistryDirectory() throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("uncreated-registry", isDirectory: true)
        _ = try FilesProviderAdapter(directory: absent, enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testPickedLocalFileIsReadWithoutNewlineOrUnicodeConversionAndKeepsUUIDAfterRestart() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("日本語.txt")
        let raw = "か\u{3099}\r\n👩‍💻\n最後"
        let bytes = try TextFileFormat.utf8BOM.encode(raw)
        try bytes.write(to: file)
        let directory = root.appendingPathComponent("registry")
        let adapter = try FilesProviderAdapter(directory: directory, enabled: true, testLocalRoot: root)
        let picked = try await adapter.registerPickedURL(file)
        XCTAssertEqual(picked.providerKind, "files")
        XCTAssertEqual(picked.baseline, .make(bytes))
        XCTAssertEqual(Array((picked.baseText ?? "").utf16), Array(raw.utf16))
        let duplicate = try await adapter.registerPickedURL(file)
        XCTAssertEqual(duplicate.identity, picked.identity)
        let reopened = try FilesProviderAdapter(directory: directory, enabled: true, testLocalRoot: root)
        let read = try await reopened.read(identity: picked.identity)
        XCTAssertEqual(read.identity, picked.identity)
        XCTAssertEqual(read.baseline, picked.baseline)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testExistingWriteRequiresFullBaselineAndLeavesChangedOriginalUntouched() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("existing.txt")
        try Data("before\r\n".utf8).write(to: file)
        let adapter = try FilesProviderAdapter(directory: root.appendingPathComponent("registry"), enabled: true, testLocalRoot: root)
        let picked = try await adapter.registerPickedURL(file)
        // A non-atomic in-place external edit retains physical identity but changes the whole-byte baseline.
        try Data("external\n".utf8).write(to: file, options: [])
        let snapshot = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: picked.name, text: "local\r\n",
                                         format: "utf8", revision: 1, target: picked)
        do { _ = try await adapter.write(kind: "existing", snapshot: snapshot, name: nil); XCTFail("Stale baseline must never overwrite") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "conflict") }
        XCTAssertEqual(try Data(contentsOf: file), Data("external\n".utf8))
    }

    func testAcceptedAtomicExistingWriteUpdatesBookmarkAndReadbackWithoutClaimingCloudSync() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("existing.txt")
        try Data("before".utf8).write(to: file)
        let directory = root.appendingPathComponent("registry")
        let adapter = try FilesProviderAdapter(directory: directory, enabled: true, testLocalRoot: root)
        let picked = try await adapter.registerPickedURL(file)
        let snapshot = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: picked.name, text: "after\nか\u{3099}",
                                         format: "utf8", revision: 1, target: picked, lineEnding: "crlf")
        let accepted = try await adapter.write(kind: "existing", snapshot: snapshot, name: nil)
        XCTAssertEqual(accepted.identity, picked.identity)
        XCTAssertEqual(accepted.baseline, .make(try snapshot.encodedBytes()))
        XCTAssertEqual(try Data(contentsOf: file), try snapshot.encodedBytes())
        let reopened = try FilesProviderAdapter(directory: directory, enabled: true, testLocalRoot: root)
        let readback = try await reopened.read(identity: accepted.identity)
        XCTAssertEqual(readback.baseline, accepted.baseline)
        XCTAssertTrue(accepted.location.contains("未確認"))
    }

    func testNewSaveAsIsUnsupportedAndDoesNotCreateAFile() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let adapter = try FilesProviderAdapter(directory: root.appendingPathComponent("registry"), enabled: true, testLocalRoot: root)
        let snapshot = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: "new.txt", text: "draft",
                                         format: "utf8", revision: 1, target: nil)
        do { _ = try await adapter.write(kind: "saveAs", snapshot: snapshot, name: "new.txt"); XCTFail("Unsupported new save must stop") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "unsupported") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }

    func testMalformedTextAndDeletedBookmarkNeverBecomeWritableTargets() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        let adapter = try FilesProviderAdapter(directory: root.appendingPathComponent("registry"), enabled: true, testLocalRoot: root)
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: file)
        do { _ = try await adapter.registerPickedURL(file); XCTFail("Malformed UTF-16 must be rejected") }
        catch { XCTAssertTrue(error is StorageError) }
        try Data("valid".utf8).write(to: file)
        let picked = try await adapter.registerPickedURL(file)
        try FileManager.default.removeItem(at: file)
        do { _ = try await adapter.read(identity: picked.identity); XCTFail("Deleted target must not produce a receipt") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testRegistryCorruptionDoesNotSilentlyResetSelectedFileIdentity() throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("broken json".utf8).write(to: root.appendingPathComponent("bookmarks.json"))
        XCTAssertThrowsError(try FilesBookmarkRegistry(directory: root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bookmarks.json")), Data("broken json".utf8))
    }

    func testReplacedPhysicalFileDoesNotInheritOldWritePermission() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: file)
        let adapter = try FilesProviderAdapter(directory: root.appendingPathComponent("registry"), enabled: true, testLocalRoot: root)
        let picked = try await adapter.registerPickedURL(file)
        let replacement = Data("different physical file".utf8)
        try replacement.write(to: file, options: .atomic)
        do { _ = try await adapter.read(identity: picked.identity); XCTFail("A replacement resource must be rejected") }
        catch { /* Bookmark stale/deleted/identityChanged depends on the local filesystem. */ }
        let stale = CoreWriteSnapshot(id: UUID(), sessionID: UUID(), name: picked.name, text: "must not overwrite",
                                      format: "utf8", revision: 1, target: picked)
        do { _ = try await adapter.write(kind: "existing", snapshot: stale, name: nil); XCTFail("Old identity must not authorize a replacement write") }
        catch { XCTAssertEqual(try Data(contentsOf: file), replacement) }
    }

    func testUnresolvableBookmarkIsRetainedAndFailsClosed() async throws {
        let root = try self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("registry")
        var registry = try FilesBookmarkRegistry(directory: directory)
        let identity = UUID().uuidString
        let invalid = FilesBookmarkRegistry.Entry(identity: identity, bookmark: Data([1, 2, 3]),
                                                 resourceIdentity: .init(file: Data([1]), volume: Data([2])), name: "original.txt")
        try registry.put(invalid)
        let adapter = try FilesProviderAdapter(directory: directory, enabled: true, testLocalRoot: root)
        do { _ = try await adapter.read(identity: identity); XCTFail("Invalid bookmark must not fall back to a path") }
        catch let failure as ProviderFailure { XCTAssertEqual(failure.code, "bookmark") }
        let retained = try FilesBookmarkRegistry(directory: directory).entry(identity)
        XCTAssertEqual(retained.bookmark, invalid.bookmark)
    }
}
