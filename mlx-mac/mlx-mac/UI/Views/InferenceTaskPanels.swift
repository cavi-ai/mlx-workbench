import AppKit
import SwiftUI

struct InferenceTaskPanel: View {
    @ObservedObject var coordinator: InferenceTaskCoordinator
    let model: LibraryModel
    @Environment(\.isRouteActive) private var isRouteActive

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                if model.item.task?.type == .classification {
                    classifier
                } else if model.item.task?.type == .musicGeneration {
                    music
                }
                RecentTaskList(coordinator: coordinator, model: model)
            }
        }
        .task { if isRouteActive { await coordinator.refreshRecent() } }
        .task(id: coordinator.selectedTask?.id) {
            while !Task.isCancelled && isRouteActive {
                guard let task = coordinator.selectedTask, task.state.isActive else { break }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await coordinator.refresh(id: task.id)
            }
        }
        .onChange(of: model.item.path) { _, _ in coordinator.stopPlayback() }
        .onDisappear { coordinator.stopPlayback() }
    }

    private var classifier: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Classify")
            TextEditor(text: $coordinator.classificationDraft.state)
                .frame(minHeight: 72, maxHeight: 120)
                .accessibilityIdentifier("task-classification-state")
            if let validationError = coordinator.classificationDraft.validationError,
               coordinator.classificationDraft.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.classificationDraft.questions.isEmpty {
                Text(validationError).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            ForEach($coordinator.classificationDraft.questions) { $question in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    HStack {
                        TextField("Question name", text: $question.name).accessibilityIdentifier("task-question-\(coordinator.classificationDraft.questions.firstIndex(where: { $0.id == question.id }) ?? 0)-name")
                        Picker("Question type", selection: $question.type) {
                            ForEach(ClassificationQuestionType.allCases) { type in Text(type.title).tag(type) }
                        }.frame(width: 150)
                    }
                    TextField("What should the model decide?", text: $question.instructions, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("task-question-\(coordinator.classificationDraft.questions.firstIndex(where: { $0.id == question.id }) ?? 0)-instructions")
                    switch question.type {
                    case .choice, .score:
                        ForEach(question.options.indices, id: \.self) { index in
                            HStack {
                                TextField(question.type == .choice ? "Option label" : "Level description", text: $question.options[index])
                                    .accessibilityIdentifier("task-question-\(coordinator.classificationDraft.questions.firstIndex(where: { $0.id == question.id }) ?? 0)-option-\(index)")
                                if question.options.count > 2 {
                                    Button("Remove") { question.options.remove(at: index) }.buttonStyle(.borderless)
                                }
                            }
                        }
                        Button("Add option") { question.options.append("") }.buttonStyle(.borderless)
                    case .noul:
                        TextField("False means… (optional)", text: $question.falseDescription)
                        TextField("True means… (optional)", text: $question.trueDescription)
                    }
                    if let error = question.error { Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure) }
                    if coordinator.classificationDraft.questions.count > 1 {
                        Button("Remove question") { coordinator.classificationDraft.questions.removeAll { $0.id == question.id } }.buttonStyle(.borderless)
                    }
                }
                .padding(WorkbenchSpacing.sm)
                .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: 8))
            }
            Button("Add question") { coordinator.classificationDraft.questions.append(ClassificationQuestionDraft()) }.buttonStyle(.bordered)
            taskActions(kind: .classification)
        }
    }

    private var music: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Generate music")
            TextField("Describe the music", text: $coordinator.musicDraft.caption, axis: .vertical)
                .lineLimit(2...5).accessibilityIdentifier("task-music-caption")
            TextField("Lyrics (leave blank for instrumental)", text: $coordinator.musicDraft.lyrics, axis: .vertical).lineLimit(2...5)
            HStack {
                TextField("Duration (seconds)", value: $coordinator.musicDraft.duration, format: .number).frame(width: 145)
                TextField("Steps", value: $coordinator.musicDraft.steps, format: .number).frame(width: 90)
                TextField("Seed", value: $coordinator.musicDraft.seed, format: .number).frame(width: 120)
            }
            if let validationError = coordinator.musicDraft.validationError {
                Text(validationError).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            taskActions(kind: .musicGeneration)
        }
    }

    private func taskActions(kind: TaskKind) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let error = coordinator.error { InlineMessage(kind: .warning, text: error) }
            if let readError = coordinator.readError { InlineMessage(kind: .warning, text: "Recent tasks could not refresh: \(readError)") }
            HStack {
                Button(coordinator.busy ? "Starting…" : "Start") { Task { await coordinator.start(kind: kind, model: model) } }
                    .buttonStyle(.borderedProminent).disabled(!coordinator.canStart || !coordinator.isDraftValid(for: kind)).accessibilityIdentifier("task-start")
                if let task = coordinator.selectedTask, task.state.isActive {
                    Button("Cancel") { Task { await coordinator.cancel(id: task.id) } }.accessibilityIdentifier("task-cancel")
                    Button("Refresh") { Task { await coordinator.refresh(id: task.id) } }.accessibilityIdentifier("task-status")
                } else if coordinator.busy {
                    Button("Cancel") { coordinator.requestCancelDuringStart() }.accessibilityIdentifier("task-cancel")
                }
                if coordinator.startOutcomeUnknown {
                    Button("Refresh Recent tasks") { Task { await coordinator.refreshRecent() } }.accessibilityIdentifier("task-status")
                }
            }
        }
    }
}

