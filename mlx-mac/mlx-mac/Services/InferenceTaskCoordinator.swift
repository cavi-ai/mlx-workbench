import Foundation

protocol InferenceTaskAPI: Sendable {
    func taskCapabilities() async throws -> TaskCapabilities
    func taskStart(_ request: TaskRequest) async throws -> TaskRecord
    func taskStatus(id: String) async throws -> TaskRecord
    func taskList(limit: Int) async throws -> TaskPage
    func taskResult(id: String) async throws -> TaskResultResponse
    func taskCancel(id: String) async throws -> TaskRecord
    func taskVerifyModel(id: String) async throws -> TaskModelVerification
}

enum ClassificationQuestionType: String, CaseIterable, Identifiable, Sendable {
    case choice, score, noul
    var id: String { rawValue }
    var title: String { rawValue == "noul" ? "True or false" : rawValue.capitalized }
}

struct ClassificationQuestionDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "Question"
    var instructions = ""
    var type: ClassificationQuestionType = .choice
    var options = ["billing", "other"]
    var falseDescription = ""
    var trueDescription = ""

    var error: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Add a name and instructions." }
        switch type {
        case .choice:
            guard options.count >= 2, options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(options).count == options.count else { return "Choice questions need at least two distinct option labels." }
        case .score:
            guard options.count >= 2, options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return "Score questions need at least two level descriptions." }
        case .noul: break
        }
        return nil
    }

    var value: JSONValue {
        var fields: [String: JSONValue] = ["type": .string(type.rawValue), "instructions": .string(instructions)]
        switch type {
        case .choice: fields["criteria"] = .array(options.map(JSONValue.string))
        case .score: fields["criteria"] = .array(options.map(JSONValue.string))
        case .noul:
            let descriptions = ["false": falseDescription, "true": trueDescription].filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !descriptions.isEmpty { fields["criteria"] = .object(descriptions.mapValues(JSONValue.string)) }
        }
        return .object(fields)
    }
}

struct ClassificationDraft: Equatable, Sendable {
    var state = ""
    var questions = [ClassificationQuestionDraft()]

    var validationError: String? {
        guard !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Describe the state or support request to classify." }
        guard !questions.isEmpty else { return "Add at least one question." }
        guard Set(questions.map(\.name)).count == questions.count else { return "Question names must be unique." }
        return questions.first(where: { $0.error != nil })?.error
    }

    func request(modelPath: String) throws -> TaskRequest {
        guard validationError == nil else { throw TaskProtocolError.invalidRequest }
        let definitions = Dictionary(uniqueKeysWithValues: questions.map { ($0.name, $0.value) })
        let request = TaskRequest(kind: .classification, modelPath: modelPath,
                                  parameters: ["state": .string(state), "questions": .object(definitions)])
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest) throws {
        guard request.kind == .classification,
              let state = request.parameters["state"]?.stringValue,
              let questions = request.parameters["questions"]?.objectValue else { throw TaskProtocolError.invalidRequest }
        var drafts: [ClassificationQuestionDraft] = []
        for (name, raw) in questions.sorted(by: { $0.key < $1.key }) {
            guard let fields = raw.objectValue,
                  Set(fields.keys).isSubset(of: ["type", "instructions", "criteria"]),
                  let typeRaw = fields["type"]?.stringValue,
                  let type = ClassificationQuestionType(rawValue: typeRaw),
                  let instructions = fields["instructions"]?.stringValue else { throw TaskProtocolError.invalidRequest }
            var draft = ClassificationQuestionDraft(name: name, instructions: instructions, type: type)
            switch type {
            case .choice, .score:
                guard let labels = fields["criteria"]?.arrayValue?.compactMap(\.stringValue), labels.count == fields["criteria"]?.arrayValue?.count else { throw TaskProtocolError.invalidRequest }
                draft.options = labels
            case .noul:
                let criteria = fields["criteria"]?.objectValue ?? [:]
                if let value = criteria["false"]?.stringValue { draft.falseDescription = value }
                if let value = criteria["true"]?.stringValue { draft.trueDescription = value }
                guard criteria.keys.allSatisfy({ ["false", "true"].contains($0) }), criteria.values.allSatisfy({ $0.stringValue != nil }) else { throw TaskProtocolError.invalidRequest }
            }
            guard draft.error == nil else { throw TaskProtocolError.invalidRequest }
            drafts.append(draft)
        }
        guard !drafts.isEmpty else { throw TaskProtocolError.invalidRequest }
        self.state = state
        self.questions = drafts
    }
}

