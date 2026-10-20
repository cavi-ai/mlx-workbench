import Darwin
import Foundation

/// A bounded, read-only excerpt from an engine-reported installation log.
enum BackendInstallLog: Equatable, Sendable {
    case content(String, truncated: Bool)
    case empty
    case unavailable

    static let byteLimit = 64 * 1024
    static let lineLimit = 80

    static func read(path: String) -> Self {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return .unavailable }
        // Nonblocking open plus descriptor inspection refuses FIFOs and devices without waiting.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .unavailable }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(byteLimit) ? end - UInt64(byteLimit) : 0
            try handle.seek(toOffset: start)
            var data = try handle.read(upToCount: byteLimit) ?? Data()
            guard !data.isEmpty else { return .empty }
            if start > 0, let newline = data.firstIndex(of: 10), newline < data.index(before: data.endIndex) {
                data = Data(data[data.index(after: newline)...])
            }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            return .content(lines.suffix(lineLimit).joined(separator: "\n"),
                            truncated: start > 0 || lines.count > lineLimit)
        } catch { return .unavailable }
    }
}
