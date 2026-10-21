import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media prompt sets

private extension View {
    func comparisonPromptActionHint(_ message: String) -> some View {
        help(message).accessibilityHint(message)
    }
}

struct ComparisonPromptCancelButton: View {
    let requiresConfirmation: Bool
    let onDismiss: () -> Void
    @State private var confirmingDiscard = false

    var body: some View {
        Group {
            if confirmingDiscard && requiresConfirmation {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Button("Keep editing") { confirmingDiscard = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Discard changes", role: .destructive, action: onDismiss)
                        .help("Close without keeping these draft changes.")
                }
                .controlSize(.small)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Unsaved prompt changes")
            } else {
                Button("Cancel") {
                    if requiresConfirmation { confirmingDiscard = true }
                    else { onDismiss() }
                }.keyboardShortcut(.cancelAction)
            }
        }
        .onChange(of: requiresConfirmation) { _, required in
            if !required { confirmingDiscard = false }
        }
    }
}

struct ComparisonPromptSetEditor: View {
    @State var draft: PromptSetDraft
    let onSave: (PromptSetDraft) async -> String?
    @State private var checkpoint: ComparisonPromptDraftCheckpoint<PromptSetDraft.Prompt>
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(draft: PromptSetDraft, onSave: @escaping (PromptSetDraft) async -> String?) {
        _draft = State(initialValue: draft)
        _checkpoint = State(initialValue: ComparisonPromptDraftCheckpoint(name: draft.name, prompts: draft.prompts))
        self.onSave = onSave
    }

    private var hasUnsavedChanges: Bool {
        draft.original != nil ? draft.hasChanges : checkpoint.hasChanges(name: draft.name, prompts: draft.prompts)
    }

    private var isMusic: Bool { draft.mode == .musicGeneration }