struct MusicTaskDraft: Equatable, Sendable {
    var caption = ""
    var lyrics = ""
    var duration = 15.0
    var steps = 30
    var seed = 42

    var validationError: String? {
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Describe the music to generate." }
        return InferenceSettings.problem {
            try InferenceSettings.Music.caption.check(caption)
            if !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try InferenceSettings.Music.lyrics.check(lyrics) }
            try InferenceSettings.Music.duration.check(duration)
            try InferenceSettings.Music.steps.check(steps)
            try InferenceSettings.seed.check(seed)
        }
    }

    func request(modelPath: String) throws -> TaskRequest {
        var parameters: [String: JSONValue] = ["caption": .string(caption), "duration": .number(duration), "steps": .number(Double(steps)), "seed": .number(Double(seed))]
        if !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parameters["lyrics"] = .string(lyrics) }
        let request = TaskRequest(kind: .musicGeneration, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest) throws {
        guard request.kind == .musicGeneration,
              let caption = request.parameters["caption"]?.stringValue else { throw TaskProtocolError.invalidRequest }
        var draft = MusicTaskDraft()
        draft.caption = caption
        draft.lyrics = request.parameters["lyrics"]?.stringValue ?? ""
        draft.duration = request.parameters["duration"]?.numberValue ?? 15
        draft.steps = request.parameters["steps"]?.integerValue ?? 30
        draft.seed = request.parameters["seed"]?.integerValue ?? 42
        try request.validate()
        guard draft.validationError == nil else { throw TaskProtocolError.invalidRequest }
        self = draft
    }
}

struct TranscribeTaskDraft: Equatable, Sendable {
    var audioPath = ""
    var language = ""

    var validationError: String? {
        guard audioPath.hasPrefix("/"), !audioPath.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return "Choose a readable local audio file."
        }
        return nil
    }

    func request(modelPath: String) throws -> TaskRequest {
        guard validationError == nil else { throw TaskProtocolError.invalidRequest }
        var parameters: [String: JSONValue] = ["audio_path": .string(audioPath)]
        if !language.isEmpty { parameters["language"] = .string(language) }
        let request = TaskRequest(kind: .transcribe, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest, retainedAudioPath: String) throws {
        guard request.kind == .transcribe else { throw TaskProtocolError.invalidRequest }
        var parameters = request.parameters
        parameters["audio_path"] = .string(retainedAudioPath)
        let reused = TaskRequest(kind: .transcribe, modelPath: request.modelPath, parameters: parameters)
        try reused.validate()
        audioPath = retainedAudioPath
        language = parameters["language"]?.stringValue ?? ""
    }
}

struct SpeakTaskDraft: Equatable, Sendable {
    var text = ""
    var voice = ""
    var speed = ""
    var languageCode = ""

    var validationError: String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter text to speak." }
        return InferenceSettings.problem {
            try InferenceSettings.Speech.text.check(text)
            _ = try InferenceSettings.Speech.speed.value(speed)
        }
    }
    /// Any field was filled in; an untouched form shows no validation message.
    var hasInput: Bool { !(text.isEmpty && voice.isEmpty && speed.isEmpty && languageCode.isEmpty) }

    func request(modelPath: String) throws -> TaskRequest {
        guard validationError == nil else { throw TaskProtocolError.invalidRequest }
        var parameters: [String: JSONValue] = ["text": .string(text)]
        if !voice.isEmpty { parameters["voice"] = .string(voice) }
        if let value = try InferenceSettings.Speech.speed.value(speed) { parameters["speed"] = .number(value) }
        if !languageCode.isEmpty { parameters["lang_code"] = .string(languageCode) }
        let request = TaskRequest(kind: .speak, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest) throws {
        guard request.kind == .speak else { throw TaskProtocolError.invalidRequest }
        try request.validate()
        text = request.parameters["text"]?.stringValue ?? ""
        voice = request.parameters["voice"]?.stringValue ?? ""
        speed = request.parameters["speed"]?.numberValue.map { String($0) } ?? ""
        languageCode = request.parameters["lang_code"]?.stringValue ?? ""
    }
}

struct ImageGenerationTaskDraft: Equatable, Sendable {
    var prompt = ""
    var width = String(InferenceSettings.ImageGeneration.defaults.width)
    var height = String(InferenceSettings.ImageGeneration.defaults.height)
    var steps = String(InferenceSettings.ImageGeneration.defaults.steps)
    var seed = String(InferenceSettings.ImageGeneration.defaults.seed)

