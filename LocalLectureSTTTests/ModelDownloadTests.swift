import Darwin
import Foundation
import XCTest
@testable import LocalLectureSTT

final class ModelDownloadTests: XCTestCase {
    override func setUp() { super.setUp(); executionTimeAllowance = 30 }
    private func expect(_ code: ModelDownloadCode, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)") }
        catch let f as ModelDownloadFailure { XCTAssertEqual(f.code, code) }
        catch { XCTFail("Unexpected \(error)") }
    }
    private func installed(_ service: ModelDownloadService, _ key: InstalledModelKey) async throws -> ModelDownloadSnapshot {
        let id = try await service.start(key); let s = try await service.wait(id)
        XCTAssertEqual(s.phase, .installed, "\(String(describing: s.failure))")
        return s
    }
    func testOldAndNewCatalogIdentityAndDeliverySchemas() throws {
        let f = try DownloadFixture()
        let old = try BundledModelCatalog(entries: [f.descriptor])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]); json.removeValue(forKey: "deliveries")
        XCTAssertEqual(try JSONDecoder().decode(BundledModelCatalog.self, from: JSONSerialization.data(withJSONObject: json)), old)
        XCTAssertEqual(try JSONDecoder().decode(BundledModelCatalog.self, from: JSONEncoder().encode(f.catalog)), f.catalog)
        XCTAssertEqual(f.catalog.entries[0].model.checksum, old.entries[0].model.checksum)
        XCTAssertEqual(FileModelRepository.namespace(f.descriptor.key), FileModelRepository.namespace(old.entries[0].key))
        for url in ["http://fixture.invalid/a", "https://u:p@fixture.invalid/a", "https:///", "ftp://fixture.invalid/a", "https://fixture.invalid/a#path", "https://fixture.invalid/a\n"] {
            XCTAssertThrowsError(try ModelDeliveryLocation(path: "a", httpsURL: url))
        }
        XCTAssertThrowsError(try ModelDeliveryLocation(path: "../a", httpsURL: "https://fixture.invalid/a"))
        XCTAssertThrowsError(try ModelDelivery(key: f.descriptor.key, locations: [f.delivery.locations[0], f.delivery.locations[0]]))
        XCTAssertThrowsError(try BundledModelCatalog(entries: [f.descriptor], deliveries: [ModelDelivery(key: f.descriptor.key, locations: [f.delivery.locations[0]])]))
        XCTAssertThrowsError(try BundledModelCatalog(entries: [], deliveries: [f.delivery]))
        XCTAssertThrowsError(try BundledModelCatalog(entries: [f.descriptor], deliveries: [f.delivery, f.delivery]))
        let bad = Data("{\"path\":\"a\",\"httpsURL\":\"https://fixture.invalid/a\",\"byteCount\":0}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ModelDeliveryLocation.self, from: bad))
        XCTAssertThrowsError(try JSONDecoder().decode(BundledModelCatalog.self, from: Data("{\"schemaVersion\":2}".utf8)))
        let failure = ModelDownloadFailure(code: .transport, transportCode: -1005, cleanup: .ownership)
        XCTAssertEqual(try JSONDecoder().decode(ModelDownloadFailure.self, from: JSONEncoder().encode(failure)), failure)
    }
    func testConstructionPendingInventoryAndBundleCatalogAreInert() async throws {
        let f = try DownloadFixture(); let count = DownloadTestCounter(); let r = f.repository(); let service = f.service(repository: r, counter: count)
        let pending = try await service.pending(); XCTAssertTrue(pending.isEmpty)
        let inventory = try await r.inventory(); XCTAssertTrue(inventory.isEmpty)
        let catalog = try await r.catalog(); XCTAssertEqual(catalog, f.catalog)
        do { _ = try await r.validate(f.descriptor.key); XCTFail() } catch {}
        let production = try BundledModelCatalogLoader().load()
        XCTAssertEqual(production.entries.count, 1)
        XCTAssertEqual(production.deliveries.map(\.key), production.entries.map(\.key))
        XCTAssertEqual(count.value, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: f.downloads.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.path))
    }
    func testCapacityBoundaryUnknownOverflowAndAdmissionBeforeTransport() async throws {
        let f = try DownloadFixture(); let count = DownloadTestCounter()
        let sum = f.descriptor.files.reduce(Int64(0)) { $0 + $1.byteCount }
        let needed = 3 * sum + ModelDownloadCapacity.safetyBytes
        for available: Int64? in [nil, needed - 1] {
            let service = f.service(capacity: available, counter: count)
            await expect(available == nil ? .capacityUnknown : .insufficientCapacity) { _ = try await service.start(f.descriptor.key) }
        }
        XCTAssertEqual(count.value, 0)
        let exact = try ModelDownloadCapacity.assess(lengths: [10,20], completed: 10, available: 80 + ModelDownloadCapacity.safetyBytes)
        XCTAssertTrue(exact.sufficient); XCTAssertEqual(exact.requiredAdditionalBytes, 80 + ModelDownloadCapacity.safetyBytes)
        for lengths in [[Int64.max,1], [Int64.max / 2], [-1]] {
            XCTAssertThrowsError(try ModelDownloadCapacity.assess(lengths: lengths, completed: 0, available: Int64.max))
        }
        XCTAssertThrowsError(try ModelDownloadCapacity.assess(lengths: [1], completed: 2, available: Int64.max))
        _ = try await installed(f.service(capacity: needed, counter: count), f.descriptor.key)
        XCTAssertEqual(count.value, 2)
    }
    func testRealURLSessionNestedPackageInstallsAndFreshRepositoryResolvesOffline() async throws {
        let f = try DownloadFixture(); let server = try DownloadHTTPServer(payloads: f.payloads); defer { server.stop() }
        let config = server.configuration()
        let service = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
            transportFactory: { id in URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: id), configuration: config) })
        let s = try await installed(service, f.descriptor.key)
        XCTAssertEqual(s.result?.manifest.origin, .bundledCatalog); XCTAssertNil(s.result?.warning)
        XCTAssertEqual(server.requests.count, 2)
        server.stop(); try FileManager.default.removeItem(at: f.source)
        let fresh = f.repository(); try await f.assertInstalled(fresh)
        let digest = try await fresh.withResolvedPackage(f.descriptor.key) { dir, descriptor in
            let pair = try await dir.hash(descriptor.files[0].path, chunk: {}); return pair.1
        }
        XCTAssertEqual(digest, f.descriptor.files[0].sha256)
        let pending = try await service.pending(); XCTAssertEqual(pending, [])
        let late = try await service.snapshot(s.id); XCTAssertEqual(late, s)
    }
    func testRealURLSessionPauseFreshServiceResumeUsesRangeAndEarlierBytes() async throws {
        var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 37, count: 2_097_152))
        let f = try DownloadFixture(payloads: ["Native/weights.bin": bytes])
        let server = try DownloadHTTPServer(payloads: f.payloads, slow: true); defer { server.stop() }
        let observed = XCTestExpectation(description: "URLSession acknowledged received prefix")
        let once = DownloadTestCounter(); let positiveBytes = DownloadTestCounter()
        var config = server.configuration()
        config.observedProgress = { p in if p.bytes > 0 { positiveBytes.increment() } }
        let configValue = config
        func service() -> ModelDownloadService {
            ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
                hooks: .init(visit: { point in
                    if point == .progressObserved, positiveBytes.value > 0, once.value == 0 { once.increment(); observed.fulfill() }
                }), transportFactory: { id in URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: id), configuration: configValue) })
        }
        let first = service(); let id = try await first.start(f.descriptor.key)
        guard await XCTWaiter.fulfillment(of: [observed], timeout: 10) == .completed else {
            server.releaseBody(); _ = try? await first.cancel(id); XCTFail("No acknowledged prefix"); return
        }
        let paused = try await first.pause(id); server.releaseBody()
        XCTAssertEqual(paused.phase, .paused); XCTAssertTrue(paused.resumable)
        let (_, _, journal) = try f.storage.read(id)
        XCTAssertNotNil(journal.resumeData); XCTAssertGreaterThan(paused.completedBytes, 0)
        let fresh = service(); let pending = try await fresh.pending(); XCTAssertEqual(pending.count, 1)
        let before = server.requests.count; XCTAssertEqual(before, 1)
        try await fresh.resume(id); let result = try await fresh.wait(id)
        XCTAssertEqual(result.phase, .installed, "\(String(describing: result.failure))")
        XCTAssertGreaterThan(result.resumedOffset, 0); XCTAssertFalse(result.restartedFromZero)
        XCTAssertTrue(server.requests.contains { ($0.range ?? 0) > 0 })
        XCTAssertEqual(server.requests.filter { $0.path == "/Native/weights.bin" }.count, 2)
        try await f.assertInstalled(f.repository())
    }
    func testBackgroundConfigurationAndReconnectReusesExistingTaskAssociation() async throws {
        let id = ModelDownloadID(); let identifier = URLSessionModelTransport.identifier(for: id)
        let background = ModelTransportConfiguration().make(identifier)
        XCTAssertEqual(background.identifier, identifier); XCTAssertFalse(background.isDiscretionary); XCTAssertFalse(background.sessionSendsLaunchEvents)
        // Construct/close the real production background session with no tasks. This
        // proves the factory/configuration, not daemon continuation or relaunch.
        let production = URLSessionModelTransport(identifier: identifier); await production.close()
        var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 41, count: 524_288))
        let f = try DownloadFixture(payloads: ["a.bin": bytes])
        let expected = Int64(bytes.count)
        let server = try DownloadHTTPServer(payloads: f.payloads, slow: true); defer { server.stop() }
        var c = server.configuration()
        c.created = { session in
            let t = session.downloadTask(with: URL(string: "http://127.0.0.1:\(server.port)/a.bin")!)
            t.taskDescription = "stable-original-association"; t.resume()
        }
        let adapter = URLSessionModelTransport(identifier: identifier, configuration: c)
        let association = DownloadTestCounter()
        let live = await XCTWaiter.fulfillment(of: [server.prefixSent], timeout: 10)
        XCTAssertEqual(live, .completed)
        let attached = XCTestExpectation(description: "reconnected existing live task")
        let job = Task {
            await adapter.transfer(.init(association: "new-generation", previousAssociation: "stable-original-association",
                url: URL(string: "https://fixture.invalid/a.bin")!, expectedBytes: expected, resumeData: nil), associated: { tag in
                    XCTAssertEqual(tag, "stable-original-association"); association.increment(); attached.fulfill()
                }, progress: { _ in })
        }
        let reconnected = await XCTWaiter.fulfillment(of: [attached], timeout: 10)
        XCTAssertEqual(reconnected, .completed); server.releaseBody()
        let result = await job.value; await adapter.close()
        XCTAssertTrue(result.reconnected)
        XCTAssertNil(result.failure); XCTAssertNotNil(result.receipt); XCTAssertEqual(server.requests.count, 1); XCTAssertEqual(association.value, 1)
    }
    func testRealHTTPFailuresRedirectAndDestinationByteVerification() async throws {
        for status in [404,500] {
            let f = try DownloadFixture(); let server = try DownloadHTTPServer(payloads: f.payloads, status: status); defer { server.stop() }
            let config = server.configuration()
            let service = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
                transportFactory: { id in URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: id), configuration: config) })
            let id = try await service.start(f.descriptor.key); let result = try await service.wait(id)
            XCTAssertEqual(result.phase, .failed); XCTAssertEqual(result.failure?.code, .httpStatus); XCTAssertEqual(result.failure?.httpStatus, status)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
        }
        let f = try DownloadFixture(); let server = try DownloadHTTPServer(payloads: f.payloads, redirect: "http://example.invalid/weights"); defer { server.stop() }
        let config = server.configuration()
        let service = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
            transportFactory: { id in URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: id), configuration: config) })
        let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
        XCTAssertEqual(s.failure?.code, .redirectRejected); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
    }
    func testWrongLengthHashFormatAndUnavailableValidatorNeverInstall() async throws {
        for variant in 0..<5 {
            let f = try DownloadFixture(); var data = f.payloads
            let path = f.descriptor.files[0].path
            if variant == 0 { data[path] = Data("short".utf8) }
            if variant == 1 { data[path]!.append(1) }
            if variant == 2 { data[path]![0] ^= 1 }
            let payloads = data
            let r = f.repository(validator: DownloadTestValidator(code: variant == 3 ? .incompatible : variant == 4 ? .validationUnavailable : nil))
            let service = f.service(repository: r, transport: { FixtureTransport(payloads: payloads) })
            let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
            XCTAssertEqual(s.phase, .failed); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
            XCTAssertNil(s.failure?.cleanup)
            let inventory = try await r.inventory(); XCTAssertTrue(inventory.isEmpty)
        }
    }
    func testCancellationAcrossServiceAndInstallerGatesAndLateTerminal() async throws {
        for point in [ModelDownloadPoint.beforeRequest, .journal, .receipt, .copyChunk, .beforeInstall] {
            let f = try DownloadFixture(); let gate = DownloadGate()
            let stoppedSignal = XCTestExpectation(description: "cancel command acknowledged")
            let service = f.service(hooks: .init(visit: { if $0 == point { await gate.hold() }; if $0 == .stopRequested { stoppedSignal.fulfill() } }))
            let id = try await service.start(f.descriptor.key)
            do {
                try await gate.wait()
                let cancellation = Task { try await service.cancel(id) }
                let stopped = await XCTWaiter.fulfillment(of: [stoppedSignal], timeout: 10)
                XCTAssertEqual(stopped, .completed)
                await gate.release()
                let s = try await cancellation.value
                XCTAssertEqual(s.phase, .cancelled); XCTAssertNil(s.failure?.cleanup)
                let late = try await service.wait(id); XCTAssertEqual(late, s)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
            } catch { await gate.release(); _ = try? await service.cancel(id); throw error }
        }
        for point in [ModelRepositoryPoint.hashChunk, .manifestWrite, .beforePublish, .afterPublish] {
            let f = try DownloadFixture(); let gate = DownloadGate()
            let r = f.repository(hooks: .init(visit: { if $0 == point { await gate.hold() } }))
            let stoppedSignal = XCTestExpectation(description: "installer cancel acknowledged")
            let service = f.service(repository: r, hooks: .init(visit: { if $0 == .stopRequested { stoppedSignal.fulfill() } })); let id = try await service.start(f.descriptor.key)
            do {
                try await gate.wait()
                let cancellation = Task { try await service.cancel(id) }
                let stopped = await XCTWaiter.fulfillment(of: [stoppedSignal], timeout: 10)
                XCTAssertEqual(stopped, .completed)
                await gate.release()
                let s = try await cancellation.value
                if point == .afterPublish {
                    XCTAssertEqual(s.phase, .installed); XCTAssertEqual(s.result?.warning, .cancelled)
                    try await f.assertInstalled(f.repository())
                } else { XCTAssertEqual(s.phase, .cancelled); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path)) }
            } catch { await gate.release(); _ = try? await service.cancel(id); throw error }
        }
    }
}

