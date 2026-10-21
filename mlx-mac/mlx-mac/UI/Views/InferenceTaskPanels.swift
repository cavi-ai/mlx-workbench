import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct InferenceTaskPanel: View {
    @ObservedObject var coordinator: InferenceTaskCoordinator
    let model: LibraryModel
    var onEngineSetup: (() -> Void)? = nil
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var understandingMode: UnderstandingMode = .image
    @State private var videoPreviewLoadRevision = UUID()

    private enum UnderstandingMode: String, CaseIterable, Identifiable {
        case image = "Image"
        case video = "Video"
        var id: String { rawValue }
    }

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                if model.item.task?.type == .classification {
                    classifier
                } else if model.item.task?.type == .musicGeneration {
                    music
                } else if model.item.task?.type == .speechToText {
                    transcribe
                } else if model.item.task?.type == .textToSpeech {
                    speak
                } else if model.item.task?.type == .imageGeneration {
                    imageGeneration
                } else if model.item.task?.type == .visionLanguage {
                    understanding
                } else if model.item.task?.type == .videoGeneration {
                    videoGeneration
                }
                RecentTaskList(coordinator: coordinator, filterModel: model, reuseModel: model,
                               videoPreviewReloadRevision: videoPreviewLoadRevision,
                               videoPreviewEnabled: understandingMode == .video)
            }
        }
        .task { if isRouteActive { await coordinator.refreshRecent() } }
        .onAppear { synchronizeUnderstandingMode(coordinator.selectedTask?.kind) }
        .onChange(of: coordinator.selectedTask?.kind) { _, kind in synchronizeUnderstandingMode(kind) }
        .onChange(of: coordinator.reuseRevision) { _, _ in synchronizeUnderstandingMode(coordinator.lastReusedTaskKind) }
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

    private func synchronizeUnderstandingMode(_ kind: TaskKind?) {
        switch kind {
        case .imageUnderstanding: understandingMode = .image
        case .videoUnderstanding: understandingMode = .video
        default: break
        }
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
                .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
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

    private var transcribe: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Transcribe audio")
            HStack {
                TextField("Choose an audio file", text: $coordinator.transcribeDraft.audioPath)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("task-transcribe-audio-path")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.wav, .mp3] + [UTType(filenameExtension: "flac")].compactMap { $0 }
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url { coordinator.transcribeDraft.audioPath = url.path }
                    }
                }
                .accessibilityIdentifier("task-transcribe-choose-audio")
            }
            TextField("Language code (optional)", text: $coordinator.transcribeDraft.language)
                .accessibilityIdentifier("task-transcribe-language")
            Text("The engine keeps a verified copy of the selected audio with the task.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            // An untouched form only disables Start; the message appears once a path is entered.
            if !coordinator.transcribeDraft.audioPath.isEmpty, let error = coordinator.transcribeDraft.validationError {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            taskActions(kind: .transcribe)
        }
    }

    private var speak: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Speak text")
            TextEditor(text: $coordinator.speakDraft.text)
                .frame(minHeight: 72, maxHeight: 160)
                .accessibilityIdentifier("task-speak-text")
            HStack {
                TextField("Voice (optional)", text: $coordinator.speakDraft.voice)
                TextField("Speed (optional)", text: $coordinator.speakDraft.speed)
                TextField("Language code (optional)", text: $coordinator.speakDraft.languageCode)
            }
            if coordinator.speakDraft.hasInput, let error = coordinator.speakDraft.validationError {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            taskActions(kind: .speak)
        }
    }

    private var imageGeneration: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Generate image")
            TextField("Describe the image", text: $coordinator.imageGenerationDraft.prompt, axis: .vertical)
                .lineLimit(2...5).accessibilityIdentifier("task-image-generation-prompt")
            Text(coordinator.imageGenerationDraft.settingsSummary)
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .accessibilityIdentifier("task-image-generation-settings")
            DisclosureGroup("Advanced options") {
                Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.sm, verticalSpacing: WorkbenchSpacing.xs) {
                    GridRow {
                        Text("Width")
                        TextField("1024", text: $coordinator.imageGenerationDraft.width)
                            .accessibilityIdentifier("task-image-generation-width")
                    }
                    GridRow {
                        Text("Height")
                        TextField("1024", text: $coordinator.imageGenerationDraft.height)
                            .accessibilityIdentifier("task-image-generation-height")
                    }
                    GridRow {
                        Text("Steps")
                        TextField("40", text: $coordinator.imageGenerationDraft.steps)
                            .accessibilityIdentifier("task-image-generation-steps")
                    }
                    GridRow {
                        Text("Seed")
                        TextField("42", text: $coordinator.imageGenerationDraft.seed)
                            .accessibilityIdentifier("task-image-generation-seed")
                    }
                }.font(WorkbenchTypography.secondary).padding(.top, WorkbenchSpacing.xs)
            }
            if !coordinator.imageGenerationDraft.prompt.isEmpty, let validationError = coordinator.imageGenerationDraft.validationError {
                Text(validationError).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            taskActions(kind: .imageGeneration)
        }
    }

    private var imageUnderstanding: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Understand image")
            HStack {
                TextField("Choose an image file", text: $coordinator.imageUnderstandingDraft.imagePath)
                    .textSelection(.enabled).accessibilityIdentifier("task-image-understanding-path")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg] + [UTType(filenameExtension: "webp")].compactMap { $0 }
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url { coordinator.imageUnderstandingDraft.imagePath = url.path }
                    }
                }
                .accessibilityIdentifier("task-image-understanding-choose")
            }
            TextField("Ask a question about the image", text: $coordinator.imageUnderstandingDraft.prompt, axis: .vertical)
                .lineLimit(2...4).accessibilityIdentifier("task-image-understanding-prompt")
            DisclosureGroup("Advanced options") {
                HStack {
                    TextField("Max tokens · planner default", text: $coordinator.imageUnderstandingDraft.maxTokens)
                    TextField("Temperature · planner default", text: $coordinator.imageUnderstandingDraft.temperature)
                    TextField("Max pixels · planner default", text: $coordinator.imageUnderstandingDraft.maxPixels)
                }
            }
            if let validationError = coordinator.imageUnderstandingDraft.validationError {
                Text(validationError).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            Text("The engine keeps a verified copy of the selected image with the task.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            taskActions(kind: .imageUnderstanding)
        }
    }

    private var understanding: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Picker("Understand", selection: $understandingMode) {
                ForEach(UnderstandingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("task-understanding-mode")
            .onChange(of: understandingMode) { _, mode in
                coordinator.stopPlayback()
                if mode == .video { videoPreviewLoadRevision = UUID() }
            }
            if understandingMode == .image { imageUnderstanding }
            else { videoUnderstanding }
        }
    }

    private var videoUnderstanding: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Understand video")
            HStack {
                TextField("Choose a video file", text: $coordinator.videoUnderstandingDraft.videoPath)
                    .textSelection(.enabled).accessibilityIdentifier("task-video-understanding-path")
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.mpeg4Movie, .movie]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url { coordinator.videoUnderstandingDraft.videoPath = url.path }
                    }
                }
                .accessibilityIdentifier("task-video-understanding-choose")
            }
            TextField("Ask a question about the video", text: $coordinator.videoUnderstandingDraft.prompt, axis: .vertical)
                .lineLimit(2...4).accessibilityIdentifier("task-video-understanding-prompt")
            DisclosureGroup("Advanced options") {
                HStack {
                    TextField("FPS · planner default", text: $coordinator.videoUnderstandingDraft.fps)
                        .accessibilityIdentifier("task-video-understanding-fps")
                    TextField("Temperature · planner default", text: $coordinator.videoUnderstandingDraft.temperature)
                        .accessibilityIdentifier("task-video-understanding-temperature")
                    TextField("Max tokens · planner default", text: $coordinator.videoUnderstandingDraft.maxTokens)
                        .accessibilityIdentifier("task-video-understanding-max-tokens")
                    TextField("Max pixels · planner default", text: $coordinator.videoUnderstandingDraft.maxPixels)
                        .accessibilityIdentifier("task-video-understanding-max-pixels")
                }
            }
            if let error = coordinator.videoUnderstandingDraft.validationError {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            Text("The engine keeps a verified copy of the selected video with the task.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            taskActions(kind: .videoUnderstanding)
        }
    }

    private var videoGeneration: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "Generate video")
            TextField("Describe the video", text: $coordinator.videoGenerationDraft.prompt, axis: .vertical)
                .lineLimit(2...5).accessibilityIdentifier("task-video-generation-prompt")
            DisclosureGroup("Video settings") {
                HStack(spacing: WorkbenchSpacing.sm) {
                    TextField("Width · planner default", text: $coordinator.videoGenerationDraft.width)
                        .accessibilityIdentifier("task-video-generation-width")
                    TextField("Height · planner default", text: $coordinator.videoGenerationDraft.height)
                        .accessibilityIdentifier("task-video-generation-height")
                    TextField("Frames · planner default", text: $coordinator.videoGenerationDraft.frames)
                        .accessibilityIdentifier("task-video-generation-frames")
                }
                HStack(spacing: WorkbenchSpacing.sm) {
                    TextField("FPS · planner default", text: $coordinator.videoGenerationDraft.fps)
                        .accessibilityIdentifier("task-video-generation-fps")
                    TextField("Steps · planner default", text: $coordinator.videoGenerationDraft.steps)
                        .accessibilityIdentifier("task-video-generation-steps")
                    TextField("Seed · planner default", text: $coordinator.videoGenerationDraft.seed)
                        .accessibilityIdentifier("task-video-generation-seed")
                }
            }
            if let error = coordinator.videoGenerationDraft.validationError {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            taskActions(kind: .videoGeneration)
        }
    }

    private func taskActions(kind: TaskKind) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let error = coordinator.error { InlineMessage(kind: .warning, text: error) }
            if coordinator.needsEngineSetup, let onEngineSetup {
                Button("Open Health…", action: onEngineSetup)
                    .accessibilityIdentifier("task-engine-setup")
            }
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
    var filterModel: LibraryModel?
    var reuseModel: LibraryModel?
    var videoPreviewReloadRevision: UUID?
    var videoPreviewEnabled: Bool
    @ObservedObject private var audio: AudioClipPlayer
    @State private var exportError: String?
    @State private var resultJSONExpanded = false

    private var visibleTasks: [TaskRecord] {
        Self.visibleTasks(in: coordinator.recent, for: filterModel)
    }

    private var visibleSelectedTask: TaskRecord? {
        Self.visibleSelectedTask(coordinator.selectedTask, in: visibleTasks)
    }

    init(coordinator: InferenceTaskCoordinator, filterModel: LibraryModel? = nil, reuseModel: LibraryModel? = nil,
         videoPreviewReloadRevision: UUID? = nil, videoPreviewEnabled: Bool = true) {
        self.coordinator = coordinator
        self.filterModel = filterModel
        self.reuseModel = reuseModel
        self.videoPreviewReloadRevision = videoPreviewReloadRevision
        self.videoPreviewEnabled = videoPreviewEnabled
        _audio = ObservedObject(wrappedValue: coordinator.audio)
    }

    static func visibleTasks(in tasks: [TaskRecord], for model: LibraryModel?) -> [TaskRecord] {
        guard let model else { return tasks }
        return tasks.filter { $0.modelPath == model.item.path }
    }

    static func visibleSelectedTask(_ task: TaskRecord?, in visibleTasks: [TaskRecord]) -> TaskRecord? {
        guard let task, visibleTasks.contains(where: { $0.id == task.id }) else { return nil }
        return task
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
                        if let known = visibleSelectedTask {
                            Text("Showing last known status: \(known.state.wireValue.capitalized).")
                                .font(WorkbenchTypography.secondary)
                        }
                    }
                    Spacer()
                    Button("Retry") {
                        if let selected = visibleSelectedTask {
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
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            Text("\(task.kind.title) · \(task.state.wireValue.capitalized)")
                            Text(URL(fileURLWithPath: task.modelPath).lastPathComponent).font(WorkbenchTypography.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("task-history-row-\(task.id)")
                    if task.kind.modelTaskType != nil {
                        let reason = reuseUnavailableReason(task)
                        Button("Reuse") { if let reuseModel, reason == nil { Task { await coordinator.reuse(id: task.id, for: reuseModel) } } }
                            .disabled(reason != nil)
                            .help(reason ?? "Fill the task form from this recorded request")
                            .accessibilityHint(reason ?? "Fills the task form without starting a new task")
                            .accessibilityIdentifier("task-reuse")
                    }
                }
            }
            if let error = exportError { Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure) }
            if let task = visibleSelectedTask {
                Divider()
                Text("\(task.kind.title) · \(task.state.wireValue.capitalized)").font(WorkbenchTypography.value)
                    .accessibilityIdentifier("task-status")
                Text("Task ID: \(task.id)").font(WorkbenchTypography.secondary).textSelection(.enabled)
                Text("Recorded model: \(task.modelPath)").font(WorkbenchTypography.secondary).textSelection(.enabled)
                Text("Engine \(task.identity.engineVersion ?? "unknown") · \(task.identity.backend ?? "backend unknown") \(task.identity.backendVersion ?? "") · Python \(task.identity.pythonVersion ?? "unknown")")
                    .font(WorkbenchTypography.secondary).textSelection(.enabled)
                if let taskError = task.error { InlineMessage(kind: .warning, text: "\(taskError.message) · \(taskError.remediation)") }
                if task.kind == .classification,
                   let raw = coordinator.verifiedResult?.json {
                    ClassificationTaskAnswerSummary(projection: TaskResultProjection(raw: raw))
                }
                if task.kind == .transcribe {
                    if let input = coordinator.verifiedInput {
                        Text("Verified input audio · \(input.reference.bytes) bytes · \(input.reference.sha256)")
                            .font(WorkbenchTypography.secondary).textSelection(.enabled)
                    }
                    if let transcript = coordinator.verifiedResult?.json?.objectValue?["text"]?.stringValue {
                        SectionTitle(text: "Transcript")
                        Text(transcript).font(WorkbenchTypography.value).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("task-transcript")
                    }
                }
                if task.kind == .imageUnderstanding {
                    if let input = coordinator.verifiedInput {
                        Text("Verified input image · \(input.reference.bytes) bytes · \(input.reference.sha256)")
                            .font(WorkbenchTypography.secondary).textSelection(.enabled)
                        TaskImagePreview(artifact: input, label: "Verified input image")
                            .accessibilityIdentifier("task-image-input")
                    }
                    if let answer = coordinator.verifiedResult?.json?.objectValue?["text"]?.stringValue {
                        SectionTitle(text: "Image response")
                        Text(answer).font(WorkbenchTypography.value).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("task-image-understanding-result")
                    }
                }
                if task.kind == .imageGeneration, let output = coordinator.verifiedOutput {
                    SectionTitle(text: "Generated image")
                    TaskImagePreview(artifact: output, label: "Generated image")
                        .accessibilityIdentifier("task-image-output")
                    Text("Verified PNG · \(output.reference.bytes) bytes · \(output.reference.sha256)")
                        .font(WorkbenchTypography.secondary).textSelection(.enabled)
                    Button("Export PNG…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "task-\(task.id)-output.png"
                        panel.allowedContentTypes = [.png]
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            Task {
                                do { try await coordinator.exportImage(id: task.id, to: url); exportError = nil }
                                catch { exportError = AppHost.render(error) }
                            }
                        }
                    }
                    .accessibilityIdentifier("task-export-image")
                }
                if task.kind == .videoUnderstanding {
                    if let input = coordinator.verifiedInput {
                        TaskVideoPreview(artifact: input, player: coordinator.video,
                                         reloadRevision: videoPreviewReloadRevision, isEnabled: videoPreviewEnabled)
                            .accessibilityIdentifier("task-video-input")
                    }
                    if let answer = coordinator.verifiedResult?.json?.objectValue?["text"]?.stringValue {
                        SectionTitle(text: "Video response")
                        Text(answer).font(WorkbenchTypography.value).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("task-video-understanding-result")
                    }
                }
                if task.kind == .videoGeneration, let output = coordinator.verifiedOutput {
                    SectionTitle(text: "Generated video")
                    TaskVideoPreview(artifact: output, player: coordinator.video)
                        .accessibilityIdentifier("task-video-output")
                    Button("Export MP4…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "task-\(task.id)-output.mp4"
                        panel.allowedContentTypes = [.mpeg4Movie]
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            Task {
                                do { try await coordinator.exportVideo(id: task.id, to: url); exportError = nil }
                                catch { exportError = AppHost.render(error) }
                            }
                        }
                    }
                    .accessibilityIdentifier("task-export-video")
                }
                if let output = coordinator.verifiedOutput, task.kind == .speak || task.kind == .musicGeneration {
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
                DisclosureGroup("Result JSON", isExpanded: $resultJSONExpanded) {
                    if let raw = coordinator.verifiedResult?.json {
                        Text(raw.prettyJSON).font(WorkbenchTypography.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if coordinator.selectedResult != nil {
                        Text("The verified result is too large for inline preview to render.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
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
                .font(WorkbenchTypography.value)
            }
        }
        .onChange(of: coordinator.selectedTask?.id) { _, _ in
            audio.stop()
            coordinator.video.stop()
            resultJSONExpanded = false
        }
        .onDisappear { audio.stop(); coordinator.video.stop() }
    }

    private func reuseUnavailableReason(_ task: TaskRecord) -> String? {
        guard let model = reuseModel else { return "Select the matching Ready model in Library to reuse this request." }
        guard model.readiness == .ready else { return "Reuse requires a Ready model." }
        guard model.item.path == task.modelPath else { return "Select the model recorded for this task." }
        guard model.item.task?.type == task.kind.modelTaskType else { return "The selected model does not support this task type." }
        return nil
    }
}

private struct TaskVideoPreview: View {
    let artifact: VerifiedTaskArtifact
    @ObservedObject var player: VideoComparisonPlayer
    var reloadRevision: UUID? = nil
    var isEnabled = true
    @Environment(\.isRouteActive) private var isRouteActive

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let avPlayer = player.players.first {
                SharedVideoPane(player: avPlayer)
                    .frame(minHeight: 180, idealHeight: 280, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
                    .accessibilityLabel("Verified task video")
            } else if player.isLoading {
                ProgressView("Loading video…").frame(maxWidth: .infinity, minHeight: 160)
            } else if let failure = player.failure {
                InlineMessage(kind: .warning, text: failure)
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                Button(player.isPlaying ? "Pause" : "Play") { Task { await player.toggle() } }
                    .disabled(player.players.isEmpty || player.isLoading || player.failure != nil)
                    .accessibilityIdentifier(player.isPlaying ? "task-video-pause" : "task-video-play")
                Slider(value: Binding(get: { player.position }, set: { value in Task { await player.seek(to: value) } }),
                       in: 0...max(player.duration, 0.001))
                    .disabled(player.players.isEmpty || player.isLoading)
                    .accessibilityLabel("Task video position")
                Text(String(format: "%.1f / %.1f s", player.position, player.duration))
                    .font(WorkbenchTypography.secondaryTabular)
            }
            Text("Verified MP4 · \(artifact.reference.bytes) bytes · \(artifact.reference.sha256)")
                .font(WorkbenchTypography.secondary).textSelection(.enabled)
        }
        .task(id: "\(artifact.url.absoluteString):\(reloadRevision?.uuidString ?? ""):\(isEnabled)") {
            guard isEnabled else { return }
            await player.load([artifact.url], preservingPosition: false)
        }
        .onChange(of: isRouteActive) { _, active in if !active { player.stop() } }
        .onDisappear { player.stop() }
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
                        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                    }
                }
            }
        }
    }
}

