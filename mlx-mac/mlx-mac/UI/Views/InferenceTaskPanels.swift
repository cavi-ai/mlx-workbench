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
        .task(id: "\(isRouteActive):\(coordinator.selectedTask?.id ?? ""):\(coordinator.selectedTask?.state.wireValue ?? "")") {
            guard isRouteActive, let task = coordinator.selectedTask, task.state.isActive else {
                coordinator.stopPolling(owner: "model-inspector")
                return
            }
            coordinator.startPolling(id: task.id, owner: "model-inspector")
        }
        .onChange(of: isRouteActive) { _, active in
            if !active { coordinator.stopPolling(owner: "model-inspector"); coordinator.stopPlayback() }
        }
        .onChange(of: model.item.path) { _, _ in coordinator.stopPlayback() }
        .onDisappear { coordinator.stopPolling(owner: "model-inspector"); coordinator.stopPlayback() }
    }

    private var classifier: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Classify")
            TextEditor(text: $coordinator.classificationDraft.state)
                .frame(minHeight: 72, maxHeight: 120)
                .accessibilityIdentifier("task-classification-state")
            if let validationError = coordinator.classificationDraft.validationError,
               coordinator.classificationDraft.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.classificationDraft.questions.isEmpty || Set(coordinator.classificationDraft.questions.map(\.name)).count != coordinator.classificationDraft.questions.count {
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
            HStack {
                Button(coordinator.busy ? "Starting…" : "Start") { Task { await coordinator.start(kind: kind, model: model) } }
                    .buttonStyle(.borderedProminent).disabled(!coordinator.canStart || !coordinator.isDraftValid(for: kind)).accessibilityIdentifier("task-start")
                if let task = coordinator.selectedTask, task.state.isActive {
                    Button("Cancel") { Task { await coordinator.cancel(id: task.id) } }.accessibilityIdentifier("task-cancel")
                    Button("Refresh") { Task { await coordinator.refresh(id: task.id) } }.accessibilityIdentifier("task-refresh")
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
            if let readError = coordinator.readError {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text("Could not refresh task history: \(readError)")
                        if let known = coordinator.selectedTask {
                            Text("Showing last known status: \(known.state.wireValue.capitalized).")
                                .font(WorkbenchTypography.secondary)
                        }
                    }
                    Spacer()
                    Button("Retry") {
                        if let selected = coordinator.selectedTask {
                            Task {
                                if selected.state.isActive { await coordinator.refresh(id: selected.id) }
                                else { await coordinator.inspect(id: selected.id) }
                            }
                        } else { Task { await coordinator.refreshRecent() } }
                    }
                }
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.failure)
                .accessibilityIdentifier("task-read-error")
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
                    if task.kind.modelTaskType != nil {
                        let reason = reuseUnavailableReason(task)
                        Button("Reuse") { if let model, reason == nil { Task { await coordinator.reuse(id: task.id, for: model) } } }
                            .disabled(reason != nil)
                            .help(reason ?? "Fill the task form from this recorded request")
                            .accessibilityHint(reason ?? "Fills the task form without starting a new task")
                            .accessibilityIdentifier("task-reuse")
                    }
                }
            }
            if let error = exportError { Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure) }
            if let task = coordinator.selectedTask {
                Divider()
                Text("\(task.kind.title) · \(task.state.wireValue.capitalized)").font(WorkbenchTypography.value)
                    .accessibilityIdentifier("task-status")
                Text("Recorded model: \(task.modelPath)").font(WorkbenchTypography.secondary).textSelection(.enabled)
                Text("Engine \(task.identity.engineVersion ?? "unknown") · \(task.identity.backend ?? "backend unknown") \(task.identity.backendVersion ?? "") · Python \(task.identity.pythonVersion ?? "unknown")")
                    .font(WorkbenchTypography.secondary).textSelection(.enabled)
                if let taskError = task.error { InlineMessage(kind: .warning, text: "\(taskError.message) · \(taskError.remediation)") }
                if task.kind == .classification,
                   let raw = coordinator.selectedResult?.result ?? coordinator.verifiedResult?.json {
                    ClassificationTaskAnswerSummary(projection: TaskResultProjection(raw: raw))
                }
                if let raw = coordinator.verifiedResult?.json {
                    Text(raw.prettyJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else if coordinator.selectedResult != nil {
                    Text("The verified result is too large for inline preview. Export the JSON to inspect it.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                if let output = coordinator.verifiedOutput {
                    HStack {
                        Button(audio.activeURL == output.url && audio.isPlaying ? "Pause" : "Play WAV") { audio.toggle(output.url) }
                            .accessibilityIdentifier(audio.isPlaying ? "task-audio-pause" : "task-audio-play")
                        Button("Export WAV…") {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "task-\(task.id)-output.wav"
                            panel.begin { response in
                                guard response == .OK, let url = panel.url else { return }
                                Task {
                                    do { try await coordinator.exportAudio(id: task.id, to: url); exportError = nil }
                                    catch { exportError = AppHost.render(error) }
                                }
                            }
                        }
                        .accessibilityIdentifier("task-export-audio")
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

    private func reuseUnavailableReason(_ task: TaskRecord) -> String? {
        guard let model else { return "Select the matching Ready model in Library to reuse this request." }
        guard model.readiness == .ready else { return "Reuse requires a Ready model." }
        guard model.item.path == task.modelPath else { return "Select the model recorded for this task." }
        guard model.item.task?.type == task.kind.modelTaskType else { return "The selected model does not support this task type." }
        return nil
    }
}

private struct ClassificationTaskAnswerSummary: View {
    let projection: TaskResultProjection

    var body: some View {
        if !projection.answers.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                SectionTitle(text: "Classification answers")
                ForEach(projection.answers.keys.sorted(), id: \.self) { name in
                    if let answer = projection.answers[name] {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            Text(name).font(WorkbenchTypography.value)
                            if let type = answer.type { Text("Type: \(type)") }
                            if let choice = answer.choice { Text("Choice: \(choice)") }
                            if let score = answer.score { Text("Score: \(score.formatted())") }
                            if let noul = answer.noul { Text("True/false value: \(noul.formatted())") }
                            if let legend = answer.legend { Text("Legend: \(JSONValue.object(legend).prettyJSON)") }
                            if let probabilities = answer.probabilities { Text("Probabilities: \(JSONValue.object(probabilities).prettyJSON)") }
                            if let confidence = answer.confidence { Text("Confidence: \(confidence.formatted())") }
                            if let activityProbability = answer.activityProbability { Text("Activity probability: \(activityProbability.formatted())") }
                        }
                        .font(WorkbenchTypography.secondary)
                        .textSelection(.enabled)
                        .padding(WorkbenchSpacing.sm)
                        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
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