extension ModelDownloadTests {
    private func pauseBetweenPayloads(_ f: DownloadFixture) async throws -> (ModelDownloadService, ModelDownloadID) {
        let gate = DownloadGate(); let requests = DownloadTestCounter()
        let stopped = XCTestExpectation(description: "pause acknowledged")
        let service = f.service(hooks: .init(visit: { point in
            if point == .beforeRequest { requests.increment(); if requests.value == 2 { await gate.hold() } }
            if point == .stopRequested { stopped.fulfill() }
        }))
        let id = try await service.start(f.descriptor.key)
        do {
            try await gate.wait()
            let pause = Task { try await service.pause(id) }
            let ack = await XCTWaiter.fulfillment(of: [stopped], timeout: 10); XCTAssertEqual(ack, .completed)
            await gate.release(); let result = try await pause.value
            XCTAssertEqual(result.phase, .paused); XCTAssertTrue(result.resumable)
            return (service, id)
        } catch { await gate.release(); _ = try? await service.cancel(id); throw error }
    }
    func testRetainedCompletedPayloadFreshInstanceAndCapacityAccounting() async throws {
        let f = try DownloadFixture(); let (_, id) = try await pauseBetweenPayloads(f)
        let (_, _, j) = try f.storage.read(id); XCTAssertEqual(j.completed.count, 1)
        let retainedBytes = f.descriptor.files.first { $0.path == j.completed[0] }!.byteCount
        let total = f.descriptor.files.reduce(Int64(0)) { $0 + $1.byteCount }
        let count = DownloadTestCounter()
        let tooSmall = f.service(capacity: 3 * total - retainedBytes + ModelDownloadCapacity.safetyBytes - 1, counter: count)
        await expect(.insufficientCapacity) { try await tooSmall.resume(id) }; XCTAssertEqual(count.value, 0)
        let fresh = f.service(capacity: 3 * total - retainedBytes + ModelDownloadCapacity.safetyBytes, counter: count)
        let pending = try await fresh.pending(); XCTAssertEqual(pending.count, 1); XCTAssertEqual(count.value, 0)
        try await fresh.resume(id); let result = try await fresh.wait(id)
        XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.generation, 2); XCTAssertEqual(count.value, 1)
        try await f.assertInstalled(f.repository())
    }
    func testNilCorruptAndRejectedResumeHaveOneTruthfulFallbackAndNoDuplicateStart() async throws {
        for variant in 0..<3 {
            let f = try DownloadFixture(); let (_, id) = try await pauseBetweenPayloads(f)
            let (dir, _, value) = try f.storage.read(id); var journal = value
            let remaining = f.descriptor.files.first { !journal.completed.contains($0.path) }!
            journal.activePath = remaining.path; journal.association = "prior-task"
            journal.resumeData = variant == 0 ? nil : Data("opaque-invalid-token".utf8)
            try f.storage.write(journal, directory: dir, expectedState: ModelFileStamp(try dir.info("state.json")))
            let count = DownloadTestCounter(); let payloads = f.payloads
            let fresh = f.service(counter: count, transport: {
                if variant > 0, count.value == 1 { return FixtureTransport(payloads: payloads, error: .init(code: .invalidResume, transportCode: -1000)) }
                if variant == 2 { return FixtureTransport(payloads: payloads, error: .init(code: .transport, transportCode: -1005)) }
                return FixtureTransport(payloads: payloads)
            })
            try await fresh.resume(id); let result = try await fresh.wait(id)
            XCTAssertTrue(result.restartedFromZero)
            XCTAssertEqual(count.value, variant == 0 ? 1 : 2)
            if variant == 2 { XCTAssertEqual(result.phase, .failed); XCTAssertEqual(result.resumeFailure?.code, .invalidResume); XCTAssertEqual(result.failure?.code, .transport) }
            else { XCTAssertEqual(result.phase, .installed); if variant == 1 { XCTAssertEqual(result.resumeFailure?.code, .invalidResume) } }
        }
    }
    func testCompletedBytesAndExactCatalogRecheckedBeforeResume() async throws {
        for variant in 0..<3 {
            let f = try DownloadFixture(); let (_, id) = try await pauseBetweenPayloads(f)
            let (_, payload, j) = try f.storage.read(id)
            let count = DownloadTestCounter()
            var catalog = f.catalog
            if variant == 0 {
                let url = payload.url.appendingPathComponent(j.completed[0]); var bytes = try Data(contentsOf: url); bytes[0] ^= 1; try bytes.write(to: url)
            } else if variant == 1 {
                let newDelivery = try ModelDelivery(key: f.descriptor.key, locations: f.delivery.locations.map { try .init(path: $0.path, httpsURL: "https://changed.invalid/" + $0.path) })
                catalog = try .init(entries: [f.descriptor], deliveries: [newDelivery])
            } else {
                try Data("unknown".utf8).write(to: payload.url.appendingPathComponent("unknown.bin"))
            }
            let fresh = f.service(repository: f.repository(catalog: catalog), counter: count)
            await expect(variant == 1 ? .resourceChanged : .ownership) { try await fresh.resume(id) }
            XCTAssertEqual(count.value, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.url.path))
        }
    }
    func testDownloadClaimsExcludeLocalImportValidationDeletionAndOtherDownloads() async throws {
        let f = try DownloadFixture(); let gate = DownloadGate()
        let r = f.repository(); let service = f.service(repository: r, hooks: .init(visit: { if $0 == .beforeRequest { await gate.hold() } }))
        let id = try await service.start(f.descriptor.key)
        do {
            try await gate.wait()
            let other = f.service()
            do { _ = try await other.start(f.descriptor.key); XCTFail() } catch let c as ModelDownloadFailure { XCTAssertEqual(c.code, .busy) }
            let source = await f.sources.register(f.source, start: { true }, stop: {})
            for operation in 0..<3 {
                do {
                    if operation == 0 { _ = try await f.repository().importPackage(from: source, descriptor: f.descriptor, origin: .suppliedLocal) }
                    if operation == 1 { _ = try await f.repository().prepareDeletion(f.descriptor.key) }
                    if operation == 2 { _ = try await f.repository().validate(f.descriptor.key) }
                    XCTFail("Claim must be exclusive")
                } catch let e as ModelOperationFailure { XCTAssertEqual(e.cause, .busy) }
            }
            await gate.release(); let result = try await service.wait(id); XCTAssertEqual(result.phase, .installed)
            let existing = try await installed(other, f.descriptor.key)
            XCTAssertEqual(existing.result?.disposition, .alreadyInstalled)
            try await f.assertInstalled(f.repository())
        } catch { await gate.release(); _ = try? await service.cancel(id); throw error }
    }
    func testCancelCleanupClaimBlocksRetryUntilAcknowledgedRelease() async throws {
        let f = try DownloadFixture(); let cleanup = DownloadGate()
        let service = f.service(hooks: .init(visit: { if $0 == .beforeRequest { throw ModelDownloadFailure(code: .transport, transportCode: -1005) }; if $0 == .cleanup { await cleanup.hold() } }))
        let id = try await service.start(f.descriptor.key)
        do {
            try await cleanup.wait()
            let other = f.service()
            do { _ = try await other.start(f.descriptor.key); XCTFail() } catch let c as ModelDownloadFailure { XCTAssertEqual(c.code, .busy) }
            await cleanup.release(); let failed = try await service.wait(id); XCTAssertEqual(failed.phase, .failed)
            let s = try await installed(other, f.descriptor.key)
            XCTAssertEqual(s.result?.disposition, .installed); try await f.assertInstalled(f.repository())
        } catch { await cleanup.release(); _ = try? await service.cancel(id); throw error }
    }
    func testDiskWriteManifestFlushAndPublishFaultsKeepFirstCauseAndReleaseClaims() async throws {
        for point in [ModelDownloadPoint.copyChunk, .journal] {
            let f = try DownloadFixture(); let service = f.service(hooks: .init(visit: {
                if $0 == point { throw ModelDownloadFailure(code: .diskWrite, transportCode: NSURLErrorCannotWriteToFile) }
            }))
            let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
            XCTAssertEqual(s.phase, .failed); XCTAssertEqual(s.failure?.code, .diskWrite)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
            _ = try await installed(f.service(), f.descriptor.key)
        }
        for point in [ModelRepositoryPoint.manifestWrite, .flush, .beforePublish, .afterPublish] {
            let f = try DownloadFixture()
            let service = f.service(repository: f.repository(hooks: .init(visit: { if $0 == point { throw ModelRepositoryCode.flushFailed } })))
            let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
            if point == .afterPublish { XCTAssertEqual(s.phase, .installed); XCTAssertEqual(s.result?.warning, .flushFailed); try await f.assertInstalled(f.repository()) }
            else { XCTAssertEqual(s.phase, .failed); XCTAssertEqual(s.failure?.repository?.cause, .flushFailed); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path)) }
        }
        let f = try DownloadFixture()
        let service = f.service(hooks: .init(visit: {
            if $0 == .beforeRequest { throw ModelDownloadFailure(code: .transport, transportCode: -1005) }
            if $0 == .cleanup { throw ModelDownloadFailure(code: .diskWrite) }
        }))
        let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
        XCTAssertEqual(s.failure?.code, .transport); XCTAssertEqual(s.failure?.transportCode, -1005); XCTAssertEqual(s.failure?.cleanup, .diskWrite)
        let pending = try await service.pending(); XCTAssertEqual(pending.count, 1)
    }
    func testPostCommitCleanupFailureRetainsInstallAndExplicitRetryReconcilesStaleJournal() async throws {
        let f = try DownloadFixture(); let gate = DownloadGate()
        let service = f.service(hooks: .init(visit: { if $0 == .cleanup { await gate.hold(); throw ModelDownloadFailure(code: .cleanup) } }))
        let id = try await service.start(f.descriptor.key)
        do {
            try await gate.wait()
            // Claim is still held while the installed model's transport state settles.
            do { _ = try await f.repository().validate(f.descriptor.key); XCTFail() } catch let e as ModelOperationFailure { XCTAssertEqual(e.cause, .busy) }
            await gate.release(); let s = try await service.wait(id)
            XCTAssertEqual(s.phase, .installed); XCTAssertEqual(s.result?.warning, .cleanupFailed)
            let count = DownloadTestCounter(); let fresh = f.service(counter: count)
            let pending = try await fresh.pending(); XCTAssertEqual(pending.count, 1); XCTAssertEqual(count.value, 0)
            let retry = try await fresh.retry(id); XCTAssertEqual(retry, id)
            let reconciled = try await fresh.wait(retry)
            XCTAssertEqual(reconciled.phase, .installed); XCTAssertEqual(reconciled.result?.disposition, .alreadyInstalled)
            XCTAssertEqual(count.value, 0); try await f.assertInstalled(f.repository())
            let empty = try await fresh.pending(); XCTAssertTrue(empty.isEmpty)
        } catch { await gate.release(); _ = try? await service.cancel(id); throw error }
    }
    func testUnknownFutureDamagedJournalAndCancelledPausedOperationArePreservedOrOwned() async throws {
        let f = try DownloadFixture(); let (_, id) = try await pauseBetweenPayloads(f)
        let futureID = ModelDownloadID(); let futureDir = f.downloads.appendingPathComponent(ModelDownloadStorage.name(futureID))
        try FileManager.default.createDirectory(at: futureDir.appendingPathComponent("payload"), withIntermediateDirectories: true)
        let future = Data("{\"schemaVersion\":2,\"newLayout\":true}".utf8)
        try future.write(to: futureDir.appendingPathComponent("state.json"))
        let unknown = f.downloads.appendingPathComponent("unknown"); try Data("sentinel".utf8).write(to: unknown)
        let damagedID = ModelDownloadID(); let damaged = f.downloads.appendingPathComponent(ModelDownloadStorage.name(damagedID))
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        let count = DownloadTestCounter(); let fresh = f.service(counter: count)
        let pending = try await fresh.pending()
        XCTAssertEqual(pending.count, 4); XCTAssertEqual(pending.filter { $0.issue != nil }.count, 3); XCTAssertEqual(count.value, 0)
        await expect(.unsupportedState) { try await fresh.resume(futureID) }
        let cancelled = try await fresh.cancel(id); XCTAssertEqual(cancelled.phase, .cancelled); XCTAssertNil(cancelled.failure?.cleanup)
        XCTAssertEqual(try Data(contentsOf: futureDir.appendingPathComponent("state.json")), future)
        XCTAssertEqual(try Data(contentsOf: unknown), Data("sentinel".utf8))
        let remaining = try await fresh.pending(); XCTAssertEqual(remaining.count, 3)
    }
}