struct RecentTaskList: View {
    @ObservedObject var coordinator: InferenceTaskCoordinator
    var model: LibraryModel?
    @ObservedObject private var audio: AudioClipPlayer
    @State private var exportError: String?

    private var visibleTasks: [TaskRecord] {
        guard let model else { return coordinator.recent }
        return coordinator.recent.filter { $0.modelPath == model.item.path }
    }

    init(coordinator: InferenceTaskCoordinator, model: LibraryModel? = nil) {
        self.coordinator = coordinator
        self.model = model
        _audio = ObservedObject(wrappedValue: coordinator.audio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                SectionTitle(text: "Recent tasks")
                Spacer()
                Button("Refresh") { Task { await coordinator.refreshRecent() } }
            }
            if visibleTasks.isEmpty {
                Text("No recent inference tasks.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            if coordinator.hasMoreRecent {
                Text("Showing the 100 newest tasks. Older tasks are not available in this list.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            ForEach(visibleTasks, id: \.id) { task in
                HStack {
                    Button {
                        Task { await coordinator.selectTask(id: task.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(task.kind.title) · \(task.state.wireValue.capitalized)")
                            Text(URL(fileURLWithPath: task.modelPath).lastPathComponent).font(WorkbenchTypography.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("task-history-row-\(task.id)")
                    if model?.item.path == task.modelPath {
                        Button("Reuse") { if let model { Task { await coordinator.reuse(id: task.id, for: model) } } }
                            .disabled(task.kind.modelTaskType != model?.item.task?.type || model?.readiness != .ready)
                            .accessibilityIdentifier("task-reuse")
                    }
                }
            }
            if let error = exportError { Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure) }
            if let task = coordinator.selectedTask {
                Divider()
                Text("\(task.kind.title) · \(task.state.wireValue.capitalized)").font(WorkbenchTypography.value)
                Text("Recorded model: \(task.modelPath)").font(WorkbenchTypography.secondary).textSelection(.enabled)
                Text("Engine \(task.identity.engineVersion ?? "unknown") · \(task.identity.backend ?? "backend unknown") \(task.identity.backendVersion ?? "") · Python \(task.identity.pythonVersion ?? "unknown")")
                    .font(WorkbenchTypography.secondary).textSelection(.enabled)
                if let taskError = task.error { InlineMessage(kind: .warning, text: "\(taskError.message) · \(taskError.remediation)") }
                if let raw = coordinator.verifiedResult?.json {
                    Text(raw.prettyJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else if coordinator.selectedResult != nil {
                    Text("The verified result is too large for inline preview. Export the JSON to inspect it.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                if let output = coordinator.verifiedOutput {
                    HStack {
                        Button(audio.activeURL == output.url && audio.isPlaying ? "Pause" : "Play WAV") { audio.toggle(output.url) }
                            .accessibilityIdentifier(audio.isPlaying ? "task-audio-pause" : "task-audio-play")
                        if audio.activeURL == output.url {
                            Slider(value: Binding(get: { audio.position }, set: { audio.seek(to: $0) }), in: 0...max(audio.duration, 0.01))
                        }
                    }
                    Text("Verified WAV · \(output.reference.bytes) bytes · \(output.reference.sha256)").font(WorkbenchTypography.secondary).textSelection(.enabled)
                }
                Button("Export result…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "task-\(task.id)-result.json"
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        Task {
                            do { try await coordinator.export(id: task.id, to: url); exportError = nil }
                            catch { exportError = AppHost.render(error) }
                        }
                    }
                }
            }
        }
        .onChange(of: coordinator.selectedTask?.id) { _, _ in audio.stop() }
        .onDisappear { audio.stop() }
    }
}

private extension JSONValue {
    var prettyJSON: String {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return "Result payload could not be rendered." }
        return text
    }
}

private extension TaskKind {
    var title: String {
        switch self {
        case .classification: "Classification"
        case .musicGeneration: "Music generation"
        case .unsupported(let name): name
        }
    }
}
