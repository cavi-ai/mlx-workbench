import SwiftUI
import AppKit

// MARK: - Shared UI helpers for the workbench views

struct ErrorBanner: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.systemRed)
                .padding(WorkbenchSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkbenchColor.systemRed.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        }
    }
}

struct WorkbenchStatus: Equatable {
    enum Tone: Equatable {
        case neutral
        case information
        case success
        case warning
        case failure
    }

    let label: String
    let tone: Tone

    static let idle = WorkbenchStatus(label: "Idle", tone: .neutral)
    static let pending = WorkbenchStatus(label: "Pending", tone: .warning)
    static let running = WorkbenchStatus(label: "Running", tone: .information)
    static let ready = WorkbenchStatus(label: "Ready", tone: .information)
    static let completed = WorkbenchStatus(label: "Completed", tone: .information)
    static let converted = WorkbenchStatus(label: "Converted", tone: .information)
    static let verified = WorkbenchStatus(label: "Verified", tone: .success)
    static let enabled = WorkbenchStatus(label: "Enabled", tone: .success)
    static let disabled = WorkbenchStatus(label: "Disabled", tone: .neutral)
    static let warning = WorkbenchStatus(label: "Warning", tone: .warning)
    static let failure = WorkbenchStatus(label: "Failed", tone: .failure)
    static let queued = WorkbenchStatus(label: "Queued", tone: .information)
    static let stopped = WorkbenchStatus(label: "Stopped", tone: .neutral)
    static let unknown = WorkbenchStatus(label: "Unknown", tone: .neutral)

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = trimmed
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        switch canonical {
        case "": self = .unknown
        case "pending": self = .pending
        case "running", "started", "active": self = .running
        case "converted": self = .converted
        case "ready", "ok": self = .ready
        case "completed": self = .completed
        case "verified": self = .verified
        case "enabled": self = .enabled
        case "disabled": self = .disabled
        case "waiting", "gone", "warning", "unreadable", "issue":
            self = WorkbenchStatus(label: Self.displayLabel(for: trimmed), tone: .warning)
        case "failed", "failure", "error": self = .failure
        case "queued": self = .queued
        case "stopped": self = .stopped
        case "unknown": self = .unknown
        case "inspectingsource":
            self = WorkbenchStatus(label: "Inspecting Source", tone: .information)
        case "existingmodelfound":
            self = WorkbenchStatus(label: "Existing Model Found", tone: .success)
        case "previewing", "previewingconversion":
            self = WorkbenchStatus(label: canonical == "previewing" ? "Previewing" : "Previewing Conversion", tone: .information)
        case "readytoconfirm":
            self = WorkbenchStatus(label: "Ready to Confirm", tone: .warning)
        case "verifying":
            self = WorkbenchStatus(label: "Verifying", tone: .information)
        case "verificationfailed":
            self = WorkbenchStatus(label: "Verification Failed", tone: .failure)
        case "needsconversion":
            self = WorkbenchStatus(label: "Needs Conversion", tone: .warning)
        case "needsruntime":
            self = WorkbenchStatus(label: "Needs Runtime", tone: .warning)
        case "incompletecache":
            self = WorkbenchStatus(label: "Incomplete Cache", tone: .warning)
        case "unsupported":
            self = WorkbenchStatus(label: "Unsupported", tone: .warning)
        case "duplicate":
            self = WorkbenchStatus(label: "Duplicate", tone: .warning)
        case "quarantined":
            self = WorkbenchStatus(label: "Quarantined", tone: .neutral)
        case "available":
            self = WorkbenchStatus(label: "Available", tone: .success)
        case "low":
            self = WorkbenchStatus(label: "Low", tone: .warning)
        case "medium":
            self = WorkbenchStatus(label: "Medium", tone: .information)
        case "high":
            self = WorkbenchStatus(label: "High", tone: .information)
        default:
            // External tools can add states independently. Preserve their
            // actual value instead of laundering it into a false "Unknown".
            self = WorkbenchStatus(label: Self.displayLabel(for: trimmed), tone: .neutral)
        }
    }

    private init(label: String, tone: Tone) {
        self.label = label
        self.tone = tone
    }

    private static func displayLabel(for rawValue: String) -> String {
        let separated = rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var result = ""
        for character in separated {
            if character.isUppercase,
               let previous = result.last,
               previous.isLowercase || previous.isNumber {
                result.append(" ")
            }
            result.append(character)
        }
        return result
            .split(whereSeparator: \.isWhitespace)
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    var color: Color {
        switch tone {
        case .neutral: return WorkbenchColor.graphiteMuted
        case .information: return WorkbenchColor.fluxTeal
        case .success: return WorkbenchColor.verifiedGreen
        case .warning: return WorkbenchColor.thermalAmber
        case .failure: return WorkbenchColor.systemRed
        }
    }
}