    var settingsSummary: String {
        let defaults = InferenceSettings.ImageGeneration.defaults
        func display(_ raw: String, fallback: Int) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(fallback) : trimmed
        }
        return "\(display(width, fallback: defaults.width)) × \(display(height, fallback: defaults.height)) · \(display(steps, fallback: defaults.steps)) steps · seed \(display(seed, fallback: defaults.seed))"
    }

    var validationError: String? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Describe the image to generate." }
        return InferenceSettings.problem {
            try InferenceSettings.ImageGeneration.prompt.check(prompt)
            _ = try settings()
        }
    }

    func request(modelPath: String) throws -> TaskRequest {
        guard validationError == nil else { throw TaskProtocolError.invalidRequest }
        var parameters = try settings()
        parameters["prompt"] = .string(prompt)
        let request = TaskRequest(kind: .imageGeneration, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest) throws {
        guard request.kind == .imageGeneration else { throw TaskProtocolError.invalidRequest }
        try request.validate()
        prompt = request.parameters["prompt"]?.stringValue ?? ""
        width = request.parameters["width"]?.integerValue.map(String.init) ?? ""
        height = request.parameters["height"]?.integerValue.map(String.init) ?? ""
        steps = request.parameters["steps"]?.integerValue.map(String.init) ?? ""
        seed = request.parameters["seed"]?.integerValue.map(String.init) ?? ""
    }

    /// Entered settings only; blank fields are left to the engine planner.
    private func settings() throws -> [String: JSONValue] {
        typealias Rules = InferenceSettings.ImageGeneration
        var values: [String: JSONValue] = [:]
        if let value = try Rules.width.value(width) { values["width"] = .number(Double(value)) }
        if let value = try Rules.height.value(height) { values["height"] = .number(Double(value)) }
        if let value = try Rules.steps.value(steps) { values["steps"] = .number(Double(value)) }
        if let value = try InferenceSettings.seed.value(seed) { values["seed"] = .number(Double(value)) }
        return values
    }
}

struct ImageUnderstandingTaskDraft: Equatable, Sendable {
    var imagePath = ""
    var prompt = ""
    var maxTokens = ""
    var temperature = ""
    var maxPixels = ""

    var validationError: String? {
        guard imagePath.hasPrefix("/"), !imagePath.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return "Choose a local image file."
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Ask a question about the image." }
        return InferenceSettings.problem {
            try InferenceSettings.Understanding.prompt.check(prompt)
            _ = try settings()
        }
    }

    func request(modelPath: String) throws -> TaskRequest {
        guard validationError == nil else { throw TaskProtocolError.invalidRequest }
        var parameters = try settings()
        parameters["image_path"] = .string(imagePath)
        parameters["prompt"] = .string(prompt)
        let request = TaskRequest(kind: .imageUnderstanding, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest, retainedImagePath: String) throws {
        guard request.kind == .imageUnderstanding else { throw TaskProtocolError.invalidRequest }
        var parameters = request.parameters
        parameters["image_path"] = .string(retainedImagePath)
        let reused = TaskRequest(kind: .imageUnderstanding, modelPath: request.modelPath, parameters: parameters)
        try reused.validate()
        imagePath = retainedImagePath
        prompt = request.parameters["prompt"]?.stringValue ?? ""
        maxTokens = request.parameters["max_tokens"]?.integerValue.map(String.init) ?? ""
        temperature = request.parameters["temperature"]?.numberValue.map { String($0) } ?? ""
        maxPixels = request.parameters["max_pixels"]?.integerValue.map(String.init) ?? ""
    }

    /// Entered settings only; blank fields are left to the engine planner.
    private func settings() throws -> [String: JSONValue] {
        typealias Rules = InferenceSettings.Understanding
        var values: [String: JSONValue] = [:]
        if let value = try Rules.maxTokens.value(maxTokens) { values["max_tokens"] = .number(Double(value)) }
        if let value = try Rules.temperature.value(temperature) { values["temperature"] = .number(value) }
        if let value = try Rules.maxPixels.value(maxPixels) { values["max_pixels"] = .number(Double(value)) }
        return values
    }
}

struct VideoUnderstandingTaskDraft: Equatable, Sendable {
    var videoPath = ""
    var prompt = ""
    var fps = ""
    var temperature = ""
    var maxTokens = ""
    var maxPixels = ""

    var validationError: String? {
        guard videoPath.hasPrefix("/"), !videoPath.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return "Choose a local video file."
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Ask a question about the video." }
        return InferenceSettings.problem {
            try InferenceSettings.Understanding.prompt.check(prompt)
            _ = try settings()
        }
    }