extension ModelDownloadTests {
    func testReplacedDownloadRootPayloadAndStagingNeverTouchSentinels() async throws {
        for variant in 0..<4 {
            let f = try DownloadFixture(); let moved = f.root.appendingPathComponent("kept-original")
            let point: ModelDownloadPoint = variant < 2 ? .receipt : .beforeInstall
            let service = f.service(hooks: .init(visit: { p in
                guard p == point else { return }
                let target: URL
                if variant == 0 { target = f.downloads }
                else {
                    let op = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.downloads, includingPropertiesForKeys: nil).first)
                    target = variant == 1 ? op : op.appendingPathComponent("payload")
                }
                try FileManager.default.moveItem(at: target, to: moved)
                if variant == 3 {
                    let unrelated = f.root.appendingPathComponent("unrelated"); try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
                    try Data("sentinel".utf8).write(to: unrelated.appendingPathComponent("sentinel"))
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: unrelated)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    try Data("sentinel".utf8).write(to: target.appendingPathComponent("sentinel"))
                }
            }))
            let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
            XCTAssertEqual(s.phase, .failed); XCTAssertNotNil(s.failure?.cleanup)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
            if variant == 0 { XCTAssertEqual(try Data(contentsOf: f.downloads.appendingPathComponent("sentinel")), Data("sentinel".utf8)) }
            if variant == 3 { XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("unrelated/sentinel")), Data("sentinel".utf8)) }
        }
    }
    func testNestedOwnedPayloadReplacementAndCleanupReplacementAreConservative() async throws {
        for point in [ModelDownloadPoint.copyChunk, .cleanup] {
            let f = try DownloadFixture(); let moved = f.root.appendingPathComponent("kept-nested")
            let counter = DownloadTestCounter()
            let service = f.service(hooks: .init(visit: { p in
                if p == .beforeInstall && point == .cleanup { throw ModelDownloadFailure(code: .transport, transportCode: -1005) }
                guard p == point, counter.value == 0 else { return }; counter.increment()
                let op = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.downloads, includingPropertiesForKeys: nil).first)
                let nested = op.appendingPathComponent("payload/Native")
                try FileManager.default.moveItem(at: nested, to: moved)
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                try Data("sentinel".utf8).write(to: nested.appendingPathComponent("sentinel"))
            }))
            let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
            XCTAssertEqual(s.phase, .failed); XCTAssertNotNil(s.failure?.cleanup)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
            let op = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.downloads, includingPropertiesForKeys: nil).first)
            XCTAssertEqual(try Data(contentsOf: op.appendingPathComponent("payload/Native/sentinel")), Data("sentinel".utf8))
        }
    }
    func testFinalCollisionStagingSwapAndVerifiedPayloadMutationRejectPublication() async throws {
        for variant in 0..<3 {
            let f = try DownloadFixture()
            let r = f.repository(hooks: .init(visit: { p in
                if variant == 0, p == .beforePublish {
                    try FileManager.default.createDirectory(at: f.installed, withIntermediateDirectories: true)
                    try Data("sentinel".utf8).write(to: f.installed.appendingPathComponent("sentinel"))
                }
                if variant > 0, p == .manifestWrite {
                    let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.store, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".operation-") })
                    if variant == 1 {
                        try FileManager.default.moveItem(at: stage, to: f.root.appendingPathComponent("kept-stage"))
                        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                        try Data("sentinel".utf8).write(to: stage.appendingPathComponent("sentinel"))
                    } else {
                        let path = stage.appendingPathComponent(f.descriptor.files[0].path)
                        var bytes = try Data(contentsOf: path); bytes[0] ^= 1; try bytes.write(to: path)
                    }
                }
            }))
            let service = f.service(repository: r); let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
            XCTAssertEqual(s.phase, .failed)
            XCTAssertEqual(s.failure?.repository?.cause, variant == 0 ? .collision : .identityChanged)
            if variant == 0 { XCTAssertEqual(try Data(contentsOf: f.installed.appendingPathComponent("sentinel")), Data("sentinel".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path)) }
            for (path, data) in f.payloads { XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(path)), data) }
        }
    }
    func testPostCommitReplacementDuringTransportCleanupKeepsOriginalAndReplacement() async throws {
        let f = try DownloadFixture(); let original = f.root.appendingPathComponent("kept-installed")
        let service = f.service(hooks: .init(visit: { p in
            if p == .cleanup {
                try FileManager.default.moveItem(at: f.installed, to: original)
                try FileManager.default.createDirectory(at: f.installed, withIntermediateDirectories: true)
                try Data("sentinel".utf8).write(to: f.installed.appendingPathComponent("sentinel"))
            }
        }))
        let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
        XCTAssertEqual(s.phase, .installed); XCTAssertEqual(s.result?.warning, .identityChanged)
        XCTAssertEqual(try Data(contentsOf: f.installed.appendingPathComponent("sentinel")), Data("sentinel".utf8))
        for (path, data) in f.payloads { XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent(path)), data) }
    }
    func testExistingCorruptInstallIsNeverRepairedAndRevisionsCoexist() async throws {
        let f = try DownloadFixture(); let sibling = try DownloadFixture(revision: "r/2")
        let catalog = try BundledModelCatalog(entries: [f.descriptor, sibling.descriptor], deliveries: [f.delivery, sibling.delivery])
        let first = f.repository(catalog: catalog)
        _ = try await installed(f.service(repository: first), f.descriptor.key)
        let other = FileModelRepository(storeURL: { f.store }, sources: sibling.sources, validator: DownloadTestValidator(),
                                       references: DownloadTestReferences(), catalogLoader: .init(load: { catalog }))
        _ = try await installed(sibling.service(repository: other), sibling.descriptor.key)
        let namespace = FileModelRepository.namespace(sibling.descriptor.key).reduce(f.store) { $0.appendingPathComponent($1) }
        let siblingBytes = try Data(contentsOf: namespace.appendingPathComponent(sibling.descriptor.files[0].path))
        let path = f.installed.appendingPathComponent(f.descriptor.files[0].path)
        let corrupt = Data("corrupt".utf8); try corrupt.write(to: path)
        let count = DownloadTestCounter(); let service = f.service(repository: first, counter: count)
        let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
        XCTAssertEqual(s.phase, .failed); XCTAssertEqual(count.value, 0)
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
        XCTAssertEqual(try Data(contentsOf: namespace.appendingPathComponent(sibling.descriptor.files[0].path)), siblingBytes)
        let e = try await other.validate(sibling.descriptor.key); XCTAssertEqual(e.state, .usable)
    }
}

