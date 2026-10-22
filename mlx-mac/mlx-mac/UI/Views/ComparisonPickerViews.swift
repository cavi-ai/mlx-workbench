import SwiftUI

// MARK: - Prompt set selection

enum ComparisonPromptSetPickerLogic {
    enum Section: String, CaseIterable { case temporary = "Temporary setup", saved = "Saved sets", builtin = "Built-in presets" }
    struct Group: Identifiable {
        let section: Section
        let sets: [PromptSet]
        var id: Section { section }
    }
    static func groups(_ sets: [PromptSet], temporaryID: String?, query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = sets.filter { set in
            query.isEmpty || ([set.name] + set.prompts.map { "\($0.text) \($0.tool?.name ?? "")" })
                .joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        return Section.allCases.compactMap { section in
            let entries = matches.filter { set in
                let source: Section = set.id == temporaryID ? .temporary : set.origin == .builtin ? .builtin : .saved
                return source == section
            }
            return entries.isEmpty ? nil : Group(section: section, sets: entries)
        }
    }
    static func promptCount(_ set: PromptSet) -> String {
        "\(set.prompts.count) \(set.prompts.count == 1 ? "prompt" : "prompts")"
    }
}

struct ComparisonPromptSetPicker: View {
    let sets: [PromptSet]
    @Binding var selection: String
    let temporaryID: String?
    @State private var expanded = false

    private var selected: PromptSet? { sets.first { $0.id == selection } ?? sets.first }

    var body: some View {
        Button { expanded = true } label: {
            HStack(spacing: WorkbenchSpacing.xs) {
                Text("Prompt set").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Text(selected?.name ?? "No prompt sets").font(WorkbenchTypography.emphasis)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .buttonStyle(.plain).disabled(sets.isEmpty)
        .accessibilityLabel("Choose prompt set")
        .accessibilityValue(selected?.name ?? "No prompt sets")
        .help(selected?.name ?? "No prompt sets available for this comparison mode")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ComparisonPromptSetPanel(sets: sets, selection: selected?.id, temporaryID: temporaryID) { id in
                guard sets.contains(where: { $0.id == id }) else { return }
                selection = id
                expanded = false
            }
        }
        .onChange(of: sets.map(\.id)) { _, _ in expanded = false }
    }
}

struct ComparisonPromptSetPanel: View {
    let sets: [PromptSet]
    let selection: String?
    let temporaryID: String?
    let onSelect: (String) -> Void
    @State var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Prompt sets").font(WorkbenchTypography.cardTitle)
            HStack(spacing: WorkbenchSpacing.xs) {
                TextField("Search names, prompts or tools", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search prompt sets")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.muted)
                        .accessibilityLabel("Clear prompt set search")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    let groups = ComparisonPromptSetPickerLogic.groups(sets, temporaryID: temporaryID, query: query)
                    if groups.isEmpty {
                        Text(sets.isEmpty ? "No prompt sets for this mode" : "No matching prompt sets")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ForEach(groups) { group in
                        Text(group.section.rawValue).font(WorkbenchTypography.metadata.weight(.semibold))
                            .foregroundStyle(WorkbenchColor.accent).padding(.top, WorkbenchSpacing.xs)
                        ForEach(group.sets) { set in
                            Button { onSelect(set.id) } label: {
                                HStack(spacing: WorkbenchSpacing.sm) {
                                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                        Text(set.name).font(WorkbenchTypography.label).lineLimit(1).truncationMode(.middle)
                                        Text(ComparisonPromptSetPickerLogic.promptCount(set))
                                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                    }
                                    Spacer()
                                    if selection == set.id { Image(systemName: "checkmark").foregroundStyle(WorkbenchColor.accent) }
                                }
                                .padding(WorkbenchSpacing.sm).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == set.id ? WorkbenchColor.accent.opacity(.fill) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(set.name)
                            .accessibilityAddTraits(selection == set.id ? [.isSelected] : [])
                        }
                    }
                }
            }.frame(maxHeight: 400)
        }
        .padding(WorkbenchSpacing.md).frame(width: 400)
        .onAppear { searchFocused = true }
    }
}

// MARK: - Run history

enum ComparisonHistoryLogic {
    struct Group: Identifiable {
        let mode: ComparisonMode
        let runs: [ComparisonRun]
        var id: ComparisonMode { mode }
    }

    static func groups(_ runs: [ComparisonRun], query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = runs.filter { query.isEmpty || "\($0.effectiveMode.title) \($0.promptSetName) \($0.variants.joined(separator: " "))".localizedCaseInsensitiveContains(query) }
        return ComparisonMode.allCases.compactMap { mode in
            let entries = matching.filter { $0.effectiveMode == mode }.sorted { $0.startedAt > $1.startedAt }
            return entries.isEmpty ? nil : Group(mode: mode, runs: entries)
        }
    }

    static func modelCount(_ run: ComparisonRun) -> String {
        "\(run.variants.count) \(run.variants.count == 1 ? "model" : "models")"
    }
}

struct ComparisonHistoryPicker: View {
    let runs: [ComparisonRun]
    @Binding var selection: UUID?
    @State private var expanded = false

    private var selected: ComparisonRun? { runs.first { $0.id == selection } }

    var body: some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(WorkbenchColor.muted)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text(selected?.promptSetName ?? "Run history").font(WorkbenchTypography.label).lineLimit(1)
                    if let selected {
                        Text("\(selected.effectiveMode.title) · \(selected.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose comparison run")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ComparisonHistoryPanel(runs: runs, selection: selection) { id in
                selection = id
                expanded = false
            }
        }
    }
}

struct ComparisonHistoryPanel: View {
    let runs: [ComparisonRun]
    let selection: UUID?
    let onSelect: (UUID) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Run history").font(WorkbenchTypography.cardTitle)
            TextField("Search runs or models", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    let groups = ComparisonHistoryLogic.groups(runs, query: query)
                    if groups.isEmpty {
                        Text("No matching runs").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ForEach(groups) { group in
                        Text(group.mode.title).font(WorkbenchTypography.metadata.weight(.semibold))
                            .foregroundStyle(WorkbenchColor.muted).padding(.top, WorkbenchSpacing.xs)
                        ForEach(group.runs) { run in
                            Button {
                                onSelect(run.id)
                            } label: {
                                HStack(spacing: WorkbenchSpacing.sm) {
                                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                        Text(run.promptSetName).font(WorkbenchTypography.label).lineLimit(1)
                                        Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(ComparisonHistoryLogic.modelCount(run)) · \(run.state.rawValue.capitalized)")
                                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                    }
                                    Spacer()
                                    if selection == run.id {
                                        Image(systemName: "checkmark").foregroundStyle(WorkbenchColor.accent)
                                    }
                                }
                                .padding(WorkbenchSpacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == run.id ? WorkbenchColor.accent.opacity(.fill) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == run.id ? [.isSelected] : [])
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .padding(WorkbenchSpacing.md)
        .frame(width: 400)
    }
}