    private var footnote: String {
        switch draft.mode {
        case .musicGeneration where draft.original == nil:
            "Settings apply to each prompt. Duration is a maximum request. Blank settings use the current defaults. Saving does not generate audio."
        case .musicGeneration:
            "Save changes to this set. Blank settings use the current defaults. Past runs keep their recorded inputs, audio and ratings."
        case .videoGeneration:
            "Blank settings use runtime defaults. Each model checks its size alignment and frame grouping when run. Saving does not generate output."
        default:
            "Settings apply to each prompt. Saving does not run a comparison; past runs keep their recorded inputs and outputs."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("\(draft.original == nil ? "New" : "Edit") \(isMusic ? "music" : draft.mode.title.lowercased()) prompt set",
                  systemImage: isMusic && draft.original == nil ? "music.note.list" : "slider.horizontal.3")
                .font(WorkbenchTypography.cardTitle)
            if draft.original == nil {
                ComparisonPromptSetNameField(name: $draft.name, accessibilityName: isMusic ? "Music prompt set name" : "Prompt set name")
            } else {
                Text(draft.name).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            if isMusic { MusicPromptFields(draft: $draft) } else { ComparisonPromptFields(draft: $draft) }
            if draft.mode.inputKind != nil {
                Text("Saving keeps input copies with this set. Unchanged saved files are reused.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            Text(footnote).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error ?? draft.identityValidationError)
            if saving {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(draft.mode.inputKind != nil ? "Saving prompt set and input copies…" : "Saving prompt set…")
                        .font(WorkbenchTypography.metadata)
                }
            }
            HStack {
                Button { draft.addPrompt() } label: { Label("Add prompt", systemImage: "plus") }
                if draft.original != nil {
                    Button("Revert changes") { draft.revertChanges(); error = nil }
                        .buttonStyle(.borderless).disabled(!draft.hasChanges)
                        .help("Restore the set as it was when this editor opened.")
                }
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: hasUnsavedChanges) { dismiss() }
                Button(draft.original == nil ? "Save prompt set" : "Save changes") {
                    let copy = draft
                    saving = true
                    Task { @MainActor in
                        error = await onSave(copy)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.workbenchPrimary).tint(WorkbenchColor.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationError != nil || !draft.hasChanges)
                .comparisonPromptActionHint(draft.validationError
                    ?? (draft.hasChanges ? "Save this prompt set." : "No changes to save."))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: isMusic ? WorkbenchSize.Compare.musicPromptEditorWidth : WorkbenchSize.Compare.promptEditorWidth)
        .disabled(saving)
        .interactiveDismissDisabled(saving || hasUnsavedChanges)
    }

    /// The open panel, filtered to the kind of file the mode takes.
    static func pick(_ kind: ComparisonMediaKind) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch kind {
        case .image: panel.allowedContentTypes = [.png, .jpeg, .webP]
        case .video: panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        case .audio: panel.allowedContentTypes = [.wav, .mp3]
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

enum ComparisonPromptScrollLogic {
    struct Anchor: Hashable { let promptID: String }
    struct Issue: Equatable {
        let promptID: String
        let number: Int
        let message: String
    }

    static func firstIssue<Prompt: Identifiable>(in prompts: [Prompt],
        error: (Prompt) -> String?) -> Issue? where Prompt.ID == String {
        guard prompts.count > 1 else { return nil }
        for (index, prompt) in prompts.enumerated() {
            if let message = error(prompt) {
                return Issue(promptID: prompt.id, number: index + 1, message: message)
            }
        }
        return nil
    }

    static func insertedID(before: [String], after: [String]) -> String? {
        let previous = Set(before)
        return after.first { !$0.isEmpty && !previous.contains($0) }
    }
}

struct ComparisonPromptList<Content: View>: View {
    let promptIDs: [String]
    let maximumHeight: CGFloat
    let issue: ComparisonPromptScrollLogic.Issue?
    let content: Content

    init(promptIDs: [String], maximumHeight: CGFloat = WorkbenchSize.Compare.promptEditorHeight,
         issue: ComparisonPromptScrollLogic.Issue? = nil, @ViewBuilder content: () -> Content) {
        self.promptIDs = promptIDs; self.maximumHeight = maximumHeight
        self.issue = issue; self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                ScrollView { content }
                    .onChange(of: promptIDs) { before, after in
                        if let id = ComparisonPromptScrollLogic.insertedID(before: before, after: after) {
                            proxy.scrollTo(ComparisonPromptScrollLogic.Anchor(promptID: id), anchor: .top)
                        }
                    }
                if let issue {
                    Button {
                        proxy.scrollTo(ComparisonPromptScrollLogic.Anchor(promptID: issue.promptID), anchor: .top)
                    } label: {
                        Label("Fix prompt \(issue.number)", systemImage: "exclamationmark.circle")
                            .font(WorkbenchTypography.label)
                            .foregroundStyle(WorkbenchColor.warning)
                    }
                    .buttonStyle(.borderless)
                    .help(issue.message)
                    .accessibilityHint(issue.message)
                }
            }
        }.frame(maxHeight: maximumHeight)
    }
}

/// The same cards are used for new sets, saved-set edits and recorded-run reuse.
struct ComparisonPromptFields: View {
    @Binding var draft: PromptSetDraft
    @StateObject private var audio = AudioClipPlayer()

    var body: some View {
        ComparisonPromptList(promptIDs: draft.prompts.map(\.id),
            issue: ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: draft.mode) }) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                ForEach($draft.prompts) { $prompt in
                    ComparisonPromptCard(prompt: $prompt, mode: draft.mode,
                        number: (draft.prompts.firstIndex { $0.id == prompt.id } ?? 0) + 1,
                        canRemove: draft.prompts.count > 1,
                        canMoveUp: draft.prompts.first?.id != prompt.id,
                        canMoveDown: draft.prompts.last?.id != prompt.id,
                        audio: audio,
                        onDuplicate: { draft.duplicatePrompt(id: prompt.id) },
                        onMove: { draft.movePrompt(id: prompt.id, direction: $0) },
                        onRemove: { draft.removePrompt(id: prompt.id) })
                        .id(ComparisonPromptScrollLogic.Anchor(promptID: prompt.id))
                }
            }
        }
        .onDisappear { audio.stop() }
    }
}

