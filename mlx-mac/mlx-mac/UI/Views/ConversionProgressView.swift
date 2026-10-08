import SwiftUI

// MARK: - ConversionProgressSnapshot

/// What a running conversion has observably done: bytes in the destination
/// against the agent's size estimate, and the converter's log tail. Converters
/// write nothing while they load and quantize, so the fraction exists only once
/// writing starts; before that the ring is indeterminate.
struct ConversionProgressSnapshot: Equatable {
    let writtenBytes: Int64
    let estimatedBytes: Int64?
    let logLines: [String]

    var fraction: Double? {
        guard writtenBytes > 0, let estimatedBytes, estimatedBytes > 0 else { return nil }
        return min(1, Double(writtenBytes) / Double(estimatedBytes))
    }

    var phaseTitle: String {
        writtenBytes == 0 ? "Loading and quantizing weights" : "Writing MLX weights"
    }

    var sizeText: String? {
        guard writtenBytes > 0 else { return nil }
        let written = LibraryTablePresentation.byteCount(writtenBytes)
        guard let estimatedBytes else { return "\(written) written" }
        return "\(written) of about \(LibraryTablePresentation.byteCount(estimatedBytes))"
    }

    /// The intake estimate for the bit width the destination names (`-MLX-<bits>bit`).
    static func estimate(for workflow: ConversionWorkflow) -> Int64? {
        guard let estimates = workflow.estimatedOutputBytes, let bits = workflow.destinationBits else { return nil }
        return estimates[String(bits)]
    }
}

// MARK: - ConversionProgressReader

enum ConversionProgressReader {
    static func writtenBytes(at path: String, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Last lines of a converter log; a progress bar redrawn with `\r` keeps only its latest state.
    static func logTail(at path: String?, maxLines: Int = 200, maxBytes: Int = 64 * 1024) -> [String] {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let latest = line.split(separator: "\r").last.map(String.init) ?? ""
                let trimmed = latest.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
        return Array(lines.suffix(maxLines))
    }

    /// The agent's ISO 8601 timestamps carry microseconds, which ISO8601DateFormatter does not parse.
    static func date(fromAgentTimestamp value: String?) -> Date? {
        guard let value else { return nil }
        let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    static func elapsedText(seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

// MARK: - ProgressRing

struct ProgressRing: View {
    let fraction: Double?
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(WorkbenchColor.hairline, lineWidth: 8)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(WorkbenchColor.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .workbenchAnimation(WorkbenchMotion.progress, value: fraction)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(WorkbenchTypography.emphasis)
                    .foregroundStyle(WorkbenchColor.ink)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(WorkbenchColor.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .workbenchAnimation(WorkbenchMotion.spin, value: spinning)
                    .onAppear { spinning = true }
            }
        }
        .frame(width: 76, height: 76)
        .accessibilityElement()
        .accessibilityLabel("Conversion progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

// MARK: - ConversionProgressCard

struct ConversionProgressCard: View {
    let snapshot: ConversionProgressSnapshot
    let startedAt: Date?

    var body: some View {
        HStack(alignment: .center, spacing: WorkbenchSpacing.md) {
            ProgressRing(fraction: snapshot.fraction)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(snapshot.phaseTitle)
                    .font(WorkbenchTypography.emphasis)
                    .foregroundStyle(WorkbenchColor.ink)
                if let size = snapshot.sizeText {
                    Text(size)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("Elapsed \(ConversionProgressReader.elapsedText(seconds: max(0, Int(context.date.timeIntervalSince(startedAt)))))")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - ConversionLogAccordion

struct ConversionLogAccordion: View {
    let lines: [String]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(lines.isEmpty ? "No log output yet." : lines.joined(separator: "\n"))
                        .font(WorkbenchTypography.value)
                        .foregroundStyle(WorkbenchColor.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log-end")
                }
                .frame(maxHeight: 220)
                .onChange(of: lines) { _, _ in proxy.scrollTo("log-end", anchor: .bottom) }
            }
        } label: {
            Text("Log")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.ink)
        }
    }
}
