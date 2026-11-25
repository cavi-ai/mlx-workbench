import Darwin
import Foundation

/// Per-process memory reported by macOS, independent of model-fit headroom.
/// The value is the physical footprint Activity Monitor shows as Memory, or
/// resident pages when the footprint cannot be read.
struct ProcessMemorySnapshot: Equatable, Sendable {
    struct Entry: Equatable, Identifiable, Sendable {
        let pid: Int32
        let name: String
        let memoryBytes: UInt64
        var id: Int32 { pid }
    }
    let processes: [Entry]

    enum ReadError: Error { case unavailable }

    static func probe() throws -> Self {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw ReadError.unavailable }
        // Allow for processes starting between enumeration calls, with a fixed upper bound.
        var pids = [Int32](repeating: 0, count: min(Int(estimate) + 1024, 65_536))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { throw ReadError.unavailable }
        return try probe(pids: Array(pids.prefix(min(Int(count), pids.count))))
    }

    static func probe(pids: [Int32]) throws -> Self {
        var entries: [Entry] = []
        for pid in Set(pids) where pid > 0 {
            guard let bytes = footprint(pid) ?? resident(pid), bytes > 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 1024)
            let length = nameBuffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            let name = length > 0
                ? String(decoding: nameBuffer.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : "Process \(pid)"
            entries.append(.init(pid: pid, name: name, memoryBytes: bytes))
        }
        guard !entries.isEmpty || pids.isEmpty else { throw ReadError.unavailable }
        entries.sort { $0.memoryBytes == $1.memoryBytes ? $0.pid < $1.pid : $0.memoryBytes > $1.memoryBytes }
        return Self(processes: entries)
    }

    private static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    private static func resident(_ pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let bytes = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(size)) }
        return bytes == size ? info.pti_resident_size : nil
    }
}
