import Darwin
import Foundation

// MARK: - Fit models
//
// Memory-fit Advisor (premium spec 05, free tier): before a serve is
// confirmed, compute whether the model plus its KV cache fits in unified
// memory *right now* — and suggest the largest context that does fit.
// Verdicts are always derived, never persisted.

enum FitVerdict: Equatable, Sendable {
    case fits(headroomGB: Double)
    case tight(headroomGB: Double)
    case wontFit(deficitGB: Double, suggestedMaxContext: Int?)
    case unknown(reason: String)

    var summary: String {
        switch self {
        case .fits(let headroom):
            return String(format: "Fits — %.1f GB headroom", headroom)
        case .tight(let headroom):
            return String(format: "Tight — only %.1f GB headroom; other apps may swap", headroom)
        case .wontFit(let deficit, let suggestion):
            var text = String(format: "Won't fit — %.1f GB short", deficit)
            if let suggestion {
                text += "; \(suggestion) tokens would fit"
            }
            return text
        case .unknown(let reason):
            return "Fit not checked: \(reason)"
        }
    }
}

/// System-wide sampled headroom, not engine allocation or model-only memory use.
struct SystemMemoryEvidence: Codable, Equatable, Sendable {
    let totalBytes: Int64
    let baselineAvailableBytes: Int64
    let minimumAvailableBytes: Int64
    let endingAvailableBytes: Int64
    let sampleCount: Int
    let missedSamples: Int
    let startedAt: Date
    let endedAt: Date
    let samplingIntervalSeconds: Double

    var isValid: Bool {
        totalBytes > 0 && sampleCount >= 2 && missedSamples >= 0 && endedAt >= startedAt
            && samplingIntervalSeconds.isFinite && samplingIntervalSeconds > 0
            && [baselineAvailableBytes, minimumAvailableBytes, endingAvailableBytes].allSatisfy { (0...totalBytes).contains($0) }
            && minimumAvailableBytes <= min(baselineAvailableBytes, endingAvailableBytes)
    }
}

/// Live unified-memory snapshot via Mach probes.
struct MemorySnapshot: Codable, Equatable, Sendable {
    let totalBytes: Int64
    /// Free (including speculative) + reclaimable inactive memory, right now.
    let availableBytes: Int64

    /// Derived system-wide estimate, not a per-process or GPU allocation.
    var unavailableBytes: Int64 { max(0, totalBytes - availableBytes) }

    static func probe() -> MemorySnapshot? {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        // Free already includes speculative pages. Purgeable pages overlap
        // other categories, so use free + inactive as a headroom estimate.
        // https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        return MemorySnapshot(totalBytes: Int64(total), availableBytes: min(Int64(total), Int64(pages * UInt64(pageSize))))
    }
}

/// Processor load, swap in use and the free space on one volume, read together.
struct SystemLoadReading: Equatable, Sendable {
    /// One-minute run-queue average; equal to `processorCount` means every core is busy.
    let loadAverage: Double
    let processorCount: Int
    let swapUsedBytes: Int64?
    let swapTotalBytes: Int64?
    let volumeName: String?
    let volumeFreeBytes: Int64?
    let volumeTotalBytes: Int64?

    var busyFraction: Double { processorCount > 0 ? loadAverage / Double(processorCount) : 0 }

    /// Reads the volume holding `path`; nil only when the load average is unavailable.
    static func probe(volumeOf path: String?) -> SystemLoadReading? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) >= 1, loads[0].isFinite, loads[0] >= 0 else { return nil }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapRead = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let values = path.flatMap { try? URL(fileURLWithPath: $0).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey]) }
        return SystemLoadReading(
            loadAverage: loads[0], processorCount: ProcessInfo.processInfo.activeProcessorCount,
            swapUsedBytes: swapRead ? Int64(clamping: swap.xsu_used) : nil,
            swapTotalBytes: swapRead ? Int64(clamping: swap.xsu_total) : nil,
            volumeName: values?.volumeLocalizedName, volumeFreeBytes: values?.volumeAvailableCapacityForImportantUsage,
            volumeTotalBytes: values?.volumeTotalCapacity.map(Int64.init))
    }
}
