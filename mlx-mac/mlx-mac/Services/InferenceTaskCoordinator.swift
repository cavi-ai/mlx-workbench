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
        guard caption.count <= 2_000 else { return "Caption must be 2,000 characters or fewer." }
        guard lyrics.count <= 10_000 else { return "Lyrics must be 10,000 characters or fewer." }
        guard duration.isFinite, duration > 0, duration <= 360 else { return "Duration must be greater than 0 and at most 360 seconds." }
        guard (1...30).contains(steps) else { return "Steps must be between 1 and 30." }
        guard (0...4_294_967_295).contains(seed) else { return "Seed must be an unsigned 32-bit integer." }
        return nil
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

@MainActor
final class InferenceTaskCoordinator: ObservableObject {
    @Published var classificationDraft = ClassificationDraft()
    @Published var musicDraft = MusicTaskDraft()
    @Published private(set) var recent: [TaskRecord] = []
    @Published private(set) var hasMoreRecent = false
    @Published private(set) var selectedTask: TaskRecord?
    @Published private(set) var selectedResult: TaskResultResponse?
    @Published private(set) var verifiedResult: VerifiedTaskArtifact?
    @Published private(set) var verifiedOutput: VerifiedTaskArtifact?
    @Published private(set) var busy = false
    @Published private(set) var startOutcomeUnknown = false
    @Published private(set) var error: String?
    @Published private(set) var readError: String?
    @Published private(set) var cancellationPending = false
    let audio = AudioClipPlayer()

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
        selectedTask = record
        selectedResult = nil
        verifiedResult = nil
        verifiedOutput = nil
        if record.state.isActive { await refresh(id: id) }
        else { await inspect(id: id) }
    }

    func start(kind: TaskKind, model: LibraryModel) async {
        guard canStart else { return }
        guard model.readiness == .ready, model.item.task?.type.rawValue == kind.wireValue else {
            error = "Choose a Ready model with the matching task type."
            return
        }
        let request: TaskRequest
        do { request = try kind == .classification ? classificationDraft.request(modelPath: model.item.path) : musicDraft.request(modelPath: model.item.path) }
        catch { self.error = AppHost.render(error); return }
        busy = true
        cancellationPending = false
        error = nil
        startOutcomeUnknown = false
        defer { busy = false }
        do {
            let capabilities = try await api.taskCapabilities()
            guard capabilities.isSupported,
                  capabilities.tasks.contains(where: { $0.kind == kind && $0.requiresLocalModel }) else {
                cancellationPending = false
                error = "The installed mlx-agent does not advertise this local task type."
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
            var output: VerifiedTaskArtifact?
            if let raw = (response.result ?? json.json)?.objectValue?["output_artifact"],
               let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) {
                output = try await TaskArtifactVerifier.verify(reference: reference, taskID: id, root: artifactRoot)
            }
            selectedTask = response.task
            selectedResult = response
            verifiedResult = json
            verifiedOutput = output
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
            if request.kind == .classification { try classificationDraft.load(request) }
            else if request.kind == .musicGeneration { try musicDraft.load(request) }
            error = nil
        } catch { self.error = "This task request cannot be safely reused: \(AppHost.render(error))" }
    }

    func export(id: String, to destination: URL) async throws {
        let response = try await api.taskResult(id: id)
        let result = try await TaskArtifactVerifier.verify(reference: response.artifact, taskID: id, root: artifactRoot)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: result.url, to: destination)
    }

    func exportAudio(id: String, to destination: URL) async throws {
        let response = try await api.taskResult(id: id)
        let result = try await TaskArtifactVerifier.verify(reference: response.artifact, taskID: id, root: artifactRoot)
        guard let raw = (response.result ?? result.json)?.objectValue?["output_artifact"],
              let reference = try? JSONDecoder().decode(TaskArtifactReference.self, from: JSONEncoder().encode(raw)) else {
            throw TaskArtifactVerificationError.unavailable
        }
        let output = try await TaskArtifactVerifier.verify(reference: reference, taskID: id, root: artifactRoot)
        guard output.url.pathExtension.lowercased() == "wav" else { throw TaskArtifactVerificationError.invalidReference }
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

    func stopPlayback() { audio.stop() }

    func isDraftValid(for kind: TaskKind) -> Bool {
        switch kind {
        case .classification: classificationDraft.validationError == nil
        case .musicGeneration: musicDraft.validationError == nil
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
        case .unsupported: nil
        }
    }
}
