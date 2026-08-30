import Foundation

protocol StorageRootControlling: Sendable {
    func availability() async -> StorageRootAvailability
    func registerSelectedDirectory(_ url: URL) async throws -> StorageRootSummary
    func reauthorize(rootID: StorageRootID, with url: URL) async throws -> StorageRootSummary
}
