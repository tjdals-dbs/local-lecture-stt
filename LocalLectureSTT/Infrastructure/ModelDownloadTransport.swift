import Darwin
import Foundation

struct ModelTransferRequest: Sendable {
    let association: String
    let previousAssociation: String?
    let url: URL
    let expectedBytes: Int64
    let resumeData: Data?
}
struct ModelTransferProgress: Sendable { let bytes: Int64; let resumedOffset: Int64 }
struct ModelTransferOutcome: Sendable {
    let receipt: ModelDownloadReceipt?
    let failure: ModelDownloadFailure?
    let resumeData: Data?
    let resumedOffset: Int64
    var reconnected: Bool = false
}
protocol ModelDownloadTransport: Sendable {
    func transfer(_ request: ModelTransferRequest,
                  associated: @escaping @Sendable (String) async throws -> Void,
                  progress: @escaping @Sendable (ModelTransferProgress) -> Void) async -> ModelTransferOutcome
    /// Reconcile and join existing tasks only; never create or resume a request.
    func discard(association: String) async throws
    func stop(preservingResume: Bool) async
    func close() async
}

/// Opened synchronously by didFinishDownloadingTo. The OS may unlink its pathname
/// on callback return; this descriptor still owns the bytes. No hashing on the delegate queue.
final class ModelDownloadReceipt: @unchecked Sendable {
    let fd: Int32
    let stamp: ModelFileStamp
    init(temporaryURL: URL) throws {
        fd = Darwin.open(temporaryURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ModelDownloadFailure(code: .receiptMissing) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw ModelDownloadFailure(code: .receiptMissing)
        }
        stamp = ModelFileStamp(s)
    }
    deinit { Darwin.close(fd) }
    func copy(to directory: ModelPackageDirectory, path: String, expected: Int64,
              owned: ModelDownloadOwnedNodes, chunk: @Sendable () async throws -> Void) async throws {
        guard stamp.size == expected else { throw ModelDownloadFailure(code: .byteCount) }
        let (parent, name) = try owned.parent(for: path, in: directory)
        let output = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw ModelDownloadFailure(code: .diskWrite) }; defer { Darwin.close(output) }
        var info = stat(); guard fstat(output, &info) == 0 else { throw ModelDownloadFailure(code: .diskWrite) }
        let outputStamp = ModelFileStamp(info)
        owned.record(path, stamp: outputStamp)
        var buffer = [UInt8](repeating: 0, count: ModelPackageDirectory.chunkSize)
        var offset: Int64 = 0
        while offset < expected {
            try Task.checkCancellation(); try await chunk(); try directory.check(); try parent.check()
            guard outputStamp.sameObject(ModelFileStamp(try parent.info(name))) else { throw ModelRepositoryCode.identityChanged }
            let count = pread(fd, &buffer, min(buffer.count, Int(min(expected - offset, Int64(buffer.count)))), off_t(offset))
            guard count > 0 else { throw ModelDownloadFailure(code: .diskWrite) }
            try ModelPackageDirectory.writeAll(Data(buffer.prefix(count)), fd: output); offset += Int64(count)
        }
        var now = stat()
        guard fstat(fd, &now) == 0 else { throw ModelRepositoryCode.identityChanged }
        let after = ModelFileStamp(now)
        // URLSession is allowed to unlink its temporary pathname after the receipt
        // was opened (changing ctime/link count). Byte length/mtime and the open
        // inode must remain the original ones.
        guard after.sameObject(stamp), after.size == stamp.size, after.modified == stamp.modified,
              after.modifiedNS == stamp.modifiedNS else { throw ModelRepositoryCode.identityChanged }
        guard fsync(output) == 0 else { throw ModelRepositoryCode.flushFailed }; try parent.sync()
    }
}

struct ModelTransportConfiguration: Sendable {
    var make: @Sendable (String) -> URLSessionConfiguration = { identifier in
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = false // no new exit/relaunch policy in T13
        return c
    }
    var created: @Sendable (URLSession) -> Void = { _ in }
    var observedProgress: @Sendable (ModelTransferProgress) -> Void = { _ in }
    var endpoint: @Sendable (URL) -> URL = { $0 }
    var permits: @Sendable (URL) -> Bool = { url in
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "https" && !(c.host ?? "").isEmpty && c.user == nil && c.password == nil && c.fragment == nil
    }
}

