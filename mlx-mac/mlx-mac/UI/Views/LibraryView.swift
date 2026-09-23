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

/// One-line footer describing the snapshot the table was built from.
struct LibrarySummary: Equatable {
    let families: Int
    let models: Int
    let storage: String
    let reclaimable: String
    let scanned: String
}

enum LibraryPresentation {
    static let unknownQuantizationLabel = "Unknown"

    static func summary(for snapshot: LibrarySnapshot) -> LibrarySummary {
        LibrarySummary(
            families: snapshot.groups.count,
            models: snapshot.models.count,
            storage: LibraryTablePresentation.byteCount(snapshot.totalBytes),
            reclaimable: LibraryTablePresentation.byteCount(snapshot.reclaimableBytes),
            scanned: snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)
        )
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

// MARK: - LibraryView

struct LibraryView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (AppRoute) -> Void

    @State private var search = ""
    @State private var readinessFilter: ModelReadiness?
    @State private var quantizationFilter: String?
    @State private var selection: String?
    @State private var sortOrder = LibraryTablePresentation.defaultSortOrder
    @State private var showInspector = true
    @Environment(\.isRouteActive) private var isRouteActive

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
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

    private var rows: [LibraryRow] {
        LibraryTablePresentation.rows(groups: groups, sortOrder: sortOrder)
    }

    private var visiblePaths: [String] {
        groups.flatMap { $0.variants.map(\.item.path) }
    }

    private var selectedModel: LibraryModel? {
        model(at: LibraryTablePresentation.modelPath(forSelection: selection))
    }

    private var selectedFamily: LibraryRow? {
        guard let selection, selection.hasPrefix(LibraryRow.familyIDPrefix) else { return nil }
        return rows.first { $0.id == selection }
    }

    private var quantizationOptions: [String] {
        guard let snapshot else { return [] }
        return LibraryPresentation.quantizationOptions(in: snapshot)
    }

