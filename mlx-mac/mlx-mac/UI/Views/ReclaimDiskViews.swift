import AppKit
import SwiftUI

// MARK: - Rows

/// A model row; a model stored more than once lists its versions as children. Sortable by every column.
struct DiskRow: Identifiable, Hashable {
    let id: String
    let name: String
    let versions: Int
    let bytes: Int64
    let couldFree: Int64
    let lastUsedKey: Double
    let storesText: String
    let modelID: String
    /// Set on a version row, and on the row of a model stored once.
    let copy: DiskCopy?
    let children: [DiskRow]?

    static let defaultSortOrder = [KeyPathComparator(\DiskRow.bytes, order: .reverse)]

    static func rows(_ models: [DiskModel], items: [StoredModel], sortOrder: [KeyPathComparator<DiskRow>]) -> [DiskRow] {
        let order = sortOrder.isEmpty ? defaultSortOrder : sortOrder
        return models.map { model in
            let single = model.copies.count == 1 ? model.copies.first : nil
            return DiskRow(
                id: model.id, name: model.name, versions: model.copies.count, bytes: model.bytes,
                couldFree: model.couldFree, lastUsedKey: model.lastUsed?.timeIntervalSince1970 ?? -1,
                storesText: model.stores.map(storeTitle).joined(separator: ", "), modelID: model.id, copy: single,
                children: single != nil ? nil : model.copies.map { copy in
                    DiskRow(
                        id: copy.id, name: copy.item.name, versions: 1, bytes: copy.item.bytes,
                        couldFree: model.extras.contains(copy) ? DiskLedger.freedBytes(removing: [copy.id], items: items) : 0,
                        lastUsedKey: copy.lastUsed?.timeIntervalSince1970 ?? -1, storesText: storeTitle(copy.item.store),
                        modelID: model.id, copy: copy, children: nil)
                })
        }.sorted(using: order)
    }

    static func storeTitle(_ store: String) -> String {
        switch store {
        case "huggingface": "Hugging Face cache"
        case "ollama": "Ollama"
        default: "Folder"
        }
    }
}

// MARK: - Panel

/// Reclaim's model view: this Mac's load, what to remove and why, then every model and where its bytes sit.
struct ReclaimDiskPanel: View {
    let appHost: AppHost
    @ObservedObject var reclaim: ReclaimCoordinator
    @ObservedObject var usage: UsageTracker
    let onOpenQuarantine: () -> Void