extension ModelDownloadTests {
    func testActualDelegateReceiptLifetimeDuplicateOutOfOrderAndErrorSettlement() async throws {
        for variant in 0..<4 {
            var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 31, count: 524_288))
            let server = try DownloadHTTPServer(payloads: ["weights.bin": bytes], slow: true); defer { server.stop() }
            let probe = DownloadSessionProbe(); let attached = XCTestExpectation(description: "delegate continuation attached")
            var config = server.configuration()
            config.created = { session in
                let task = session.downloadTask(with: URL(string: "http://127.0.0.1:\(server.port)/weights.bin")!)
                task.taskDescription = "original"; probe.record(session, task: task); task.resume()
            }
            let adapter = URLSessionModelTransport(identifier: UUID().uuidString, configuration: config)
            let progress = DownloadTestCounter()
            let expectedBytes = Int64(bytes.count)
            let transfer = Task {
                await adapter.transfer(.init(association: "next", previousAssociation: "original", url: URL(string: "https://fixture.invalid/weights.bin")!,
                    expectedBytes: expectedBytes, resumeData: nil), associated: { _ in attached.fulfill() }, progress: { _ in progress.increment() })
            }
            let acknowledged = await XCTWaiter.fulfillment(of: [attached, server.prefixSent], timeout: 10)
            guard acknowledged == .completed else {
                let (_, task) = try probe.get(); task.cancel(); server.releaseBody(); _ = await transfer.value; await adapter.close(); XCTFail("HTTP/delegate handshake missing"); continue
            }
            let (session, task) = try probe.get()
            // Deliberately coalescible and out-of-order callbacks exercise the
            // production delegate's bounded progress owner, not timing quotas.
            for value in stride(from: 0, through: bytes.count, by: 257) {
                adapter.urlSession(session, downloadTask: task, didWriteData: 257,
                                   totalBytesWritten: Int64(value), totalBytesExpectedToWrite: Int64(bytes.count))
            }
            adapter.urlSession(session, downloadTask: task, didWriteData: 0, totalBytesWritten: 0, totalBytesExpectedToWrite: Int64(bytes.count))
            let tmp = URL(fileURLWithPath: "/private/tmp/stt-t13-delegate-" + UUID().uuidString)
            try Data("STT-TEST receipt".utf8).write(to: tmp)
            if variant != 0 && variant != 3 {
                adapter.urlSession(session, downloadTask: task, didFinishDownloadingTo: tmp)
                adapter.urlSession(session, downloadTask: task, didFinishDownloadingTo: tmp) // duplicate receipt
            }
            try FileManager.default.removeItem(at: tmp) // callback has returned; URL is gone
            let error: Error? = variant < 2 ? NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost) : nil
            adapter.urlSession(session, task: task, didCompleteWithError: error)
            adapter.urlSession(session, task: task, didCompleteWithError: nil)
            adapter.urlSession(session, downloadTask: task, didFinishDownloadingTo: tmp) // late callback cannot revive
            let result = await transfer.value
            let beforeLate = progress.value
            adapter.urlSession(session, downloadTask: task, didWriteData: 1, totalBytesWritten: Int64(bytes.count), totalBytesExpectedToWrite: Int64(bytes.count))
            XCTAssertEqual(progress.value, beforeLate)
            task.cancel(); server.releaseBody(); await adapter.close()
            if variant < 2 { XCTAssertEqual(result.failure?.transportCode, NSURLErrorNetworkConnectionLost); XCTAssertNil(result.receipt) }
            if variant == 3 { XCTAssertEqual(result.failure?.code, .receiptMissing) }
            if variant == 2 {
                XCTAssertNil(result.failure)
                let f = try DownloadFixture(payloads: ["a.bin": Data("STT-TEST receipt".utf8)])
                let directory = try ModelPackageDirectory(url: f.root.appendingPathComponent("receipt-copy"), create: true)
                try await XCTUnwrap(result.receipt).copy(to: directory, path: "a.bin", expected: 16, owned: .init(), chunk: {})
                XCTAssertEqual(try directory.readMetadata("a.bin"), Data("STT-TEST receipt".utf8))
            }
            XCTAssertLessThanOrEqual(progress.value, 66)
        }
        let disk = URLSessionModelTransport.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile))
        XCTAssertEqual(disk.transportCode, NSURLErrorCannotWriteToFile); XCTAssertEqual(disk.code, .diskWrite)
    }
}