    /// The inspector belongs to this route only; a mounted-but-hidden Library
    /// must not keep a trailing column open over another tab.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showInspector && isRouteActive },
            set: { showInspector = $0 }
        )
    }

    var body: some View {
        content
            .background(WorkbenchColor.canvas)
            .inspector(isPresented: inspectorBinding) {
                inspector
                    .inspectorColumnWidth(min: 380, ideal: 500, max: 720)
            }
            .routeSearchable(text: $search, prompt: "Search family, variant, path, key, or evidence", isActive: isRouteActive)
            .toolbar { libraryToolbar }
            .onAppear {
                if appHost.librarySnapshot == nil, !appHost.isScanning {
                    appHost.requestRescan()
                }
                syncSelection()
            }
            .onChange(of: visiblePaths) {
                syncSelection()
            }
            .onChange(of: selection) { _, newValue in
                if let path = LibraryTablePresentation.modelPath(forSelection: newValue) {
                    appHost.selectedModelPath = path
                }
            }
            .onChange(of: appHost.selectedModelPath) { _, path in
                // Other tabs (Activity, Overview) can select a model; follow them.
                if let path, visiblePaths.contains(path), selection != path {
                    selection = path
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            VStack(spacing: 0) {
                ErrorBanner(text: appHost.lastError)
                    .padding([.horizontal, .top], WorkbenchSpacing.sm)
                if rows.isEmpty {
                    ContentUnavailableView(noMatchTitle, systemImage: noMatchSymbol, description: Text(noMatchDescription))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    table
                }
                Divider()
                footer(LibraryPresentation.summary(for: snapshot))
            }
        } else if appHost.isScanning {
            ProgressView("Scanning local library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ContentUnavailableView {
                Label("No local library snapshot yet", systemImage: "books.vertical")
            } description: {
                Text("Run a local scan to populate the native Library inventory.")
            } actions: {
                Button("Scan library") { appHost.requestRescan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(appHost.isScanning)
                Button("Open Settings") { onRouteSelection(.settings) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(of: LibraryRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.name) { row in
                LibraryNameCell(row: row)
            }
            .width(min: 240, ideal: 380)

            TableColumn("Readiness", value: \.readinessSortKey) { row in
                LibraryReadinessCell(row: row)
            }
            .width(min: 120, ideal: 150, max: 190)

            TableColumn("Quant", value: \.quantization) { row in
                Text(row.quantization)
                    .font(WorkbenchTypography.value)
            }
            .width(min: 56, ideal: 72, max: 110)

            TableColumn("Size", value: \.bytes) { row in
                Text(LibraryTablePresentation.byteCount(row.bytes))
                    .font(WorkbenchTypography.value)
            }
            .width(min: 80, ideal: 96, max: 130)

            TableColumn("Modified", value: \.modifiedSortKey) { row in
                Text(row.modifiedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            .width(min: 100, ideal: 130, max: 170)
        } rows: {
            ForEach(rows) { row in
                if let children = row.children {
                    DisclosureTableRow(row) {
                        ForEach(children) { child in
                            TableRow(child)
                        }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: LibraryRow.ID.self) { ids in
            if let model = model(at: LibraryTablePresentation.modelPath(forSelection: ids.first)) {
                contextMenuItems(for: ModelActions(appHost: appHost, model: model, onRouteSelection: onRouteSelection))
            }
        } primaryAction: { ids in
            if LibraryTablePresentation.modelPath(forSelection: ids.first) != nil {
                showInspector = true
            }
        }
        .copyable(selectedModel.map { [$0.item.path] } ?? [])
        .onKeyPress(.return) {
            guard selectedModel != nil else { return .ignored }
            showInspector = true
            return .handled
        }
    }

    @ViewBuilder
    private func contextMenuItems(for actions: ModelActions) -> some View {
        Button("Copy Path") { actions.copyPath() }
        Button("Reveal in Finder") { actions.revealInFinder() }
        Divider()
        if actions.canPrepare {
            Button("Prepare to run") { actions.prepare() }
        }
        Button("Select for Compare") { actions.compare() }
        Button("Select for Run") { actions.run() }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let selectedModel {
            ModelDetailsView(appHost: appHost, model: selectedModel, onRouteSelection: onRouteSelection)
        } else if let family = selectedFamily {
            ContentUnavailableView(family.name, systemImage: "square.stack.3d.up", description: Text("\(family.detail) · \(LibraryTablePresentation.byteCount(family.bytes)). Select a variant to inspect it."))
        } else {
            ContentUnavailableView("No model selected", systemImage: "square.and.pencil", description: Text("Choose a row to inspect its evidence and route it to Prepare, Compare, or Run."))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if isRouteActive {
            if appHost.isScanning {
                ToolbarItem(placement: .automatic) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ToolbarItem(placement: .automatic) {
                Picker("Readiness", selection: $readinessFilter) {
                    Text("All readiness").tag(ModelReadiness?.none)
                    ForEach(ModelReadiness.allCases) { readiness in
                        Text(readiness.title).tag(Optional(readiness))
                    }
                }
                .pickerStyle(.menu)
                .help("Filter by readiness")
            }
            ToolbarItem(placement: .automatic) {
                Picker("Quantization", selection: $quantizationFilter) {
                    Text("All quantization").tag(String?.none)
                    ForEach(quantizationOptions, id: \.self) { option in
                        Text(option).tag(Optional(option))
                    }
                }
                .pickerStyle(.menu)
                .help("Filter by quantization")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appHost.requestRescan()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appHost.isScanning)
                .help("Refresh library scan")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showInspector ? "Hide the model inspector (⌥⌘I)" : "Show the model inspector (⌥⌘I)")
            }
        }
    }

    // MARK: - Footer

    private func footer(_ summary: LibrarySummary) -> some View {
        HStack(spacing: WorkbenchSpacing.md) {
            Text("\(summary.models) models in \(summary.families) families")
            Text(summary.storage)
            Text("\(summary.reclaimable) reclaimable")
            Spacer()
            HStack(spacing: WorkbenchSpacing.xxs) {
                Text("Scanned")
                Text(summary.scanned)
                    .foregroundStyle(WorkbenchColor.ink)
            }
        }
        .font(WorkbenchTypography.secondary)
        .foregroundStyle(WorkbenchColor.muted)
        .padding(.horizontal, WorkbenchSpacing.md)
        .padding(.vertical, WorkbenchSpacing.xs)
        .background(WorkbenchColor.surface)
    }

    // MARK: - Empty states

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

    // MARK: - Helpers

    private func model(at path: String?) -> LibraryModel? {
        guard let path else { return nil }
        for group in groups {
            if let model = group.variants.first(where: { $0.item.path == path }) {
                return model
            }
        }
        return nil
    }

    private func syncSelection() {
        let candidate = LibraryPresentation.selectionCandidate(
            in: groups,
            currentPath: appHost.selectedModelPath
        )
        appHost.selectedModelPath = candidate
        if selection == nil || LibraryTablePresentation.modelPath(forSelection: selection) != candidate {
            selection = candidate
        }
    }
}
