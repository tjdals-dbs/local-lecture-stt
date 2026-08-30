import Foundation

protocol StorageRootControlling: Sendable {
    func availability() async -> StorageRootAvailability
    func storageRootCatalog() async throws -> StorageRootCatalog
    func registerSelectedDirectory(_ url: URL) async throws -> StorageRootSummary
    func reauthorize(rootID: StorageRootID, with url: URL) async throws -> StorageRootSummary
}
