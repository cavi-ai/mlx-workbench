import SwiftUI

struct LibraryGroupViewModel: Identifiable, Equatable, Hashable {
    let sourceGroup: ModelGroup
    let variants: [LibraryModel]

    var id: String {
        let anchor = variants.first?.item.path ?? sourceGroup.primaryDisplayName
        return "\(sourceGroup.normalizedModelKey)::\(anchor)"
    }

    var primaryDisplayName: String { sourceGroup.primaryDisplayName }
    var totalBytes: Int64 { variants.reduce(into: Int64(0)) { $0 += $1.item.bytes } }
    var duplicateBytes: Int64 { sourceGroup.duplicateBytes }
}

struct LibraryReadinessCount: Equatable, Hashable {
    let readiness: ModelReadiness
    let count: Int
}

enum LibraryPresentation {
    static let unknownQuantizationLabel = "Unknown"

    static func filteredGroups(
        in snapshot: LibrarySnapshot,
        search: String,
        readiness: ModelReadiness?,
        quantization: String?
    ) -> [LibraryGroupViewModel] {
        orderedGroups(snapshot.groups).compactMap { group in
            let variants = orderedVariants(in: group).filter { model in
                matchesSearch(model, query: search)
                    && matchesReadiness(model, readiness: readiness)
                    && matchesQuantization(model, quantization: quantization)
            }
            guard !variants.isEmpty else { return nil }
            return LibraryGroupViewModel(sourceGroup: group, variants: variants)
        }
    }

    static func orderedGroups(_ groups: [ModelGroup]) -> [ModelGroup] {
        groups.sorted { lhs, rhs in
            let lhsName = lhs.primaryDisplayName.localizedLowercase
            let rhsName = rhs.primaryDisplayName.localizedLowercase
            if lhsName != rhsName {
                return lhsName < rhsName
            }
            if lhs.normalizedModelKey != rhs.normalizedModelKey {
                return lhs.normalizedModelKey < rhs.normalizedModelKey
            }
            return firstPath(in: lhs) < firstPath(in: rhs)
        }
    }

    static func orderedVariants(in group: ModelGroup) -> [LibraryModel] {
        group.variants.sorted { lhs, rhs in
            let lhsName = lhs.displayName.localizedLowercase
            let rhsName = rhs.displayName.localizedLowercase
            if lhsName != rhsName {
                return lhsName < rhsName
            }
            if lhs.item.path != rhs.item.path {
                return lhs.item.path < rhs.item.path
            }
            return lhs.item.bytes > rhs.item.bytes
        }
    }

    static func quantizationOptions(in snapshot: LibrarySnapshot) -> [String] {
        var values = Set<String>()
        var hasUnknown = false

        for model in snapshot.models {
            if let quantization = normalizedQuantization(for: model) {
                values.insert(quantization)
            } else {
                hasUnknown = true
            }
        }

        var ordered = values.sorted()
        if hasUnknown {
            ordered.append(unknownQuantizationLabel)
        }
        return ordered
    }

    static func readinessCounts(in group: LibraryGroupViewModel) -> [LibraryReadinessCount] {
        let counts = group.variants.reduce(into: [ModelReadiness: Int]()) { partialResult, model in
            partialResult[model.readiness, default: 0] += 1
        }

        return ModelReadiness.allCases.compactMap { readiness in
            guard let count = counts[readiness] else { return nil }
            return LibraryReadinessCount(readiness: readiness, count: count)
        }
    }

    static func selectionCandidate(in groups: [LibraryGroupViewModel], currentPath: String?) -> String? {
        if let currentPath,
           groups.contains(where: { group in group.variants.contains(where: { $0.item.path == currentPath }) }) {
            return currentPath
        }
        return groups.first?.variants.first?.item.path
    }

    static func userFacingEvidence(_ evidence: [String]) -> [String] {
        evidence.filter { entry in
            let key = entry
                .split(separator: "=", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return key != "capabilities"
        }
    }

    static func matchesSearch(_ model: LibraryModel, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalizedQuery.isEmpty else { return true }

        let searchFields = [
            model.displayName,
            model.normalizedFamilyKey,
            model.item.name,
            model.item.path,
            model.item.modelKey,
            model.item.architecture,
            model.item.parameters,
            model.item.quantization,
            model.item.signature,
        ]
        + model.sourcePaths
        + model.outputPaths
        + userFacingEvidence(model.evidence)

        return searchFields
            .compactMap { $0 }
            .contains { $0.localizedLowercase.contains(normalizedQuery) }
    }

    private static func matchesReadiness(_ model: LibraryModel, readiness: ModelReadiness?) -> Bool {
        guard let readiness else { return true }
        return model.readiness == readiness
    }

    private static func matchesQuantization(_ model: LibraryModel, quantization: String?) -> Bool {
        guard let quantization else { return true }
        if quantization == unknownQuantizationLabel {
            return normalizedQuantization(for: model) == nil
        }
        return normalizedQuantization(for: model) == quantization
    }

    private static func normalizedQuantization(for model: LibraryModel) -> String? {
        let trimmed = model.item.quantization?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    private static func firstPath(in group: ModelGroup) -> String {
        group.variants.map(\.item.path).sorted().first ?? ""
    }
}

struct LibraryView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (String) -> Void

    @State private var search = ""
    @State private var readinessFilter: ModelReadiness?
    @State private var quantizationFilter: String?

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
    }

    private var snapshot: LibrarySnapshot? {
        appHost.librarySnapshot
    }