struct StatusBadge: View {
    let status: WorkbenchStatus

    init(status: WorkbenchStatus) {
        self.status = status
    }

    init(state: String) {
        self.status = WorkbenchStatus(rawValue: state)
    }

    var body: some View {
        Text(status.label)
            .font(WorkbenchTypography.monoUtility)
            .textCase(.uppercase)
            .padding(.horizontal, WorkbenchSpacing.xs)
            .padding(.vertical, WorkbenchSpacing.xxs)
            .foregroundColor(status.color)
            .background(status.color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
    }
}

struct StatusPill: View {
    let state: String

    var body: some View {
        StatusBadge(state: state)
    }
}

struct WorkbenchSurface<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = WorkbenchSpacing.surfaceInset, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchColor.instrumentSurface)
            .overlay {
                RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous)
                    .stroke(WorkbenchColor.hairline, lineWidth: WorkbenchSpacing.hairline)
            }
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous))
    }
}

struct PreviewDictView: View {
    let value: [String: Any]
    var maxDepth: Int = 3

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text(for: value, depth: 0))
                .font(WorkbenchTypography.monoUtility)
                .foregroundColor(WorkbenchColor.graphiteInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func text(for object: Any, depth: Int) -> String {
        if depth > maxDepth {
            return "<…>\n"
        }
        guard let dict = object as? [String: Any] else {
            return "\(nullSafe(object))\n"
        }
        var lines = ""
        let indent = String(repeating: "  ", count: depth)
        for key in dict.keys.sorted() {
            let value = dict[key]
            if let nested = value as? [String: Any] {
                lines += "\(indent)\(key):\n"
                lines += text(for: nested, depth: depth + 1)
            } else if let array = value as? [Any] {
                lines += "\(indent)\(key): [\(array.count) items]\n"
            } else {
                lines += "\(indent)\(key): \(nullSafe(value))\n"
            }
        }
        return lines
    }

    private func nullSafe(_ value: Any?) -> String {
        guard let value else { return "null" }
        if value is NSNull { return "null" }
        return "\(value)"
    }
}

/// Raw agent payloads stay inspectable but collapsed by default, so primary
/// surfaces show structured summaries instead of JSON dumps.
struct RawJSONDisclosure: View {
    let title: String
    let value: [String: Any]

    init(_ title: String = "Raw data", value: [String: Any]) {
        self.title = title
        self.value = value
    }

    var body: some View {
        DisclosureGroup {
            PreviewDictView(value: value)
                .padding(.top, WorkbenchSpacing.xxs)
        } label: {
            Text(title)
                .font(WorkbenchTypography.navigation)
                .foregroundColor(WorkbenchColor.graphiteMuted)
        }
    }
}

/// Guided runtime setup: one button that runs `make install` with a live
/// log tail, then re-probes. Hidden entirely when the app isn't running
/// from a checkout (no repo root to install into).
struct RuntimeInstallView: View {
    @ObservedObject var installer: RuntimeInstaller
    let onFinished: () -> Void

    @State private var showConfirm = false

    var body: some View {
        if installer.repoRoot != nil {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Button("Install Runtime…") { showConfirm = true }
                        .buttonStyle(.borderedProminent)
                        .tint(WorkbenchColor.fluxTeal)
                        .disabled(!installer.canInstall)
                    if installer.state == .running {
                        ProgressView()
                            .controlSize(.small)
                        Text(installer.summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if installer.state == .succeeded {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(WorkbenchColor.verifiedGreen)
                    }
                }
                if case .failed(let reason) = installer.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(WorkbenchColor.systemRed)
                }
                if !installer.logTail.isEmpty {
                    DisclosureGroup("Install log") {
                        ScrollView {
                            Text(installer.logTail.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                        .padding(.top, WorkbenchSpacing.xxs)
                    }
                }
            }
            .confirmationDialog(
                "Install the convert/serve runtime?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("Run make install") {
                    Task {
                        await installer.install()
                        onFinished()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Runs `make install` in the mlx-workbench checkout: creates the .venv (Python 3.12) and downloads the convert/serve packages. This can take several minutes.")
            }
        }
    }
}

struct SectionTitle: View {    let text: String

    var body: some View {
        Text(text)
            .font(WorkbenchTypography.section)
            .foregroundColor(WorkbenchColor.graphiteInk)
    }
}

extension View {
    func formSection<SupplementalContent: View>(@ViewBuilder content: () -> SupplementalContent) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                self
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(WorkbenchSpacing.md)
            .background(WorkbenchColor.instrumentSurface)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.surface, style: .continuous))
        }
}
