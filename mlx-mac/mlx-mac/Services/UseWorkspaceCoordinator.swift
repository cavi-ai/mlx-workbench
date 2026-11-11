import Darwin
import Foundation

@MainActor
final class UseWorkspaceCoordinator: ObservableObject {
    @Published private(set) var sessions: [UseSession] = []
    @Published private(set) var selected: UseSession?
    @Published private(set) var hasLoaded = false
    @Published private(set) var isChanging = false
    @Published private(set) var isSending = false
    @Published var isPresentingPanel = false
    @Published private(set) var activeServer: ServerInfo?
    @Published private(set) var error: String?
    @Published private(set) var hasUnsavedChanges = false
    private let store: UseSessionStore
    let images: UseImageStore
    private let client: UseChatClient
    private var loadTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var activeTurnID: UUID?
    private var terminating = false
    private var lastCheckpoint = Date.distantPast

    init(store: UseSessionStore = UseSessionStore(), images: UseImageStore = UseImageStore(), client: UseChatClient) {
        self.store = store; self.images = images; self.client = client
    }
    deinit { draftTask?.cancel(); requestTask?.cancel() }

    var canSend: Bool {
        hasLoaded && !isPresentingPanel && !isChanging && !isSending && !hasUnsavedChanges && selected?.mode == .chat
            && selected?.endpoint != nil && !(selected?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    var canChange: Bool { hasLoaded && !isChanging && !isSending && !hasUnsavedChanges }

    func load() async {
        if hasLoaded { return }
        if let loadTask { await loadTask.value; return }
        let task = Task {
            do {
                try await store.recoverInterrupted()
                sessions = try await store.list()
                let saved = try await store.selectedID()
                if let id = saved ?? sessions.first?.id { selected = try await store.record(id: id) }
                hasLoaded = true; error = nil
            } catch { self.error = "History could not be opened: " + error.localizedDescription }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func open(model: LibraryModel, server: ServerInfo? = nil) async throws {
        await load()
        guard canChange else { throw UseSessionError.busy }
        guard let first = UseMode.modes(for: model).first else { throw UseSessionError.modelUnavailable }
        let mode: UseMode = server?.runtime == "tasks" && UseMode.modes(for: model).contains(.tasks) ? .tasks : first
        if let recent = sessions.first(where: { Quarantine.resolve($0.modelPath) == Quarantine.resolve(model.item.path) && $0.mode == mode }) {
            try await select(id: recent.id)
            if let server { try await setEndpoint(server) }
        } else {
            try await create(modelPath: model.item.path, modelName: model.item.name, mode: mode, endpoint: server)
        }
    }

    func create(modelPath: String, modelName: String, mode: UseMode, endpoint: ServerInfo? = nil) async throws {
        await load()
        guard canChange else { throw UseSessionError.busy }
        isChanging = true
        defer { isChanging = false }
        try await flushDraft()
        if let endpoint, !UseChatClient.matches(endpoint, modelPath: modelPath) { throw UseSessionError.changed }
        var session = UseSession(title: mode == .chat ? "New conversation" : modelName + " tasks", modelPath: modelPath, modelName: modelName, mode: mode, endpoint: endpoint)
        session.settings = try await store.defaults()
        try await store.save(session)
        try await store.select(session.id)
        selected = session
        await refreshList()
        error = nil
    }

    func select(id: UUID) async throws {
        guard canChange else { throw UseSessionError.busy }
        isChanging = true
        defer { isChanging = false }
        try await flushDraft()
        guard let session = try await store.record(id: id) else { throw UseSessionError.history }
        try await store.select(id)
        selected = session; error = nil
    }
    func setEndpoint(_ server: ServerInfo?) async throws {
        guard canChange, let session = selected else { throw UseSessionError.history }
        if let server {
            guard UseChatClient.matches(server, modelPath: session.modelPath),
                  session.mode == .tasks ? server.runtime == "tasks" : server.supportsChatCompletions else { throw UseSessionError.changed }
        }
        isChanging = true
        defer { isChanging = false }
        try await flushDraft()
        selected?.endpoint = server
        try await saveSelected()
        error = nil
    }
    func setSettings(_ value: UseRequestDefaults, saveDefaults: Bool) async throws {
        guard canChange else { throw UseSessionError.busy }
        try value.validate()
        isChanging = true
        defer { isChanging = false }
        try await flushDraft()
        selected?.settings = value
        try await saveSelected()
        if saveDefaults { try await store.saveDefaults(value) }
    }
    func updateDraft(_ text: String) {
        guard !isSending, !isChanging, selected != nil else { return }
        selected?.draft = text
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try await self?.saveSelected()
            } catch is CancellationError {} catch { self?.recordSaveFailure(error) }
        }
    }
    func flushDraft() async throws {
        draftTask?.cancel()
        await draftTask?.value
        draftTask = nil
        if selected != nil { try await saveSelected() }
    }
    func retrySave() async {
        do { try await saveSelected(); hasUnsavedChanges = false; error = nil }
        catch { recordSaveFailure(error) }
    }
    func addImage(_ url: URL) async {
        guard canChange, UseChatClient.supportsImages(selected?.endpoint), (selected?.draftImages.count ?? 4) < 4 else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            try await flushDraft()
            let image = try await images.importImage(url)
            if selected?.draftImages.contains(where: { $0.id == image.id }) != true { selected?.draftImages.append(image) }
            try await saveSelected()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func removeImage(_ image: UseImage) async {
        guard canChange else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            try await flushDraft()
            selected?.draftImages.removeAll { $0.id == image.id }
            try await saveSelected()
            try await images.trashIfUnused(image, retainedHashes: store.retainedImageHashes())
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func send() -> Task<Void, Never>? {
        guard canSend, let session = selected else { return nil }
        return begin(prompt: session.draft, inputImages: session.draftImages, retryOf: nil)
    }
    @discardableResult
    func retryLastTurn() -> Task<Void, Never>? {
        guard canChange, let last = selected?.turns.last, last.state.canRetry else { return nil }
        return begin(prompt: last.prompt, inputImages: last.images, retryOf: last.id)
    }
    func stop() { requestTask?.cancel() }
    func showError(_ error: Error) { self.error = error.localizedDescription }

    func prepareForQuit() async -> Bool {
        terminating = true
        draftTask?.cancel(); requestTask?.cancel()
        guard var session = selected else { return true }
        session.wasSending = false
        for index in session.turns.indices where session.turns[index].state == .sending {
            session.turns[index].state = .interrupted
            session.turns[index].notice = UseSessionError.interrupted.localizedDescription
        }
        selected = session
        do {
            try await store.save(session)
            hasUnsavedChanges = false
            return true
        } catch {
            terminating = false
            recordSaveFailure(error)
            return false
        }
    }

    func export(to destination: URL, json: Bool) async throws {
        draftTask?.cancel()
        await draftTask?.value
        guard let session = selected else { throw UseSessionError.history }
        try await Task.detached(priority: .utility) {
            let data: Data
            if json {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(session)
            } else { data = Data(session.markdown().utf8) }
            let parent = destination.deletingLastPathComponent()
            guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw UseSessionError.history }
            let temporary = parent.appendingPathComponent(".use-export-\(UUID())")
            let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
            try output.write(contentsOf: data); try output.synchronize(); try output.close()
            guard rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }.value
    }

    private func begin(prompt: String, inputImages: [UseImage], retryOf: UUID?) -> Task<Void, Never>? {
        guard let session = selected, let server = session.endpoint,
              UseChatClient.supports(server), UseChatClient.matches(server, modelPath: session.modelPath),
              !isSending, !isChanging, !hasUnsavedChanges else { error = UseSessionError.noEndpoint.localizedDescription; return nil }
        isSending = true
        activeServer = server
        error = nil
        let task = Task { await perform(prompt: prompt, inputImages: inputImages, retryOf: retryOf, server: server) }
        requestTask = task
        return task
    }
    private func perform(prompt: String, inputImages: [UseImage], retryOf: UUID?, server: ServerInfo) async {
        var dispatched = false
        defer { isSending = false; activeServer = nil; activeTurnID = nil; requestTask = nil }
        do {
            try await flushDraft()
            try Task.checkCancellation()
            guard let session = selected else { throw UseSessionError.history }
            let token = try await client.prepare(server)
            let messages = try await UseChatRequest.messages(session: session, prompt: prompt, images: inputImages, inputs: images, server: server)
            try Task.checkCancellation()
            var turn = UseTurn(prompt: prompt, images: inputImages, endpoint: server, settings: session.settings)
            turn.retryOf = retryOf
            var pending = session
            pending.turns.append(turn)
            if retryOf == nil { pending.draft = ""; pending.draftImages = [] }
            pending.wasSending = true
            if session.turns.isEmpty { pending.title = String(prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(64) ?? "Conversation") }
            try pending.validate()
            selected = pending
            let turnID = turn.id
            activeTurnID = turnID
            // The durable pending turn precedes the only inference request.
            try await saveSelected()
            try await client.assertCurrent(server)
            try Task.checkCancellation()
            dispatched = true
            lastCheckpoint = .distantPast
            let result = try await client.stream(server, messages, session.settings, token, { [weak self] text, reasoning in
                guard let self else { throw CancellationError() }
                try await self.receive(text: text, reasoning: reasoning, turnID: turnID)
            })
            try await client.assertCurrent(server)
            try Task.checkCancellation()
            updateActiveTurn {
                $0.answer = result.text; $0.reasoning = result.reasoningText ?? ""
                switch result.finishReason {
                case "stop" where !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: $0.state = .complete
                case "stop": $0.state = .interrupted; $0.notice = "The server returned no answer text."
                case "length": $0.state = .limited
                default: $0.state = .interrupted; $0.notice = UseSessionError.interrupted.localizedDescription
                }
            }
            selected?.wasSending = false
            try await saveSelected()
            await refreshList()
        } catch {
            if terminating { return }
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            let requestRejected: Bool
            if case UseSessionError.requestTooLarge = error { requestRejected = true }
            else { requestRejected = false }
            let refusal = requestRejected || (error as? ProbeHTTPError).map { value in
                if case .httpStatus(let status) = value { return [400, 401, 403, 404, 409, 422].contains(status) }
                return false
            } ?? false
            let notice = cancelled
                ? (dispatched ? "Stopped waiting. The server may still be finishing this request. The partial answer is retained." : "Cancelled before sending.")
                : error.localizedDescription
            updateActiveTurn {
                $0.state = cancelled ? .stoppedWaiting : (dispatched && !refusal ? .interrupted : .failed)
                $0.notice = notice
            }
            if retryOf == nil && (!dispatched || refusal) { selected?.draft = prompt; selected?.draftImages = inputImages }
            selected?.wasSending = false
            self.error = notice
            do { try await saveSelected(); await refreshList() }
            catch { recordSaveFailure(error) }
        }
    }
    private func receive(text: String, reasoning: String, turnID: UUID) async throws {
        guard !terminating, activeTurnID == turnID else { throw CancellationError() }
        try Task.checkCancellation()
        guard let session = selected else { throw UseSessionError.history }
        let priorBytes = session.turns.filter { $0.id != turnID }.reduce(0) { $0 + $1.prompt.utf8.count + $1.answer.utf8.count + $1.reasoning.utf8.count }
        let promptBytes = session.turns.first(where: { $0.id == turnID })?.prompt.utf8.count ?? 0
        guard priorBytes + promptBytes + text.utf8.count + reasoning.utf8.count <= 8_388_608 else { throw UseSessionError.history }
        updateActiveTurn { $0.answer = text; $0.reasoning = reasoning }
        if Date().timeIntervalSince(lastCheckpoint) >= 1 {
            try await saveSelected()
            lastCheckpoint = Date()
        }
    }
    private func updateActiveTurn(_ update: (inout UseTurn) -> Void) {
        guard let id = activeTurnID, let index = selected?.turns.firstIndex(where: { $0.id == id }) else { return }
        update(&selected!.turns[index])
    }
    private func saveSelected() async throws {
        guard var session = selected else { return }
        session.updatedAt = Date()
        do {
            try await store.save(session)
            if selected?.id == session.id { selected?.updatedAt = session.updatedAt }
            if hasUnsavedChanges { error = nil }
            hasUnsavedChanges = false
        } catch { recordSaveFailure(error); throw error }
    }
    private func recordSaveFailure(_ error: Error) {
        hasUnsavedChanges = true
        self.error = "History could not be saved: " + error.localizedDescription
    }
    private func refreshList() async {
        do { sessions = try await store.list() }
        catch { self.error = "History could not be refreshed: " + error.localizedDescription }
    }
}
