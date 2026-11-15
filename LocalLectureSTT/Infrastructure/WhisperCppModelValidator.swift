import CryptoKit
import Darwin
import Foundation

enum WhisperCppProfile: WhisperAdapterProfile {
    static let identity = try! EngineIdentity(id: EngineID("whisper.cpp"), version: "d1be6fde11ac6e0407606b4e42fe72d34add8037")
    static let compute = "Metal preferred+Accelerate;threads=4;flash=true"
    static let format = "whisper.cpp-ggml-v1"
    static func supportsTurbo(_ descriptor: ModelPackageDescriptor) -> Bool {
        WhisperCppModelValidator.Variant.turbo.matches(descriptor)
    }
    static func makeBackend() -> any WhisperIntervalBackend { NativeWhisperBackend() }
}

typealias WhisperCppSTTEngine = WhisperIntervalEngine<WhisperCppProfile>

struct WhisperCppModelValidator: OfflineModelFormatValidating {
    enum Variant: String {
        case large = "large-v3"
        case turbo = "large-v3-turbo"

        var filename: String { "ggml-" + rawValue + ".bin" }
        var size: Int64 { self == .large ? 3_095_033_483 : 1_624_555_275 }
        var digest: String {
            switch self {
            case .large: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
            case .turbo: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
            }
        }
        func matches(_ descriptor: ModelPackageDescriptor) -> Bool {
            guard descriptor.model.id.rawValue == "ggerganov/ggml-" + rawValue,
                  descriptor.model.revision == "5359861c739e955e79d9a303bcbc70fb988958b1",
                  descriptor.variant == rawValue, descriptor.files.count == 1 else { return false }
            let file = descriptor.files[0]
            return file.path == filename && file.sha256 == digest && file.byteCount == size
        }
    }
    static func variant(_ descriptor: ModelPackageDescriptor) throws -> Variant {
        guard descriptor.engine == WhisperCppProfile.identity, descriptor.format == WhisperCppProfile.format,
              descriptor.quantization == "none", descriptor.compute == WhisperCppProfile.compute,
              let variant = Variant(rawValue: descriptor.variant), variant.matches(descriptor) else {
            throw ModelRepositoryCode.incompatible
        }
        return variant
    }

    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws {
        let variant = try Self.variant(descriptor)
        let (fd, stamp) = try directory.regularFD(variant.filename)
        defer { close(fd) }
        try Self.checkHeader(fd, size: stamp.size, variant: variant)
        try directory.checkFile(variant.filename, fd: fd, expected: stamp)
    }

    // Repository verification independently streams the pinned SHA of every byte,
    // including vocabulary strings, tensor dimensions, storage types and weights.
    static func checkHeader(_ fd: Int32, size: Int64, variant: Variant = .large) throws {
        func words(_ count: Int, offset: off_t) throws -> [UInt32] {
            var values = [UInt32](repeating: 0, count: count)
            guard pread(fd, &values, count * 4, offset) == count * 4 else { throw ModelRepositoryCode.integrityMismatch }
            return values.map(UInt32.init(littleEndian:))
        }
        let decoderLayers: UInt32 = variant == .large ? 32 : 4
        guard size == variant.size,
              try words(14, offset: 0) == [0x67676d6c, 51866, 1500, 1280, 20, 32, 448, 1280, 20, decoderLayers, 128, 1, 128, 201],
              try words(1, offset: 56 + 128 * 201 * 4) == [50257] else { throw ModelRepositoryCode.incompatible }
    }

    /// Freeze the actual parser input. The native parser assumes trusted tensor lengths.
    /// Verify the pinned FD against the original lease, then stream into an unlinked,
    /// private file while hashing. No mutable installation path is given to C++.
    static func withVerifiedWeights<T>(_ lease: ModelUseLease, checkCancellation: () throws -> Void,
                                       _ body: (String) throws -> T) throws -> T {
        let variant = try variant(lease.descriptor)
        let (input, stamp) = try lease.directory.regularFD(variant.filename)
        defer { close(input) }
        try lease.check()
        try lease.directory.checkFile(variant.filename, fd: input, expected: stamp)
        try checkHeader(input, size: stamp.size, variant: variant)
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("stt-weights.XXXXXX").path.utf8CString)
        let output = mkstemp(&template)
        guard output >= 0 else { throw ModelRepositoryCode.storageUnavailable }
        defer { close(output) }
        guard unlink(template) == 0 else { throw ModelRepositoryCode.cleanupFailed }
        var hash = SHA256()
        var buffer = Data(count: 1024 * 1024)
        var total: Int64 = 0
        while total < variant.size {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            guard count > 0 else { throw ModelRepositoryCode.integrityMismatch }
            let bytes = buffer.prefix(count)
            hash.update(data: bytes)
            try ModelPackageDirectory.writeAll(bytes, fd: output)
            total += Int64(count)
        }
        guard total == variant.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == variant.digest,
              lseek(output, 0, SEEK_SET) == 0 else { throw ModelRepositoryCode.integrityMismatch }
        try lease.directory.checkFile(variant.filename, fd: input, expected: stamp)
        try lease.check()
        try checkCancellation()
        return try body("/dev/fd/\(output)")
    }
}