private struct TaskImagePreview: View {
    let artifact: VerifiedTaskArtifact
    let label: String
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var viewport = ImageInspectionViewport()
    @State private var dragOrigin: ImageInspectionViewport?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSpacing.xs) {
                Button { viewport.setZoom(viewport.zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(viewport.zoom == 1).accessibilityLabel("Zoom out")
                Slider(value: Binding(get: { viewport.zoom }, set: { viewport.setZoom($0) }), in: 1...8)
                    .frame(maxWidth: 200).accessibilityLabel("Image zoom")
                Button { viewport.setZoom(viewport.zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(viewport.zoom == 8).accessibilityLabel("Zoom in")
                Text(String(format: "%.0f%%", viewport.zoom * 100)).font(WorkbenchTypography.secondaryTabular)
                Button("Reset") { viewport.reset() }
                Spacer()
                Text("Drag or use arrow keys to pan").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            .controlSize(.small)
            GeometryReader { geometry in
                ZStack {
                    WorkbenchColor.surface
                    if let image {
                        let fit = viewport.fittedSize(image: image.size, canvas: geometry.size)
                        let offset = viewport.offset(image: image.size, canvas: geometry.size)
                        Image(nsImage: image).resizable()
                            .frame(width: fit.width * viewport.zoom, height: fit.height * viewport.zoom)
                            .offset(offset)
                    } else if loaded {
                        Text("Image unavailable").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    } else { ProgressView() }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped().contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    guard let image else { return }
                    if dragOrigin == nil { dragOrigin = viewport }
                    var next = dragOrigin ?? viewport
                    next.pan(by: value.translation, image: image.size, canvas: geometry.size)
                    viewport = next
                }.onEnded { _ in dragOrigin = nil })
                .focusable()
                .onMoveCommand { direction in
                    guard let image else { return }
                    let step: CGFloat = 40
                    let translation: CGSize
                    switch direction {
                    case .left: translation = CGSize(width: step, height: 0)
                    case .right: translation = CGSize(width: -step, height: 0)
                    case .up: translation = CGSize(width: 0, height: step)
                    case .down: translation = CGSize(width: 0, height: -step)
                    @unknown default: return
                    }
                    viewport.pan(by: translation, image: image.size, canvas: geometry.size)
                }
                .accessibilityLabel(label)
                .accessibilityValue(String(format: "%.0f percent zoom", viewport.zoom * 100))
            }
            .frame(minHeight: 180, idealHeight: 320, maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        }
        .task(id: artifact.url) {
            image = nil
            loaded = false
            viewport.reset()
            image = await MediaImageLoader.load(artifact.url)
            loaded = true
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
        case .transcribe: "Transcription"
        case .speak: "Speech"
        case .imageGeneration: "Image generation"
        case .imageUnderstanding: "Image understanding"
        case .videoUnderstanding: "Video understanding"
        case .videoGeneration: "Video generation"
        case .unsupported(let name): name
        }
    }
}
