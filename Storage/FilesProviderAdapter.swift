import Foundation

enum FilesObservation: Sendable {
    case changed(identity: String)
    case moved(identity: String)
    case deleted(identity: String)
    case failed(identity: String, message: String)
}

/// Source-only Files route. It has never been compiled or exercised with an iOS file provider.
actor FilesProviderAdapter: ProviderAdapter {
    static let isEnabled = false
    private let enabled: Bool
    private let testLocalRoot: URL?
    private var registry: FilesBookmarkRegistry
    private var observers: [String: ObservationHandle] = [:]
    private let byteLimit = 20 * 1024 * 1024
    private struct ObservationHandle: Sendable { let presenter: FilesChangePresenter; let scopedURL: URL; let startedScope: Bool }
    private struct ReadResult {
        let url: URL
        let bytes: Data
        let text: String
        let format: TextFileFormat
        let resource: FilesBookmarkRegistry.ResourceIdentity
        let bookmark: Data
    }

    init(directory: URL? = nil, enabled: Bool = FilesProviderAdapter.isEnabled, testLocalRoot: URL? = nil) throws {
        self.enabled = enabled
        self.testLocalRoot = testLocalRoot?.standardizedFileURL.resolvingSymlinksInPath()
        // An unavailable integration must not stop local drafts or the fake provider from starting.
        // In particular, do not create directories or decode an old, possibly corrupt registry.
        if enabled { registry = try FilesBookmarkRegistry(directory: directory) }
        else { registry = .disabled() }
    }

    deinit {
        for handle in observers.values {
            NSFileCoordinator.removeFilePresenter(handle.presenter)
            if handle.startedScope { handle.scopedURL.stopAccessingSecurityScopedResource() }
        }
    }

    func owns(identity: String) -> Bool { (try? registry.entry(identity)) != nil }

    func registerPickedURL(_ pickedURL: URL) async throws -> CoreTarget {
        try requireEnabled()
        return try withScope(pickedURL) {
            let read = try coordinatedRead(pickedURL, expected: nil)
            let existing = try registry.matching(read.resource)
            let identity = existing?.identity ?? UUID().uuidString
            let entry = try refreshedEntry(identity: identity, read: read)
            try registry.put(entry)
            return target(identity: identity, read: read)
        }
    }

    func read(identity: String) async throws -> CoreTarget {
        try requireEnabled()
        let entry = try registry.entry(identity)
        let url = try resolve(entry)
        return try withScope(url) {
            let read = try coordinatedRead(url, expected: entry.resourceIdentity)
            // Preserve UUID when the bookmark resolves a move to the SAME physical resource.
            try registry.put(refreshedEntry(identity: identity, read: read))
            return target(identity: identity, read: read)
        }
    }

    func find(name: String) async throws -> CoreTarget? {
        try requireEnabled()
        let canonical = name.precomposedStringWithCanonicalMapping.lowercased()
        let matches = registry.entries.filter { $0.name.precomposedStringWithCanonicalMapping.lowercased() == canonical }
        if matches.count > 1 { throw ProviderFailure(code: "ambiguousName", message: "同名の登録が複数あります。名前だけで保存先を選びません。") }
        throw ProviderFailure(code: "unsupported", message: "Files の結果不明照合には保存先 UUID が必要です。名前だけの検索は行いません。")
    }

    func write(kind: String, snapshot: CoreWriteSnapshot, name: String?) async throws -> CoreTarget {
        try requireEnabled()
        guard kind == "existing", let expected = snapshot.target else {
            throw ProviderFailure(code: "unsupported", message: "Files の新規・別名保存は未対応です。衝突や上書きを防ぐ実機検証後に追加します。")
        }
        let entry = try registry.entry(expected.identity)
        let url = try resolve(entry)
        let bytes = try snapshot.encodedBytes()
        guard bytes.count <= byteLimit else { throw StorageError.tooLarge }
        return try withScope(url) {
            let coordinator = NSFileCoordinator(filePresenter: observers[expected.identity]?.presenter)
            var coordinationError: NSError?
            var result: Result<CoreTarget, Error>?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                var writeAttempted = false
                do {
                    try Task.checkCancellation()
                    let original = try uncoordinatedRead(coordinatedURL, expected: entry.resourceIdentity)
                    guard CoreBaseline.make(original.bytes) == expected.baseline else {
                        throw ProviderFailure(code: "conflict", message: "Files の原本が変更されています。比較確認まで書き込みを止めます。")
                    }
                    try Task.checkCancellation()
                    writeAttempted = true
                    // File coordination covers compare AND atomic replacement. No export/overwrite picker route.
                    try bytes.write(to: coordinatedURL, options: .atomic)
                    let accepted = try uncoordinatedRead(coordinatedURL, expected: nil)
                    guard accepted.bytes == bytes else { throw ProviderFailure(code: "unknownOutcome", message: "書き込んだ全バイトの一致を確認できません。") }
                    try registry.put(refreshedEntry(identity: expected.identity, read: accepted))
                    result = .success(target(identity: expected.identity, read: accepted))
                } catch {
                    result = .failure(writeAttempted ? ProviderFailure(code: "unknownOutcome", message: "Files の書き込み結果を確定できません。再確認まで同じファイルへ再試行しません。 " + error.localizedDescription) : error)
                }
            }
            if let result { return try result.get() }
            if let coordinationError { throw ProviderFailure(code: "coordination", message: coordinationError.localizedDescription) }
            throw ProviderFailure(code: "coordination", message: "Files の書き込み調整が完了しませんでした。")
        }
    }

    func beginObserving(identity: String, onChange: @escaping @Sendable (FilesObservation) -> Void) async throws {
        try requireEnabled()
        stopObserving(identity: identity)
        let entry = try registry.entry(identity)
        let url = try resolve(entry)
        let started = try acquireScope(url)
        do {
            _ = try coordinatedRead(url, expected: entry.resourceIdentity)
            let presenter = FilesChangePresenter(url: url, identity: identity) { [weak self] event in
                onChange(event)
                if case .moved = event {
                    Task { await self?.refreshAfterMove(identity: identity, onChange: onChange) }
                }
            }
            observers[identity] = ObservationHandle(presenter: presenter, scopedURL: url, startedScope: started)
            NSFileCoordinator.addFilePresenter(presenter)
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func stopObserving(identity: String) {
        guard let handle = observers.removeValue(forKey: identity) else { return }
        NSFileCoordinator.removeFilePresenter(handle.presenter)
        if handle.startedScope { handle.scopedURL.stopAccessingSecurityScopedResource() }
    }

    func shutdownObservers() { for identity in Array(observers.keys) { stopObserving(identity: identity) } }

    private func refreshAfterMove(identity: String, onChange: @escaping @Sendable (FilesObservation) -> Void) {
        do {
            let entry = try registry.entry(identity)
            let url = try resolve(entry)
            try withScope(url) {
                let read = try coordinatedRead(url, expected: entry.resourceIdentity)
                try registry.put(refreshedEntry(identity: identity, read: read))
            }
        } catch { onChange(.failed(identity: identity, message: "移動後の権限と同一性を確認できません。Files で選び直してください。 " + error.localizedDescription)) }
    }

    private func requireEnabled() throws {
        guard enabled else { throw ProviderFailure(code: "unavailable", message: "Files 連携は未検証のため既定で無効です。") }
    }

    private func acquireScope(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw ProviderFailure(code: "invalidURL", message: "ファイル URL 以外は開きません。") }
        if url.startAccessingSecurityScopedResource() { return true }
        if let root = testLocalRoot {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if path.hasPrefix(prefix) { return false }
        }
        throw ProviderFailure(code: "permission", message: "Files のアクセス権を取得できません。保存先を選び直してください。")
    }

    private func withScope<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let started = try acquireScope(url)
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func resolve(_ entry: FilesBookmarkRegistry.Entry) throws -> URL {
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: entry.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw ProviderFailure(code: "bookmark", message: "保存先の bookmark を解決できません。Files で選び直してください。") }
        guard !stale else { throw ProviderFailure(code: "staleBookmark", message: "保存先の bookmark が古くなりました。自動で別の保存先に置き換えません。Files で選び直してください。") }
        return url
    }

    private func coordinatedRead(_ url: URL, expected: FilesBookmarkRegistry.ResourceIdentity?) throws -> ReadResult {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<ReadResult, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try uncoordinatedRead(coordinatedURL, expected: expected) }
        }
        if let result { return try result.get() }
        if let coordinationError { throw ProviderFailure(code: "coordination", message: coordinationError.localizedDescription) }
        throw ProviderFailure(code: "coordination", message: "Files の読み込み調整が完了しませんでした。")
    }

    private func uncoordinatedRead(_ url: URL, expected: FilesBookmarkRegistry.ResourceIdentity?) throws -> ReadResult {
        try Task.checkCancellation()
        let resource = try FilesBookmarkRegistry.ResourceIdentity.capture(url)
        if let expected, resource != expected { throw ProviderFailure(code: "identityChanged", message: "保存先のファイル同一性が変わっています。上書きせず選び直してください。") }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = attributes.fileSize, size >= 0, size <= byteLimit else { throw StorageError.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= byteLimit else { throw StorageError.tooLarge }
        guard try FilesBookmarkRegistry.ResourceIdentity.capture(url) == resource else {
            throw ProviderFailure(code: "identityChanged", message: "読み込み中にファイル同一性が変わりました。原本を上書きしません。")
        }
        let (text, format) = try TextFileFormat.decode(bytes)
        let bookmark = try url.bookmarkData(options: [.minimalBookmark],
                                           includingResourceValuesForKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey], relativeTo: nil)
        guard try FilesBookmarkRegistry.ResourceIdentity.capture(url) == resource else {
            throw ProviderFailure(code: "identityChanged", message: "bookmark の取得中にファイル同一性が変わりました。")
        }
        return ReadResult(url: url, bytes: bytes, text: text, format: format, resource: resource, bookmark: bookmark)
    }

    private func refreshedEntry(identity: String, read: ReadResult) throws -> FilesBookmarkRegistry.Entry {
        return FilesBookmarkRegistry.Entry(identity: identity, bookmark: read.bookmark, resourceIdentity: read.resource, name: read.url.lastPathComponent)
    }

    private func target(identity: String, read: ReadResult) -> CoreTarget {
        var result = CoreTarget(identity: identity, name: read.url.lastPathComponent, location: "Files（クラウド反映未確認）",
                                baseline: .make(read.bytes), baseText: read.text, format: read.format.rawValue, lineEnding: "preserve")
        result.providerKind = "files"
        return result
    }
}

/// Explicit add/remove lifecycle is required: NSFileCoordinator retains registered presenters.
private final class FilesChangePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL
    private let identity: String
    private let notify: @Sendable (FilesObservation) -> Void
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.name = "IyoFilesPresenter"; return queue
    }()
    var presentedItemURL: URL? { lock.lock(); defer { lock.unlock() }; return url }
    init(url: URL, identity: String, notify: @escaping @Sendable (FilesObservation) -> Void) {
        self.url = url; self.identity = identity; self.notify = notify; super.init()
    }
    func presentedItemDidChange() { notify(.changed(identity: identity)) }
    func presentedItemDidMove(to newURL: URL) {
        lock.lock(); url = newURL; lock.unlock(); notify(.moved(identity: identity))
    }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        notify(.deleted(identity: identity)); completionHandler(nil)
    }
}
