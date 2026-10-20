import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum LibraryLoadState: Equatable {
    case snapshot
    case scanning
    case failed(String)
    case empty

    static func derive(hasSnapshot: Bool, isScanning: Bool, error: String?) -> Self {
        if hasSnapshot { return .snapshot }
        if isScanning { return .scanning }
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failed(error) }
        return .empty
    }
}

struct LibraryEmptyPresentation: Equatable {
    let showsAcquisition: Bool
    let hasSearch: Bool
    let hasFilters: Bool
    let title: String
    let description: String
    let symbol: String

    init(modelCount: Int, search: String, readiness: ModelReadiness?, quantization: String?) {
        showsAcquisition = modelCount == 0
        hasSearch = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasFilters = readiness != nil || quantization != nil
        if showsAcquisition {
            title = "No models found"
            description = "Add a model from Hugging Face, or choose model folders in Settings and scan again."
            symbol = "books.vertical"
        } else if hasSearch {
            title = "No models matched that search"
            description = "Clear the search to reveal local models, or try a broader family, path, or variant term."
            symbol = "magnifyingglass"
        } else if hasFilters {
            title = "No models matched the current filters"
            description = "Clear the readiness and quantization filters to reveal models already in this library."
            symbol = "line.3.horizontal.decrease.circle"
        } else {
            title = "No visible models"
            description = "Scan again to refresh the local inventory."
            symbol = "books.vertical"
        }
    }
}

/// Intake progress is observed only while the empty state is displayed.
private struct LibraryEmptyView: View {
    let presentation: LibraryEmptyPresentation
    @ObservedObject var intake: IntakeCoordinator
    let isScanning: Bool
    let onSettings: () -> Void
    let onRescan: () -> Void
    let onClearSearch: () -> Void
    let onClearFilters: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label(presentation.title, systemImage: presentation.symbol)
        } description: {
            Text(presentation.description)
        } actions: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.sm) { actions }
                VStack(spacing: WorkbenchSpacing.xs) { actions }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var actions: some View {
        if presentation.showsAcquisition {
            Button("Add from Hugging Face…") {
                guard !intake.isBusy else { return }
                intake.open(with: "")
                openWindow(id: IntakeWindow.id)
            }
            .buttonStyle(.workbenchPrimary)
            .disabled(intake.isBusy)
            .help(intake.isBusy ? "An intake is in progress" : "Choose a model and review it before downloading")
            Button("Open Settings", action: onSettings).buttonStyle(.bordered)
        }
        if presentation.hasSearch { Button("Clear search", action: onClearSearch).buttonStyle(.bordered) }
        if presentation.hasFilters { Button("Clear filters", action: onClearFilters).buttonStyle(.bordered) }
        Button("Scan again", action: onRescan).buttonStyle(.bordered).disabled(isScanning)
    }
}

enum LibraryInspectorPresentation {
    static func usesColumn(in viewport: CGSize) -> Bool {
        viewport.width >= WorkbenchSize.Library.inspectorWindowMinimum
    }