struct ComparisonPromptSetNameField: View {
    @Binding var name: String
    var placeholder = "Set name"
    var accessibilityName = "Prompt set name"
    var showInitialError = false
    @State private var edited = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(accessibilityName)
            if let message = PromptSetNameValidation.error(for: name),
               showInitialError || edited || !name.isEmpty {
                ComparisonDraftValidationMessage(message: message)
            }
        }
        .onChange(of: name) { _, _ in edited = true }
    }
}

private struct ComparisonDraftValidationMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ComparisonPromptRemoveButton: View {
    let number: Int
    let canRemove: Bool
    let onRemove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        Group {
            if confirmingRemoval && canRemove {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Button("Keep prompt") { confirmingRemoval = false }
                        .comparisonPromptActionHint("Keep this prompt in the draft.")
                    Button("Remove prompt", role: .destructive) {
                        guard canRemove else { return }
                        confirmingRemoval = false
                        onRemove()
                    }
                    .comparisonPromptActionHint("Remove prompt \(number) from this draft.")
                }
                .controlSize(.small)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Removal choices for prompt \(number)")
            } else {
                Button { confirmingRemoval = true } label: { Image(systemName: "minus.circle") }
                    .disabled(!canRemove)
                    .accessibilityLabel("Remove prompt \(number)")
                    .comparisonPromptActionHint(canRemove
                        ? "Review removal of this prompt." : "At least one prompt is required.")
            }
        }
        .buttonStyle(.borderless)
        .onChange(of: canRemove) { _, allowed in
            if !allowed { confirmingRemoval = false }
        }
    }
}

/// Restores raw values without validation, saving or touching input files.
struct ComparisonPromptRevertAction<Prompt: Identifiable & Equatable>: View {
    @Binding var prompt: Prompt
    let opened: Prompt
    let number: Int

    var body: some View {
        Button {
            guard prompt.id == opened.id else { return }
            prompt = opened
        } label: { Label("Revert prompt", systemImage: "arrow.uturn.backward") }
        .disabled(prompt.id != opened.id || prompt == opened)
        .comparisonPromptActionHint("Restore prompt \(number) as it was when this card opened; keep other prompts and their order.")
    }
}

private struct ComparisonPromptActions<Prompt: Identifiable & Equatable>: View {
    @Binding var prompt: Prompt
    @State private var opened: Prompt
    let number: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDuplicate: () -> Void
    let onMove: (ComparisonPromptMoveDirection) -> Void

    init(prompt: Binding<Prompt>, number: Int, canMoveUp: Bool, canMoveDown: Bool,
         onDuplicate: @escaping () -> Void, onMove: @escaping (ComparisonPromptMoveDirection) -> Void) {
        _prompt = prompt; _opened = State(initialValue: prompt.wrappedValue)
        self.number = number; self.canMoveUp = canMoveUp; self.canMoveDown = canMoveDown
        self.onDuplicate = onDuplicate; self.onMove = onMove
    }

    var body: some View {
        Menu {
            Button(action: onDuplicate) { Label("Duplicate prompt", systemImage: "plus.square.on.square") }
            Divider()
            Button { onMove(.up) } label: { Label("Move up", systemImage: "arrow.up") }
                .disabled(!canMoveUp)
            Button { onMove(.down) } label: { Label("Move down", systemImage: "arrow.down") }
                .disabled(!canMoveDown)
            Divider()
            ComparisonPromptRevertAction(prompt: $prompt, opened: opened, number: number)
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Actions for prompt \(number)")
            .help("Duplicate, reorder or revert this prompt")
    }
}

private struct ComparisonPromptCard: View {
    @Binding var prompt: PromptSetDraft.Prompt
    let mode: ComparisonMode
    let number: Int
    let canRemove: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let audio: AudioClipPlayer
    let onDuplicate: () -> Void
    let onMove: (PromptSetDraft.MoveDirection) -> Void
    let onRemove: () -> Void