    func request(modelPath: String) throws -> TaskRequest {
        guard validationError == nil else { throw TaskProtocolError.invalidRequest }
        var parameters = try settings()
        parameters["video_path"] = .string(videoPath)
        parameters["prompt"] = .string(prompt)
        let request = TaskRequest(kind: .videoUnderstanding, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest, retainedVideoPath: String) throws {
        guard request.kind == .videoUnderstanding else { throw TaskProtocolError.invalidRequest }
        var parameters = request.parameters
        parameters["video_path"] = .string(retainedVideoPath)
        let reused = TaskRequest(kind: .videoUnderstanding, modelPath: request.modelPath, parameters: parameters)
        try reused.validate()
        videoPath = retainedVideoPath
        prompt = request.parameters["prompt"]?.stringValue ?? ""
        fps = request.parameters["fps"]?.numberValue.map { String($0) } ?? ""
        temperature = request.parameters["temperature"]?.numberValue.map { String($0) } ?? ""
        maxTokens = request.parameters["max_tokens"]?.integerValue.map(String.init) ?? ""
        maxPixels = request.parameters["max_pixels"]?.integerValue.map(String.init) ?? ""
    }

    /// Entered settings only; blank fields are left to the engine planner.
    private func settings() throws -> [String: JSONValue] {
        typealias Rules = InferenceSettings.Understanding
        var values: [String: JSONValue] = [:]
        if let value = try Rules.videoFPS.value(fps) { values["fps"] = .number(value) }
        if let value = try Rules.temperature.value(temperature) { values["temperature"] = .number(value) }
        if let value = try Rules.maxTokens.value(maxTokens) { values["max_tokens"] = .number(Double(value)) }
        if let value = try Rules.maxPixels.value(maxPixels) { values["max_pixels"] = .number(Double(value)) }
        return values
    }
}

struct VideoGenerationTaskDraft: Equatable, Sendable {
    var prompt = ""
    var width = ""
    var height = ""
    var frames = ""
    var fps = ""
    var steps = ""
    var seed = ""

    var validationError: String? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Describe the video to generate." }
        return InferenceSettings.problem {
            try InferenceSettings.VideoGeneration.prompt.check(prompt)
            _ = try settings()
        }
    }

    func request(modelPath: String) throws -> TaskRequest {
        guard validationError == nil else { throw TaskProtocolError.invalidRequest }
        var parameters = try settings()
        parameters["prompt"] = .string(prompt)
        let request = TaskRequest(kind: .videoGeneration, modelPath: modelPath, parameters: parameters)
        try request.validate()
        return request
    }

    mutating func load(_ request: TaskRequest) throws {
        guard request.kind == .videoGeneration else { throw TaskProtocolError.invalidRequest }
        try request.validate()
        prompt = request.parameters["prompt"]?.stringValue ?? ""
        width = request.parameters["width"]?.integerValue.map(String.init) ?? ""
        height = request.parameters["height"]?.integerValue.map(String.init) ?? ""
        frames = request.parameters["frames"]?.integerValue.map(String.init) ?? ""
        fps = request.parameters["fps"]?.integerValue.map(String.init)
            ?? request.parameters["fps"]?.numberValue.map { String($0) } ?? ""
        steps = request.parameters["steps"]?.integerValue.map(String.init) ?? ""
        seed = request.parameters["seed"]?.integerValue.map(String.init) ?? ""
    }

    /// Entered settings only; blank fields are left to the engine planner.
    private func settings() throws -> [String: JSONValue] {
        typealias Rules = InferenceSettings.VideoGeneration
        var values: [String: JSONValue] = [:]
        if let value = try Rules.width.value(width) { values["width"] = .number(Double(value)) }
        if let value = try Rules.height.value(height) { values["height"] = .number(Double(value)) }
        if let value = try Rules.frames.value(frames) { values["frames"] = .number(Double(value)) }
        if let value = try Rules.fps.value(fps) { values["fps"] = .number(Double(value)) }
        if let value = try Rules.steps.value(steps) { values["steps"] = .number(Double(value)) }
        if let value = try InferenceSettings.seed.value(seed) { values["seed"] = .number(Double(value)) }
        return values
    }
}

@MainActor
final class InferenceTaskCoordinator: ObservableObject {
    @Published var classificationDraft = ClassificationDraft()
    @Published var musicDraft = MusicTaskDraft()
    @Published var transcribeDraft = TranscribeTaskDraft()
    @Published var speakDraft = SpeakTaskDraft()
    @Published var imageGenerationDraft = ImageGenerationTaskDraft()
    @Published var imageUnderstandingDraft = ImageUnderstandingTaskDraft()
    @Published var videoUnderstandingDraft = VideoUnderstandingTaskDraft()
    @Published var videoGenerationDraft = VideoGenerationTaskDraft()
    @Published private(set) var recent: [TaskRecord] = []
    @Published private(set) var hasMoreRecent = false
    @Published private(set) var selectedTask: TaskRecord?
    @Published private(set) var selectedResult: TaskResultResponse?
    @Published private(set) var verifiedResult: VerifiedTaskArtifact?
    @Published private(set) var verifiedOutput: VerifiedTaskArtifact?
    @Published private(set) var verifiedInput: VerifiedTaskArtifact?
    @Published private(set) var busy = false
    @Published private(set) var startOutcomeUnknown = false
    @Published private(set) var error: String?
    @Published private(set) var needsEngineSetup = false
    @Published private(set) var readError: String?
    @Published private(set) var cancellationPending = false
    @Published private(set) var lastReusedTaskKind: TaskKind?
    @Published private(set) var reuseRevision = UUID()
    let audio = AudioClipPlayer()
    let video = VideoComparisonPlayer()