/// One serialized URLSession delegate owns receipt + completion + pause settlement.
/// A factory is invoked only from explicit service admission, never construction/pending reads.
final class URLSessionModelTransport: NSObject, ModelDownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    private final class Entry {
        var task: URLSessionDownloadTask?
        var request: ModelTransferRequest?
        var receipt: ModelDownloadReceipt?
        var first: ModelDownloadFailure?
        var completed = false
        var stopping = false
        var stopReady = false
        var resume: Data?
        var resumed: Int64 = 0
        var reconnected = false
        var bucket: Int64 = -1
        var discardWaiters = [CheckedContinuation<Void, Never>]()
        var continuation: CheckedContinuation<ModelTransferOutcome, Never>?
        var progress: (@Sendable (ModelTransferProgress) -> Void)?
    }
    let identifier: String
    private let config: ModelTransportConfiguration
    private let lock = NSLock()
    private var entries = [Int: Entry]()
    private var active: Entry?
    private var requestedStop: Bool?
    private var invalidation: CheckedContinuation<Void, Never>?
    private var invalidated = false
    private var session: URLSession!
    init(identifier: String, configuration: ModelTransportConfiguration = .init()) {
        self.identifier = identifier; config = configuration
        super.init()
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration.make(identifier), delegate: self, delegateQueue: queue)
        configuration.created(session)
    }
    static func identifier(for id: ModelDownloadID) -> String { "io.github.tjdals-dbs.LocalLectureSTT.download." + id.rawValue.uuidString.lowercased() }
    private func entry(_ task: URLSessionTask) -> Entry {
        if let e = entries[task.taskIdentifier] { return e }
        let e = Entry(); e.task = task as? URLSessionDownloadTask; entries[task.taskIdentifier] = e; return e
    }
    private func settle(_ e: Entry) {
        guard e.completed, !e.stopping || e.stopReady else { return }
        let waiters = e.discardWaiters; e.discardWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard let c = e.continuation else { return }
        e.continuation = nil; e.progress = nil
        c.resume(returning: .init(receipt: e.first == nil ? e.receipt : nil, failure: e.first, resumeData: e.resume, resumedOffset: e.resumed, reconnected: e.reconnected))
        e.receipt = nil
    }
    func transfer(_ request: ModelTransferRequest, associated: @escaping @Sendable (String) async throws -> Void,
                  progress: @escaping @Sendable (ModelTransferProgress) -> Void) async -> ModelTransferOutcome {
        let target = config.endpoint(request.url)
        guard config.permits(target) else { return .init(receipt: nil, failure: .init(code: .redirectRejected), resumeData: nil, resumedOffset: 0) }
        let tasks = await session.allTasks
        if lock.withLock({ invalidated }) {
            return .init(receipt: nil, failure: .init(code: .transport), resumeData: nil, resumedOffset: 0)
        }
        let cached = lock.withLock { entries.values.compactMap { $0.completed ? $0.task : nil } }
        let candidates = tasks.compactMap { $0 as? URLSessionDownloadTask } + cached.filter { cached in !tasks.contains { $0.taskIdentifier == cached.taskIdentifier } }
        let matches = candidates.filter {
            $0.taskDescription == request.association || (request.previousAssociation != nil && $0.taskDescription == request.previousAssociation)
        }
        guard matches.count <= 1 else { return .init(receipt: nil, failure: .init(code: .busy), resumeData: nil, resumedOffset: 0) }
        let task: URLSessionDownloadTask
        if let existing = matches.first { task = existing }
        else if let data = request.resumeData {
            task = session.downloadTask(withResumeData: data)
        } else {
            var r = URLRequest(url: target); r.cachePolicy = .reloadIgnoringLocalCacheData
            r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            task = session.downloadTask(with: r)
        }
        // Task association is durable before a newly created suspended task can run.
        let association = matches.isEmpty ? request.association : (task.taskDescription ?? request.association)
        task.taskDescription = association
        do { try await associated(association) }
        catch {
            task.cancel()
            return .init(receipt: nil, failure: (error as? ModelDownloadFailure) ?? .init(code: .journal), resumeData: nil, resumedOffset: 0)
        }
        return await withCheckedContinuation { continuation in
            let stop = lock.withLock { () -> Bool? in
                let e = entry(task); e.request = request; e.reconnected = !matches.isEmpty; e.continuation = continuation; e.progress = progress; active = e
                if invalidated { e.first = e.first ?? .init(code: .transport); e.completed = true; e.stopReady = true }
                settle(e); return requestedStop
            }
            if let stop { stopTask(task, preserving: stop) }
            else if task.state == .suspended { task.resume() }
        }
    }
    private func stopTask(_ task: URLSessionDownloadTask, preserving: Bool) {
        let should = lock.withLock { () -> Bool in
            let e = entry(task)
            guard !e.stopping, !e.completed else { return false }; e.stopping = true; return true
        }
        guard should else { return }
        if preserving {
            task.cancel { [self] data in
                lock.withLock {
                    let e = entry(task); e.resume = data.flatMap { $0.count <= 1_048_576 ? $0 : nil }
                    e.stopReady = true; settle(e)
                }
            }
        } else {
            lock.withLock { let e = entry(task); e.stopReady = true }; task.cancel()
        }
    }
    func discard(association: String) async throws {
        guard !association.isEmpty, association.utf8.count <= 512 else { throw ModelDownloadFailure(code: .ownership) }
        // The operation-specific session already exists from an explicit command.
        // Reattach only its exact durable association, without starting any task.
        let tasks = await session.allTasks
        guard !lock.withLock({ invalidated }) else { throw ModelDownloadFailure(code: .transport) }
        let cached = lock.withLock { entries.values.compactMap { $0.task } }
        let candidates = tasks.compactMap { $0 as? URLSessionDownloadTask } +
            cached.filter { cached in !tasks.contains { $0.taskIdentifier == cached.taskIdentifier } }
        let matches = candidates.filter { $0.taskDescription == association }
        for task in matches {
            stopTask(task, preserving: false)
            await withCheckedContinuation { continuation in
                lock.withLock {
                    let e = entry(task); e.discardWaiters.append(continuation)
                    if invalidated { e.completed = true; e.stopReady = true }
                    settle(e)
                }
            }
        }
        try lock.withLock {
            guard !invalidated else { throw ModelDownloadFailure(code: .transport) }
            for task in matches {
                let e = entry(task); e.receipt = nil; e.resume = nil
            }
        }
    }
    func stop(preservingResume: Bool) async {
        let task = lock.withLock { () -> URLSessionDownloadTask? in requestedStop = preservingResume; return active?.task }
        if let task { stopTask(task, preserving: preservingResume) }
    }
    func close() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if invalidated { return true }; invalidation = continuation; return false
            }
            if done { continuation.resume() } else { session.finishTasksAndInvalidate() }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.withLock {
            let e = entry(downloadTask); guard !e.completed, e.receipt == nil else { return }
            guard let finalURL = downloadTask.response?.url, config.permits(finalURL) else {
                e.first = e.first ?? .init(code: .redirectRejected); return
            }
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                e.first = e.first ?? .init(code: .httpStatus, httpStatus: (downloadTask.response as? HTTPURLResponse)?.statusCode); return
            }
            do { e.receipt = try ModelDownloadReceipt(temporaryURL: location) }
            catch { e.first = e.first ?? .init(code: .receiptMissing) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            let e = entry(task); guard !e.completed else { return }
            if let error {
                let n = error as NSError
                e.first = e.first ?? Self.failure(n)
                if e.resume == nil, let data = n.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, data.count <= 1_048_576 { e.resume = data }
            } else if e.receipt == nil { e.first = e.first ?? .init(code: .receiptMissing) }
            e.completed = true; settle(e)
        }
    }
    static func failure(_ error: NSError) -> ModelDownloadFailure {
        let code: ModelDownloadCode
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { code = .cancelled }
        else if (error.domain == NSURLErrorDomain && [NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile,
            NSURLErrorCannotMoveFile, NSURLErrorCannotOpenFile].contains(error.code)) ||
            (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) { code = .diskWrite }
        else { code = .transport }
        return .init(code: code, transportCode: error.code)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let callback = lock.withLock { () -> ((@Sendable (ModelTransferProgress) -> Void), ModelTransferProgress)? in
            let e = entry(downloadTask)
            guard !e.completed, let request = e.request, let progress = e.progress else { return nil }
            if totalBytesWritten > request.expectedBytes {
                e.first = e.first ?? .init(code: .byteCount); downloadTask.cancel(); return nil
            }
            let bucket = totalBytesWritten / max(1, request.expectedBytes / 64)
            guard bucket > e.bucket else { return nil }; e.bucket = bucket
            return (progress, .init(bytes: max(0, totalBytesWritten), resumedOffset: e.resumed))
        }
        if let (f, p) = callback { config.observedProgress(p); f(p) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.withLock { let e = entry(downloadTask); if !e.completed { e.resumed = max(0, fileOffset) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url.map(config.permits) ?? false
        if !allowed { lock.withLock { let e = entry(task); e.first = e.first ?? .init(code: .redirectRejected) } }
        completionHandler(allowed ? request : nil)
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.withLock {
            invalidated = true
            for e in entries.values where !e.completed {
                e.first = e.first ?? error.map { Self.failure($0 as NSError) } ?? .init(code: .transport)
                e.completed = true; e.stopReady = true; settle(e)
            }
            invalidation?.resume(); invalidation = nil
        }
    }
}
