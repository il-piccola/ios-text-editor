import Foundation
import CryptoKit

/// App-private draft state. A provider receipt never implies cloud upload completion.
struct DraftRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = "無題.txt"
    var text: String = ""
    var format: TextFileFormat = .utf8
    var revision: Int = 0
    var updatedAt: Date = Date()
    var remote: RemoteTarget?
    var epoch: Int = 0
    var acceptedRevision: Int?
    var coreTarget: CoreTarget?
}

extension DraftRecord {
    private enum CodingKeys: String, CodingKey {
        case id, name, text, format, revision, updatedAt, remote, epoch, acceptedRevision, coreTarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        text = try container.decode(String.self, forKey: .text)
        format = try container.decode(TextFileFormat.self, forKey: .format)
        revision = try container.decode(Int.self, forKey: .revision)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        remote = try container.decodeIfPresent(RemoteTarget.self, forKey: .remote)
        epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        let accepted = try container.decodeIfPresent(Int.self, forKey: .acceptedRevision)
        acceptedRevision = accepted.flatMap { $0 < 0 ? nil : $0 }
        coreTarget = try container.decodeIfPresent(CoreTarget.self, forKey: .coreTarget)
    }
}

enum TextFileFormat: String, Codable, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE

    static func decode(_ data: Data) throws -> (String, TextFileFormat) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else { throw StorageError.unsupportedEncoding }
            return try checkedRoundTrip(text, format: .utf8BOM, original: data)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else { throw StorageError.unsupportedEncoding }
            return try checkedRoundTrip(text, format: .utf16LE, original: data)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else { throw StorageError.unsupportedEncoding }
            return try checkedRoundTrip(text, format: .utf16BE, original: data)
        }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { throw StorageError.unsupportedEncoding }
        return try checkedRoundTrip(text, format: .utf8, original: data)
    }

    private static func checkedRoundTrip(_ text: String, format: TextFileFormat, original: Data) throws -> (String, TextFileFormat) {
        guard try format.encode(text) == original else { throw StorageError.unsupportedEncoding }
        return (text, format)
    }

    func encode(_ text: String) throws -> Data {
        let encoding: String.Encoding
        let prefix: [UInt8]
        switch self {
        case .utf8: encoding = .utf8; prefix = []
        case .utf8BOM: encoding = .utf8; prefix = [0xEF, 0xBB, 0xBF]
        case .utf16LE: encoding = .utf16LittleEndian; prefix = [0xFF, 0xFE]
        case .utf16BE: encoding = .utf16BigEndian; prefix = [0xFE, 0xFF]
        }
        guard let bytes = text.data(using: encoding, allowLossyConversion: false) else { throw StorageError.unsupportedEncoding }
        return Data(prefix) + bytes
    }
}

struct FileBaseline: Codable, Equatable, Sendable {
    var sha256: String
    var modifiedAt: Date?
    var byteCount: Int

    static func make(data: Data, modifiedAt: Date?) -> FileBaseline {
        FileBaseline(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                     modifiedAt: modifiedAt, byteCount: data.count)
    }
}

struct RemoteTarget: Codable, Equatable, Sendable {
    var bookmark: Data
    var name: String
    /// A user-readable Files location; this is not a provider identity or a Drive file ID.
    var location: String
    var baseline: FileBaseline
}

struct OpenedFile: Sendable {
    var text: String
    var format: TextFileFormat
    var target: RemoteTarget
}

struct ProviderWriteReceipt: Sendable {
    var target: RemoteTarget
    var acceptedAt: Date
    var savedRevision: Int
    let cloudStatus: CloudReflectionStatus = .unconfirmed
}

enum CloudReflectionStatus: String, Codable, Sendable { case unconfirmed }

enum StorageError: Error, LocalizedError {
    case conflict, staleBookmark, unsupportedEncoding, tooLarge, invalidName, missingFile, noResult, invalidDraft, staleDraft

    var errorDescription: String? {
        switch self {
        case .conflict: return "保存先が他のアプリや端末で変更されています。下書きは残っています。別名で保存するか、保存先を開き直してください。"
        case .staleBookmark: return "保存先へのアクセスが切れました。Files から選び直してください。下書きは残っています。"
        case .unsupportedEncoding: return "対応していない文字コードです。原本は変更していません。UTF-8 または BOM 付き UTF-16 のテキストを選んでください。"
        case .tooLarge: return "この試作では 20 MB を超えるファイルを開けません。原本は変更していません。"
        case .invalidName: return "ファイル名を確認してください。空の名前、/、: は使えません。"
        case .missingFile: return "保存先が見つかりません。下書きは残っています。Files から選び直してください。"
        case .noResult: return "Files の操作を完了できませんでした。下書きは残っています。"
        case .invalidDraft: return "下書きの形式を確認できません。ファイルを残したまま処理を止めました。"
        case .staleDraft: return "新しい下書きを古い状態で置き換える操作を止めました。"
        }
    }
}
