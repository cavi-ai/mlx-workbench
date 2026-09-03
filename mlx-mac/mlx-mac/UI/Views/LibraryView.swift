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
    static let detailDrillInThreshold: CGFloat = 760

    enum LayoutMode: Equatable {
        case masterDetail
        case drillIn
    }

    static func layoutMode(contentWidth: CGFloat) -> LayoutMode {
        contentWidth < detailDrillInThreshold ? .drillIn : .masterDetail
    }

    static func shouldShowSummary(containerHeight: CGFloat) -> Bool {
        containerHeight >= 620
    }

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
    @State private var isShowingDetail = false

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
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                header
                ErrorBanner(text: appHost.lastError)
                if let snapshot {
                    if LibraryPresentation.shouldShowSummary(containerHeight: geometry.size.height) { summary(snapshot: snapshot) }
                    filters
                    content(snapshot: snapshot, width: geometry.size.width)
                } else if appHost.isScanning {
                    ProgressView("Scanning local library…").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    VStack(spacing: 16) {
                        ContentUnavailableView("No local library snapshot yet", systemImage: "books.vertical", description: Text("Run a local scan to populate the native Library inventory."))
                        HStack(spacing: 10) {
                            Button("Scan library") { appHost.requestRescan() }.disabled(appHost.isScanning)
                            Button("Open Settings") { onRouteSelection(AppRoute.settings.rawValue) }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .background(WorkbenchColor.alloyCanvas)
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
                Text("LIBRARY / INVENTORY").font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.fluxTeal).tracking(0.8)
                Text("Local model inventory").font(WorkbenchTypography.section)
                Text("Grouped by family, with readiness and evidence kept visible.").font(WorkbenchTypography.body).foregroundColor(WorkbenchColor.graphiteMuted)
            }
            Spacer()
            if appHost.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh") { appHost.requestRescan() }.accessibilityLabel("Refresh library scan")
            .disabled(appHost.isScanning)
        }
    }

    private func summary(snapshot: LibrarySnapshot) -> some View {
        WorkbenchSurface(padding: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.lg) {
                statValue("FAMILIES", "\(snapshot.groups.count)")
                statValue("MODELS", "\(snapshot.models.count)")
                statValue("STORAGE", byteCount(snapshot.totalBytes))
                statValue("RECLAIMABLE", byteCount(snapshot.reclaimableBytes))
                statValue("SCANNED", format(snapshot.generatedAt))
            }
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.sm) { filterControls }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { filterControls }
        }
    }

    @ViewBuilder private var filterControls: some View {
            TextField("Search family, variant, path, key, or evidence", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 440)
                .accessibilityLabel("Search model library")

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

    @ViewBuilder private func content(snapshot: LibrarySnapshot, width: CGFloat) -> some View {
        switch LibraryPresentation.layoutMode(contentWidth: width) {
        case .masterDetail:
            HSplitView {
                libraryList(snapshot: snapshot).frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
                detail(snapshot: snapshot)
            }
        case .drillIn:
            if isShowingDetail && selectedModel != nil {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    Button { isShowingDetail = false } label: { Label("Back to Library", systemImage: "chevron.left") }
                        .buttonStyle(.link).accessibilityLabel("Back to Library")
                    detail(snapshot: snapshot)
                }
            } else {
                libraryList(snapshot: snapshot)
            }
        }
    }

    private func detail(snapshot: LibrarySnapshot) -> some View {
        Group {
            if let selectedModel {
                ModelDetailsView(appHost: appHost, model: selectedModel, snapshotGeneratedAt: snapshot.generatedAt, onRouteSelection: onRouteSelection)
            } else {
                ContentUnavailableView("No model selected", systemImage: "square.and.pencil", description: Text("Choose a library row to inspect the local evidence and route selection.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                        isShowingDetail = true
                                    }
                            }
                        } header: {
                            LibraryGroupHeaderView(group: group)
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: appHost.selectedModelPath) { _, path in
                    // A List selection can come from the keyboard as well as
                    // the pointer. In compact drill-in mode either path must
                    // open the selected model's detail.
                    if path != nil {
                        isShowingDetail = true
                    }
                }
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

    private func statValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(WorkbenchTypography.monoUtility)
                .foregroundColor(WorkbenchColor.graphiteMuted)
            Text(value)
                .font(WorkbenchTypography.section)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundColor(WorkbenchColor.thermalAmber)
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