    @State private var filter: DiskFilter = .all
    @State private var sortOrder = DiskRow.defaultSortOrder
    @State private var focused: DiskRow.ID?
    @State private var selected: Set<String> = []
    @State private var keep: [String: String] = [:]
    @State private var expanded: Set<String> = []
    @State private var allSuggestions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                ErrorBanner(text: reclaim.lastError)
                ReclaimSystemSection(resources: appHost.resources, inventory: appHost.servingInventory,
                                     volumePath: appHost.scanResult?.storage?.roots.first?.root)
                if let storage = appHost.scanResult?.storage {
                    content(storage)
                } else {
                    ReclaimDesignedState(symbol: "internaldrive", text: appHost.isScanning
                        ? "Scanning model folders…"
                        : "This engine does not report disk use per model yet. Update mlx-agent, then rescan.")
                }
            }
            .padding(WorkbenchSpacing.pageInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func content(_ storage: ScanStorage) -> some View {
        let protected = appHost.occupancy.protectedPaths.union(reclaim.protectedPaths())
        let duplicates = appHost.scanResult?.duplicates ?? []
        let all = DiskLedger.models(storage: storage, families: appHost.scanResult?.families ?? [], duplicates: duplicates,
                                    lastUsedByPath: usage.lastUsedByPath, protectedPaths: protected, keep: keep)
        let staleDays = appHost.config.reclaimStaleDays
        let staleBefore = Date().addingTimeInterval(-Double(staleDays) * 86_400)
        let modified = Dictionary((appHost.librarySnapshot?.models ?? []).compactMap { model in
            model.item.modifiedAt.map { (model.item.path, Date(timeIntervalSince1970: TimeInterval($0))) }
        }, uniquingKeysWith: { first, _ in first })
        let suggestions = DiskLedger.suggestions(models: all, items: storage.items, duplicates: duplicates,
                                                 staleBefore: staleBefore, modifiedByPath: modified)
        let shown = DiskLedger.filter(all, by: filter, staleBefore: staleBefore)
        let removable = Set(all.flatMap(\.removable).map(\.id))
        let selection = selected.intersection(removable)
        let freed = DiskLedger.freedBytes(removing: selection, items: storage.items)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            suggestionList(suggestions, items: storage.items, staleDays: staleDays)
            DiskSummaryView(storage: storage)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Text("Models").font(WorkbenchTypography.section)
                    Picker("Show", selection: $filter) {
                        ForEach(DiskFilter.allCases) { option in
                            Text("\(option.title) (\(DiskLedger.filter(all, by: option, staleBefore: staleBefore).count))").tag(option)
                        }
                    }
                    .pickerStyle(.menu).fixedSize()
                    Spacer()
                    if shown.contains(where: { !$0.extras.isEmpty }) {
                        Button("Select extra versions") { selected.formUnion(shown.flatMap(\.extras).map(\.id)) }
                            .controlSize(.small)
                            .help("Every version except the kept one, or the largest when none is kept")
                    }
                }
                Text(filterNote(staleDays: staleDays)).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                table(DiskRow.rows(shown, items: storage.items, sortOrder: sortOrder), models: all)
                    .frame(height: WorkbenchSize.Reclaim.modelTableHeight)
                actionBar(selection: selection, freed: freed, items: storage.items)
                if !reclaim.lastMoves.isEmpty { moveResults }
            }
        }
    }

    private func filterNote(staleDays: Int) -> String {
        switch filter {
        case .all: "Every model the scan recognized, with its versions. Versions share a model name across formats and stores; fine-tunes are separate models."
        case .redundant: "Models stored in more than one format, quantization or store."
        case .unused: "No version used in MLX Workbench in \(staleDays) days."
        case .identical: "The scan found the same weights twice."
        }
    }

    // MARK: Suggestions

    private func suggestionList(_ suggestions: [DiskSuggestion], items: [StoredModel], staleDays: Int) -> some View {
        let actionable = suggestions.filter { !$0.remove.isEmpty }
        let total = DiskLedger.freedBytes(removing: Set(actionable.flatMap(\.remove)), items: items)
        let visible = allSuggestions ? suggestions : Array(suggestions.prefix(WorkbenchSize.Reclaim.suggestionPreview))
        return WorkbenchSurface(.tinted) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                CardHeader("Suggested removals", systemImage: "sparkles") {
                    if total > 0 {
                        Text("Up to \(ReclaimFormat.byteCount(total))").font(WorkbenchTypography.tabular)
                    }
                }
                if suggestions.isEmpty {
                    Text("Nothing to remove: no identical copies, no unused extra versions, and no model over 1 GB idle for \(staleDays) days.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                ForEach(visible) { suggestion in
                    suggestionRow(suggestion, items: items)
                    if suggestion.id != visible.last?.id { Divider() }
                }
                if suggestions.count > WorkbenchSize.Reclaim.suggestionPreview {
                    Button(allSuggestions ? "Show fewer" : "Show all \(suggestions.count)") { allSuggestions.toggle() }
                        .buttonStyle(.borderless).font(WorkbenchTypography.secondary)
                }
                Text("Use counts what MLX Workbench serves, verifies or compares. Removed models go to quarantine and can be put back.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    private func suggestionRow(_ suggestion: DiskSuggestion, items: [StoredModel]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            Image(systemName: Self.symbol(suggestion.kind)).foregroundStyle(WorkbenchColor.accent)
                .frame(width: WorkbenchSize.Reclaim.symbolColumn)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(suggestion.name).font(WorkbenchTypography.emphasis).lineLimit(1).help(suggestion.name)
                Text(suggestion.detail).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            Text((suggestion.remove.isEmpty ? "at least " : "") + ReclaimFormat.byteCount(suggestion.bytes))
                .font(WorkbenchTypography.secondaryTabular)
            if suggestion.remove.isEmpty {
                Button("Choose…") { focus(suggestion.modelID) }
                    .controlSize(.small)
                    .help("Show the versions so you can mark the one to keep")
            } else {
                Button("Review…") { Task { await reclaim.previewCopies(Set(suggestion.remove), items: items) } }
                    .controlSize(.small)
                    .disabled(reclaim.isApplying)
            }
        }
    }

    private func focus(_ modelID: String) {
        filter = .all
        expanded.insert(modelID)
        focused = modelID
    }

    static func symbol(_ kind: DiskSuggestion.Kind) -> String {
        switch kind {
        case .identical: "square.on.square"
        case .otherVersions: "square.stack.3d.up"
        case .chooseVersion: "hand.point.up.left"
        case .notUsed: "clock"
        }
    }

    // MARK: Table

    private func table(_ rows: [DiskRow], models: [DiskModel]) -> some View {
        Table(of: DiskRow.self, selection: $focused, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.name) { row in nameCell(row, models: models) }
                .width(min: 260, ideal: 420)
            TableColumn("Versions", value: \.versions) { row in
                Text(row.children != nil || row.copy == nil || row.versions > 1 || row.id == row.modelID
                     ? "\(row.versions)" : (row.copy?.item.format?.uppercased() ?? row.copy?.item.kind ?? ""))
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(row.id == row.modelID ? WorkbenchColor.ink : WorkbenchColor.muted)
            }.width(min: 56, ideal: 72, max: 90)
            TableColumn("Size", value: \.bytes) { row in
                Text(ReclaimFormat.byteCount(row.bytes)).font(WorkbenchTypography.secondaryTabular)
            }.width(min: 70, ideal: 90, max: 110)
            TableColumn("Could free", value: \.couldFree) { row in
                Text(row.couldFree > 0 ? ReclaimFormat.byteCount(row.couldFree) : "—")
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(row.couldFree > 0 ? WorkbenchColor.ink : WorkbenchColor.muted)
                    .help("Freed by keeping one version and removing the others")
            }.width(min: 80, ideal: 96, max: 120)
            TableColumn("Used here", value: \.lastUsedKey) { row in
                Text(row.lastUsedKey < 0 ? "—" : WorkbenchRelativeTime.text(for: Date(timeIntervalSince1970: row.lastUsedKey), style: .abbreviated))
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .help("Last served, verified or compared in MLX Workbench")
            }.width(min: 70, ideal: 96, max: 120)
            TableColumn("Where", value: \.storesText) { row in
                Text(row.storesText).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
            }.width(min: 90, ideal: 150)
        } rows: {
            ForEach(rows) { row in
                if let children = row.children {
                    DisclosureTableRow(row, isExpanded: expansion(row.id)) {
                        ForEach(children) { TableRow($0) }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: DiskRow.ID.self) { ids in
            if let id = ids.first, let row = rows.flatMap({ [$0] + ($0.children ?? []) }).first(where: { $0.id == id }),
               let model = models.first(where: { $0.id == row.modelID }) {
                if let copy = row.copy {
                    if model.copies.count > 1 { Button("Keep this version") { keep[model.id] = copy.id; selected.remove(copy.id) } }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.id)]) }
                }
                if model.copies.count > 1 {
                    Button("Select extra versions") { selected.formUnion(model.extras.map(\.id)) }.disabled(model.extras.isEmpty)
                }
                Button("Clear selection") { selected.subtract(model.copies.map(\.id)) }
            }
        }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    @ViewBuilder
    private func nameCell(_ row: DiskRow, models: [DiskModel]) -> some View {
        let model = models.first { $0.id == row.modelID }
        if let copy = row.copy, let model {
            let isKept = model.keep == copy.id
            let several = model.copies.count > 1
            HStack(spacing: WorkbenchSpacing.xs) {
                Toggle("Remove \(copy.item.name)", isOn: Binding(
                    get: { selected.contains(copy.id) },
                    set: { if $0 { selected.insert(copy.id) } else { selected.remove(copy.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(isKept || copy.isProtected || reclaim.isApplying)
                    .help(isKept ? "The kept version stays. Choose Keep on another version to remove this one."
                          : copy.isProtected ? "Serving, preferred or in use." : "Remove this " + (several ? "version" : "model"))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: WorkbenchSpacing.xxs) {
                        Text(several ? DiskLedger.versionLabel(copy.item, model: model) : copy.item.name)
                            .font(several ? WorkbenchTypography.secondary : WorkbenchTypography.emphasis).lineLimit(1)
                        if copy.isIdentical { tag("identical") }
                        if copy.isProtected {
                            Image(systemName: "lock.fill").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                .help("Serving, preferred or in use")
                        }
                    }
                    Text(copy.id).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1).truncationMode(.middle).help(copy.id)
                }
                Spacer(minLength: WorkbenchSpacing.xs)
                if several {
                    if isKept {
                        tag(keepTitle(model.keepReason)).foregroundStyle(WorkbenchColor.accent)
                    } else {
                        Button("Keep") { keep[model.id] = copy.id; selected.remove(copy.id) }
                            .buttonStyle(.borderless).controlSize(.small).font(WorkbenchTypography.secondary)
                            .help("Keep this version and mark the others as extra")
                    }
                }
            }
        } else {
            Text(row.name).font(WorkbenchTypography.emphasis).lineLimit(1).help(row.name)
        }
    }

    private func keepTitle(_ reason: DiskModel.KeepReason?) -> String {
        switch reason {
        case .used: "Used · keep"
        case .protected: "Serving · keep"
        case .chosen, nil: "Keep"
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(WorkbenchTypography.label)
            .padding(.horizontal, WorkbenchSpacing.xxs).padding(.vertical, WorkbenchSpacing.xxxs)
            .overlay(RoundedRectangle(cornerRadius: WorkbenchRadius.chip).stroke(WorkbenchColor.hairline))
    }

    // MARK: Action bar

    private func actionBar(selection: Set<String>, freed: Int64, items: [StoredModel]) -> some View {
        let quarantineBytes = reclaim.quarantined.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: WorkbenchSpacing.sm) {
            Button {
                onOpenQuarantine()
            } label: {
                Label(reclaim.quarantined.isEmpty ? "Quarantine is empty"
                      : "Quarantine: \(ReclaimFormat.count(reclaim.quarantined.count, "item")) · \(ReclaimFormat.byteCount(quarantineBytes))",
                      systemImage: "tray")
            }
            .buttonStyle(.borderless).font(WorkbenchTypography.secondary)
            Spacer()
            if let progress = reclaim.progressMessage { ProgressView(progress).controlSize(.small) }
            if !selection.isEmpty {
                Text("\(ReclaimFormat.count(selection.count, "item")) · frees \(ReclaimFormat.byteCount(freed))")
                    .font(WorkbenchTypography.tabular)
                Button("Clear") { selected = [] }.controlSize(.small)
            }
            Button("Review removal…") { Task { await reclaim.previewCopies(selection, items: items) } }
                .buttonStyle(.workbenchPrimary)
                .disabled(selection.isEmpty || reclaim.isApplying)
        }
    }

    private var moveResults: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            ForEach(reclaim.lastMoves, id: \.path) { move in
                Text(move.error.map { "\(URL(fileURLWithPath: move.path).lastPathComponent): \($0)" }
                     ?? "Removed \(URL(fileURLWithPath: move.path).lastPathComponent)")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(move.error == nil ? WorkbenchColor.success : WorkbenchColor.failure)
            }
        }
    }
}