extension ModelDownloadTests {
    func testRealRangeNonSupportAndChangedResourceNeverAppendFullBodyToPartial() async throws {
        for changed in [false, true] {
            var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 77, count: 1_048_576))
            let f = try DownloadFixture(payloads: ["weights.bin": bytes])
            let server = try DownloadHTTPServer(payloads: f.payloads, slow: true, ignoreRange: true, changedOnRange: changed); defer { server.stop() }
            let received = XCTestExpectation(description: "download prefix received")
            let once = DownloadTestCounter(); let positiveBytes = DownloadTestCounter()
            var config = server.configuration()
            config.observedProgress = { p in if p.bytes > 0 { positiveBytes.increment() } }
            let value = config
            let factory: @Sendable (ModelDownloadID) -> any ModelDownloadTransport = {
                URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: $0), configuration: value)
            }
            let service = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
                hooks: .init(visit: { point in
                    if point == .progressObserved, positiveBytes.value > 0, once.value == 0 { once.increment(); received.fulfill() }
                }), transportFactory: factory)
            let id = try await service.start(f.descriptor.key)
            let ack = await XCTWaiter.fulfillment(of: [received], timeout: 10)
            guard ack == .completed else { server.releaseBody(); _ = try? await service.cancel(id); XCTFail(); continue }
            let paused = try await service.pause(id); server.releaseBody(); XCTAssertTrue(paused.resumable)
            let fresh = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }), transportFactory: factory)
            try await fresh.resume(id); let s = try await fresh.wait(id)
            XCTAssertEqual(s.resumedOffset, 0); XCTAssertTrue(s.restartedFromZero)
            XCTAssertTrue(server.requests.contains { ($0.range ?? 0) > 0 })
            if changed { XCTAssertEqual(s.phase, .failed); XCTAssertEqual(s.failure?.repository?.cause, .integrityMismatch); XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path)) }
            else { XCTAssertEqual(s.phase, .installed); try await f.assertInstalled(f.repository()) }
        }
    }
    func testCapacityProviderFailureIsTypedAndDoesNotCreateSession() async throws {
        let f = try DownloadFixture(); let counter = DownloadTestCounter()
        let service = ModelDownloadService(repository: f.repository(), storage: f.storage,
            capacity: .init(available: { _ in throw ModelDownloadFailure(code: .capacityUnknown) }),
            transportFactory: { _ in counter.increment(); return FixtureTransport(payloads: f.payloads) })
        await expect(.capacityUnknown) { _ = try await service.start(f.descriptor.key) }
        XCTAssertEqual(counter.value, 0)
        let id = ModelDownloadID(); let s = ModelDownloadSnapshot(id: id, key: f.descriptor.key, generation: 1,
            phase: .failed, completedBytes: 0, totalBytes: 1, failure: .init(code: .transport, transportCode: -1005))
        XCTAssertEqual(try JSONDecoder().decode(ModelDownloadSnapshot.self, from: JSONEncoder().encode(s)), s)
    }
    func testExplicitRetryUsesNewAttemptAfterCleanFailureAndKeepsTerminalObservation() async throws {
        let f = try DownloadFixture(); let attempts = DownloadTestCounter()
        let service = f.service(counter: attempts, transport: {
            FixtureTransport(payloads: f.payloads, error: attempts.value == 1 ? .init(code: .transport, transportCode: -1005) : nil)
        })
        let id = try await service.start(f.descriptor.key); let failed = try await service.wait(id)
        XCTAssertEqual(failed.phase, .failed)
        let retry = try await service.retry(id); XCTAssertNotEqual(retry, id)
        let result = try await service.wait(retry); XCTAssertEqual(result.phase, .installed)
        let late = try await service.snapshot(id); XCTAssertEqual(late, failed)
        try await f.assertInstalled(f.repository())
    }
}

extension ModelDownloadTests {
    func testReplacedJournalCannotBeOverwrittenOrRemovedByOldAttempt() async throws {
        let f = try DownloadFixture(); let sentinel = Data("unknown replacement journal".utf8)
        let service = f.service(hooks: .init(visit: { p in
            if p == .receipt {
                let op = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.downloads, includingPropertiesForKeys: nil).first)
                let state = op.appendingPathComponent("state.json")
                try FileManager.default.moveItem(at: state, to: f.root.appendingPathComponent("kept-state.json"))
                try sentinel.write(to: state)
            }
        }))
        let id = try await service.start(f.descriptor.key); let s = try await service.wait(id)
        XCTAssertEqual(s.phase, .failed); XCTAssertEqual(s.failure?.code, .ownership); XCTAssertEqual(s.failure?.cleanup, .ownership)
        let op = f.downloads.appendingPathComponent(ModelDownloadStorage.name(id))
        XCTAssertEqual(try Data(contentsOf: op.appendingPathComponent("state.json")), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
    }
    func testRealTransportCorruptOpaqueResumeTokenFallsBackOnceWithoutRewritingToken() async throws {
        let f = try DownloadFixture(); let (_, id) = try await pauseBetweenPayloads(f)
        let (dir, _, old) = try f.storage.read(id); var journal = old
        let remaining = f.descriptor.files.first { !old.completed.contains($0.path) }!
        journal.activePath = remaining.path; journal.association = "old-task"
        journal.resumeData = Data("corrupt opaque token; never parsed or edited".utf8)
        try f.storage.write(journal, directory: dir, expectedState: ModelFileStamp(try dir.info("state.json")))
        let server = try DownloadHTTPServer(payloads: f.payloads); defer { server.stop() }
        let count = DownloadTestCounter(); let config = server.configuration()
        let fresh = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
            transportFactory: { id in count.increment(); return URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: id), configuration: config) })
        try await fresh.resume(id); let s = try await fresh.wait(id)
        XCTAssertEqual(s.phase, .installed); XCTAssertTrue(s.restartedFromZero); XCTAssertNotNil(s.resumeFailure)
        XCTAssertEqual(count.value, 2); XCTAssertEqual(server.requests.count, 1)
        try await f.assertInstalled(f.repository())
    }
}

extension ModelDownloadTests {
    func testActiveTransportCancelJoinsAndOldGenerationProgressCannotMutateExplicitResume() async throws {
        for discard in [false, true] {
            let f = try DownloadFixture(payloads: ["weights.bin": Data("STT-TEST weights".utf8)])
            let probe = DownloadProgressProbe(); let held = HeldDownloadTransport(probe: probe)
            let factories = DownloadTestCounter(); let requests = DownloadTestCounter(); let nextRequest = DownloadGate()
            let progressAck = XCTestExpectation(description: "stale progress handled by owner")
            let service = f.service(hooks: .init(visit: { p in
                if p == .beforeRequest { requests.increment(); if requests.value == 2 { await nextRequest.hold() } }
                if p == .progressObserved { progressAck.fulfill() }
            }), counter: factories, transport: { if factories.value == 1 { return held }; return FixtureTransport(payloads: f.payloads) })
            let id = try await service.start(f.descriptor.key)
            do {
                try await held.entered.wait()
                if discard {
                    let cancelled = try await service.cancel(id); XCTAssertEqual(cancelled.phase, .cancelled)
                    let pending = try await service.pending(); XCTAssertTrue(pending.isEmpty)
                    let closes = await held.closes; XCTAssertEqual(closes, 1)
                    _ = try await installed(f.service(), f.descriptor.key)
                } else {
                    let paused = try await service.pause(id); XCTAssertEqual(paused.phase, .paused); XCTAssertTrue(paused.resumable)
                    try await service.resume(id); try await nextRequest.wait()
                    probe.emit(.init(bytes: 15, resumedOffset: 12))
                    let ack = await XCTWaiter.fulfillment(of: [progressAck], timeout: 10); XCTAssertEqual(ack, .completed)
                    let snapshot = try await service.snapshot(id)
                    XCTAssertEqual(snapshot.generation, 2); XCTAssertEqual(snapshot.completedBytes, 0); XCTAssertEqual(snapshot.resumedOffset, 0)
                    await nextRequest.release(); let result = try await service.wait(id); XCTAssertEqual(result.phase, .installed)
                    let late = try await service.wait(id); XCTAssertEqual(late, result)
                    let closes = await held.closes; XCTAssertEqual(closes, 1)
                }
            } catch { await nextRequest.release(); _ = try? await service.cancel(id); throw error }
        }
    }
    func testRealHTTPTruncationOversizeAndWrongChecksumCannotPublish() async throws {
        for variant in 0..<3 {
            let f = try DownloadFixture(payloads: ["weights.bin": Data("STT-TEST payload".utf8)])
            var data = f.payloads
            if variant == 1 { data["weights.bin"]!.append(contentsOf: [1,2,3]) }
            if variant == 2 { data["weights.bin"]![0] ^= 1 }
            let server = try DownloadHTTPServer(payloads: data, declaredExtraBytes: variant == 0 ? 10 : 0); defer { server.stop() }
            let config = server.configuration()
            let service = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
                transportFactory: { id in URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: id), configuration: config) })
            let id = try await service.start(f.descriptor.key); let result = try await service.wait(id)
            XCTAssertTrue(result.phase == .failed || result.phase == .paused)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.installed.path))
            if variant == 0 { XCTAssertEqual(result.failure?.code, .transport) }
            if variant == 1 { XCTAssertEqual(result.failure?.code, .byteCount) }
            if variant == 2 { XCTAssertEqual(result.failure?.repository?.cause, .integrityMismatch) }
            if result.phase == .paused { _ = try await service.cancel(id) }
        }
    }
}

extension ModelDownloadTests {
    func testCancelDuringFreshResumeAdmissionCannotStartTransfer() async throws {
        let f = try DownloadFixture(); let (_, id) = try await pauseBetweenPayloads(f)
        let gate = DownloadGate(); let stopped = XCTestExpectation(description: "admission cancellation acknowledged")
        let counter = DownloadTestCounter()
        let fresh = f.service(hooks: .init(visit: { p in
            if p == .resumeAdmission { await gate.hold() }
            if p == .stopRequested { stopped.fulfill() }
        }), counter: counter)
        let resume = Task { try await fresh.resume(id) }
        do {
            try await gate.wait()
            let cancel = Task { try await fresh.cancel(id) }
            let ack = await XCTWaiter.fulfillment(of: [stopped], timeout: 10); XCTAssertEqual(ack, .completed)
            await gate.release(); try await resume.value
            let result = try await cancel.value
            XCTAssertEqual(result.phase, .cancelled); XCTAssertEqual(counter.value, 0)
            let pending = try await fresh.pending(); XCTAssertTrue(pending.isEmpty)
            _ = try await installed(f.service(), f.descriptor.key)
        } catch { await gate.release(); _ = try? await resume.value; _ = try? await fresh.cancel(id); throw error }
    }
}

