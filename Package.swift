// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LocalLectureSTTBenchmarks", platforms: [.macOS(.v15)],
    products: [.executable(name: "stt-benchmark", targets: ["STTBenchmark"])],
    dependencies: [.package(path: "Packages/WhisperNative"), .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", revision: "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4")],
    targets: [.executableTarget(name: "STTBenchmark", dependencies: [.product(name: "WhisperNative", package: "WhisperNative"), .product(name: "WhisperKit", package: "argmax-oss-swift")],
        path: ".", exclude: ["Packages", "benchmark-results", "tools/t15", "tools/t16", "LocalLectureSTT/Domain/BOUNDARY.md", "LocalLectureSTT/Application/BOUNDARY.md", "LocalLectureSTT/Infrastructure/BOUNDARY.md", "LocalLectureSTT/App", "LocalLectureSTT/Features", "LocalLectureSTT/Resources", "LocalLectureSTTTests", "LocalLectureSTTIntegrationTests", "LocalLectureSTT.xcodeproj", "docs", "prompts", "tools/t14/bootstrap.py", "tools/t14/candidate.json", "tools/t14/published-files.json", "tools/t14/offline.sb", "AGENTS.md", "IMPLEMENTATION_PLAN.md", "MVP_SPEC.md", "PROJECT_STATUS.md", "README.md"],
        sources: ["LocalLectureSTT/Domain", "LocalLectureSTT/Application", "LocalLectureSTT/Infrastructure", "tools/t14/BenchmarkMain.swift", "tools/t14/LectureBatch.swift"],
        linkerSettings: [.linkedLibrary("sqlite3")])])
