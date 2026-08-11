import SwiftUI

// MARK: - QuickStartView
// Health summary and quick actions for the primary loops.

struct QuickStartView: View {
    @ObservedObject var appHost: AppHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                quickStatusSection
                totalsSection
                SectionTitle(text: "Where models live")
                rootsList
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var quickStatusSection: some View {
        HStack(spacing: 10) {
            statusCard("Agent", healthText, healthColor)
            statusCard("Convert", runtimeReport.convert.message, runtimeReport.convert.ok ? .green : .orange)
            statusCard("Serve", runtimeReport.serve.message, runtimeReport.serve.ok ? .green : .orange)
        }
    }

    private func statusCard(_ title: String, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(text)
                .font(.callout)
                .foregroundColor(color)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var healthText: String {
        switch appHost.agentHealth {
        case .notConfigured:
            return "No mlx-agent configured."
        case .notFound(_, let cli):
            return "Missing \(cli)"
        case .ready(_, let cli):
            return cli
        }
    }

    private var healthColor: Color {
        switch appHost.agentHealth {
        case .ready: return .green
        case .notFound: return .red
        case .notConfigured: return .orange
        }
    }

    private var runtimeReport: RuntimeReport {
        appHost.runtimeReport
    }

    private var totalsSection: some View {
        Group {
            if let totals = appHost.scanResult?.totals {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Inventory")
                    HStack(spacing: 24) {
                        metric("GGUF", "\(totals.gguf)")
                        metric("Pending", "\(totals.pending)")
                        metric("Converted", "\(totals.converted)")
                        metric("Bytes", ByteCountFormatter.string(fromByteCount: totals.bytes, countStyle: .file))
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).fontWeight(.semibold)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }

    private var rootsList: some View {
        let roots = appHost.config.ggufRoots.isEmpty ? appHost.discoveredRoots : appHost.config.ggufRoots
        return VStack(alignment: .leading, spacing: 4) {
            if roots.isEmpty {
                Text("No scan roots detected.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(roots, id: \.self) { root in
                    Text(root).font(.caption)
                }
            }
        }
    }
}