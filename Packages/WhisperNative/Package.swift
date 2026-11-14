// swift-tools-version: 6.0
import PackageDescription

// The v1.9.5 release points to build b5454 of the same source revision.
let package = Package(
    name: "WhisperNative",
    platforms: [.macOS(.v15)],
    products: [.library(name: "WhisperNative", targets: ["whisper"])],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        )
    ]
)