extension ModelDownloadTests {
    func testSessionInvalidationSettlesWithoutReceiptOrNewNetworkTask() async throws {
        let f = try DownloadFixture(); let server = try DownloadHTTPServer(payloads: f.payloads); defer { server.stop() }
        let invalidated = XCTestExpectation(description: "actual session invalidation requested")
        var config = server.configuration()
        config.created = { session in session.invalidateAndCancel(); invalidated.fulfill() }
        let adapter = URLSessionModelTransport(identifier: UUID().uuidString, configuration: config)
        let acknowledged = await XCTWaiter.fulfillment(of: [invalidated], timeout: 10); XCTAssertEqual(acknowledged, .completed)
        // close joins Foundation's invalidation callback before admission.
        await adapter.close()
        let outcome = await adapter.transfer(.init(association: "never-start", previousAssociation: nil,
            url: URL(string: "https://fixture.invalid/config.bin")!, expectedBytes: 1, resumeData: nil), associated: { _ in XCTFail("No task allowed after invalidation") }, progress: { _ in XCTFail() })
        XCTAssertEqual(outcome.failure?.code, .transport); XCTAssertNil(outcome.receipt); XCTAssertTrue(server.requests.isEmpty)
    }
}

extension ModelDownloadTests {
    func testDownloadExistingValidationClaimBlocksPreviouslyConfirmedDeletion() async throws {
        let f = try DownloadFixture(); let r = f.repository()
        _ = try await installed(f.service(repository: r), f.descriptor.key)
        let assessment = try await r.prepareDeletion(f.descriptor.key)
        let gate = DownloadGate()
        let downloading = f.service(repository: f.repository(hooks: .init(visit: { if $0 == .hashChunk { await gate.hold() } })))
        let id = try await downloading.start(f.descriptor.key)
        do {
            try await gate.wait()
            do {
                _ = try await r.delete(assessment, confirmation: .init(assessmentID: assessment.id, acknowledgeReferences: true, acknowledgeIncompleteCoverage: true))
                XCTFail("Confirmed deletion must respect download's claim")
            } catch let e as ModelOperationFailure { XCTAssertEqual(e.cause, .busy) }
            await gate.release(); let result = try await downloading.wait(id)
            XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.result?.disposition, .alreadyInstalled)
            try await f.assertInstalled(r)
        } catch { await gate.release(); _ = try? await downloading.cancel(id); throw error }
    }
}

// Same-Task review regressions reproduced against 0665f32 before these repairs.
extension ModelDownloadTests {
    func testReviewPauseDuringOwnedCopyMustResumeWithoutDiscardingCompletedPayload() async throws {
        var large = Data("STT-TEST".utf8); large.append(Data(repeating: 71, count: 300_000))
        let f = try DownloadFixture(payloads: ["Config/a.bin": Data("STT-TEST first".utf8), "Native/z.bin": large])
        let gate = DownloadGate(); let chunks = DownloadTestCounter()
        let stop = XCTestExpectation(description: "pause during partial owned copy acknowledged")
        let service = f.service(hooks: .init(visit: { point in
            if point == .copyChunk { chunks.increment(); if chunks.value == 3 { await gate.hold() } }
            if point == .stopRequested { stop.fulfill() }
        }))
        let id = try await service.start(f.descriptor.key)
        do {
            try await gate.wait()
            let pausing = Task { try await service.pause(id) }
            let ack = await XCTWaiter.fulfillment(of: [stop], timeout: 10); XCTAssertEqual(ack, .completed)
            await gate.release(); let paused = try await pausing.value
            let (_, payload, journal) = try f.storage.read(id)
            XCTAssertEqual(paused.phase, .paused); XCTAssertTrue(paused.resumable)
            XCTAssertEqual(journal.completed, ["Config/a.bin"])
            let partial = try payload.child("Native").info("z.bin").st_size
            XCTAssertGreaterThan(partial, 0); XCTAssertLessThan(partial, Int64(large.count))
            print("REVIEW partial-copy: resumable=\(paused.resumable), completed=\(journal.completed), partial=\(partial)")
            let factories = DownloadTestCounter(); let fresh = f.service(counter: factories)
            do {
                try await fresh.resume(id)
                let result = try await fresh.wait(id); XCTAssertEqual(result.phase, .installed)
                XCTAssertTrue(result.restartedFromZero); XCTAssertEqual(factories.value, 1)
                try await f.assertInstalled(f.repository())
            } catch { XCTFail("Explicit resume rejected its proven owned partial file: \(error)") }
            _ = try? await fresh.cancel(id)
        } catch { await gate.release(); _ = try? await service.cancel(id); throw error }
    }
    func testReviewPublicRetryMustReconcileOriginalCommittedStaleJournal() async throws {
        let f = try DownloadFixture()
        let service = f.service(hooks: .init(visit: { if $0 == .cleanup { throw ModelDownloadFailure(code: .cleanup) } }))
        let id = try await service.start(f.descriptor.key); let committed = try await service.wait(id)
        XCTAssertEqual(committed.phase, .installed); XCTAssertEqual(committed.result?.warning, .cleanupFailed)
        let count = DownloadTestCounter(); let fresh = f.service(counter: count)
        let retriedID = try await fresh.retry(id); let reconciled = try await fresh.wait(retriedID)
        XCTAssertEqual(reconciled.phase, .installed); XCTAssertEqual(reconciled.result?.disposition, .alreadyInstalled)
        let pending = try await fresh.pending()
        print("REVIEW retry: old=\(id.rawValue), new=\(retriedID.rawValue), remaining=\(pending.map { $0.operation?.rawValue.uuidString ?? "unknown" }), transfers=\(count.value)")
        XCTAssertEqual(retriedID, id)
        XCTAssertTrue(pending.isEmpty, "Public retry left its original fully owned stale journal/payload behind")
        XCTAssertEqual(count.value, 0); try await f.assertInstalled(f.repository())
    }
    func testReviewFreshCancelMustSettlePersistedLiveTransferBeforeCleanCancellation() async throws {
        var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 23, count: 524_288))
        let f = try DownloadFixture(payloads: ["weights.bin": bytes])
        let gate = DownloadGate(); let stopped = XCTestExpectation(description: "seed pending record without live process claim")
        let seed = f.service(hooks: .init(visit: {
            if $0 == .beforeRequest { await gate.hold() }
            if $0 == .stopRequested { stopped.fulfill() }
        }))
        let id = try await seed.start(f.descriptor.key)
        do {
            try await gate.wait()
            let pausing = Task { try await seed.pause(id) }
            let ack = await XCTWaiter.fulfillment(of: [stopped], timeout: 10); XCTAssertEqual(ack, .completed)
            await gate.release(); _ = try await pausing.value
        } catch { await gate.release(); _ = try? await seed.cancel(id); throw error }
        let (dir, _, old) = try f.storage.read(id); var journal = old
        journal.association = "persisted-surviving-transfer"; journal.activePath = "weights.bin"; journal.snapshot.phase = .transferring
        try f.storage.write(journal, directory: dir, expectedState: ModelFileStamp(try dir.info("state.json")))
        let server = try DownloadHTTPServer(payloads: f.payloads, slow: true); defer { server.stop() }
        let probe = DownloadSessionProbe(); var config = server.configuration()
        config.created = { session in
            let task = session.downloadTask(with: URL(string: "http://127.0.0.1:\(server.port)/weights.bin")!)
            task.taskDescription = "persisted-surviving-transfer"; probe.record(session, task: task); task.resume()
        }
        let adapter = URLSessionModelTransport(identifier: URLSessionModelTransport.identifier(for: id), configuration: config)
        let (_, task) = try probe.get()
        let ack = await XCTWaiter.fulfillment(of: [server.prefixSent], timeout: 10)
        guard ack == .completed else { task.cancel(); server.releaseBody(); await adapter.close(); XCTFail("No live transfer"); return }
        let count = DownloadTestCounter()
        let fresh = ModelDownloadService(repository: f.repository(), storage: f.storage, capacity: .init(available: { _ in Int64.max }),
            transportFactory: { _ in count.increment(); return adapter })
        do {
            let cancelled = try await fresh.cancel(id)
            let remaining = try await fresh.pending()
            print("REVIEW fresh-cancel: phase=\(cancelled.phase), cleanup=\(String(describing: cancelled.failure?.cleanup)), transportFactoryCalls=\(count.value), taskState=\(task.state.rawValue), remainingJournals=\(remaining.count)")
            XCTAssertEqual(cancelled.phase, .cancelled); XCTAssertNil(cancelled.failure?.cleanup)
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertNotEqual(task.state, .running, "Clean cancellation returned while original URLSession task is still running")
            XCTAssertGreaterThan(count.value, 0, "Fresh cancellation never reconciled the persisted session/task association")
            XCTAssertEqual(server.requests.count, 1, "Cancel may not create or resume another request")
        } catch { XCTFail("Unexpected fresh cancel failure: \(error)") }
        task.cancel(); server.releaseBody(); await adapter.close()
    }
}

