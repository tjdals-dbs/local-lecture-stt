import CryptoKit
import Darwin
import Foundation

enum WhisperCppProfile: WhisperAdapterProfile {
    static let identity = try! EngineIdentity(id: EngineID("whisper.cpp"), version: "d1be6fde11ac6e0407606b4e42fe72d34add8037")
    static let compute = "Metal preferred+Accelerate;threads=4;flash=true"
    static let format = "whisper.cpp-ggml-v1"
    static func makeBackend() -> any WhisperIntervalBackend { NativeWhisperBackend() }
}

typealias WhisperCppSTTEngine = WhisperIntervalEngine<WhisperCppProfile>

struct WhisperCppModelValidator: OfflineModelFormatValidating {
    static let filename = "ggml-large-v3.bin"
    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let size: Int64 = 3_095_033_483
    static let digest = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"

    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws {
        let payload = try ModelPayloadFile(path: Self.filename, byteCount: Self.size, sha256: Self.digest)
        guard descriptor.engine == WhisperCppProfile.identity, descriptor.format == WhisperCppProfile.format,
              descriptor.model.id.rawValue == "ggerganov/ggml-large-v3", descriptor.model.revision == Self.revision,
              descriptor.variant == "large-v3", descriptor.quantization == "none",
              descriptor.compute == WhisperCppProfile.compute, descriptor.files == [payload] else {
            throw ModelRepositoryCode.incompatible
        }
        let (fd, stamp) = try directory.regularFD(Self.filename)
        defer { close(fd) }
        try Self.checkHeader(fd, size: stamp.size)
        try directory.checkFile(Self.filename, fd: fd, expected: stamp)
    }

    // Repository verification independently streams the pinned SHA of every byte,
    // including vocabulary strings, tensor dimensions, storage types and weights.
    static func checkHeader(_ fd: Int32, size: Int64) throws {
        func words(_ count: Int, offset: off_t) throws -> [UInt32] {
            var values = [UInt32](repeating: 0, count: count)
            guard pread(fd, &values, count * 4, offset) == count * 4 else { throw ModelRepositoryCode.integrityMismatch }
            return values.map(UInt32.init(littleEndian:))
        }
        guard size == Self.size,
              try words(14, offset: 0) == [0x67676d6c, 51866, 1500, 1280, 20, 32, 448, 1280, 20, 32, 128, 1, 128, 201],
              try words(1, offset: 56 + 128 * 201 * 4) == [50257] else { throw ModelRepositoryCode.incompatible }
    }

    /// Freeze the actual parser input. The native parser assumes trusted tensor lengths.
    /// Verify the pinned FD against the original lease, then stream into an unlinked,
    /// private file while hashing. No mutable installation path is given to C++.
    static func withVerifiedWeights<T>(_ lease: ModelUseLease, checkCancellation: () throws -> Void,
                                       _ body: (String) throws -> T) throws -> T {
        let (input, stamp) = try lease.directory.regularFD(filename)
        defer { close(input) }
        try lease.check()
        try lease.directory.checkFile(filename, fd: input, expected: stamp)
        try checkHeader(input, size: stamp.size)
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("stt-weights.XXXXXX").path.utf8CString)
        let output = mkstemp(&template)
        guard output >= 0 else { throw ModelRepositoryCode.storageUnavailable }
        defer { close(output) }
        guard unlink(template) == 0 else { throw ModelRepositoryCode.cleanupFailed }
        var hash = SHA256()
        var buffer = Data(count: 1024 * 1024)
        var total: Int64 = 0
        while total < size {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            guard count > 0 else { throw ModelRepositoryCode.integrityMismatch }
            let bytes = buffer.prefix(count)
            hash.update(data: bytes)
            try ModelPackageDirectory.writeAll(bytes, fd: output)
            total += Int64(count)
        }
        guard total == size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest,
              lseek(output, 0, SEEK_SET) == 0 else { throw ModelRepositoryCode.integrityMismatch }
        try lease.directory.checkFile(filename, fd: input, expected: stamp)
        try lease.check()
        try checkCancellation()
        return try body("/dev/fd/\(output)")
    }
}
