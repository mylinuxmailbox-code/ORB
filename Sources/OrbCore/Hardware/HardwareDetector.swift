import Foundation

/// Detects the Mac's chip, cores, memory, disk and derives a capability tier.
public struct HardwareDetector: HardwareDetecting {
    public init() {}

    public func detect() async -> HardwareProfile {
        let chip = Self.sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
        let isAS = chip.hasPrefix("Apple")
        let gen = Self.parseGeneration(chip)
        let total = Self.sysctlInt("hw.ncpu") ?? ProcessInfo.processInfo.processorCount
        let perf = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? Self.sysctlInt("hw.physicalcpu") ?? total
        let mem = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let gpu = isAS ? Self.gpuCores() : nil
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let free = Self.freeDiskGB()
        return HardwareProfile(chip: chip, isAppleSilicon: isAS, generation: gen, performanceCores: perf,
                               totalCores: total, gpuCores: gpu, memoryGB: (mem * 10).rounded() / 10,
                               osVersion: os, freeDiskGB: free, tier: Self.tier(memoryGB: mem, isAppleSilicon: isAS))
    }

    public static func tier(memoryGB: Double, isAppleSilicon: Bool) -> HardwareProfile.Tier {
        if memoryGB >= 48 { return .ultra }
        if memoryGB >= 24 { return .high }
        if memoryGB >= 12 && isAppleSilicon { return .standard }
        if memoryGB >= 16 { return .standard }
        return .entry
    }

    /// "Apple M3 Pro" -> 3; 0 when not parseable.
    public static func parseGeneration(_ chip: String) -> Int {
        guard let r = chip.range(of: #"Apple M(\d+)"#, options: .regularExpression) else { return 0 }
        let digits = chip[r].dropFirst("Apple M".count)
        return Int(digits) ?? 0
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &size, nil, 0) == 0 { return Int(v) }
        var v32: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v32, &size, nil, 0) == 0 { return Int(v32) }
        return nil
    }

    static func freeDiskGB() -> Double {
        let url = FileManager.default.homeDirectoryForCurrentUser
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            return Double(cap) / 1_073_741_824
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let f = attrs[.systemFreeSize] as? NSNumber { return f.doubleValue / 1_073_741_824 }
        return 0
    }

    /// GPU core count via `system_profiler SPDisplaysDataType -json` (best effort), falling back to ioreg.
    static func gpuCores() -> Int? {
        if let out = run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"]),
           let data = out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["SPDisplaysDataType"] as? [[String: Any]] {
            for d in arr {
                if let s = d["sppci_cores"] as? String, let n = Int(s) { return n }
                if let n = d["sppci_cores"] as? Int { return n }
            }
        }
        if let out = run("/usr/sbin/ioreg", ["-r", "-d", "1", "-w", "0", "-c", "AGXAccelerator"]),
           let r = out.range(of: #""gpu-core-count" = (\d+)"#, options: .regularExpression) {
            let s = out[r].split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return Int(s)
        }
        return nil
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