    private var groups: [LibraryGroupViewModel] {
        guard let snapshot else { return [] }
        return LibraryPresentation.filteredGroups(
            in: snapshot,
            search: search,
            readiness: readinessFilter,
            quantization: quantizationFilter
        )
    }

    private var visiblePaths: [String] {
        groups.flatMap { $0.variants.map(\.item.path) }
    }

    private var selectedModel: LibraryModel? {
        guard let selectedPath = appHost.selectedModelPath else { return nil }
        for group in groups {
            if let model = group.variants.first(where: { $0.item.path == selectedPath }) {
                return model
            }
        }
        return nil
    }

    private var quantizationOptions: [String] {
        guard let snapshot else { return [] }
        return LibraryPresentation.quantizationOptions(in: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ErrorBanner(text: appHost.lastError)

            if let snapshot {
                summary(snapshot: snapshot)
                filters
                content(snapshot: snapshot)
            } else if appHost.isScanning {
                ProgressView("Scanning local library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No local library snapshot yet",
                        systemImage: "books.vertical",
                        description: Text("Run a local scan to populate the native Library inventory.")
                    )

                    HStack(spacing: 10) {
                        Button("Scan library") {
                            appHost.requestRescan()
                        }
                        .disabled(appHost.isScanning)

                        Button("Open Settings") {
                            onRouteSelection("settings")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .onAppear {
            if appHost.librarySnapshot == nil, !appHost.isScanning {
                appHost.requestRescan()
            }
            syncSelection()
        }
        .onChange(of: visiblePaths) {
            syncSelection()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .font(.title2)
                Text("Trustworthy local model inventory grouped by family.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if appHost.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh") {
                appHost.requestRescan()
            }
            .disabled(appHost.isScanning)
        }
    }

    private func summary(snapshot: LibrarySnapshot) -> some View {
        HStack(spacing: 12) {
            statCard("Families", "\(snapshot.groups.count)")
            statCard("Models", "\(snapshot.models.count)")
            statCard("Storage", byteCount(snapshot.totalBytes))
            statCard("Reclaimable", byteCount(snapshot.reclaimableBytes))
            statCard("Scanned", format(snapshot.generatedAt))
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            TextField("Search family, variant, path, key, or evidence", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280, maxWidth: 420)

            Picker("Readiness", selection: $readinessFilter) {
                Text("All readiness").tag(ModelReadiness?.none)
                ForEach(ModelReadiness.allCases) { readiness in
                    Text(readiness.title).tag(Optional(readiness))
                }
            }
            .pickerStyle(.menu)

            Picker("Quantization", selection: $quantizationFilter) {
                Text("All quantization").tag(String?.none)
                ForEach(quantizationOptions, id: \.self) { option in
                    Text(option).tag(Optional(option))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func content(snapshot: LibrarySnapshot) -> some View {
        HSplitView {
            libraryList(snapshot: snapshot)
                .frame(minWidth: 420, idealWidth: 500)

            Group {
                if let selectedModel {
                    ModelDetailsView(
                        appHost: appHost,
                        model: selectedModel,
                        snapshotGeneratedAt: snapshot.generatedAt,
                        onRouteSelection: onRouteSelection
                    )
                } else {
                    ContentUnavailableView(
                        "No model selected",
                        systemImage: "square.and.pencil",
                        description: Text("Choose a library row to inspect the local evidence and route selection.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity)
        }
    }

    private func libraryList(snapshot: LibrarySnapshot) -> some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView(
                    noMatchTitle,
                    systemImage: noMatchSymbol,
                    description: Text(noMatchDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $appHost.selectedModelPath) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.variants, id: \.item.path) { model in
                                LibraryVariantRow(model: model)
                                    .tag(model.item.path)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        appHost.selectedModelPath = model.item.path
                                    }
                            }
                        } header: {
                            LibraryGroupHeaderView(group: group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var noMatchTitle: String {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No models matched that search"
        }
        if readinessFilter != nil || quantizationFilter != nil {
            return "No models matched the current filters"
        }
        return "No models found"
    }

    private var noMatchDescription: String {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a broader family, path, or variant term."
        }
        if let readinessFilter {
            return "The local snapshot has no models with readiness \(readinessFilter.title)."
        }
        if let quantizationFilter {
            return "The local snapshot has no models with quantization \(quantizationFilter)."
        }
        return "Configure local roots in Settings, then refresh the library scan."
    }

    private var noMatchSymbol: String {
        if readinessFilter != nil || quantizationFilter != nil {
            return "line.3.horizontal.decrease.circle"
        }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "magnifyingglass"
        }
        return "books.vertical"
    }

    private func syncSelection() {
        appHost.selectedModelPath = LibraryPresentation.selectionCandidate(
            in: groups,
            currentPath: appHost.selectedModelPath
        )
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.medium)
        }
        .padding(8)
        .frame(minWidth: 100, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct LibraryGroupHeaderView: View {
    let group: LibraryGroupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.primaryDisplayName)
                    .font(.headline)
                Text("\(group.variants.count) variant\(group.variants.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: group.totalBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(LibraryPresentation.readinessCounts(in: group), id: \.readiness) { item in
                    Text("\(item.readiness.title) \(item.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(4)
                }
            }

            if group.duplicateBytes > 0 {
                Label(
                    "\(ByteCountFormatter.string(fromByteCount: group.duplicateBytes, countStyle: .file)) reclaimable duplicate storage",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LibraryVariantRow: View {
    let model: LibraryModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusPill(state: model.readiness.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(model.item.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(model.item.quantization ?? LibraryPresentation.unknownQuantizationLabel)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
