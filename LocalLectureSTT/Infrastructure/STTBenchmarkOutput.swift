import Darwin
import Foundation

/// Explicit disposable developer output. Atomic directory admission, never removes/replaces output.
struct STTBenchmarkOutput: Sendable {
    let directory: URL
    init(_ directory: URL) throws {
        guard directory.isFileURL, mkdir(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteFileExists) }
        self.directory = directory
    }
    func write(_ report: STTBenchmarkReport) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .withoutOverwriting)
        var view = "Case: \(report.input.caseID)\nPCM: \(report.input.pcmSHA256)\nSuccess: \(report.success)\n\(report.policy)\n"
        for m in report.measurements {
            view += "\nRepetition \(m.repetition) warmup=\(m.warmup) load=\(m.loadSeconds) final=\(m.finalSeconds?.description ?? "null") RTF=\(m.rtf?.description ?? "null")\nFailure: \(m.failure?.code.rawValue ?? "none")\n"
            for segment in m.terminal?.segments ?? [] { view += "[\(segment.start.rawValue),\(segment.end.rawValue)] \(segment.text)\n" }
        }
        try Data(view.utf8).write(to: directory.appendingPathComponent("report.txt"), options: .withoutOverwriting)
    }
}
