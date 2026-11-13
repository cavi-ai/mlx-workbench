import AppKit
import SwiftUI

// MARK: - Rows

/// A family row with its copies as children, sortable by every column.
struct DiskRow: Identifiable, Hashable {
    let id: String
    let name: String
    let copies: Int
    let bytes: Int64
    let couldFree: Int64
    let lastUsedKey: Double
    let storesText: String
    let familyID: String
    let copy: DiskCopy?
    let children: [DiskRow]?

    static let defaultSortOrder = [KeyPathComparator(\DiskRow.couldFree, order: .reverse)]

    static func rows(_ families: [DiskFamily], items: [StoredModel], sortOrder: [KeyPathComparator<DiskRow>]) -> [DiskRow] {
        let order = sortOrder.isEmpty ? defaultSortOrder : sortOrder
        return families.map { family in
            DiskRow(
                id: "family:" + family.id, name: family.name, copies: family.copies.count, bytes: family.bytes,
                couldFree: family.couldFree, lastUsedKey: family.lastUsed?.timeIntervalSince1970 ?? -1,
                storesText: family.stores.map(storeTitle).joined(separator: ", "), familyID: family.id, copy: nil,
                children: family.copies.map { copy in
                    DiskRow(
                        id: copy.id, name: copy.item.name, copies: 1, bytes: copy.item.bytes,
                        couldFree: copy.id == family.keep || copy.isProtected ? 0 : DiskLedger.freedBytes(removing: [copy.id], items: items),
                        lastUsedKey: copy.lastUsed?.timeIntervalSince1970 ?? -1, storesText: storeTitle(copy.item.store),
                        familyID: family.id, copy: copy, children: nil)
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

/// Reclaim's model view: where the disk goes and which copies can leave.
struct ReclaimDiskPanel: View {
    let appHost: AppHost
    @ObservedObject var reclaim: ReclaimCoordinator
    @ObservedObject var usage: UsageTracker
    let onOpenQuarantine: () -> Void

    @State private var filter: DiskFilter = .redundant
    @State private var sortOrder = DiskRow.defaultSortOrder
    @State private var focused: DiskRow.ID?
    @State private var selected: Set<String> = []
    @State private var keep: [String: String] = [:]

    var body: some View {
        if let storage = appHost.scanResult?.storage {
            content(storage)
        } else {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                ReclaimDesignedState(symbol: "internaldrive", text: appHost.isScanning
                    ? "Scanning model folders…"
                    : "This engine does not report disk use per model yet. Update mlx-agent, then rescan.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    private func content(_ storage: ScanStorage) -> some View {
        let protected = appHost.occupancy.protectedPaths.union(reclaim.protectedPaths())
        let all = DiskLedger.families(storage: storage, families: appHost.scanResult?.families ?? [],
                                      duplicates: appHost.scanResult?.duplicates ?? [], lastUsedByPath: usage.lastUsedByPath,
                                      protectedPaths: protected, keep: keep)
        let staleBefore = Date().addingTimeInterval(-Double(appHost.config.reclaimStaleDays) * 86_400)
        let shown = DiskLedger.filter(all, by: filter, staleBefore: staleBefore)
        let removable = Set(all.flatMap(\.removable).map(\.id))
        let selection = selected.intersection(removable)
        let freed = DiskLedger.freedBytes(removing: selection, items: storage.items)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ErrorBanner(text: reclaim.lastError)
            DiskSummaryView(storage: storage)
            HStack(spacing: WorkbenchSpacing.sm) {
                Picker("Show", selection: $filter) {
                    ForEach(DiskFilter.allCases) { option in
                        Text("\(option.title) (\(DiskLedger.filter(all, by: option, staleBefore: staleBefore).count))").tag(option)
                    }
                }
                .pickerStyle(.menu).fixedSize()
                Text(filterNote(staleBefore: staleBefore)).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Spacer()
                if filter != .all, shown.contains(where: { !$0.removable.isEmpty }) {
                    Button("Select every extra copy") { selected.formUnion(shown.flatMap(\.removable).map(\.id)) }
                        .controlSize(.small)
                }
            }
            table(DiskRow.rows(shown, items: storage.items, sortOrder: sortOrder), families: all)
            actionBar(selection: selection, freed: freed, items: storage.items)
            if !reclaim.lastMoves.isEmpty { moveResults }
        }
        .padding(WorkbenchSpacing.pageInset)
    }

    private func filterNote(staleBefore: Date) -> String {
        switch filter {
        case .redundant: "Models stored more than once, in any format. The kept copy is the one you used last."
        case .unused: "No copy used in \(appHost.config.reclaimStaleDays) days."
        case .identical: "The scan found the same weights twice."
        case .all: "Every model the scan recognized."
        }
    }

    // MARK: Table

    private func table(_ rows: [DiskRow], families: [DiskFamily]) -> some View {
        Table(of: DiskRow.self, selection: $focused, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.name) { row in nameCell(row, families: families) }
                .width(min: 260, ideal: 420)
            TableColumn("Copies", value: \.copies) { row in
                Text(row.copy == nil ? "\(row.copies)" : (row.copy?.item.format?.uppercased() ?? row.copy?.item.kind ?? ""))
                    .font(WorkbenchTypography.secondaryTabular).foregroundStyle(row.copy == nil ? WorkbenchColor.ink : WorkbenchColor.muted)
            }.width(min: 56, ideal: 72, max: 90)
            TableColumn("Size", value: \.bytes) { row in
                Text(ReclaimFormat.byteCount(row.bytes)).font(WorkbenchTypography.secondaryTabular)
            }.width(min: 70, ideal: 90, max: 110)
            TableColumn("Could free", value: \.couldFree) { row in
                Text(row.couldFree > 0 ? ReclaimFormat.byteCount(row.couldFree) : "—")
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(row.couldFree > 0 ? WorkbenchColor.ink : WorkbenchColor.muted)
            }.width(min: 80, ideal: 96, max: 120)
            TableColumn("Last used", value: \.lastUsedKey) { row in
                Text(row.lastUsedKey < 0 ? "Never" : WorkbenchRelativeTime.text(for: Date(timeIntervalSince1970: row.lastUsedKey), style: .abbreviated))
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }.width(min: 70, ideal: 96, max: 120)
            TableColumn("Where", value: \.storesText) { row in
                Text(row.storesText).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
            }.width(min: 90, ideal: 150)
        } rows: {
            ForEach(rows) { row in
                DisclosureTableRow(row) {
                    ForEach(row.children ?? []) { TableRow($0) }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: DiskRow.ID.self) { ids in
            if let id = ids.first, let row = rows.flatMap({ [$0] + ($0.children ?? []) }).first(where: { $0.id == id }) {
                if let copy = row.copy {
                    Button("Keep this copy") { keep[row.familyID] = copy.id }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.id)]) }
                } else if let family = families.first(where: { $0.id == row.familyID }) {
                    Button("Select extra copies") { selected.formUnion(family.removable.map(\.id)) }.disabled(family.removable.isEmpty)
                    Button("Clear selection") { selected.subtract(family.copies.map(\.id)) }
                }
            }
        }
    }

    @ViewBuilder
    private func nameCell(_ row: DiskRow, families: [DiskFamily]) -> some View {
        if let copy = row.copy {
            let isKept = families.first(where: { $0.id == row.familyID })?.keep == copy.id
            HStack(spacing: WorkbenchSpacing.xs) {
                Toggle("Remove \(copy.item.name)", isOn: Binding(
                    get: { selected.contains(copy.id) },
                    set: { if $0 { selected.insert(copy.id) } else { selected.remove(copy.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(isKept || copy.isProtected || reclaim.isApplying)
                    .help(isKept ? "The kept copy stays. Choose Keep on another copy to remove this one." : copy.isProtected ? "Serving, preferred or in use." : "Remove this copy")
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: WorkbenchSpacing.xxs) {
                        Text(copy.item.name).font(WorkbenchTypography.secondary).lineLimit(1)
                        if copy.isIdentical { tag("identical") }
                        if copy.isProtected { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(WorkbenchColor.muted).help("Serving, preferred or in use") }
                    }
                    Text(copy.id).font(.caption).foregroundStyle(WorkbenchColor.muted).lineLimit(1).truncationMode(.middle).help(copy.id)
                }
                Spacer(minLength: WorkbenchSpacing.xs)
                if isKept {
                    tag("Keep").foregroundStyle(WorkbenchColor.accent)
                } else {
                    Button("Keep") { keep[row.familyID] = copy.id; selected.remove(copy.id) }
                        .buttonStyle(.borderless).controlSize(.small).font(WorkbenchTypography.secondary)
                        .help("Keep this copy instead")
                }
            }
        } else {
            Text(row.name).font(WorkbenchTypography.emphasis).lineLimit(1).help(row.name)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, WorkbenchSpacing.xxs).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(WorkbenchColor.hairline))
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
                Text("\(ReclaimFormat.count(selection.count, "copy", plural: "copies")) · frees \(ReclaimFormat.byteCount(freed))")
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
            Label("Remove model copies", systemImage: "square.on.square").font(WorkbenchTypography.title)
            Text("Frees \(ReclaimFormat.byteCount(plan.freedBytes)) once quarantine is moved to Trash and Trash is emptied. Quarantined copies can be put back.")
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
                            Text(removal.path).font(.caption).foregroundStyle(WorkbenchColor.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320)
            HStack {
                Button("Cancel") { reclaim.cancelCopies() }.keyboardShortcut(.cancelAction)
                Spacer()
                if reclaim.isApplying { ProgressView().controlSize(.small) }
                Button("Remove \(ReclaimFormat.count(plan.actionable.count, "copy", plural: "copies"))") {
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
