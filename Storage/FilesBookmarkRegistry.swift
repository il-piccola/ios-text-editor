import Foundation

/// Actor-owned synchronous storage. One FilesProviderAdapter owns one registry in production.
/// Raw paths are never used as authority; only resolved bookmarks plus physical identity allow access.
struct FilesBookmarkRegistry {
    struct ResourceIdentity: Codable, Equatable, Sendable {
        let file: Data
        let volume: Data

        static func capture(_ url: URL) throws -> ResourceIdentity {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .volumeIdentifierKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let file = values.fileResourceIdentifier, let volume = values.volumeIdentifier,
                  file is NSSecureCoding, volume is NSSecureCoding else {
                throw ProviderFailure(code: "unsupportedIdentity", message: "保存先の同一性を確認できません。このプロバイダでの書き込みは停止します。")
            }
            // Opaque Foundation identifiers must support secure archival. No description/path fallback.
            return ResourceIdentity(file: try NSKeyedArchiver.archivedData(withRootObject: file, requiringSecureCoding: true),
                                    volume: try NSKeyedArchiver.archivedData(withRootObject: volume, requiringSecureCoding: true))
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        let identity: String
        var bookmark: Data
        var resourceIdentity: ResourceIdentity
        var name: String
    }

    private struct Document: Codable { var schemaVersion = 1; var entries: [Entry] }
    private let url: URL?
    private(set) var entries: [Entry]

    /// Disabled adapters have no backing URL and perform no filesystem access.
    static func disabled() -> FilesBookmarkRegistry { FilesBookmarkRegistry() }

    private init() { url = nil; entries = [] }

    init(directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true).appendingPathComponent("IyoFilesBookmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("bookmarks.json")
        url = storageURL
        if FileManager.default.fileExists(atPath: storageURL.path) {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: storageURL))
            guard document.schemaVersion == 1 else { throw StorageError.invalidDraft }
            entries = document.entries
        } else { entries = [] }
        var ids = Set<String>()
        for entry in entries {
            guard UUID(uuidString: entry.identity) != nil, ids.insert(entry.identity).inserted,
                  !entry.bookmark.isEmpty, !entry.resourceIdentity.file.isEmpty, !entry.resourceIdentity.volume.isEmpty else { throw StorageError.invalidDraft }
        }
    }

    func entry(_ identity: String) throws -> Entry {
        guard UUID(uuidString: identity) != nil, let entry = entries.first(where: { $0.identity == identity }) else {
            throw ProviderFailure(code: "unregistered", message: "保存先の登録がありません。Files で選び直してください。")
        }
        return entry
    }

    func matching(_ resource: ResourceIdentity) throws -> Entry? {
        let matches = entries.filter { $0.resourceIdentity == resource }
        guard matches.count <= 1 else { throw ProviderFailure(code: "ambiguousIdentity", message: "保存先の登録が曖昧なためアクセスを停止しました。") }
        return matches.first
    }

    mutating func put(_ entry: Entry) throws {
        guard let url else { throw ProviderFailure(code: "unavailable", message: "Files 登録簿は無効です。") }
        guard UUID(uuidString: entry.identity) != nil, !entry.bookmark.isEmpty else { throw StorageError.invalidDraft }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.identity == entry.identity }) { updated[index] = entry }
        else { updated.append(entry) }
        let bytes = try JSONEncoder().encode(Document(entries: updated))
        try bytes.write(to: url, options: .atomic)
        entries = updated
    }
}