extension ModelDownloadTests {
    func testReviewFreshCancelKeepsClaimAndOwnershipThroughDiscardAwait() async throws {
        for variant in 0..<4 {
            let f = try DownloadFixture(); let (_, id) = try await pauseBetweenPayloads(f)
            let (dir, _, old) = try f.storage.read(id); var journal = old
            journal.association = "original-transfer"; journal.activePath = f.descriptor.files.first { !old.completed.contains($0.path) }!.path
            try f.storage.write(journal, directory: dir, expectedState: ModelFileStamp(try dir.info("state.json")))
            let discard = DiscardTestTransport(error: variant == 3 ? .init(code: .transport, transportCode: -1009) : nil)
            let fresh = f.service(transport: { discard })
            let cancelling = Task { try await fresh.cancel(id) }
            do {
                try await discard.gate.wait()
                let before = try await fresh.pending(); XCTAssertEqual(before.count, 1)
                await expect(.busy) { _ = try await f.service().start(f.descriptor.key) }
                let state = dir.url.appendingPathComponent("state.json")
                let payload = dir.url.appendingPathComponent("payload")
                if variant == 1 {
                    try FileManager.default.moveItem(at: payload, to: f.root.appendingPathComponent("kept-payload"))
                    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
                    try Data("sentinel".utf8).write(to: payload.appendingPathComponent("sentinel"))
                }
                if variant == 2 {
                    try FileManager.default.moveItem(at: state, to: f.root.appendingPathComponent("kept-state"))
                    try Data("sentinel".utf8).write(to: state)
                }
                await discard.gate.release(); let result = try await cancelling.value
                let associations = await discard.associations; let closes = await discard.closes
                XCTAssertEqual(associations, ["original-transfer"]); XCTAssertEqual(closes, 1)
                XCTAssertEqual(result.phase, .cancelled)
                if variant == 0 {
                    XCTAssertNil(result.failure?.cleanup)
                    let pending = try await fresh.pending(); XCTAssertTrue(pending.isEmpty)
                    _ = try await installed(f.service(), f.descriptor.key)
                } else {
                    XCTAssertNotNil(result.failure?.cleanup)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.path))
                    if variant == 1 { XCTAssertEqual(try Data(contentsOf: payload.appendingPathComponent("sentinel")), Data("sentinel".utf8)) }
                    if variant == 2 { XCTAssertEqual(try Data(contentsOf: state), Data("sentinel".utf8)) }
                    if variant == 3 { XCTAssertEqual(result.failure?.cleanup, .transport) }
                }
                for (path, bytes) in f.payloads { XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent(path)), bytes) }
            } catch { await discard.gate.release(); _ = try? await cancelling.value; throw error }
        }
    }
    func testReviewSameInstanceRetrySettlesCommittedCleanupWarning() async throws {
        let f = try DownloadFixture(); let cleanups = DownloadTestCounter(); let factories = DownloadTestCounter()
        let service = f.service(hooks: .init(visit: { point in
            if point == .cleanup { cleanups.increment(); if cleanups.value == 1 { throw ModelDownloadFailure(code: .cleanup) } }
        }), counter: factories)
        let id = try await service.start(f.descriptor.key); let committed = try await service.wait(id)
        XCTAssertEqual(committed.phase, .installed); XCTAssertEqual(committed.result?.warning, .cleanupFailed)
        let before = factories.value
        let retriedID = try await service.retry(id); XCTAssertEqual(retriedID, id)
        let result = try await service.wait(id)
        XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.result?.disposition, .alreadyInstalled)
        XCTAssertEqual(factories.value, before)
        let pending = try await service.pending(); XCTAssertTrue(pending.isEmpty)
        try await f.assertInstalled(f.repository())
    }
    func testReviewDiscardSelectsOnlyExactLiveTaskAssociation() async throws {
        var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 19, count: 524_288))
        let server = try DownloadHTTPServer(payloads: ["weights.bin": bytes], slow: true); defer { server.stop() }
        let probe = DownloadSessionProbe(); var config = server.configuration()
        config.created = { session in
            let task = session.downloadTask(with: URL(string: "http://127.0.0.1:\(server.port)/weights.bin")!)
            task.taskDescription = "unrelated-task"; probe.record(session, task: task); task.resume()
        }
        let adapter = URLSessionModelTransport(identifier: UUID().uuidString, configuration: config)
        let (_, task) = try probe.get()
        let ack = await XCTWaiter.fulfillment(of: [server.prefixSent], timeout: 10)
        guard ack == .completed else { task.cancel(); server.releaseBody(); await adapter.close(); XCTFail(); return }
        do {
            try await adapter.discard(association: "different-operation")
            XCTAssertEqual(task.state, .running)
            try await adapter.discard(association: "unrelated-task")
            XCTAssertEqual(task.state, .completed)
            // Repeating discard is idempotent and cannot create a request.
            try await adapter.discard(association: "unrelated-task")
            XCTAssertEqual(server.requests.count, 1)
        } catch { task.cancel(); server.releaseBody(); await adapter.close(); throw error }
        server.releaseBody(); await adapter.close()
    }
}

extension ModelDownloadTests {
    func testReviewPartialRestartRejectsReplacedFileAndPreservesCompletedSibling() async throws {
        var large = Data("STT-TEST".utf8); large.append(Data(repeating: 29, count: 300_000))
        let f = try DownloadFixture(payloads: ["Native/a.bin": Data("STT-TEST first".utf8), "Native/z.bin": large])
        let chunks = DownloadTestCounter(); let gate = DownloadGate()
        let stopped = XCTestExpectation(description: "partial copy pause acknowledged")
        let seed = f.service(hooks: .init(visit: { point in
            if point == .copyChunk { chunks.increment(); if chunks.value == 3 { await gate.hold() } }
            if point == .stopRequested { stopped.fulfill() }
        }))
        let id = try await seed.start(f.descriptor.key)
        do {
            try await gate.wait()
            let pause = Task { try await seed.pause(id) }
            let ack = await XCTWaiter.fulfillment(of: [stopped], timeout: 10); XCTAssertEqual(ack, .completed)
            await gate.release(); _ = try await pause.value
        } catch { await gate.release(); _ = try? await seed.cancel(id); throw error }
        let (_, payload, journal) = try f.storage.read(id)
        XCTAssertEqual(journal.completed, ["Native/a.bin"])
        let untouched = try Data(contentsOf: payload.url.appendingPathComponent("Native/a.bin"))
        let target = payload.url.appendingPathComponent("Native/z.bin")
        let sentinel = Data("unrelated replacement".utf8)
        let factories = DownloadTestCounter()
        let fresh = f.service(hooks: .init(visit: { point in
            if point == .resumeAdmission {
                try FileManager.default.moveItem(at: target, to: f.root.appendingPathComponent("kept-partial"))
                try sentinel.write(to: target)
            }
        }), counter: factories)
        await expect(.ownership) { try await fresh.resume(id) }
        XCTAssertEqual(factories.value, 0)
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertEqual(try Data(contentsOf: payload.url.appendingPathComponent("Native/a.bin")), untouched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("kept-partial").path))
    }
}

// Same-Task postcommit regressions reproduced against db79d38.
extension ModelDownloadTests {
    func testReReviewCommittedRetryMustNotRequireAnotherInstallFootprint() async throws {
        var bytes = Data("STT-TEST".utf8); bytes.append(Data(repeating: 51, count: 2_097_152))
        let f = try DownloadFixture(payloads: ["weights.bin": bytes])
        let first = f.service(hooks: .init(visit: { if $0 == .cleanup { throw ModelDownloadFailure(code: .cleanup) } }))
        let id = try await first.start(f.descriptor.key); let installed = try await first.wait(id)
        XCTAssertEqual(installed.phase, .installed); XCTAssertEqual(installed.result?.warning, .cleanupFailed)
        let factories = DownloadTestCounter()
        // More than enough for bounded metadata/cleanup, but less than the
        // additional full model copies needed only for a new installation.
        let remaining: Int64 = ModelDownloadCapacity.safetyBytes + 1_048_576
        let fresh = f.service(capacity: remaining, counter: factories)
        do {
            let retry = try await fresh.retry(id); let result = try await fresh.wait(retry)
            XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.result?.disposition, .alreadyInstalled)
            let pending = try await fresh.pending(); XCTAssertTrue(pending.isEmpty)
        } catch { XCTFail("Committed-install reconciliation incorrectly required new-install capacity: \(error)") }
        XCTAssertEqual(factories.value, 0); try await f.assertInstalled(f.repository())
    }
    func testReReviewPartiallyCleanedJournalMustNotHideVerifiedCommittedInstall() async throws {
        let f = try DownloadFixture()
        let first = f.service(hooks: .init(visit: { point in
            if point == .cleanup {
                let op = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.downloads, includingPropertiesForKeys: nil).first)
                // Model the first successful unlink of a multi-file cleanup,
                // followed by a cleanup failure/process interruption.
                try FileManager.default.removeItem(at: op.appendingPathComponent("payload").appendingPathComponent(f.descriptor.files[0].path))
                throw ModelDownloadFailure(code: .cleanup)
            }
        }))
        let id = try await first.start(f.descriptor.key); let installed = try await first.wait(id)
        XCTAssertEqual(installed.phase, .installed); XCTAssertEqual(installed.result?.warning, .cleanupFailed)
        let factories = DownloadTestCounter(); let fresh = f.service(counter: factories)
        do {
            let retry = try await fresh.retry(id); let result = try await fresh.wait(retry)
            XCTAssertEqual(result.phase, .installed, "Conservative retained-cleanup warning must not erase a verified final install")
            let pending = try await fresh.pending(); XCTAssertTrue(pending.isEmpty)
        } catch { XCTFail("Existing final install was not reconciled before rejecting stale temporary state: \(error)") }
        XCTAssertEqual(factories.value, 0); try await f.assertInstalled(f.repository())
    }
    func testReReviewFreshCancelAfterCommitMustReportInstalledTruth() async throws {
        let f = try DownloadFixture()
        let first = f.service(hooks: .init(visit: { if $0 == .cleanup { throw ModelDownloadFailure(code: .cleanup) } }))
        let id = try await first.start(f.descriptor.key); let installed = try await first.wait(id)
        XCTAssertEqual(installed.phase, .installed)
        let fresh = f.service(); let cancelled = try await fresh.cancel(id)
        print("RE-REVIEW postcommit fresh cancel: phase=\(cancelled.phase), result=\(String(describing: cancelled.result)), cleanup=\(String(describing: cancelled.failure?.cleanup))")
        XCTAssertEqual(cancelled.phase, .installed, "Publication is already committed, regardless of fresh service construction")
        XCTAssertNotNil(cancelled.result, "Return the committed model plus any warning instead of an uncommitted cancellation result")
        XCTAssertEqual(cancelled.result?.warning, .cancelled)
        let pending = try await fresh.pending(); XCTAssertTrue(pending.isEmpty)
        try await f.assertInstalled(f.repository())
    }
}

