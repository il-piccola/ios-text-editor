import Foundation

/// The storage boundary is independent of the editor and the JS state machine.
/// Return a receipt only after accepting the exact immutable snapshot; cloud reflection remains unknown.
protocol ProviderAdapter: Sendable {
    func write(kind: String, snapshot: CoreWriteSnapshot, name: String?) async throws -> CoreTarget
    func read(identity: String) async throws -> CoreTarget
    func find(name: String) async throws -> CoreTarget?
}

// FilesProviderAdapter lives in its own source file. Its default feature flag remains disabled.
