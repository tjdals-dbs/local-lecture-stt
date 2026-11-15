import Foundation
#if !SWIFT_PACKAGE
@testable import LocalLectureSTT
#endif

struct WhisperKitModelValidator: OfflineModelFormatValidating {
    static func matchesPin(_ descriptor: ModelPackageDescriptor) -> Bool {
        guard descriptor.model.revision == "0f63a7800b00dd0226abd051b906c246e1907482" else { return false }
        switch (descriptor.variant, descriptor.model.id.rawValue) {
        case ("large-v3", "openai/whisper-large-v3-coreml"):
            return descriptor.model.checksum == "487780131212c7d2d4afcbc2e1812e648091a0829b9a60aae3c9443b7dca6ae2"
        case ("large-v3-turbo", "openai/whisper-large-v3-turbo-coreml"):
            return descriptor.model.checksum == "484e1ae56d5aae63ae1b42ee6df5d3f46c07a546dccb7d8b91b4efee97ba7600"
        default: return false
        }
    }

    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws {
        guard descriptor.engine == WhisperKitSTTEngine.identity,
              Self.matchesPin(descriptor), descriptor.format == WhisperKitProfile.format,
              descriptor.quantization == "none",
              descriptor.compute == WhisperKitSTTEngine.compute else { throw ModelRepositoryCode.incompatible }
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let dir = try directory.child(component + ".mlmodelc")
            let data = try dir.readMetadata("metadata.json")
            guard let metadata = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !metadata.isEmpty, try dir.child("weights").info("weight.bin").st_size > 0,
                  (try dir.info("coremldata.bin")).st_size > 0 else { throw ModelRepositoryCode.incompatible }
            // Real Core ML metadata plus parsed tokenizer; repository independently verifies all bytes.
            guard metadata[0]["inputSchema"] != nil, metadata[0]["outputSchema"] != nil else { throw ModelRepositoryCode.incompatible }
        }
        _ = try await LocalWhisperTokenizer.load(directory)
    }
}