    private var textLabel: String {
        switch mode {
        case .vision, .videoUnderstanding: "Question"
        case .speechToText: "Reference transcript (optional)"
        case .textToSpeech: "Text to speak"
        default: "Prompt"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text("PROMPT \(number)").font(WorkbenchTypography.metadata.weight(.semibold))
                    .foregroundStyle(WorkbenchColor.accent)
                Spacer()
                ComparisonPromptActions(prompt: $prompt, number: number, canMoveUp: canMoveUp, canMoveDown: canMoveDown,
                    onDuplicate: onDuplicate, onMove: onMove)
                ComparisonPromptRemoveButton(number: number, canRemove: canRemove, onRemove: onRemove)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(textLabel).font(WorkbenchTypography.label)
                TextField(textLabel, text: $prompt.text, axis: .vertical)
                    .lineLimit(2...5).accessibilityLabel("Prompt \(number) \(textLabel.lowercased())")
            }
            if let kind = mode.inputKind {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Button("Choose \(kind.rawValue) file…") {
                        if let path = ComparisonPromptSetEditor.pick(kind) { prompt.inputPath = path }
                    }
                    Text(prompt.inputDisplayName
                        ?? (prompt.builtinInput == nil ? "No file chosen" : "Built-in \(kind.rawValue) fixture"))
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1).truncationMode(.middle).help(prompt.inputPath)
                    if prompt.hasInputChanges {
                        Button("Revert input") { prompt.revertInput() }
                            .buttonStyle(.borderless)
                            .comparisonPromptActionHint("Restore the input from when this editor opened; keep other prompt edits.")
                            .accessibilityLabel("Revert input for prompt \(number)")
                    }
                }
                if prompt.usesSavedInput, !prompt.inputFileUnavailable {
                    Label("Saved input from this run", systemImage: "archivebox")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.accent)
                }
                if prompt.inputFileUnavailable, prompt.validationError(for: mode) == nil {
                    Label(prompt.usesSavedInput ? "Saved input unavailable · choose a replacement"
                        : "Input file unavailable · choose a replacement", systemImage: "exclamationmark.triangle")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                }
                if let url = prompt.inputPreviewURL {
                    ComparisonPromptInputPreview(url: url, kind: kind, audio: audio)
                } else if prompt.inputPath.isEmpty, prompt.builtinInput != nil {
                    Text("Built-in input is created when the comparison runs.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if mode == .vision || mode == .videoUnderstanding {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Expected words · optional").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    TextField("Comma-separated; a|b accepts either", text: $prompt.keywords)
                        .accessibilityLabel("Prompt \(number) expected words")
                }
            }
            if mode == .chat || mode == .vision || mode == .videoUnderstanding {
                parameter("Token limit", placeholder: "Default: 256", value: $prompt.maxTokens)
                    .help("Requested maximum output tokens. Run also applies the current serving token cap.")
                if mode == .chat, let name = prompt.toolName {
                    Label("Saved tool: \(name)", systemImage: "wrench.and.screwdriver")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if mode == .imageGeneration {
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    parameter("Size · square px", placeholder: "Default: 512", value: $prompt.size)
                    parameter("Steps", placeholder: "Default: 20", value: $prompt.steps)
                    parameter("Seed", placeholder: "Default: 42", value: $prompt.seed)
                }
            }
            if mode == .videoGeneration {
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    parameter("Width · px", placeholder: "Runtime default", value: $prompt.width)
                    parameter("Height · px", placeholder: "Runtime default", value: $prompt.height)
                    parameter("Frames", placeholder: "Runtime default", value: $prompt.frames)
                }
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    parameter("Frame rate · fps", placeholder: "Model default", value: $prompt.fps)
                    parameter("Steps", placeholder: "Model default", value: $prompt.steps)
                    parameter("Seed", placeholder: "Default: 42", value: $prompt.seed)
                }
            }
            if let message = prompt.validationError(for: mode) {
                ComparisonDraftValidationMessage(message: message)
                    .accessibilityLabel("Prompt \(number): \(message)")
            }
        }
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }

    private func parameter(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            TextField(placeholder, text: value).accessibilityLabel("Prompt \(number) \(title.lowercased())")
        }.frame(maxWidth: .infinity)
    }
}

