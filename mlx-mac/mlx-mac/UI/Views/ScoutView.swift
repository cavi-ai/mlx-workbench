import AppKit
import SwiftUI

// MARK: - ScoutView
// Discover MLX models for this host, by role.

enum DiscoveryState: Equatable {
    case notRun
    case running
    case completed([DiscoverCandidate])
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var candidates: [DiscoverCandidate] {
        if case .completed(let candidates) = self { return candidates }
        return []
    }
    var symbol: String {
        switch self {
        case .notRun, .running: return "magnifyingglass"
        case .completed: return "line.3.horizontal.decrease.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    var message: String {
        switch self {
        case .notRun: return "Discover models for this Mac. Choose a role, then select Discover."
        case .running: return "Discovering models…"
        case .completed: return "No candidates matched. Try another role or adjust the limit, then Discover again."
        case .failed(let message): return "Discovery failed. \(message) Try Discover again after resolving the issue."
        }
    }
}

struct ScoutView: View {
    @ObservedObject var appHost: AppHost

    @State private var role = ""
    @State private var roleChoices = ["", "coding", "writing", "reading", "terminal", "agent"]
    @State private var limitText = "10"
    @State private var fast = false
    @State private var discoveryState: DiscoveryState = .notRun
    @State private var showsCatalogDetails = false

    private var isScouting: Bool { discoveryState.isRunning }
    private var candidates: [DiscoverCandidate] { discoveryState.candidates }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                formSection
                if !candidates.isEmpty {
                    resultsSection
                } else {
                    discoveryNotice
                }
                catalogSection
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    private var discoveryNotice: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            if isScouting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Discovering models")
            } else {
                Image(systemName: discoveryState.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            Text(discoveryState.message)
                .font(WorkbenchTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(discoveryState.isFailed ? WorkbenchColor.failure : WorkbenchColor.muted)
        .padding(.top, WorkbenchSpacing.sm)
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) { catalogHeader }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { catalogHeader }
            }
            Text(appHost.catalog.statusLabel)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            DisclosureGroup("Details and catalog entries", isExpanded: $showsCatalogDetails) {
                catalogDetails
                    .padding(.top, WorkbenchSpacing.xs)
            }
            .font(WorkbenchTypography.secondary)
        }
        .formSection {}
    }

    private var catalogDetails: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Metadata only. Local installation truth comes from the Library scan, not this catalog cache.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
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
    }

    @ViewBuilder
    private var catalogHeader: some View {
        Text("Catalog metadata").font(WorkbenchTypography.emphasis)
        Spacer()
        Button(appHost.isRefreshingCatalog ? "Refreshing…" : "Refresh Metadata") {
            Task { await appHost.refreshCatalog() }
        }
        .buttonStyle(.bordered)
        .disabled(appHost.isRefreshingCatalog)
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
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
        .disabled(isScouting)
        TextField("Limit", text: $limitText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .disabled(isScouting)
        Toggle("Fast", isOn: $fast)
            .disabled(isScouting)
        Button("Discover") { discover() }
            .buttonStyle(.borderedProminent)
            .disabled(isScouting)
    }

    private func catalogResults(_ snapshot: CatalogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                SectionTitle(text: "Catalog Entries (\(snapshot.records.count))")
                Spacer()
                Text("Remote metadata only")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            List(snapshot.records, id: \.self) { record in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(record.repoIdentity)
                        .font(WorkbenchTypography.body)
                    HStack(spacing: WorkbenchSpacing.xs) {
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
                .padding(.vertical, WorkbenchSpacing.xxxs)
            }
            .frame(height: 240)
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                SectionTitle(text: "Candidates (\(candidates.count))")
                Spacer()
                Button("Clear") { discoveryState = .notRun }
            }
            List(candidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        Text(candidate.repo).font(WorkbenchTypography.body)
                        HStack(spacing: WorkbenchSpacing.xs) {
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
        guard !isScouting else { return }
        discoveryState = .running
        let r = role.isEmpty ? nil : role
        let l = Int(limitText.trimmingCharacters(in: .whitespaces)) ?? nil
        let isFast = fast
        Task {
            do {
                let result = try await appHost.api.discover(role: r, limit: l, fast: isFast, new: false)
                discoveryState = .completed(result.candidates ?? [])
            } catch let error as BridgeError {
                discoveryState = .failed(error.errorDescription ?? error.localizedDescription)
            } catch {
                discoveryState = .failed(error.localizedDescription)
            }
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
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
