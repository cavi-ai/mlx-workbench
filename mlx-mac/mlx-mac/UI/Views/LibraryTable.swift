import SwiftUI

// MARK: - LibraryRow

/// One row of the Library table. A family with more than one variant is a
/// disclosure row whose children are the variants; a single-variant family
/// is shown as the variant itself, so the table never repeats a name.
struct LibraryRow: Identifiable, Hashable {
    static let familyIDPrefix = "family:"

    let id: String
    let name: String
    let detail: String
    let readiness: ModelReadiness?
    let quantization: String
    let bytes: Int64
    let modifiedAt: Date?
    let modelPath: String?
    let children: [LibraryRow]?

    var isFamily: Bool { children != nil }
    var readinessTitle: String { readiness?.title ?? "" }
    var readinessSortKey: Int {
        readiness.flatMap { ModelReadiness.allCases.firstIndex(of: $0) } ?? ModelReadiness.allCases.count
    }
    var modifiedSortKey: TimeInterval { modifiedAt?.timeIntervalSince1970 ?? 0 }

    static func variant(_ model: LibraryModel) -> LibraryRow {
        LibraryRow(
            id: model.item.path,
            name: model.displayName,
            detail: LibraryTablePresentation.detail(for: model),
            readiness: model.readiness,
            quantization: model.item.quantization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            bytes: model.item.bytes,
            modifiedAt: model.item.modifiedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            modelPath: model.item.path,
            children: nil
        )
    }

    static func family(_ group: LibraryGroupViewModel, children: [LibraryRow]) -> LibraryRow {
        let quantizations = Set(children.map(\.quantization).filter { !$0.isEmpty })
        return LibraryRow(
            id: familyIDPrefix + group.id,
            name: group.primaryDisplayName,
            detail: "\(children.count) variants",
            readiness: nil,
            quantization: quantizations.count == 1 ? quantizations.first! : "",
            bytes: group.totalBytes,
            modifiedAt: children.compactMap(\.modifiedAt).max(),
            modelPath: nil,
            children: children
        )
    }
}

// MARK: - LibraryTablePresentation

enum LibraryTablePresentation {
    static let defaultSortOrder = [KeyPathComparator(\LibraryRow.name, comparator: .localizedStandard)]

    /// Flattens single-variant families and nests multi-variant ones, then
    /// applies the table's sort order at every level.
    static func rows(groups: [LibraryGroupViewModel], sortOrder: [KeyPathComparator<LibraryRow>]) -> [LibraryRow] {
        let order = sortOrder.isEmpty ? defaultSortOrder : sortOrder
        let top: [LibraryRow] = groups.map { group in
            let variants = group.variants.map(LibraryRow.variant).sorted(using: order)
            if variants.count == 1 {
                return variants[0]
            }
            return LibraryRow.family(group, children: variants)
        }
        return top.sorted(using: order)
    }

    /// The model path a table selection stands for; family rows stand for none.
    static func modelPath(forSelection id: String?) -> String? {
        guard let id else { return nil }
        let bucketPrefixes = [LibraryRow.familyIDPrefix, LibraryRow.typeIDPrefix, LibraryRow.useCaseIDPrefix]
        return bucketPrefixes.contains(where: id.hasPrefix) ? nil : id
    }

    /// A second line that locates the variant: the Hugging Face repo id for
    /// cache entries, otherwise the containing directory.
    static func detail(for model: LibraryModel) -> String {
        if let repoID = HFRepoID.forPath(model.item.path) {
            return repoID
        }
        return URL(fileURLWithPath: model.item.path).deletingLastPathComponent().path
    }

    static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Grouping

enum LibraryGroupMode: String, CaseIterable, Identifiable {
    case family
    case type

    var id: String { rawValue }
    var title: String { self == .family ? "Family" : "Type" }
}

extension LibraryRow {
    static let typeIDPrefix = "type:"
    static let useCaseIDPrefix = "usecase:"

    static func bucket(id: String, name: String, detail: String, children: [LibraryRow]) -> LibraryRow {
        LibraryRow(
            id: id, name: name, detail: detail, readiness: nil, quantization: "",
            bytes: children.reduce(Int64(0)) { $0 + $1.bytes },
            modifiedAt: children.compactMap(\.modifiedAt).max(),
            modelPath: nil, children: children
        )
    }
}

extension LibraryTablePresentation {
    /// Type → primary use case → family/variant rows. Types follow
    /// `ModelTaskType.allCases`; use cases sort by title.
    static func typeRows(groups: [LibraryGroupViewModel], sortOrder: [KeyPathComparator<LibraryRow>]) -> [LibraryRow] {
        var buckets: [ModelTaskType: [String: [LibraryGroupViewModel]]] = [:]
        for group in groups {
            let split = Dictionary(grouping: group.variants) { model in
                "\((model.item.task?.type ?? .other).rawValue)|\(model.item.task?.primaryUseCase ?? ModelTaskPresentation.unclassifiedUseCase)"
            }
            for (key, variants) in split {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                let type = ModelTaskType(rawValue: parts[0]) ?? .other
                buckets[type, default: [:]][parts[1], default: []].append(
                    LibraryGroupViewModel(sourceGroup: group.sourceGroup, variants: variants)
                )
            }
        }
        return ModelTaskType.allCases.compactMap { type -> LibraryRow? in
            guard let useCases = buckets[type] else { return nil }
            let useCaseRows = useCases.keys
                .sorted { ModelTaskPresentation.useCaseTitle($0) < ModelTaskPresentation.useCaseTitle($1) }
                .map { useCase -> LibraryRow in
                    let children = rows(groups: useCases[useCase] ?? [], sortOrder: sortOrder)
                    return .bucket(
                        id: LibraryRow.useCaseIDPrefix + "\(type.rawValue):\(useCase)",
                        name: ModelTaskPresentation.useCaseTitle(useCase),
                        detail: "\(children.count) \(children.count == 1 ? "entry" : "entries")",
                        children: children
                    )
                }
            return .bucket(
                id: LibraryRow.typeIDPrefix + type.rawValue,
                name: type.title,
                detail: "\(useCaseRows.count) use \(useCaseRows.count == 1 ? "case" : "cases")",
                children: useCaseRows
            )
        }
    }

    static func row(withID id: String, in rows: [LibraryRow]) -> LibraryRow? {
        for candidate in rows {
            if candidate.id == id { return candidate }
            if let children = candidate.children, let found = Self.row(withID: id, in: children) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Cells

struct LibraryNameCell: View {
    let row: LibraryRow

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.hairline) {
            Text(row.name)
                .font(row.isFamily ? WorkbenchTypography.emphasis : WorkbenchTypography.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.detail)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, WorkbenchSpacing.xxxs)
    }
}

struct LibraryReadinessCell: View {
    let row: LibraryRow

    var body: some View {
        if let readiness = row.readiness {
            StatusBadge(state: readiness.rawValue)
        } else {
            Text("")
        }
    }
}
