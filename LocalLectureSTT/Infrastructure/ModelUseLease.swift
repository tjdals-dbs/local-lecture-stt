import Foundation

/// Infrastructure lifetime handle. The original verified tree is never recaptured.
final class ModelUseLease: @unchecked Sendable {
    let directory: ModelPackageDirectory
    let descriptor: ModelPackageDescriptor
    private let tree: [String]
    private let manifest: Data
    private let claim: ModelStoreClaim
    init(directory: ModelPackageDirectory, descriptor: ModelPackageDescriptor, claim: ModelStoreClaim) throws {
        self.directory = directory; self.descriptor = descriptor; self.claim = claim
        tree = try directory.treeStamps(); manifest = try directory.readMetadata("manifest.json")
    }
    func check() throws {
        guard claim.matches(claim.value) else { throw ModelRepositoryCode.identityChanged }
        try directory.check()
        guard try directory.treeStamps() == tree, (try directory.readMetadata("manifest.json")) == manifest else {
            throw ModelRepositoryCode.identityChanged
        }
    }
    func release() { claim.release() }
}
