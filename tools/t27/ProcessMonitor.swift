import Darwin
import Foundation

// External, read-only sampler. It never opens session contents or signals the app.
// Raw CPU counters are retained without interpreting their platform time units.
struct Sample: Encodable {
    let kind: String
    let elapsedSeconds: Double
    let pid: Int32
    let processStart: UInt64
    let physicalFootprintBytes: UInt64
    let residentBytes: UInt64
    let cpuUserRaw: UInt64
    let cpuSystemRaw: UInt64
    let thermalState: Int
}

func emit<T: Encodable>(_ value: T) throws {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

let args = CommandLine.arguments
guard args.count == 4, let pid = Int32(args[1]), pid > 0,
      let duration = Double(args[2]), duration.isFinite, duration > 0, duration <= 86_400,
      let interval = Double(args[3]), interval.isFinite, interval >= 1, interval <= 60 else {
    fputs("Usage: monitor PID DURATION_SECONDS INTERVAL_SECONDS (1...60)\n", stderr)
    exit(2)
}
let started = ProcessInfo.processInfo.systemUptime
var identity: UInt64?
do {
    while true {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else {
            try emit(["kind": "samplingStopped", "reason": "processUnavailable", "errno": String(errno)])
            exit(1) // A disappeared/denied process is never reported as a passed run.
        }
        if let identity, identity != usage.ri_proc_start_abstime {
            try emit(["kind": "samplingStopped", "reason": "pidReused"])
            exit(1)
        }
        identity = usage.ri_proc_start_abstime
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try emit(Sample(kind: "sample", elapsedSeconds: elapsed, pid: pid,
                        processStart: usage.ri_proc_start_abstime,
                        physicalFootprintBytes: usage.ri_phys_footprint, residentBytes: usage.ri_resident_size,
                        cpuUserRaw: usage.ri_user_time, cpuSystemRaw: usage.ri_system_time,
                        thermalState: ProcessInfo.processInfo.thermalState.rawValue))
        if elapsed >= duration { break }
        Thread.sleep(forTimeInterval: min(interval, duration - elapsed))
    }
    try emit(["kind": "samplingFinished", "note": "resource samples only; no T27 pass decision"])
} catch {
    fputs("Unable to write resource samples.\n", stderr)
    exit(1)
}
