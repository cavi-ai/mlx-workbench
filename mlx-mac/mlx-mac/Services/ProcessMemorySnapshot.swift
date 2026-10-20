import Darwin
import Foundation

/// Resident pages reported by macOS, independent of model-fit headroom.
struct ProcessMemorySnapshot: Equatable, Sendable {
    struct Entry: Equatable, Identifiable, Sendable {
        let pid: Int32
        let name: String
        let residentBytes: UInt64
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
        var entries: [Entry] = []
        for pid in Set(pids.prefix(min(Int(count), pids.count))) where pid > 0 {
            var info = proc_taskinfo()
            let size = MemoryLayout<proc_taskinfo>.size
            let bytes = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(size)) }
            guard bytes == size, info.pti_resident_size > 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 1024)
            let length = nameBuffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            let name = length > 0
                ? String(decoding: nameBuffer.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : "Process \(pid)"
            entries.append(.init(pid: pid, name: name, residentBytes: info.pti_resident_size))
        }
        guard !entries.isEmpty else { throw ReadError.unavailable }
        entries.sort { $0.residentBytes == $1.residentBytes ? $0.pid < $1.pid : $0.residentBytes > $1.residentBytes }
        return Self(processes: entries)
    }
}
