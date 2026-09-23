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
        guard let id, !id.hasPrefix(LibraryRow.familyIDPrefix) else { return nil }
        return id
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

// MARK: - Cells

struct LibraryNameCell: View {
    let row: LibraryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
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
        .padding(.vertical, 2)
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