// MARK: - This Mac

/// Processor load, memory, swap and free disk, then each loaded model with the memory and MLX cache it holds.
struct ReclaimSystemSection: View {
    @ObservedObject var resources: SystemResourceMonitor
    @ObservedObject var inventory: ServingInventoryCoordinator
    let volumePath: String?
    @State private var load: SystemLoadReading?

    var body: some View {
        let loaded = ReclaimSystemPresentation.loaded(inventory.snapshot)
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                CardHeader("This Mac", systemImage: "gauge.with.dots.needle.50percent") {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Read load, memory, disk and loaded models again")
                        .disabled(inventory.isRefreshing)
                }
                ReclaimFlowLayout(spacing: WorkbenchSpacing.lg, lineSpacing: WorkbenchSpacing.sm) {
                    if let memory = resources.memory {
                        gauge("Memory", value: "\(ReclaimFormat.byteCount(memory.availableBytes)) free of \(ReclaimFormat.byteCount(memory.totalBytes))",
                              fraction: Double(memory.unavailableBytes) / Double(max(memory.totalBytes, 1)),
                              warn: memory.availableBytes < FitAdvisor.reserveBytes)
                    }
                    if let load, let free = load.volumeFreeBytes, let total = load.volumeTotalBytes, total > 0 {
                        gauge("Disk" + (load.volumeName.map { " · " + $0 } ?? ""),
                              value: "\(ReclaimFormat.byteCount(free)) free of \(ReclaimFormat.byteCount(total))",
                              fraction: 1 - Double(free) / Double(total), warn: Double(free) / Double(total) < 0.1)
                    }
                    if let load {
                        gauge("Processor", value: String(format: "Load %.1f on %d cores", load.loadAverage, load.processorCount),
                              fraction: min(load.busyFraction, 1), warn: load.busyFraction > 1)
                        if let used = load.swapUsedBytes {
                            figure("Swap", used == 0 ? "None in use" : "\(ReclaimFormat.byteCount(used)) in use",
                                   warn: used > 0 && (resources.memory.map { $0.availableBytes < FitAdvisor.reserveBytes } ?? false))
                        }
                    }
                }
                Divider()
                Text(loaded.isEmpty ? "No models loaded" : "Loaded models").font(WorkbenchTypography.label)
                ForEach(loaded) { service in
                    loadedRow(service)
                }
                Text("MLX cache is memory a model's worker keeps for reuse after a request. Releasing it returns that memory to the system without unloading the model.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: volumePath) {
            while !Task.isCancelled {
                await readLoad()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private func refresh() async {
        await resources.refreshMemory()
        await readLoad()
        await inventory.refresh()
    }

    private func readLoad() async {
        let path = volumePath
        load = await Task.detached(priority: .utility) { SystemLoadReading.probe(volumeOf: path) }.value
    }

    private func loadedRow(_ service: ServingServiceObservation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(service.name).font(WorkbenchTypography.emphasis).lineLimit(1).truncationMode(.middle).help(service.modelPath ?? service.modelID)
                Text(service.providerName + " · " + ReclaimSystemPresentation.memoryText(service, processMemory: inventory.processMemory))
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            if let cache = service.server?.workerMemory?.cacheBytes {
                Text("MLX cache \(ReclaimFormat.byteCount(cache))").font(WorkbenchTypography.secondaryTabular)
            }
            if service.canReleaseCache {
                Button("Release cache…") { Task { await inventory.prepare(.releaseCache, service: service) } }
                    .controlSize(.small)
                    .disabled(inventory.isChanging || !inventory.mayChange(service))
            }
        }
    }

    private func gauge(_ title: String, value: String, fraction: Double, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Text(value).font(WorkbenchTypography.secondaryTabular).foregroundStyle(warn ? WorkbenchColor.warning : WorkbenchColor.ink)
            ProgressView(value: max(0, min(fraction, 1))).tint(warn ? WorkbenchColor.warning : WorkbenchColor.accent)
                .frame(width: WorkbenchSize.Reclaim.gaugeWidth)
        }
    }

    private func figure(_ title: String, _ value: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Text(value).font(WorkbenchTypography.secondaryTabular).foregroundStyle(warn ? WorkbenchColor.warning : WorkbenchColor.ink)
        }
    }
}