/// Explicit previews share one audio player across the editor. Opening the editor
/// never generates built-in fixtures or starts playback.
struct ComparisonPromptInputPreview: View {
    let url: URL
    let kind: ComparisonMediaKind
    @ObservedObject var audio: AudioClipPlayer
    @State private var expanded: Bool
    @State private var image: PreviewImage?

    init(url: URL, kind: ComparisonMediaKind, audio: AudioClipPlayer, expanded: Bool = false) {
        self.url = url; self.kind = kind; self.audio = audio
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup("Preview input", isExpanded: $expanded) {
            if expanded {
                switch kind {
                case .image:
                    ThumbnailView(url: url, size: CGSize(width: 160, height: 160)) {
                        image = PreviewImage(url: url)
                    }
                    .accessibilityLabel("Preview input image; open a larger view")
                case .audio:
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        AudioClipButton(url: url, label: "Play input", player: audio)
                        if audio.activeURL == url {
                            Slider(value: Binding(get: { audio.position }, set: { audio.seek(to: $0) }),
                                in: 0...max(audio.duration, 0.001))
                                .accessibilityLabel("Input audio position")
                            Text(String(format: "%.1f / %.1f seconds", audio.position, audio.duration))
                                .font(WorkbenchTypography.metadata.monospacedDigit()).foregroundStyle(WorkbenchColor.muted)
                        }
                    }.frame(maxWidth: 320, alignment: .leading)
                case .video:
                    ClipVideoView(url: url).frame(width: 280, height: 158)
                }
            }
        }
        .font(WorkbenchTypography.secondary)
        .sheet(item: $image) { item in ImagePreviewSheet(url: item.url) }
        .onChange(of: expanded) { _, open in
            if !open, audio.activeURL == url { audio.stop() }
        }
        .onChange(of: url) { old, _ in
            if audio.activeURL == old { audio.stop() }
            expanded = false; image = nil
        }
        .onDisappear { if audio.activeURL == url { audio.stop() } }
    }
}

struct ComparisonRunSetupSheet: View {
    @State var setup: ComparisonRunSetup
    @State private var checkpoint: ComparisonPromptDraftCheckpoint<PromptSetDraft.Prompt>
    let availablePaths: Set<String>
    let name: (String) -> String
    let onApply: (ComparisonRunSetup, PromptSet) -> String?
    let onSave: (PromptSetDraft) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var showingSaveName = false
    @State private var saveName = ""
    @State private var savedName: String?
    @State private var saving = false

    init(setup: ComparisonRunSetup, availablePaths: Set<String>, name: @escaping (String) -> String,
         onApply: @escaping (ComparisonRunSetup, PromptSet) -> String?,
         onSave: @escaping (PromptSetDraft) async -> String?) {
        _setup = State(initialValue: setup)
        _checkpoint = State(initialValue: ComparisonPromptDraftCheckpoint(prompts: setup.draft.prompts))
        self.availablePaths = availablePaths; self.name = name; self.onApply = onApply; self.onSave = onSave
    }

    private var hasUnsavedChanges: Bool {
        checkpoint.hasChanges(prompts: setup.draft.prompts)
            || (showingSaveName && saveName != "\(setup.sourceName) copy")
    }

