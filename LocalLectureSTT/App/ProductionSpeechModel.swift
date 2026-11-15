import Foundation

enum ProductionSpeechModel {
    static var displayName: String {
        "\(WhisperCppProfile.identity.id.rawValue) · \(WhisperCppModelValidator.Variant.large.rawValue)"
    }

    static func make(repository: FileModelRepository,
                     catalog: BundledModelCatalogLoader = .init()) throws -> RecordingSpeechModel {
        let entries = try catalog.load().entries
        guard let descriptor = entries.first(where: {
            (try? WhisperCppModelValidator.variant($0)) == .large
        }) else { throw STTEngineError(.unsupportedModel) }

        let options = try STTInferenceOptions(computeMode: descriptor.compute)
        return try RecordingSpeechModel(
            engine: WhisperCppSTTEngine(repository: repository),
            configuration: STTModelConfiguration(engine: descriptor.engine, model: descriptor.model, options: options),
            settings: SessionModelSettings(weightSHA256: descriptor.files[0].sha256,
                                          quantization: descriptor.quantization, inference: options,
                                          decodingStrategy: "greedy-best-of-one")
        )
    }
}