enum ReclaimSystemPresentation {
    /// Local models in memory now, largest reading first.
    static func loaded(_ snapshot: ServingInventorySnapshot) -> [ServingServiceObservation] {
        snapshot.services.filter { $0.isLocal && !$0.stale && $0.residency == .loaded && $0.modelID != "__inventory__" }
    }

    /// The best memory reading for a loaded model: the MLX allocator, else the provider's figure, else the process.
    static func memoryText(_ service: ServingServiceObservation, processMemory: [Int: UInt64]) -> String {
        if let reading = service.server?.workerMemory { return ServingInventoryPresentation.allocatorSummary(reading) }
        if let bytes = service.reportedMemoryBytes { return ReclaimFormat.byteCount(bytes) + " reported" }
        if let pid = service.modelProcessID, let bytes = processMemory[pid] {
            return ReclaimFormat.byteCount(Int64(clamping: bytes)) + " process memory"
        }
        return "Memory not reported"
    }
}

// MARK: - Summary

/// Disk under the scanned folders, every file counted once.
struct DiskSummaryView: View {
    let storage: ScanStorage

    var body: some View {
        let total = storage.roots.reduce(Int64(0)) { $0 + $1.totalBytes }
        let other = storage.roots.flatMap(\.other).sorted { $0.bytes > $1.bytes }
        let otherBytes = other.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.lg) {
                figure(ReclaimFormat.byteCount(total), "on disk in \(ReclaimFormat.count(storage.roots.count, "scanned folder"))")
                figure(ReclaimFormat.byteCount(storage.diskBytes), "in recognized models")
                ForEach(storage.stores.sorted { $0.bytes > $1.bytes }, id: \.store) { store in
                    figure(ReclaimFormat.byteCount(store.bytes), DiskRow.storeTitle(store.store), small: true)
                }
            }
            if !other.isEmpty {
                DisclosureGroup("\(ReclaimFormat.byteCount(otherBytes)) in \(ReclaimFormat.count(other.count, "place")) the scan does not recognize as a model") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        ForEach(other.prefix(25), id: \.path) { place in
                            HStack {
                                Text(place.path).font(WorkbenchTypography.compactValue).lineLimit(1).truncationMode(.middle).help(place.path)
                                Spacer()
                                Text(ReclaimFormat.byteCount(place.bytes)).font(WorkbenchTypography.secondaryTabular)
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: place.path)]) }
                                    .buttonStyle(.borderless).controlSize(.small)
                            }
                        }
                        if other.count > 25 {
                            Text("\(other.count - 25) smaller places not shown").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }
                    }.padding(.top, WorkbenchSpacing.xxs)
                }
                .font(WorkbenchTypography.secondary)
            }
        }
    }

    private func figure(_ value: String, _ caption: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(small ? WorkbenchTypography.tabular : WorkbenchTypography.display)
            Text(caption).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
    }
}