    private var isMusic: Bool { setup.draft.mode == .musicGeneration }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(WorkbenchTypography.title).foregroundStyle(WorkbenchColor.accent)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Reuse \(isMusic ? "music" : setup.draft.mode.title.lowercased()) setup").font(WorkbenchTypography.cardTitle)
                    Text(setup.sourceName).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                ForEach(Array(setup.modelPaths.enumerated()), id: \.offset) { index, path in
                    HStack(spacing: WorkbenchSpacing.xs) {
                        LetterChip(letter: ComparePresentation.letter(index))
                        Text(name(path)).font(WorkbenchTypography.label).lineLimit(1).truncationMode(.middle)
                        if !availablePaths.contains(path) {
                            Label("Unavailable", systemImage: "exclamationmark.triangle")
                                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                        }
                    }.help(path)
                }
                if setup.modelPaths.contains(where: { !availablePaths.contains($0) }) {
                    Text("Replace or remove unavailable models in Compare before running.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                }
            }
            if isMusic { MusicPromptFields(draft: $setup.draft) } else { ComparisonPromptFields(draft: $setup.draft) }
            if setup.draft.mode.inputKind != nil {
                Text("Save as prompt set keeps its own input copies. Temporary setups use the ten-run cache; older runs use original files or built-in fixtures.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            Text(isMusic
                ? "Temporary inputs for a new run. Blank settings use the current defaults. Saved results and listening ratings stay with the original run."
                : "Recorded prompts and models for a new run. Current serving limits and runtime defaults still apply. Original results and ratings stay intact.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error ?? setup.draft.identityValidationError)
            if showingSaveName {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ComparisonPromptSetNameField(name: $saveName, placeholder: "Prompt set name",
                        accessibilityName: isMusic ? "Saved music prompt set name" : "Saved prompt set name")
                    Button("Save") {
                        let copy = setup.savedDraft(named: saveName)
                        let title = saveName
                        saving = true
                        Task { @MainActor in
                            error = await onSave(copy)
                            if error == nil {
                                checkpoint.retain(prompts: setup.draft.prompts)
                                savedName = title; showingSaveName = false
                            }
                            saving = false
                        }
                    }
                    .disabled(setup.savedDraft(named: saveName).validationError != nil)
                    .comparisonPromptActionHint(setup.savedDraft(named: saveName).validationError
                        ?? (isMusic ? "Save an independent copy of these music prompts." : "Save an independent copy of these prompts and inputs."))
                    Button { showingSaveName = false; error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Cancel saving the prompt set")
                        .accessibilityLabel("Cancel saving the prompt set")
                }
            }
            if let savedName {
                Label("Saved ‘\(savedName)’ in the prompt set picker.", systemImage: "checkmark.circle")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.success)
            }
            if saving {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(setup.draft.mode.inputKind != nil ? "Saving prompt set and input copies…" : "Saving prompt set…")
                        .font(WorkbenchTypography.metadata)
                }
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                Button { setup.draft.addPrompt() } label: { Label("Add prompt", systemImage: "plus") }
                Button("Save as prompt set…") {
                    saveName = "\(setup.sourceName) copy"; showingSaveName = true; savedName = nil; error = nil
                }
                .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.accent).disabled(showingSaveName)
                .comparisonPromptActionHint(showingSaveName
                    ? "Enter a name in the save field above." : "Name and save a copy of this setup.")
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: hasUnsavedChanges) { dismiss() }
                Button("Use setup") {
                    do {
                        error = onApply(setup, try setup.draft.promptSet())
                        if error == nil { dismiss() }
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.workbenchPrimary).tint(WorkbenchColor.accent).keyboardShortcut(.defaultAction)
                .disabled(setup.draft.validationError != nil)
                .comparisonPromptActionHint(setup.draft.validationError
                    ?? "Use these \(isMusic ? "music prompts" : "prompts") and model selections for a new comparison.")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: isMusic ? WorkbenchSize.Compare.musicPromptEditorWidth : WorkbenchSize.Compare.promptEditorWidth)
        .disabled(saving)
        .interactiveDismissDisabled(saving || hasUnsavedChanges)
    }
}

// MARK: - Saved music prompt sets

/// Shared fields for creation, saved-set editing and recorded-run reuse.
struct MusicPromptFields: View {
    @Binding var draft: PromptSetDraft