extension ModelDownloadTests {
    private func retainedCommitted(_ f: DownloadFixture) async throws -> ModelDownloadID {
        let service = f.service(hooks: .init(visit: { if $0 == .cleanup { throw ModelDownloadFailure(code: .cleanup) } }))
        let id = try await service.start(f.descriptor.key)
        let result = try await service.wait(id)
        XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.result?.warning, .cleanupFailed)
        return id
    }
    func testReReviewCommittedCommandsPreserveMissingReplacedAndUnknownPayloadRemnants() async throws {
        for variant in 0..<4 {
            for cancel in [false, true] {
                let f = try DownloadFixture(); let id = try await retainedCommitted(f)
                let (dir, _, _) = try f.storage.read(id)
                let payload = dir.url.appendingPathComponent("payload")
                let sentinel = Data("unknown sentinel".utf8)
                if variant < 3 {
                    try FileManager.default.moveItem(at: payload, to: f.root.appendingPathComponent("retained-payload"))
                    if variant == 1 {
                        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
                        try sentinel.write(to: payload.appendingPathComponent("sentinel"))
                    }
                    if variant == 2 {
                        let unrelated = f.root.appendingPathComponent("unrelated")
                        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
                        try sentinel.write(to: unrelated.appendingPathComponent("sentinel"))
                        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: unrelated)
                    }
                } else { try sentinel.write(to: payload.appendingPathComponent("sentinel")) }
                let factories = DownloadTestCounter(); let fresh = f.service(capacity: 0, counter: factories)
                let before = try await fresh.pending(); XCTAssertEqual(before.count, 1); XCTAssertEqual(factories.value, 0)
                let result: ModelDownloadSnapshot
                if cancel { result = try await fresh.cancel(id) }
                else { let retry = try await fresh.retry(id); result = try await fresh.wait(retry) }
                XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.result?.disposition, .alreadyInstalled)
                XCTAssertEqual(result.result?.warning, .cleanupFailed); XCTAssertNotNil(result.failure?.cleanup)
                XCTAssertEqual(factories.value, 0)
                let after = try await fresh.pending(); XCTAssertEqual(after.count, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("state.json").path))
                if variant == 1 || variant == 3 { XCTAssertEqual(try Data(contentsOf: payload.appendingPathComponent("sentinel")), sentinel) }
                if variant == 2 { XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("unrelated/sentinel")), sentinel) }
                if variant < 3 {
                    for (path, bytes) in f.payloads { XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("retained-payload").appendingPathComponent(path)), bytes) }
                }
                try await f.assertInstalled(f.repository())
            }
        }
    }
    func testReReviewCommittedReconciliationDoesNotQueryDownloadCapacity() async throws {
        for cancel in [false, true] {
            let f = try DownloadFixture(); let id = try await retainedCommitted(f)
            let capacityCalls = DownloadTestCounter(); let factories = DownloadTestCounter()
            let service = ModelDownloadService(repository: f.repository(), storage: f.storage,
                capacity: .init(available: { _ in capacityCalls.increment(); throw ModelDownloadFailure(code: .capacityUnknown) }),
                transportFactory: { _ in factories.increment(); return FixtureTransport(payloads: f.payloads) })
            let result: ModelDownloadSnapshot
            if cancel { result = try await service.cancel(id) }
            else { let retry = try await service.retry(id); result = try await service.wait(retry) }
            XCTAssertEqual(result.phase, .installed); XCTAssertEqual(capacityCalls.value, 0); XCTAssertEqual(factories.value, 0)
            let pending = try await service.pending(); XCTAssertTrue(pending.isEmpty)
            try await f.assertInstalled(f.repository())
        }
    }
    func testReReviewCommittedDiscoveryNeverPromotesCorruptOrUnavailableModels() async throws {
        for unavailable in [false, true] {
            for cancel in [false, true] {
                let f = try DownloadFixture(); let id = try await retainedCommitted(f)
                let target = f.installed.appendingPathComponent(f.descriptor.files[0].path)
                let original = try Data(contentsOf: target)
                if !unavailable { try Data("corrupt payload".utf8).write(to: target) }
                let before = try Data(contentsOf: target)
                let validator = DownloadTestValidator(code: unavailable ? .validationUnavailable : nil)
                let service = f.service(repository: f.repository(validator: validator))
                let code: ModelRepositoryCode = unavailable ? .validationUnavailable : .integrityMismatch
                if cancel {
                    let result = try await service.cancel(id)
                    XCTAssertEqual(result.phase, .cancelled); XCTAssertNil(result.result)
                    XCTAssertEqual(result.failure?.repository?.cause, code)
                } else {
                    do { _ = try await service.retry(id); XCTFail("Must not label unverified final bytes installed") }
                    catch let error as ModelDownloadFailure { XCTAssertEqual(error.repository?.cause, code) }
                }
                XCTAssertEqual(try Data(contentsOf: target), before)
                if unavailable { XCTAssertEqual(before, original) }
            }
        }
    }
    func testReReviewCancelDuringCommittedResumeAdmissionReportsCommitAndKeepsClaim() async throws {
        let f = try DownloadFixture(); let id = try await retainedCommitted(f)
        let gate = DownloadGate(); let stop = XCTestExpectation(description: "committed admission cancel acknowledged")
        let service = f.service(capacity: 0, hooks: .init(visit: { point in
            if point == .resumeAdmission { await gate.hold() }
            if point == .stopRequested { stop.fulfill() }
        }))
        let retry = Task { try await service.retry(id) }
        do {
            try await gate.wait()
            do { _ = try await f.repository().validate(f.descriptor.key); XCTFail("Claim must cover committed discovery and cleanup") }
            catch let error as ModelOperationFailure { XCTAssertEqual(error.cause, .busy) }
            let cancel = Task { try await service.cancel(id) }
            let ack = await XCTWaiter.fulfillment(of: [stop], timeout: 10); XCTAssertEqual(ack, .completed)
            await gate.release(); let retried = try await retry.value; XCTAssertEqual(retried, id)
            let result = try await cancel.value
            XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.result?.warning, .cancelled)
            try await f.assertInstalled(f.repository())
        } catch { await gate.release(); _ = try? await retry.value; _ = try? await service.cancel(id); throw error }
    }
    func testReReviewCommittedProofSurvivesCleanupFailureAndTargetReplacement() async throws {
        let f = try DownloadFixture(); let id = try await retainedCommitted(f)
        let original = f.root.appendingPathComponent("retained-installed")
        let sentinel = Data("replacement".utf8)
        let service = f.service(capacity: 0, hooks: .init(visit: { point in
            if point == .cleanup {
                try FileManager.default.moveItem(at: f.installed, to: original)
                try FileManager.default.createDirectory(at: f.installed, withIntermediateDirectories: true)
                try sentinel.write(to: f.installed.appendingPathComponent("sentinel"))
                throw ModelDownloadFailure(code: .diskWrite, transportCode: NSURLErrorCannotWriteToFile)
            }
        }))
        let retry = try await service.retry(id); let result = try await service.wait(retry)
        XCTAssertEqual(result.phase, .installed); XCTAssertEqual(result.result?.warning, .identityChanged)
        XCTAssertEqual(result.failure?.code, .diskWrite); XCTAssertEqual(result.failure?.transportCode, NSURLErrorCannotWriteToFile)
        XCTAssertEqual(result.failure?.cleanup, .diskWrite)
        XCTAssertEqual(try Data(contentsOf: f.installed.appendingPathComponent("sentinel")), sentinel)
        for (path, bytes) in f.payloads { XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent(path)), bytes) }
    }
}

extension ModelDownloadTests {
    func testReReviewCommittedAdmissionFaultAndLostJournalPreservePublishedTruth() async throws {
        let f = try DownloadFixture(); let id = try await retainedCommitted(f)
        let op = f.downloads.appendingPathComponent(ModelDownloadStorage.name(id))
        let originalState = try Data(contentsOf: op.appendingPathComponent("state.json"))
        let retainedState = f.root.appendingPathComponent("retained-state.json")
        let service = f.service(capacity: 0, hooks: .init(visit: { point in
            if point == .resumeAdmission {
                try FileManager.default.moveItem(at: op.appendingPathComponent("state.json"), to: retainedState)
                throw ModelDownloadFailure(code: .diskWrite, transportCode: NSURLErrorCannotWriteToFile)
            }
        }))
        let retry = try await service.retry(id); let result = try await service.wait(retry)
        XCTAssertEqual(result.phase, .installed); XCTAssertNotNil(result.result?.warning)
        XCTAssertEqual(result.failure?.code, .diskWrite); XCTAssertNotNil(result.failure?.cleanup)
        XCTAssertEqual(try Data(contentsOf: retainedState), originalState)
        try await f.assertInstalled(f.repository())
    }
}