    private let api: any InferenceTaskAPI
    private let artifactRoot: URL
    private let fileManager: FileManager
    private let pollInterval: Duration
    private var pollingTask: Task<Void, Never>?
    private var pollingOwners: Set<String> = []
    private var pollingTaskID: String?

    init(api: any InferenceTaskAPI, artifactRoot: URL, fileManager: FileManager = .default,
         pollInterval: Duration = .seconds(2)) {
        self.api = api
        self.artifactRoot = artifactRoot
        self.fileManager = fileManager
        self.pollInterval = pollInterval
    }

    deinit { pollingTask?.cancel() }

    var canStart: Bool { !busy && !startOutcomeUnknown }
    var activeModelPaths: Set<String> {
        Set(recent.filter { $0.state.isActive }.map(\.modelPath))
            .union(selectedTask.flatMap { $0.state.isActive ? [$0.modelPath] : nil } ?? [])
    }

    func refreshRecent() async {
        do {
            let page = try await api.taskList(limit: 100)
            recent = page.tasks
            hasMoreRecent = page.hasMore
            readError = nil
            if startOutcomeUnknown { startOutcomeUnknown = false; error = nil }
        } catch { readError = AppHost.render(error) }
    }

    func selectTask(id: String) async {
        guard let record = recent.first(where: { $0.id == id }) else { return }
        stopPlayback()
        selectedTask = record
        selectedResult = nil
        verifiedResult = nil
        verifiedOutput = nil
        verifiedInput = nil
        if record.state.isActive { await refresh(id: id) }
        else { await inspect(id: id) }
    }

    func start(kind: TaskKind, model: LibraryModel) async {
        guard canStart else { return }
        needsEngineSetup = false
        guard model.readiness == .ready, kind.modelTaskType != nil, model.item.task?.type == kind.modelTaskType else {
            error = "Choose a Ready model with the matching task type."
            return
        }
        let request: TaskRequest
        do {
            switch kind {
            case .classification: request = try classificationDraft.request(modelPath: model.item.path)
            case .musicGeneration: request = try musicDraft.request(modelPath: model.item.path)
            case .transcribe: request = try transcribeDraft.request(modelPath: model.item.path)
            case .speak: request = try speakDraft.request(modelPath: model.item.path)
            case .imageGeneration: request = try imageGenerationDraft.request(modelPath: model.item.path)
            case .imageUnderstanding: request = try imageUnderstandingDraft.request(modelPath: model.item.path)
            case .videoUnderstanding: request = try videoUnderstandingDraft.request(modelPath: model.item.path)
            case .videoGeneration: request = try videoGenerationDraft.request(modelPath: model.item.path)
            case .unsupported: throw TaskProtocolError.invalidRequest
            }
        }
        catch { self.error = AppHost.render(error); return }
        stopPlayback()
        busy = true
        cancellationPending = false
        error = nil
        startOutcomeUnknown = false
        defer { busy = false }
        do {
            let capabilities = try await api.taskCapabilities()
            guard capabilities.isSupported,
                  capabilities.tasks.contains(where: { $0.kind == kind && $0.requiresLocalModel }),
                  capabilities.requestSchema(for: kind) == request.schema,
                  capabilities.runSchema(for: kind) == ([.transcribe, .speak, .imageGeneration, .imageUnderstanding, .videoUnderstanding, .videoGeneration].contains(kind) ? "task-run/2" : "task-run/1") else {
                cancellationPending = false
                needsEngineSetup = true
                error = "The selected engine does not support this task. Open Health and run the setup assistant to select a compatible engine, then try again. Your inputs are retained."
                return
            }
            let record = try await api.taskStart(request)
            guard let taskUUID = UUID(uuidString: record.id), taskUUID.uuidString.lowercased() == record.id else {
                startOutcomeUnknown = true
                cancellationPending = false
                error = "Start outcome unknown. The engine response did not contain a usable task ID; refresh Recent tasks before starting again."
                return
            }
            selectedTask = record
            recent.removeAll { $0.id == record.id }
            recent.insert(record, at: 0)
            guard record.isSupported, record.kind == kind, record.modelPath == model.item.path else {
                if cancellationPending && record.state.isActive { await cancel(id: record.id) }
                else { cancellationPending = false }
                error = "The engine returned a task whose type or model does not match this request. Its recorded ID is available for inspection."
                return
            }
            if cancellationPending { await cancel(id: record.id) }
            else if !record.state.isActive { await inspect(id: record.id) }
        } catch is TaskStartOutcomeUnknown {
            startOutcomeUnknown = true
            cancellationPending = false
            error = "Start outcome unknown. Refresh Recent tasks before starting again."
        } catch let engine as TaskEngineError {
            if let known = engine.task {
                selectedTask = known
                recent.removeAll { $0.id == known.id }
                recent.insert(known, at: 0)
                if cancellationPending && known.state.isActive { await cancel(id: known.id) }
                else { cancellationPending = false }
            } else { cancellationPending = false }
            error = engine.localizedDescription
        } catch {
            cancellationPending = false
            self.error = AppHost.render(error)
        }
    }

