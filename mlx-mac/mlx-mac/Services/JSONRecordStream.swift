import Foundation

/// Frames objects in a JSON array without retaining the entire encoded archive.
/// JSONDecoder still validates each complete object; the framer validates array syntax.
enum JSONRecordStream {
    static func forEach(at url: URL, chunkSize: Int = 65_536, _ visit: (Data) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 3) ?? Data()
        if prefix != Data([0xEF, 0xBB, 0xBF]) { try input.seek(toOffset: 0) }
        enum State { case start, first, value, separator, end }
        var state = State.start
        var depth = 0, quoted = false, escaped = false
        var record = Data()
        func invalid() -> DecodingError {
            .dataCorrupted(.init(codingPath: [], debugDescription: "Expected a JSON array of objects."))
        }
        while let chunk = try input.read(upToCount: max(1, chunkSize)), !chunk.isEmpty {
            try chunk.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var start: Int? = depth > 0 ? 0 : nil
                for offset in buffer.indices {
                    let byte = buffer[offset]
                    if depth > 0 {
                        if quoted {
                            if escaped { escaped = false }
                            else if byte == 92 { escaped = true }
                            else if byte == 34 { quoted = false }
                        } else {
                            if byte == 34 { quoted = true }
                            else if byte == 123 || byte == 91 { depth += 1 }
                            else if byte == 125 || byte == 93 {
                                depth -= 1
                                if depth == 0 {
                                    record.append(buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start!), count: offset - start! + 1)
                                    try visit(record)
                                    record.removeAll(keepingCapacity: false)
                                    start = nil; state = .separator
                                }
                            }
                        }
                        continue
                    }
                    if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
                    switch state {
                    case .start:
                        guard byte == 91 else { throw invalid() }; state = .first
                    case .first where byte == 93:
                        state = .end
                    case .first, .value:
                        guard byte == 123 else { throw invalid() }
                        depth = 1; start = offset
                    case .separator:
                        if byte == 44 { state = .value }
                        else if byte == 93 { state = .end }
                        else { throw invalid() }
                    case .end:
                        throw invalid()
                    }
                }
                if let start {
                    record.append(buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start), count: buffer.count - start)
                }
            }
        }
        guard state == .end, depth == 0 else { throw invalid() }
    }
}
