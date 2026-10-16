import Foundation
import CryptoKit

struct CoreBaseline: Codable, Equatable, Sendable {
    let sha256: String
    let byteCount: Int

    static func make(_ data: Data) -> CoreBaseline {
        CoreBaseline(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: data.count)
    }
}

struct CoreTarget: Codable, Equatable, Sendable {
    let identity: String
    let name: String
    let location: String
    let baseline: CoreBaseline
    var baseText: String? = nil
    var format: String? = nil
    var lineEnding: String? = nil
    var providerKind: String? = nil
}

struct CoreEnvelope: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    let id: UUID
    let name: String
    let text: String
    let format: String
    let revision: Int
    let epoch: Int
    let target: CoreTarget?
    let acceptedRevision: Int?
    var lineEnding: String = "preserve"
    var uncertain: Bool = false
    var unknownOperation: CoreOperation? = nil
    var pendingWrite: CoreOperation? = nil
    var remoteCandidate: CoreRemoteCandidate? = nil
    var retainedEvidence: [CoreRemoteCandidate] = []

    func validate() throws {
        guard schemaVersion == 1, revision >= 0, epoch >= 0,
              TextFileFormat(rawValue: format) != nil,
              ["crlf", "preserve"].contains(lineEnding),
              uncertain == (unknownOperation != nil) else { throw StorageError.invalidDraft }
        for operation in [unknownOperation, pendingWrite].compactMap({ $0 }) {
            guard ["existing", "saveAs"].contains(operation.kind), operation.phase == "writing",
                  operation.snapshot.id == id, operation.snapshot.revision <= revision,
                  operation.snapshot.revision >= 0, TextFileFormat(rawValue: operation.snapshot.format) != nil,
                  ["preserve", "crlf"].contains(operation.snapshot.lineEnding),
                  operation.kind != "existing" || operation.snapshot.target != nil else { throw StorageError.invalidDraft }
        }
        if let candidate = remoteCandidate {
            guard candidate.target.identity == target?.identity else { throw StorageError.invalidDraft }
        }
        // A retained comparison can refer to a prior save destination. Never require its identity to match the current target.
        // Current and retained evidence receive the same strict byte/format/revision validation.
        for evidence in [remoteCandidate].compactMap({ $0 }) + retainedEvidence {
            guard !evidence.token.isEmpty, evidence.snapshotRevision >= 0,
                  evidence.snapshotRevision <= evidence.observedRevision, evidence.observedRevision <= revision,
                  UUID(uuidString: evidence.target.identity) != nil,
                  evidence.target.baseline.sha256.count == 64, evidence.target.baseline.sha256.allSatisfy({ $0.isHexDigit }),
                  evidence.target.baseline.byteCount >= 0, let encoding = TextFileFormat(rawValue: evidence.format),
                  try CoreBaseline.make(encoding.encode(evidence.text)) == evidence.target.baseline else { throw StorageError.invalidDraft }
            if let rawText = evidence.target.baseText {
                guard rawText.utf16.elementsEqual(evidence.text.utf16) else { throw StorageError.invalidDraft }
            }
            if let rawFormat = evidence.target.format {
                guard rawFormat == evidence.format else { throw StorageError.invalidDraft }
            }
            if let policy = evidence.target.lineEnding {
                guard ["crlf", "preserve"].contains(policy) else { throw StorageError.invalidDraft }
            }
        }
        if let acceptedRevision {
            guard target != nil, acceptedRevision >= 0, acceptedRevision <= revision else { throw StorageError.invalidDraft }
        }
        if let target {
            guard UUID(uuidString: target.identity) != nil,
                  target.baseline.sha256.count == 64,
                  target.baseline.sha256.allSatisfy({ $0.isHexDigit }),
                  target.baseline.byteCount >= 0 else { throw StorageError.invalidDraft }
            if let base = target.baseText, let rawFormat = target.format {
                guard let encoding = TextFileFormat(rawValue: rawFormat),
                      try CoreBaseline.make(encoding.encode(base)) == target.baseline else { throw StorageError.invalidDraft }
            }
        }
    }

    func record(updatedAt: Date) -> DraftRecord {
        DraftRecord(id: id, name: name, text: text, format: TextFileFormat(rawValue: format) ?? .utf8,
                    revision: revision, updatedAt: updatedAt, remote: nil,
                    epoch: epoch, acceptedRevision: acceptedRevision, coreTarget: target)
    }
}

