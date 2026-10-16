import Foundation

/// Serializes draft writes so a delayed older autosave cannot replace a newer revision.
actor DraftStore {
    private let directory: URL
    private let capacity: DraftCapacityConfiguration
    private let availableBytesReader: @Sendable (URL) throws -> Int?
    private var capacityBridge: CapacityPolicyBridge?
    private var nextFailure: WriteFailureInjection = .none

    enum WriteFailureInjection: Sendable { case none, beforeAtomicWrite, afterTemporaryWrite }
    /// Test-only deterministic failures; never used by the app's UI.
    func injectNextWriteFailureForTesting(_ failure: WriteFailureInjection) { nextFailure = failure }

    struct ScanResult: Sendable {
        let records: [DraftRecord]
        let failures: [String]
    }

    func scan() throws -> ScanResult {
        var records: [DraftRecord] = []
        var failures: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) {
            do {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw StorageError.invalidDraft }
                let envelope = try loadEnvelope(id)
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                records.append(envelope.record(updatedAt: modified))
            } catch {
                failures.append(url.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        return ScanResult(records: records.sorted { $0.updatedAt > $1.updatedAt }, failures: failures)
    }

    func persist(_ envelope: CoreEnvelope) throws {
        try envelope.validate()
        let url = draftURL(envelope.id)
        if let previous = try loadEnvelopeIfPresent(envelope.id) {
            guard envelope.revision >= previous.revision, envelope.epoch >= previous.epoch else { throw StorageError.staleDraft }
            if envelope.epoch == previous.epoch {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(envelope) == encoder.encode(previous) else { throw StorageError.staleDraft }
                return
            }
        }
        let data = try JSONEncoder().encode(envelope)
        let occupied = try occupiedBytes()
        let previousBytes = FileManager.default.fileExists(atPath: url.path) ? try fileBytes(url) : 0
        if capacityBridge == nil { capacityBridge = try CapacityPolicyBridge() }
        guard let capacityBridge else { throw DraftCapacityError.unavailable }
        let plan = try capacityBridge.plan(incomingBytes: data.count, previousBytes: previousBytes,
            existingBytes: occupied, availableBytes: try availableBytesReader(directory), configuration: capacity)
        guard plan.allowed else { throw DraftCapacityError.denied(plan.reason ?? "unknown") }
        let failure = nextFailure; nextFailure = .none
        switch failure {
        case .beforeAtomicWrite: throw DraftCapacityError.simulatedWriteFailure
        case .afterTemporaryWrite:
            // Only remove the exact temporary file created by this injection, never an existing safety record.
            let auxiliary = directory.appendingPathComponent(UUID().uuidString + ".capacity-test.tmp")
            try data.write(to: auxiliary, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: auxiliary) }
            throw DraftCapacityError.simulatedWriteFailure
        case .none: try data.write(to: url, options: .atomic)
        }
    }

    func loadEnvelope(_ id: UUID) throws -> CoreEnvelope {
        guard let envelope = try loadEnvelopeIfPresent(id) else { throw StorageError.missingFile }
        return envelope
    }

    init(directory: URL? = nil, capacity: DraftCapacityConfiguration = .init(),
         availableBytes: @escaping @Sendable (URL) throws -> Int? = { try DraftStore.volumeAvailableBytes($0) }) throws {
        self.capacity = capacity
        self.availableBytesReader = availableBytes
        self.directory = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("IyoDrafts", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func capacityStatus() throws -> DraftCapacityStatus {
        let used = try occupiedBytes(), available = try availableBytesReader(directory)
        guard capacity.budgetBytes >= 0, capacity.maxIncomingBytes >= 0, capacity.reserveBytes >= 0,
              available.map({ $0 >= 0 }) ?? true else { throw DraftCapacityError.unavailable }
        return DraftCapacityStatus(budgetBytes: capacity.budgetBytes, usedBytes: used,
            remainingBytes: max(0, capacity.budgetBytes - used), availableBytes: available,
            reserveBytes: capacity.reserveBytes, maxIncomingBytes: capacity.maxIncomingBytes,
            status: available == nil ? "availableUnknown" : used > capacity.budgetBytes ? "overBudget" : "known")
    }

    nonisolated static func volumeAvailableBytes(_ directory: URL) throws -> Int? {
        guard let bytes = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, bytes >= 0, let result = Int(exactly: bytes) else { return nil }
        return result
    }

    private func fileBytes(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
            throw DraftCapacityError.unavailable
        }
        return size
    }

    private func occupiedBytes() throws -> Int {
        var total = 0
        // Count all owned-directory files, including corrupt JSON and leftover temp files.
        // Unknown directories/symlinks fail closed rather than undercount protected records.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let (next, overflow) = total.addingReportingOverflow(try fileBytes(url))
            guard !overflow else { throw DraftCapacityError.unavailable }
            total = next
        }
        return total
    }

    @discardableResult
    @available(*, deprecated, message: "Use persist(CoreEnvelope) for revision and metadata epoch ordering.")
    func save(_ draft: DraftRecord) throws -> Bool {
        guard draft.remote == nil else { throw StorageError.invalidDraft }
        // This legacy entry point may import a new local record, but cannot erase durable core metadata.
        guard try loadEnvelopeIfPresent(draft.id) == nil else { throw StorageError.invalidDraft }
        try persist(CoreEnvelope(id: draft.id, name: draft.name, text: draft.text, format: draft.format.rawValue,
                                 revision: draft.revision, epoch: draft.epoch, target: draft.coreTarget,
                                 acceptedRevision: draft.acceptedRevision))
        return true
    }

    func load(_ id: UUID) throws -> DraftRecord {
        guard let draft = try loadIfPresent(id) else { throw StorageError.missingFile }
        return draft
    }

    /// A corrupt draft is reported instead of silently disappearing from Recents.
    func recent() throws -> [DraftRecord] {
        let result = try scan()
        guard result.failures.isEmpty else { throw StorageError.invalidDraft }
        return result.records
    }

    private func loadIfPresent(_ id: UUID) throws -> DraftRecord? {
        let url = draftURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try loadEnvelope(id)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
        return envelope.record(updatedAt: modified)
    }

    private func loadEnvelopeIfPresent(_ id: UUID) throws -> CoreEnvelope? {
        let url = draftURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StorageError.invalidDraft }
        if object["schemaVersion"] != nil {
            let envelope = try JSONDecoder().decode(CoreEnvelope.self, from: data)
            try envelope.validate()
            guard envelope.id == id else { throw StorageError.invalidDraft }
            return envelope
        }
        // Preserve early local drafts. Legacy external URLs are never adopted automatically.
        let legacy = try JSONDecoder().decode(DraftRecord.self, from: data)
        guard legacy.id == id else { throw StorageError.invalidDraft }
        let converted = CoreEnvelope(id: id, name: legacy.name, text: legacy.text, format: legacy.format.rawValue,
                            revision: legacy.revision, epoch: legacy.epoch, target: legacy.coreTarget,
                            acceptedRevision: legacy.acceptedRevision)
        try converted.validate()
        return converted
    }

    private func draftURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
