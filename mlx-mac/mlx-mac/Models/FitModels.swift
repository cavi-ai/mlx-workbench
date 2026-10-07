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

/// Live unified-memory snapshot via Mach probes.
struct MemorySnapshot: Equatable, Sendable {
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
