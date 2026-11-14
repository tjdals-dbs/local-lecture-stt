import Foundation

struct WhisperKitModelValidator: OfflineModelFormatValidating {
    func validate(_ descriptor: ModelPackageDescriptor, directory: ModelPackageDirectory) async throws {
        guard descriptor.engine == WhisperKitSTTEngine.identity,
              descriptor.model.checksum == "487780131212c7d2d4afcbc2e1812e648091a0829b9a60aae3c9443b7dca6ae2", descriptor.format == "whisperkit-coreml-v1",
              descriptor.variant == "large-v3", descriptor.quantization == "none",
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
