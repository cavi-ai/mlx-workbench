import Foundation

/// A snapshot of reported model allocations and observed process RSS; these are separate measurements.
enum ServingMemory {
    struct Input: Equatable {
        var modelPID: Int?
        var gatewayPID: Int?
        var hostPID: Int?
        var reportedBytes: Int64?
        var unknownOwnership = false
        var stale = false
    }

    struct Row: Equatable {
        let modelPID: Int?
        let gatewayPID: Int?
        let hostPID: Int?
        let reportedBytes: UInt64?
        let readings: [Int: UInt64]
        let unknownOwnership: Bool

        var processIDs: Set<Int> { Set([modelPID, gatewayPID, hostPID].compactMap { $0 }) }
    }

    struct Summary: Equatable {
        let measuredBytes: UInt64?
        let measuredProcesses: Int
        let identifiedProcesses: Int
        let unknownOwners: Int
        let overflow: Bool
    }

    static func row(_ input: Input, readings: [Int: UInt64]) -> Row {
        func valid(_ pid: Int?) -> Int? {
            guard let pid, pid > 0, pid <= Int(Int32.max) else { return nil }
            return pid
        }
        guard !input.stale else { return Row(modelPID: nil, gatewayPID: nil, hostPID: nil, reportedBytes: nil, readings: [:], unknownOwnership: true) }
        let model = valid(input.modelPID), gateway = valid(input.gatewayPID), host = valid(input.hostPID)
        let ids = Set([model, gateway, host].compactMap { $0 })
        return Row(modelPID: model, gatewayPID: gateway, hostPID: host,
                   reportedBytes: input.reportedBytes.flatMap { $0 >= 0 ? UInt64($0) : nil },
                   readings: readings.filter { ids.contains($0.key) },
                   unknownOwnership: input.unknownOwnership || (input.modelPID != nil && model == nil) || ids.isEmpty)
    }

    static func summary(_ rows: [Row]) -> Summary {
        let ids = rows.reduce(into: Set<Int>()) { $0.formUnion($1.processIDs) }
        let readings = rows.reduce(into: [Int: UInt64]()) { result, row in
            for (pid, bytes) in row.readings { result[pid] = bytes }
        }
        var total: UInt64 = 0
        var overflow = false
        for pid in ids {
            guard let bytes = readings[pid] else { continue }
            let result = total.addingReportingOverflow(bytes)
            total = result.partialValue
            overflow = overflow || result.overflow
        }
        return Summary(measuredBytes: readings.isEmpty || overflow ? nil : total,
                       measuredProcesses: ids.filter { readings[$0] != nil }.count,
                       identifiedProcesses: ids.count,
                       unknownOwners: rows.filter(\.unknownOwnership).count,
                       overflow: overflow)
    }
}