// MARK: - Removal sheet

struct CopyRemovalSheet: View {
    let plan: CopyRemovalPlan
    @ObservedObject var reclaim: ReclaimCoordinator
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Remove models", systemImage: "square.on.square").font(WorkbenchTypography.title)
            Text("Frees \(ReclaimFormat.byteCount(plan.freedBytes)) once quarantine is moved to Trash and Trash is emptied. Quarantined models can be put back.")
                .font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    ForEach(plan.removals) { removal in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            Text(removal.name).font(WorkbenchTypography.emphasis)
                            if let step = removal.step {
                                Text(step.summary).font(WorkbenchTypography.secondary)
                            } else {
                                Text("Skipped: \(removal.refusal ?? "not removable")").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
                            }
                            Text(removal.path).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320)
            HStack {
                Button("Cancel") { reclaim.cancelCopies() }.keyboardShortcut(.cancelAction)
                Spacer()
                if reclaim.isApplying { ProgressView().controlSize(.small) }
                Button("Remove \(ReclaimFormat.count(plan.actionable.count, "item"))") {
                    Task { await reclaim.confirmCopies(); onDone() }
                }
                .buttonStyle(.workbenchPrimary)
                .disabled(plan.actionable.isEmpty)
            }.disabled(reclaim.isApplying)
        }
        .padding(WorkbenchSpacing.lg).frame(width: 520)
        .interactiveDismissDisabled(reclaim.isApplying)
    }
}