    static func sheetSize(in viewport: CGSize) -> CGSize {
        CGSize(width: min(WorkbenchSize.Library.inspectorSheetWidth, viewport.width - WorkbenchSpacing.pageInset * 2),
               height: min(WorkbenchSize.Library.inspectorSheetHeight, viewport.height - WorkbenchSpacing.pageInset * 4))
    }
}

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

    static func summary(for snapshot: LibrarySnapshot, familyCount: Int? = nil) -> LibrarySummary {
        LibrarySummary(
            families: familyCount ?? snapshot.groups.count,
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

struct LibraryRevealRequest: Equatable {
    let id = UUID()
    let modelPath: String

    func resolvedPath(in snapshot: LibrarySnapshot?) -> String? {
        snapshot?.models.first { $0.item.path == modelPath }?.item.path
    }
}

enum LibrarySource: String, CaseIterable, Identifiable {
    case allModels, lmStudio, hosted
    var id: Self { self }
    var title: String {
        switch self {
        case .allModels: return "All models"
        case .lmStudio: return "LM Studio"
        case .hosted: return "Hosted models"
        }
    }
}

/// Source-specific views share Library's inventory and preserve the main table's state.
struct LibraryWorkspace: View {
    @ObservedObject var appHost: AppHost
    let lmStudioRequested: Bool
    let sourceHome: URL
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var source: LibrarySource
    @State private var visitedSources: Set<LibrarySource>
    @State private var revealRequest: LibraryRevealRequest?

    init(appHost: AppHost, initialSource: LibrarySource = .allModels, lmStudioRequested: Bool = false,
         sourceHome: URL = WorkbenchStatePaths.userHome(), onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.lmStudioRequested = lmStudioRequested
        self.sourceHome = sourceHome
        self.onRouteSelection = onRouteSelection
        let initial = lmStudioRequested ? LibrarySource.lmStudio : initialSource
        _source = State(initialValue: initial)
        _visitedSources = State(initialValue: [initial])
    }

    var body: some View {
        ZStack {
            ForEach(LibrarySource.allCases.filter { visitedSources.contains($0) }) { destination in
                let active = isRouteActive && source == destination
                sourceView(destination)
                    .environment(\.isRouteActive, isRouteActive && active)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .zIndex(active ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: source) { _, selected in visitedSources.insert(selected) }
        .onChange(of: lmStudioRequested) { _, requested in
            if requested { source = .lmStudio; visitedSources.insert(.lmStudio) }
        }
        .onChange(of: appHost.libraryRevealRequest, initial: true) { receiveRevealRequest() }
        .onChange(of: isRouteActive, initial: true) { receiveRevealRequest() }
        .onChange(of: appHost.hostedLibraryRequested, initial: true) { _, requested in
            if requested { source = .hosted; visitedSources.insert(.hosted); appHost.hostedLibraryRequested = false }
        }
    }

    @ViewBuilder private func sourceView(_ source: LibrarySource) -> some View {
        switch source {
        case .allModels:
            LibraryView(appHost: appHost, revealRequest: revealRequest, sourceSelection: $source,
                        onRouteSelection: onRouteSelection)
        case .lmStudio:
            VStack(spacing: 0) {
                LibrarySourcePicker(selection: $source)
                LMStudioView(appHost: appHost, home: sourceHome, onRouteSelection: navigateFromSource)
            }
        case .hosted:
            VStack(spacing: 0) {
                LibrarySourcePicker(selection: $source)
                HostedModelsView(appHost: appHost, onRouteSelection: onRouteSelection)
            }
        }
    }

    private func navigateFromSource(_ route: AppRoute) {
        if route == .library {
            source = .allModels
            visitedSources.insert(.allModels)
            receiveRevealRequest()
        }
        onRouteSelection(route)
    }

    private func receiveRevealRequest() {
        guard isRouteActive, let request = appHost.libraryRevealRequest else { return }
        source = .allModels
        visitedSources.insert(.allModels)
        revealRequest = request
    }
}

private struct LibrarySourcePicker: View {
    @Binding var selection: LibrarySource

    var body: some View {
        Picker("Source", selection: $selection) {
            ForEach(LibrarySource.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 460)
        .padding(.horizontal, WorkbenchSpacing.pageInset)
        .padding(.top, WorkbenchSpacing.pageInset)
        .accessibilityIdentifier("library-source")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LibraryView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var reclaim: ReclaimCoordinator
    private let onRouteSelection: (AppRoute) -> Void
    let revealRequest: LibraryRevealRequest?
    private let sourceSelection: Binding<LibrarySource>?

    @State private var search = ""
    @State private var readinessFilter: ModelReadiness?
    @State private var quantizationFilter: String?
    @State private var selection: String?
    @State private var sortOrder = LibraryTablePresentation.defaultSortOrder
    @State private var showInspector = false
    @State private var showRecentTasks = false
    @State private var revealError: String?
    @State private var handledRevealID: UUID?
    @State private var columnCustomization = TableColumnCustomization<LibraryRow>()
    @State private var tier = LibraryColumnTier.resolve(width: WorkbenchSize.assumedContentWidth)
    /// The fit context the rows sort by. Follows the monitor's context
    /// picker only; memory readings never reach the Library body.
    @State private var contextTokens = FitAdvisor.defaultContextTokens
    @AppStorage("library.groupMode") private var groupModeRaw = LibraryGroupMode.family.rawValue
    @Environment(\.isRouteActive) private var isRouteActive
    @Environment(\.openWindow) private var openWindow
    @Environment(\.workbenchViewport) private var viewport

    init(appHost: AppHost, revealRequest: LibraryRevealRequest? = nil, sourceSelection: Binding<LibrarySource>? = nil, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.revealRequest = revealRequest
        self.sourceSelection = sourceSelection
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
        self.onRouteSelection = onRouteSelection
    }

    private var snapshot: LibrarySnapshot? {
        appHost.librarySnapshot
    }

    private var loadState: LibraryLoadState {
        .derive(hasSnapshot: snapshot != nil, isScanning: appHost.isScanning, error: appHost.lastError)
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
        (LibraryGroupMode(rawValue: groupModeRaw) ?? .family) == .type
            ? LibraryTablePresentation.typeRows(groups: groups, sortOrder: sortOrder, contextTokens: contextTokens)
            : LibraryTablePresentation.rows(groups: groups, sortOrder: sortOrder, contextTokens: contextTokens)
    }

    private var visiblePaths: [String] {
        groups.flatMap { $0.variants.map(\.item.path) }
    }

    private var selectedModel: LibraryModel? {
        contextModel(for: selection)
    }

    private var selectedFamily: LibraryRow? {
        guard let selection, selection.hasPrefix(LibraryRow.familyIDPrefix) else { return nil }
        return LibraryTablePresentation.row(withID: selection, in: rows)
    }

    private var quantizationOptions: [String] {
        guard let snapshot else { return [] }
        return LibraryPresentation.quantizationOptions(in: snapshot)
    }

    /// The inspector belongs to this route only; a mounted-but-hidden Library
    /// must not keep a trailing column open over another tab.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showInspector && isRouteActive && usesInspectorColumn },
            set: { showInspector = $0 }
        )
    }

    private var usesInspectorColumn: Bool { LibraryInspectorPresentation.usesColumn(in: viewport) }

    private var inspectorSheetBinding: Binding<Bool> {
        Binding(get: { showInspector && isRouteActive && !usesInspectorColumn && reclaim.libraryTrashPlan == nil },
                set: { showInspector = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let sourceSelection { LibrarySourcePicker(selection: sourceSelection) }
            WorkbenchPageHeading(route: .library)
            if let revealError {
                InlineMessage(kind: .warning, text: revealError,
                    action: (title: "Dismiss", perform: { self.revealError = nil }))
                    .padding([.horizontal, .top], WorkbenchSpacing.pageInset)
                    .accessibilityIdentifier("library-reveal-error")
            }
            content
        }
            .sheet(isPresented: Binding(get: { reclaim.libraryTrashPlan != nil && isRouteActive }, set: { if !$0 { reclaim.cancelLibraryTrash() } })) {
                if let plan = reclaim.libraryTrashPlan {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                        Text("Delete model?").font(WorkbenchTypography.title)
                        Text(URL(fileURLWithPath: plan.modelPath).lastPathComponent).font(WorkbenchTypography.emphasis)
                        Text(plan.includesCacheRepository
                             ? "This moves the entire cached repository, including all its downloaded revisions and blobs, to macOS Trash."
                             : "This moves the selected model to macOS Trash. You can put it back using Finder.")
                        Text(plan.snapshot.path).font(WorkbenchTypography.secondary).textSelection(.enabled)
                        Text("\(LibraryTablePresentation.byteCount(plan.snapshot.bytes)) on disk. Empty Trash in Finder to free the space.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        HStack {
                            Button("Cancel") { reclaim.cancelLibraryTrash() }.keyboardShortcut(.cancelAction)
                            Spacer()
                            if reclaim.isApplying { ProgressView().controlSize(.small) }
                            Button("Move to Trash", role: .destructive) {
                                Task {
                                    await reclaim.confirmLibraryTrash()
                                    if reclaim.lastError == nil { appHost.requestRescan() }
                                }
                            }.buttonStyle(.workbenchPrimary)
                        }.disabled(reclaim.isApplying)
                    }.padding(WorkbenchSpacing.lg).frame(width: 480)
                        .interactiveDismissDisabled(reclaim.isApplying)
                }
            }
            .libraryInspector(isPresented: inspectorBinding) {
                inspector
                    // Long values wrap; their single-line width never widens the column.
                    .frame(minWidth: 0, idealWidth: WorkbenchSize.Library.inspectorIdeal, maxWidth: .infinity)
                    .inspectorColumnWidth(
                        min: WorkbenchSize.Library.inspectorMinimum,
                        ideal: WorkbenchSize.Library.inspectorIdeal,
                        max: WorkbenchSize.Library.inspectorMaximum
                    )
            }
            .sheet(isPresented: inspectorSheetBinding) {
                let size = LibraryInspectorPresentation.sheetSize(in: viewport)
                VStack(spacing: 0) {
                    HStack {
                        Text("Model details").font(WorkbenchTypography.cardTitle)
                        Spacer()
                        Button("Done") { showInspector = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(WorkbenchSpacing.md)
                    Divider()
                    inspector
                }
                .frame(width: size.width, height: size.height)
            }
            .sheet(isPresented: $showRecentTasks) {
                LibraryRecentTasks(coordinator: appHost.inferenceTasks, model: selectedModel)
            }
            .onChange(of: usesInspectorColumn) { _, isWide in
                if !isWide { showInspector = false }
            }
            .onChange(of: isRouteActive) { _, isActive in
                if !isActive, !usesInspectorColumn { showInspector = false }
            }
            .onReceive(appHost.resources.$contextTokens.removeDuplicates()) { contextTokens = $0 }
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
            .onChange(of: revealRequest, initial: true) { _, request in
                guard let request else { return }
                handledRevealID = request.id
                defer {
                    if appHost.libraryRevealRequest?.id == request.id { appHost.libraryRevealRequest = nil }
                }
                guard let path = request.resolvedPath(in: snapshot) else {
                    showInspector = false
                    revealError = "The requested model is not in the current Library scan. Scan again, then retry the action."
                    return
                }
                revealError = nil
                search = ""
                readinessFilter = nil
                quantizationFilter = nil
                selection = path
                appHost.selectedModelPath = path
                showInspector = true
            }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            VStack(spacing: 0) {
                ErrorBanner(text: appHost.lastError)
                    .padding([.horizontal, .top], WorkbenchSpacing.sm)
                ErrorBanner(text: reclaim.lastError)
                    .padding(.horizontal, WorkbenchSpacing.sm)
                if let note = reclaim.libraryTrashNote {
                    Text(note).font(WorkbenchTypography.secondary).textSelection(.enabled)
                        .padding(.horizontal, WorkbenchSpacing.sm)
                }
                if rows.isEmpty {
                    LibraryEmptyView(
                        presentation: LibraryEmptyPresentation(modelCount: snapshot.models.count, search: search,
                            readiness: readinessFilter, quantization: quantizationFilter),
                        intake: appHost.intake,
                        isScanning: appHost.isScanning,
                        onSettings: { onRouteSelection(.settings) },
                        onRescan: { appHost.requestRescan() },
                        onClearSearch: { search = "" },
                        onClearFilters: { readinessFilter = nil; quantizationFilter = nil }
                    )
                } else {
                    table
                }
                Divider()
                footer(LibraryPresentation.summary(for: snapshot, familyCount: Set(snapshot.models.map(ComparePresentation.familyLabel)).count))
            }
        } else if loadState == .scanning {
            ProgressView("Scanning local library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if case .failed(let error) = loadState {
            ContentUnavailableView {
                Label("Library scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                FailureNotice(error: error, details: .whenDifferent)
            } actions: {
                Button("Retry scan") { appHost.requestRescan() }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(appHost.isScanning)
                Button("Open Settings") { onRouteSelection(.settings) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No local library snapshot yet", systemImage: "books.vertical")
            } description: {
                Text("Run a local scan to populate the native Library inventory.")
            } actions: {
                Button("Scan library") { appHost.requestRescan() }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(appHost.isScanning)
                Button("Open Settings") { onRouteSelection(.settings) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Table

    private var table: some View {
        let largestLeafBytes = LibraryTablePresentation.largestLeafBytes(in: rows)
        return Table(of: LibraryRow.self, selection: Binding(get: { selection }, set: {
            selection = $0
            showInspector = $0 != nil
        }), sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("Model", value: \.name) { row in
                LibraryNameCell(row: row, isSelected: selection == row.id, showsInlineStatus: !tier.showsStatus)
            }
            .width(min: WorkbenchSize.Library.modelMinimum, ideal: WorkbenchSize.Library.modelIdeal)
            .customizationID("model")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(LibraryFitPresentation.title, value: \.fitSortKey) { row in
                LibraryFitCell(
                    row: row,
                    resources: appHost.resources,
                    reserveGB: appHost.config.fitReserveGB,
                    hardware: appHost.hardwareProfile,
                    showsGauge: tier.showsGauge
                )
            }
            .width(min: WorkbenchSize.Library.fitsMinimum, ideal: WorkbenchSize.Library.fitsIdeal, max: WorkbenchSize.Library.fitsMaximum)
            .customizationID("fits")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Quant", value: \.quantization) { row in
                LibraryQuantCell(row: row)
            }
            .width(min: WorkbenchSize.Library.quantMinimum, ideal: WorkbenchSize.Library.quantIdeal, max: WorkbenchSize.Library.quantMaximum)
            .customizationID("quant")

            TableColumn("Size", value: \.bytes) { row in
                LibrarySizeCell(row: row, largestLeafBytes: largestLeafBytes, showsBar: tier.showsSizeBar)
            }
            .width(min: WorkbenchSize.Library.sizeMinimum, ideal: WorkbenchSize.Library.sizeIdeal, max: WorkbenchSize.Library.sizeMaximum)
            .customizationID("size")

            TableColumn("Status", value: \.readinessSortKey) { row in
                LibraryReadinessCell(row: row, verification: appHost.verification)
            }
            .width(min: WorkbenchSize.Library.statusMinimum, ideal: WorkbenchSize.Library.statusIdeal, max: WorkbenchSize.Library.statusMaximum)
            .customizationID("status")

            TableColumn("Modified", value: \.modifiedSortKey) { row in
                LibraryModifiedCell(row: row)
            }
            .width(min: WorkbenchSize.Library.modifiedMinimum, ideal: WorkbenchSize.Library.modifiedIdeal, max: WorkbenchSize.Library.modifiedMaximum)
            .customizationID("modified")
        } rows: {
            tableRows(rows)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            tier = LibraryColumnTier.resolve(width: width, previous: tier)
        }
        .onChange(of: tier, initial: true) { _, newTier in
            applyTier(newTier)
        }
        .contextMenu(forSelectionType: LibraryRow.ID.self) { ids in
            if let model = contextModel(for: ids.first) {
                contextMenuItems(for: ModelActions(appHost: appHost, model: model, onRouteSelection: onRouteSelection))
            }
        } primaryAction: { ids in
            if contextModel(for: ids.first) != nil {
                showInspector = true
            }
        }
        .onPasteCommand(of: [.plainText, .url]) { _ in pasteIntake() }
        .copyable(selectedModel.map { [$0.item.path] } ?? [])
        .onKeyPress(.return) {
            guard selectedModel != nil else { return .ignored }
            showInspector = true
            return .handled
        }
    }

    /// Hides the columns the current table width has no room for. Model and
    /// Fits now are never hidden.
    private func applyTier(_ tier: LibraryColumnTier) {
        func visibility(_ shown: Bool) -> Visibility { shown ? .automatic : .hidden }
        columnCustomization[visibility: "quant"] = visibility(tier.showsQuant)
        columnCustomization[visibility: "size"] = visibility(tier.showsSize)
        columnCustomization[visibility: "status"] = visibility(tier.showsStatus)
        columnCustomization[visibility: "modified"] = visibility(tier.showsModified)
    }

    @TableRowBuilder<LibraryRow>
    private func tableRows(_ rows: [LibraryRow]) -> some TableRowContent<LibraryRow> {
        ForEach(rows) { row in
            if let children = row.children {
                DisclosureTableRow(row) { nestedRows(children) }
            } else {
                TableRow(row)
            }
        }
    }

    @TableRowBuilder<LibraryRow>
    private func nestedRows(_ rows: [LibraryRow]) -> some TableRowContent<LibraryRow> {
        ForEach(rows) { row in
            if let children = row.children {
                DisclosureTableRow(row) { leafRows(children) }
            } else {
                TableRow(row)
            }
        }
    }

    @TableRowBuilder<LibraryRow>
    private func leafRows(_ rows: [LibraryRow]) -> some TableRowContent<LibraryRow> {
        ForEach(rows) { row in
            if let children = row.children {
                DisclosureTableRow(row) { ForEach(children) { TableRow($0) } }
            } else {
                TableRow(row)
            }
        }
    }

    private func pasteIntake() {
        let text = NSPasteboard.general.string(forType: .string)
        guard IntakeCoordinator.looksLikeHFLink(text) else { return }
        appHost.intake.open(with: text)
        openWindow(id: IntakeWindow.id)
    }

    @ViewBuilder
    private func contextMenuItems(for actions: ModelActions) -> some View {
        Button("Copy Path") { actions.copyPath() }
        Button("Reveal in Finder") { actions.revealInFinder() }
        Divider()
        if ModelRuntimeRecoveryRequest(model: actions.model) != nil {
            Button("Repair runtime…") { actions.repairRuntime() }
        } else if actions.canPrepare {
            Button("Prepare to run") { actions.prepare() }
        }
        if actions.canCompare {
            Button("Select for Compare") { actions.compare() }
        }
        if actions.canServe, actions.model.readiness != .needsRuntime {
            Button("Select for Run") { actions.run() }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            Task { await reclaim.previewLibraryTrash(actions.model.item.path) }
        }.disabled(reclaim.isApplying)
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
                Picker("Group by", selection: $groupModeRaw) {
                    ForEach(LibraryGroupMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("Group the Library by model family or by type and use case")
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
                Button { showRecentTasks = true } label: {
                    Label("Recent tasks", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("task-history-open")
                .help("Review recent classification and music tasks")
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
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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

    /// A single-model heading has the same actions as its only child. A
    /// multi-model family never silently chooses a variant for deletion.
    private func contextModel(for id: String?) -> LibraryModel? {
        if let model = model(at: LibraryTablePresentation.modelPath(forSelection: id)) { return model }
        guard let id, let row = LibraryTablePresentation.row(withID: id, in: rows),
              row.fitModels.count == 1 else { return nil }
        return row.fitModels.first
    }

    private func syncSelection() {
        // Apply explicit navigation before normal table reconciliation.
        if revealError != nil { return }
        if let request = appHost.libraryRevealRequest ?? revealRequest, request.id != handledRevealID { return }
        let hadSelection = selection != nil
        let candidate = LibraryPresentation.selectionCandidate(
            in: groups,
            currentPath: appHost.selectedModelPath
        )
        appHost.selectedModelPath = candidate
        if !hadSelection, candidate != nil, usesInspectorColumn { showInspector = true }
        if selection == nil || LibraryTablePresentation.modelPath(forSelection: selection) != candidate {
            selection = candidate
        }
    }
}

private extension View {
    @ViewBuilder
    func libraryInspector<Inspector: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: () -> Inspector
    ) -> some View {
        if isPresented.wrappedValue {
            self.inspector(isPresented: isPresented) { content() }
        } else {
            self
        }
    }
}
