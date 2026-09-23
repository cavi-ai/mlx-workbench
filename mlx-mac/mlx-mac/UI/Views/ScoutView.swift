import AppKit
import SwiftUI

// MARK: - ScoutView
// Discover MLX models for this host, by role.

struct ScoutView: View {
    @ObservedObject var appHost: AppHost

    @State private var role = ""
    @State private var roleChoices = ["", "coding", "writing", "reading", "terminal", "agent"]
    @State private var limitText = "10"
    @State private var fast = false
    @State private var isScouting = false
    @State private var candidates: [DiscoverCandidate] = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                catalogSection
                formSection
                if isScouting {
                    ProgressView("Discovering models…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else if !candidates.isEmpty {
                    resultsSection
                } else {
                    Text("Run a discovery to see candidates.")
                        .foregroundStyle(WorkbenchColor.muted)
                        .padding(.top, 12)
                }
                ErrorBanner(text: errorMessage)
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) { catalogHeader }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { catalogHeader }
            }
            Text("Metadata only. Local installation truth comes from the Library scan, not this catalog cache.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    statusRow(label: "Status", value: appHost.catalog.statusLabel)
                    if let snapshot = appHost.catalog.snapshot {
                        statusRow(label: "Source", value: snapshot.sourceLabel)
                        statusRow(label: "Revision", value: snapshot.revision)
                        statusRow(label: "Last Refresh", value: Self.timestampFormatter.string(from: snapshot.fetchedAt))
                    }
                }
                Spacer()
            }
            if let message = appHost.catalog.detailMessage {
                Text(message)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else if case .missing = appHost.catalog {
                Text("Catalog metadata has not been fetched yet. Refresh Metadata to fetch it.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            if let snapshot = appHost.catalog.snapshot, !snapshot.records.isEmpty {
                catalogResults(snapshot)
            }
        }
        .formSection {}
    }

    @ViewBuilder
    private var catalogHeader: some View {
        SectionTitle(text: "Catalog Metadata")
        Spacer()
        Button(appHost.isRefreshingCatalog ? "Refreshing…" : "Refresh Metadata") {
            Task { await appHost.refreshCatalog() }
        }
        .buttonStyle(.bordered)
        .disabled(appHost.isRefreshingCatalog)
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Discovery")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { discoveryControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { discoveryControls }
            }
        }
        .formSection {}
    }

    @ViewBuilder
    private var discoveryControls: some View {
        Picker("Role", selection: $role) {
            ForEach(roleChoices, id: \.self) { choice in
                Text(choice.isEmpty ? "Any" : choice).tag(choice)
            }
        }
        .frame(maxWidth: 180, alignment: .leading)
        TextField("Limit", text: $limitText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
        Toggle("Fast", isOn: $fast)
        Button("Discover") { discover() }
            .buttonStyle(.borderedProminent)
            .disabled(isScouting)
    }

    private func catalogResults(_ snapshot: CatalogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Catalog Entries (\(snapshot.records.count))")
                Spacer()
                Text("Remote metadata only")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            List(snapshot.records, id: \.self) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.repoIdentity)
                        .font(WorkbenchTypography.body)
                    HStack(spacing: 8) {
                        if let roles = record.roles, !roles.isEmpty {
                            Text(roles.map(\.title).joined(separator: ", "))
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                        if !record.formats.isEmpty {
                            Text(record.formats.joined(separator: ", "))
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                        Text(Self.timestampFormatter.string(from: record.updatedAt))
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                    Text(record.sourceURL.absoluteString)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            .frame(height: 240)
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Candidates (\(candidates.count))")
                Spacer()
                Button("Clear") { candidates = [] }
            }
            List(candidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.repo).font(WorkbenchTypography.body)
                        HStack(spacing: 8) {
                            if let roles = candidate.roles, !roles.isEmpty {
                                Text(roles.joined(separator: ", "))
                                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            }
                            if let ram = candidate.paramsText {
                                Text(ram).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            }
                        }
                    }
                    Spacer()
                    if let license = candidate.license {
                        Text(license).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    Button("Copy repo id") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(candidate.repo, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Open on Hugging Face") {
                        if let url = URL(string: "https://huggingface.co/\(candidate.repo)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(height: 380)
        }
        .formSection {}
    }

    private func discover() {
        errorMessage = nil
        isScouting = true
        let r = role.isEmpty ? nil : role
        let l = Int(limitText.trimmingCharacters(in: .whitespaces)) ?? nil
        let isFast = fast
        Task {
            defer { isScouting = false }
            do {
                let result = try await appHost.api.discover(role: r, limit: l, fast: isFast, new: false)
                candidates = result.candidates ?? []
                if candidates.isEmpty {
                    errorMessage = "No candidates matched."
                }
            } catch let error as BridgeError {
                candidates = []
                errorMessage = error.errorDescription
            } catch {
                candidates = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            Text(value)
                .font(WorkbenchTypography.secondary)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