    func requestCancelDuringStart() { if busy { cancellationPending = true } }

    func cancel(id: String) async {
        guard !id.isEmpty else { return }
        cancellationPending = false
        do {
            selectedTask = try await api.taskCancel(id: id)
            replaceSelectedInRecent()
            if selectedTask?.state.isActive != true { stopPolling() }
            error = nil
        }
        catch { self.error = "Cancel requested; current engine status could not be read: \(AppHost.render(error))" }
    }

    func refresh(id: String) async {
        do {
            selectedTask = try await api.taskStatus(id: id)
            replaceSelectedInRecent()
            readError = nil
            startOutcomeUnknown = false
            if let selectedTask, !selectedTask.state.isActive { stopPolling(); await inspect(id: id) }
        } catch { readError = AppHost.render(error) }
    }

    func inspect(id: String) async {
        do {
            let response = try await api.taskResult(id: id)
            let json = try await TaskArtifactVerifier.verify(reference: response.artifact, taskID: id, root: artifactRoot)
            let payload = try verifiedResultPayload(response, artifact: json)
            var output: VerifiedTaskArtifact?
            var input: VerifiedTaskArtifact?
            if response.task.kind == .speak || response.task.kind == .musicGeneration,
               let raw = payload?.objectValue?["output_artifact"],
               let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) {
                if URL(fileURLWithPath: reference.path).lastPathComponent == "output.wav" {
                    output = try await TaskArtifactVerifier.verify(reference: reference, taskID: id, root: artifactRoot)
                }
            }
            if response.task.kind == .imageGeneration,
               let raw = payload?.objectValue?["output_artifact"],
               let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) {
                guard URL(fileURLWithPath: reference.path).lastPathComponent == "output.png" else {
                    throw TaskArtifactVerificationError.invalidReference
                }
                output = try await TaskArtifactVerifier.verifyPNG(reference: reference, taskID: id, root: artifactRoot)
            }
            if response.task.kind == .videoGeneration,
               let raw = payload?.objectValue?["output_artifact"],
               let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) {
                guard URL(fileURLWithPath: reference.path).lastPathComponent == "output.mp4" else {
                    throw TaskArtifactVerificationError.invalidReference
                }
                output = try await TaskArtifactVerifier.verifyVideo(reference: reference, taskID: id, root: artifactRoot)
            }
            if response.task.kind == .transcribe || response.task.kind == .imageUnderstanding {
                guard let recorded = response.task.inputArtifact,
                      let returned = payload?.objectValue?["input_artifact"],
                      let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(returned)),
                      reference == recorded else { throw TaskArtifactVerificationError.invalidReference }
                input = response.task.kind == .imageUnderstanding
                    ? try await TaskArtifactVerifier.verifyImage(reference: recorded, taskID: id, root: artifactRoot)
                    : try await TaskArtifactVerifier.verify(reference: recorded, taskID: id, root: artifactRoot)
            }
            if response.task.kind == .videoUnderstanding {
                guard let recorded = response.task.inputArtifact,
                      let returned = payload?.objectValue?["input_artifact"],
                      let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(returned)),
                      reference == recorded else { throw TaskArtifactVerificationError.invalidReference }
                input = try await TaskArtifactVerifier.verifyVideo(reference: recorded, taskID: id, root: artifactRoot)
            }
            selectedTask = response.task
            selectedResult = response
            verifiedResult = json
            verifiedOutput = output
            verifiedInput = input
            replaceSelectedInRecent()
            readError = nil
        } catch { readError = AppHost.render(error) }
    }

    func reuse(id: String, for model: LibraryModel) async {
        guard let record = recent.first(where: { $0.id == id }) ?? (selectedTask?.id == id ? selectedTask : nil) else {
            error = "This task is no longer in Recent tasks. Refresh the list and try again."
            return
        }
        guard model.readiness == .ready, model.item.task?.type == record.kind.modelTaskType,
              model.item.path == record.modelPath else {
            error = "Reuse requires a Ready model with the same task type. The saved result remains available."
            return
        }
        do {
            let verification = try await api.taskVerifyModel(id: id)
            guard verification.matches, verification.modelPath == model.item.path else {
                error = "The saved task belongs to a different model identity. The result remains available."
                return
            }
            let artifact = try await TaskArtifactVerifier.verify(reference: record.request, taskID: id, root: artifactRoot)
            guard let request = artifact.request, request.kind == record.kind, request.modelPath == model.item.path else { throw TaskProtocolError.invalidRequest }
            switch request.kind {
            case .classification: try classificationDraft.load(request)
            case .musicGeneration: try musicDraft.load(request)
            case .transcribe:
                guard let input = record.inputArtifact else { throw TaskArtifactVerificationError.unavailable }
                _ = try await TaskArtifactVerifier.verify(reference: input, taskID: id, root: artifactRoot)
                try transcribeDraft.load(request, retainedAudioPath: input.path)
            case .speak: try speakDraft.load(request)
            case .imageGeneration: try imageGenerationDraft.load(request)
            case .imageUnderstanding:
                guard let input = record.inputArtifact else { throw TaskArtifactVerificationError.unavailable }
                _ = try await TaskArtifactVerifier.verifyImage(reference: input, taskID: id, root: artifactRoot)
                try imageUnderstandingDraft.load(request, retainedImagePath: input.path)
            case .videoGeneration: try videoGenerationDraft.load(request)
            case .videoUnderstanding:
                guard let input = record.inputArtifact else { throw TaskArtifactVerificationError.unavailable }
                _ = try await TaskArtifactVerifier.verifyVideo(reference: input, taskID: id, root: artifactRoot)
                try videoUnderstandingDraft.load(request, retainedVideoPath: input.path)
            case .unsupported: throw TaskProtocolError.invalidRequest
            }
            lastReusedTaskKind = request.kind
            reuseRevision = UUID()
            error = nil
        } catch { self.error = "This task request cannot be safely reused: \(AppHost.render(error))" }
    }

    func export(id: String, to destination: URL) async throws {
        let response = try await api.taskResult(id: id)
        let result = try await TaskArtifactVerifier.verify(reference: response.artifact, taskID: id, root: artifactRoot)
        guard let raw = try verifiedResultPayload(response, artifact: result), case .object(let fields) = raw else { throw TaskArtifactVerificationError.invalidJSON }
        let safeFields = fields.filter { key, _ in
            let normalized = key.lowercased()
            return !normalized.contains("path") && !normalized.contains("artifact")
                && !["audio", "model", "request", "input", "prompt", "command", "argv"].contains(normalized)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(JSONValue.object(safeFields))
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    func exportAudio(id: String, to destination: URL) async throws {
        let response = try await api.taskResult(id: id)
        guard response.task.kind == .speak || response.task.kind == .musicGeneration else {
            throw TaskArtifactVerificationError.unavailable
        }
        let result = try await TaskArtifactVerifier.verify(reference: response.artifact, taskID: id, root: artifactRoot)
        guard let raw = try verifiedResultPayload(response, artifact: result)?.objectValue?["output_artifact"],
              let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) else {
            throw TaskArtifactVerificationError.unavailable
        }
        guard URL(fileURLWithPath: reference.path).lastPathComponent == "output.wav" else {
            throw TaskArtifactVerificationError.invalidReference
        }
        let output = try await TaskArtifactVerifier.verify(reference: reference, taskID: id, root: artifactRoot)
        guard output.url.pathExtension.lowercased() == "wav" else { throw TaskArtifactVerificationError.invalidReference }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: output.url, to: destination)
    }

    func exportImage(id: String, to destination: URL) async throws {
        let response = try await api.taskResult(id: id)
        guard response.task.kind == .imageGeneration else { throw TaskArtifactVerificationError.unavailable }
        let result = try await TaskArtifactVerifier.verify(reference: response.artifact, taskID: id, root: artifactRoot)
        guard let raw = try verifiedResultPayload(response, artifact: result)?.objectValue?["output_artifact"],
              let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) else {
            throw TaskArtifactVerificationError.unavailable
        }
        guard URL(fileURLWithPath: reference.path).lastPathComponent == "output.png" else {
            throw TaskArtifactVerificationError.invalidReference
        }
        let output = try await TaskArtifactVerifier.verifyPNG(reference: reference, taskID: id, root: artifactRoot)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: output.url, to: destination)
    }

    func exportVideo(id: String, to destination: URL) async throws {
        let response = try await api.taskResult(id: id)
        guard response.task.kind == .videoGeneration else { throw TaskArtifactVerificationError.unavailable }
        let result = try await TaskArtifactVerifier.verify(reference: response.artifact, taskID: id, root: artifactRoot)
        guard let raw = try verifiedResultPayload(response, artifact: result)?.objectValue?["output_artifact"],
              let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) else {
            throw TaskArtifactVerificationError.unavailable
        }
        guard URL(fileURLWithPath: reference.path).lastPathComponent == "output.mp4" else {
            throw TaskArtifactVerificationError.invalidReference
        }
        let output = try await TaskArtifactVerifier.verifyVideo(reference: reference, taskID: id, root: artifactRoot)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: output.url, to: destination)
    }

    func startPolling(id: String, owner: String = "default") {
        guard selectedTask?.id == id, selectedTask?.state.isActive == true else {
            stopPolling(owner: owner)
            return
        }
        pollingOwners.insert(owner)
        guard pollingTaskID != id || pollingTask == nil else { return }
        cancelPollingTask()
        pollingTaskID = id
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self,
                      self.selectedTask?.id == id, self.selectedTask?.state.isActive == true else { return }
                await self.refresh(id: id)
            }
            if !Task.isCancelled, let self, self.pollingTaskID == id {
                self.pollingTask = nil
                self.pollingTaskID = nil
            }
        }
    }

    func stopPolling(owner: String) {
        pollingOwners.remove(owner)
        if pollingOwners.isEmpty { cancelPollingTask() }
    }

    func stopPolling() {
        pollingOwners.removeAll()
        cancelPollingTask()
    }

    private func cancelPollingTask() {
        pollingTask?.cancel()
        pollingTask = nil
        pollingTaskID = nil
    }

    func stopPlayback() { audio.stop(); video.stop() }

    private func verifiedResultPayload(_ response: TaskResultResponse, artifact: VerifiedTaskArtifact) throws -> JSONValue? {
        guard let verified = artifact.json else {
            guard response.result == nil else { throw TaskArtifactVerificationError.invalidJSON }
            return nil
        }
        if let inline = response.result, inline != verified { throw TaskArtifactVerificationError.invalidJSON }
        return verified
    }

    func isDraftValid(for kind: TaskKind) -> Bool {
        switch kind {
        case .classification: classificationDraft.validationError == nil
        case .musicGeneration: musicDraft.validationError == nil
        case .transcribe: transcribeDraft.validationError == nil
        case .speak: speakDraft.validationError == nil
        case .imageGeneration: imageGenerationDraft.validationError == nil
        case .imageUnderstanding: imageUnderstandingDraft.validationError == nil
        case .videoUnderstanding: videoUnderstandingDraft.validationError == nil
        case .videoGeneration: videoGenerationDraft.validationError == nil
        case .unsupported: false
        }
    }

    private func replaceSelectedInRecent() {
        guard let selectedTask else { return }
        if let index = recent.firstIndex(where: { $0.id == selectedTask.id }) { recent[index] = selectedTask }
        else { recent.insert(selectedTask, at: 0) }
    }
}

extension TaskKind {
    var modelTaskType: ModelTaskType? {
        switch self {
        case .classification: .classification
        case .musicGeneration: .musicGeneration
        case .transcribe: .speechToText
        case .speak: .textToSpeech
        case .imageGeneration: .imageGeneration
        case .imageUnderstanding: .visionLanguage
        case .videoUnderstanding: .visionLanguage
        case .videoGeneration: .videoGeneration
        case .unsupported: nil
        }
    }
}
