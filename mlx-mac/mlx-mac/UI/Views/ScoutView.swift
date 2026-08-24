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
            VStack(alignment: .leading, spacing: 16) {
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
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                }
                ErrorBanner(text: errorMessage)
                Spacer()
            }
            .padding()
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Catalog Metadata")
                Spacer()
                Button(appHost.isRefreshingCatalog ? "Refreshing…" : "Refresh Metadata") {
                    Task { await appHost.refreshCatalog() }
                }
                .disabled(appHost.isRefreshingCatalog)
            }
            Text("Metadata only. Local installation truth comes from the Library scan, not this catalog cache.")
                .font(.caption)
                .foregroundColor(.secondary)
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
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if case .missing = appHost.catalog {
                Text("No catalog cache is stored yet. Refresh metadata once a provider is configured.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let snapshot = appHost.catalog.snapshot, !snapshot.records.isEmpty {
                catalogResults(snapshot)
            }
        }
        .formSection {}
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Discovery")
            HStack {
                Picker("Role", selection: $role) {
                    ForEach(roleChoices, id: \.self) { choice in
                        Text(choice.isEmpty ? "Any" : choice).tag(choice)
                    }
                }
                .frame(width: 180)
                TextField("Limit", text: $limitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Toggle("Fast", isOn: $fast)
                Spacer()
                Button("Discover") {
                    discover()
                }
                .disabled(isScouting)
            }
        }
        .formSection {}
    }

    private func catalogResults(_ snapshot: CatalogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Catalog Entries (\(snapshot.records.count))")
                Spacer()
                Text("Remote metadata only")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            List(snapshot.records, id: \.self) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.repoIdentity)
                        .font(.body)
                    HStack(spacing: 8) {
                        if let roles = record.roles, !roles.isEmpty {
                            Text(roles.map(\.title).joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if !record.formats.isEmpty {
                            Text(record.formats.joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(Self.timestampFormatter.string(from: record.updatedAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(record.sourceURL.absoluteString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                        Text(candidate.repo).font(.body)
                        HStack(spacing: 8) {
                            if let roles = candidate.roles, !roles.isEmpty {
                                Text(roles.joined(separator: ", "))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            if let ram = candidate.paramsText {
                                Text(ram).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if let license = candidate.license {
                        Text(license).font(.caption).foregroundColor(.secondary)
                    }
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
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