extension CoreEnvelope {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, text, format, revision, epoch, target, acceptedRevision, lineEnding, uncertain, unknownOperation, pendingWrite, remoteCandidate, retainedEvidence
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        format = try c.decode(String.self, forKey: .format)
        revision = try c.decode(Int.self, forKey: .revision)
        epoch = try c.decode(Int.self, forKey: .epoch)
        target = try c.decodeIfPresent(CoreTarget.self, forKey: .target)
        acceptedRevision = try c.decodeIfPresent(Int.self, forKey: .acceptedRevision)
        lineEnding = try c.decodeIfPresent(String.self, forKey: .lineEnding) ?? "preserve"
        uncertain = try c.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
        unknownOperation = try c.decodeIfPresent(CoreOperation.self, forKey: .unknownOperation)
        pendingWrite = try c.decodeIfPresent(CoreOperation.self, forKey: .pendingWrite)
        remoteCandidate = try c.decodeIfPresent(CoreRemoteCandidate.self, forKey: .remoteCandidate)
        retainedEvidence = try c.decodeIfPresent([CoreRemoteCandidate].self, forKey: .retainedEvidence) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(text, forKey: .text)
        try container.encode(format, forKey: .format)
        try container.encode(revision, forKey: .revision)
        try container.encode(epoch, forKey: .epoch)
        // Explicit JSON null is part of the JS schema; synthesized optional encoding would omit these keys.
        try container.encode(target, forKey: .target)
        try container.encode(acceptedRevision, forKey: .acceptedRevision)
        try container.encode(lineEnding, forKey: .lineEnding)
        try container.encode(uncertain, forKey: .uncertain)
        try container.encode(unknownOperation, forKey: .unknownOperation)
        try container.encode(pendingWrite, forKey: .pendingWrite)
        try container.encode(remoteCandidate, forKey: .remoteCandidate)
        try container.encode(retainedEvidence, forKey: .retainedEvidence)
    }
}

struct CoreWriteSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let name: String
    let text: String
    let format: String
    let revision: Int
    let target: CoreTarget?
    var lineEnding: String = "preserve"

    var outputText: String {
        guard lineEnding == "crlf" else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    func encodedBytes() throws -> Data {
        guard let encoding = TextFileFormat(rawValue: format) else { throw StorageError.unsupportedEncoding }
        guard ["preserve", "crlf"].contains(lineEnding) else { throw StorageError.invalidDraft }
        return try encoding.encode(outputText)
    }
}

struct ProviderFailure: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

extension CoreWriteSnapshot {
    private enum CodingKeys: String, CodingKey { case id, sessionID, name, text, format, revision, target, lineEnding }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        format = try c.decode(String.self, forKey: .format)
        revision = try c.decode(Int.self, forKey: .revision)
        target = try c.decodeIfPresent(CoreTarget.self, forKey: .target)
        lineEnding = try c.decodeIfPresent(String.self, forKey: .lineEnding) ?? "preserve"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(sessionID, forKey: .sessionID)
        try c.encode(name, forKey: .name); try c.encode(text, forKey: .text)
        try c.encode(format, forKey: .format); try c.encode(revision, forKey: .revision)
        try c.encode(target, forKey: .target); try c.encode(lineEnding, forKey: .lineEnding)
    }
}

struct CoreRemoteCandidate: Codable, Equatable, Sendable {
    let token: String
    let text: String
    let format: String
    let target: CoreTarget
    let observedRevision: Int
    let snapshotRevision: Int
    let localText: String
    let baseText: String?
}

extension CoreRemoteCandidate {
    private enum CodingKeys: String, CodingKey { case token, text, format, target, observedRevision, snapshotRevision, localText, baseText }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token); try c.encode(text, forKey: .text)
        try c.encode(format, forKey: .format); try c.encode(target, forKey: .target)
        try c.encode(observedRevision, forKey: .observedRevision); try c.encode(snapshotRevision, forKey: .snapshotRevision)
        try c.encode(localText, forKey: .localText); try c.encode(baseText, forKey: .baseText)
    }
}

enum SaveName {
    static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", name.utf8.count <= 180,
              !name.contains(where: { "/\\:".contains($0) || $0.isNewline || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) })
        else { throw StorageError.invalidName }
        return name
    }
}