    var body: some View {
        ComparisonPromptList(promptIDs: draft.prompts.map(\.id), maximumHeight: WorkbenchSize.Compare.musicPromptEditorHeight,
            issue: ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: .musicGeneration) }) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                ForEach($draft.prompts) { $prompt in
                    let promptID = prompt.id
                    let number = (draft.prompts.firstIndex { $0.id == promptID } ?? 0) + 1
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        HStack {
                            Text("PROMPT \(number)").font(WorkbenchTypography.metadata.weight(.semibold))
                                .foregroundStyle(WorkbenchColor.accent)
                            Spacer()
                            ComparisonPromptActions(prompt: $prompt, number: number,
                                canMoveUp: draft.prompts.first?.id != promptID, canMoveDown: draft.prompts.last?.id != promptID,
                                onDuplicate: { draft.duplicatePrompt(id: promptID) },
                                onMove: { draft.movePrompt(id: promptID, direction: $0) })
                            ComparisonPromptRemoveButton(number: number, canRemove: draft.prompts.count > 1) {
                                draft.removePrompt(id: promptID)
                            }
                        }
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            Text("Caption").font(WorkbenchTypography.label)
                            TextField("Describe the music", text: $prompt.text, axis: .vertical)
                                .lineLimit(2...5).accessibilityLabel("Prompt \(number) caption")
                        }
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            Text("Lyrics").font(WorkbenchTypography.label)
                            TextField("Default: [instrumental]", text: $prompt.lyrics, axis: .vertical)
                                .lineLimit(2...6).accessibilityLabel("Prompt \(number) lyrics")
                        }
                        HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                            parameter("Duration · seconds", defaultValue: "Default: 15", value: $prompt.duration)
                            parameter("Steps", defaultValue: "Default: 30", value: $prompt.steps)
                            parameter("Seed", defaultValue: "Default: 42", value: $prompt.seed)
                        }
                        if let message = prompt.validationError(for: .musicGeneration) {
                            ComparisonDraftValidationMessage(message: message)
                                .accessibilityLabel("Prompt \(number): \(message)")
                        }
                    }
                    .padding(WorkbenchSpacing.md)
                    .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                    .id(ComparisonPromptScrollLogic.Anchor(promptID: promptID))
                }
            }
        }
    }

    private func parameter(_ title: String, defaultValue: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            TextField(defaultValue, text: value).accessibilityLabel(title)
        }.frame(maxWidth: .infinity)
    }
}

struct PromptSetActions: View {
    let name: String?
    let isEnabled: Bool
    var isCopyEnabled = false
    let onEdit: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    var onCopy: (() -> Void)? = nil

    var body: some View {
        Menu {
            if let onCopy {
                Button("Customize copy…", systemImage: "doc.on.doc", action: onCopy).disabled(!isCopyEnabled)
            }
            if isEnabled {
                if onCopy != nil { Divider() }
                Button("Edit…", systemImage: "slider.horizontal.3", action: onEdit)
                Button("Rename…", systemImage: "pencil", action: onRename)
                Button("Remove…", systemImage: "trash", role: .destructive, action: onRemove)
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!isEnabled && !isCopyEnabled)
            .accessibilityLabel("Manage saved prompt set")
            .help(isEnabled ? "Manage \(name ?? "prompt set")"
                : isCopyEnabled ? "Customize a copy of \(name ?? "prompt set")"
                : "Select a prompt set after the current save or comparison finishes.")
    }
}

struct PromptSetRenameSheet: View {
    let set: PromptSet
    let onRename: (String) -> String?
    @State private var draft: PromptSetRenameDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(set: PromptSet, onRename: @escaping (String) -> String?) {
        self.set = set
        self.onRename = onRename
        _draft = State(initialValue: PromptSetRenameDraft(set: set))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Rename \(set.effectiveMode.title.lowercased()) prompt set", systemImage: "pencil")
                .font(WorkbenchTypography.cardTitle)
            Text("Only this saved set's name changes. Past runs keep their recorded names and inputs.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            ComparisonPromptSetNameField(name: $draft.name, placeholder: "Prompt set name", showInitialError: true)
            ErrorBanner(text: error)
            HStack {
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: draft.hasChanges) { dismiss() }
                Button("Rename") {
                    error = onRename(draft.normalizedName)
                    if error == nil { dismiss() }
                }
                .buttonStyle(.workbenchPrimary).tint(WorkbenchColor.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canRename)
                .comparisonPromptActionHint(draft.validationError
                    ?? (draft.canRename ? "Save this prompt set's new name." : "No name change to save."))
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.Compare.promptSetRenameWidth)
        .interactiveDismissDisabled(draft.hasChanges)
    }
}
