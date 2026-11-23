import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UseWorkspaceView: View {
    let appHost: AppHost
    let onRouteSelection: (AppRoute) -> Void
    @ObservedObject private var coordinator: UseWorkspaceCoordinator
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @ObservedObject private var servedTasks: ServedTaskSessions
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var filePanelPresented = false
    @State private var refreshingServers = false
    @State private var showChatServer = false
    @State private var chatServerSessionID: UUID?
    @State private var chatServerReview: EndpointChangeReview?
    @State private var chatServerError: String?
    @State private var chatServerBusy = false
    @State private var chatServerHold: String?
    private var controlsPresented: Bool { showHistory || showSettings || filePanelPresented || showChatServer }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void) {
        self.appHost = appHost; self.onRouteSelection = onRouteSelection
        _coordinator = ObservedObject(wrappedValue: appHost.useWorkspace)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _servedTasks = ObservedObject(wrappedValue: appHost.servedTasks)
    }
    private var libraryIndex: UseLibraryIndex { UseLibraryIndex(appHost.librarySnapshot?.models ?? []) }
    private func sendBlockReason(_ session: UseSession, index: UseLibraryIndex) -> String? {
        guard session.mode == .chat else { return nil }
        if let serversError = workflow.serversError { return serversError }
        guard session.endpoint == nil, index.model(for: session.modelPath) != nil else { return nil }
        return "\(index.displayName(for: session)) is not running. Choose a server, or set one up. Your message stays here."
    }
    private func adoptSelectedLibraryName() async {
        guard let session = coordinator.selected, let model = libraryIndex.model(for: session.modelPath) else { return }
        await coordinator.adoptLibraryName(model.displayName, modelPath: model.item.path)
    }
    private var choices: [UseConnectionChoice] {
        guard let session = coordinator.selected else { return [] }
        var choices: [String: UseConnectionChoice] = [:]
        for server in workflow.servers where UseChatClient.supports(server) && UseChatClient.matches(server, modelPath: session.modelPath) {
            let choice = UseConnectionChoice(server); choices[choice.id] = choice
        }
        if let server = session.endpoint { let choice = UseConnectionChoice(server); choices[choice.id] = choice }
        return choices.values.sorted { ($0.server.port ?? 0, $0.id) < ($1.server.port ?? 0, $1.id) }
    }

    var body: some View {
        let index = libraryIndex
        GeometryReader { geometry in
            let wide = geometry.size.width >= WorkbenchSize.Use.historyBreakpoint
            let showContext = wide && coordinator.selected?.mode == .chat
            HStack(spacing: 0) {
                if wide && !showContext {
                    history(index)
                        .frame(width: WorkbenchSize.Use.historyWidth)
                    Divider()
                }
                VStack(spacing: 0) {
                    header(showHistoryButton: !wide || showContext, showContext: showContext, index: index)
                    Divider()
                    if let session = coordinator.selected {
                        if session.mode == .chat { chat(session, index: index) }
                        else { tasks(session, index: index) }
                    } else { emptyState }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showContext, let session = coordinator.selected {
                    Divider()
                    modelContext(session, index: index)
                        .frame(width: min(300, geometry.size.width * 0.25))
                }
            }
        }
        .task(id: "\(isRouteActive):\(appHost.handoffs[.useModel]?.id.uuidString ?? ""):\(appHost.librarySnapshot?.models.count ?? 0):\(coordinator.isSending)") {
            guard isRouteActive else { return }
            await coordinator.load()
            await servedTasks.load()
            if !coordinator.isSending { await refreshServers() }
            await consumeHandoff()
            await adoptSelectedLibraryName()
        }
        .onChange(of: controlsPresented, initial: true) { _, value in coordinator.isPresentingPanel = value }
        .onChange(of: isRouteActive) { _, active in
            if !active { Task { do { try await coordinator.flushDraft() } catch { coordinator.showError(error) } } }
        }
        .sheet(isPresented: gated($showHistory)) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                HStack { Text("Work sessions").font(WorkbenchTypography.title); Spacer(); Button("Done") { showHistory = false } }
                history(libraryIndex)
            }.padding(WorkbenchSpacing.md)
                .frame(width: WorkbenchSize.Use.settingsWidth, height: WorkbenchSize.Use.historyHeight)
        }
        .sheet(isPresented: gated($showSettings)) {
            if let session = coordinator.selected { UseSettingsSheet(settings: session.settings, coordinator: coordinator) }
        }
        .sheet(isPresented: gated($showChatServer)) { chatServerSheet }

    }

    private func header(showHistoryButton: Bool, showContext: Bool, index: UseLibraryIndex) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.sm) {
                if showHistoryButton {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Work sessions").accessibilityIdentifier("use-history")
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text(coordinator.selected?.title ?? "Choose a model")
                        .font(WorkbenchTypography.inspectorTitle).lineLimit(1)
                    if !showContext, let session = coordinator.selected {
                        Text(index.displayName(for: session)).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: WorkbenchSpacing.xs)
                newMenu(index)
                if coordinator.selected?.mode == .chat {
                    if !showContext {
                        Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Request settings").accessibilityIdentifier("use-settings")
                            .disabled(!coordinator.canChange)
                    }
                    Menu {
                        Button("Export Markdown…") { export(json: false) }
                        Button("Export JSON…") { export(json: true) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export conversation").accessibilityIdentifier("use-export")
                }
            }
            if !showContext, let session = coordinator.selected, session.mode == .chat {
                connection(session, index: index)
            }
            if let error = coordinator.error {
                HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                    Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                        .textSelection(.enabled).accessibilityIdentifier("use-error")
                    if coordinator.hasUnsavedChanges { Button("Save again") { Task { await coordinator.retrySave() } } }
                    if !coordinator.hasLoaded { Button("Retry") { Task { await coordinator.load() } } }
                }
            }
        }
        .padding(WorkbenchSpacing.md)
    }
    private func newMenu(_ index: UseLibraryIndex) -> some View {
        Menu {
            ForEach(index.usable, id: \.item.path) { model in
                Button(model.displayName) { Task { await create(model) } }
            }
            if let path = coordinator.selected?.modelPath, let model = index.model(for: path),
               UseMode.modes(for: model).count > 1, coordinator.selected?.mode == .chat {
                Button("New model task") { Task { await create(model, mode: .tasks) } }
            }
            if index.usable.isEmpty { Button("Open Library") { onRouteSelection(.library) } }
        } label: { Label("New", systemImage: "square.and.pencil") }
        .disabled(!coordinator.canChange)
        .accessibilityIdentifier("use-new")
    }
    private func history(_ index: UseLibraryIndex) -> some View {
        List(selection: Binding(get: { coordinator.selected?.id }, set: { id in
            guard let id else { return }
            Task {
                do {
                    try await coordinator.select(id: id)
                    showHistory = false
                    await adoptSelectedLibraryName()
                } catch { coordinator.showError(error) }
            }
        })) {
            ForEach(coordinator.sessions) { session in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(session.title).font(WorkbenchTypography.emphasis).lineLimit(2)
                    Label(index.displayName(for: session), systemImage: session.mode == .chat ? "bubble.left" : "tray.full")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                }.tag(session.id).padding(.vertical, WorkbenchSpacing.xxs)
                    .accessibilityIdentifier("use-session-\(session.id)")
            }
        }.listStyle(.sidebar).disabled(!coordinator.canChange)
            .accessibilityIdentifier("use-session-list")
    }
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Work with your models", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Choose a ready model to keep a conversation or run a model task.")
        } actions: {
            Button("Open Library") { onRouteSelection(.library) }
        }
    }
    private func connection(_ session: UseSession, index: UseLibraryIndex) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.sm) { endpointPicker(session); refreshServersButton; manageServer(session, index: index) }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack(spacing: WorkbenchSpacing.sm) { endpointPicker(session); refreshServersButton }
                manageServer(session, index: index)
            }
        }
    }
    private func modelContext(_ session: UseSession, index: UseLibraryIndex) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Text("Model").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Text(index.displayName(for: session)).font(WorkbenchTypography.emphasis).textSelection(.enabled)
                endpointPicker(session)
                HStack(spacing: WorkbenchSpacing.sm) {
                    refreshServersButton
                    manageServer(session, index: index)
                }
                Divider()
                HStack {
                    Text("Request settings").font(WorkbenchTypography.emphasis)
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Request settings").accessibilityIdentifier("use-settings")
                        .disabled(!coordinator.canChange)
                }
                HStack {
                    Text("Response limit")
                    Spacer()
                    Text("\(session.settings.maximumTokens) tokens")
                }
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(session.settings.temperature.formatted())
                }
                .font(WorkbenchTypography.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkbenchSpacing.md)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("use-model-context")
    }
    private var refreshServersButton: some View {
        Button { Task { await refreshServers() } } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel("Refresh servers").accessibilityIdentifier("use-refresh-servers")
            .disabled(coordinator.isSending || refreshingServers)
    }
    private func refreshServers() async {
        guard !refreshingServers else { return }
        refreshingServers = true
        defer { refreshingServers = false }
        await workflow.refreshServers()
    }
    private func endpointPicker(_ session: UseSession) -> some View {
        Picker("Server", selection: Binding(get: { session.endpoint.map { UseConnectionChoice($0).id } ?? "" }, set: { id in
            Task {
                do { try await coordinator.setEndpoint(choices.first(where: { $0.id == id })?.server) }
                catch { coordinator.showError(error) }
            }
        })) {
            Text("Choose a server").tag("")
            ForEach(choices) { choice in
                let current = workflow.servers.contains { $0.sameProcess(as: choice.server) && $0.state == "running" }
                Text(":\(String(choice.server.port ?? 0)) · \(current ? "Running" : "Disconnected")\(choice.server.apiKeySHA256 == nil ? "" : " · API key")\(choice.server.adapterPath == nil ? "" : " · Adapter")").tag(choice.id)
            }
        }.disabled(!coordinator.canChange).accessibilityIdentifier("use-endpoint")
    }
    private func manageServer(_ session: UseSession, index: UseLibraryIndex) -> some View {
        Button(session.endpoint == nil ? "Start server…" : "Manage server…") {
            if session.endpoint == nil, let model = index.model(for: session.modelPath) {
                openChatServer(model, sessionID: session.id)
            } else {
                openServingReview(session, index: index)
            }
        }.disabled(coordinator.isSending || chatServerBusy).accessibilityIdentifier("use-manage-server")
    }
    private func openServingReview(_ session: UseSession, index: UseLibraryIndex) {
        appHost.selectedModelPath = session.modelPath
        if let model = index.model(for: session.modelPath) { appHost.modelWorkflow.prepareServe(model: model) }
        appHost.handoffs.send(UseServerReviewRequest(sessionID: session.id, modelPath: session.modelPath), as: .returnToUse)
        onRouteSelection(.run)
    }
    private func openChatServer(_ model: LibraryModel, sessionID: UUID) {
        chatServerSessionID = sessionID
        chatServerError = nil
        chatServerHold = nil
        switch UseChatServerSetup.review(model: model, appHost: appHost) {
        case .review(let review):
            chatServerReview = review
            showChatServer = true
        case .portRejected(let message):
            chatServerReview = nil
            chatServerError = message
            showChatServer = true
        case .noModel:
            break
        }
    }
    private var chatServerSheet: some View {
        let name = chatServerReview?.model?.displayName ?? coordinator.selected.map { libraryIndex.displayName(for: $0) } ?? "This model"
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Start \(name)").font(WorkbenchTypography.cardTitle)
            if let review = chatServerReview {
                Text(review.slot == nil
                    ? "This chat stays open. The server listens on 127.0.0.1:\(review.port), loads on the first message, and releases the weights afterward."
                    : "Start the saved server on 127.0.0.1:\(review.port) with its current settings.")
                    .fixedSize(horizontal: false, vertical: true)
                if review.unverified {
                    InlineMessage(kind: .warning, text: "This model has not passed verification. Confirm only if you intend to serve it unverified.")
                }
                if let warning = review.memoryWarning {
                    InlineMessage(kind: .warning, text: warning)
                }
            }
            if let chatServerError { InlineMessage(kind: .error, text: chatServerError) }
            if let hold = chatServerHold {
                InlineMessage(kind: .warning, text: "Fleet memory: \(hold). Start anyway?")
            }
            if chatServerBusy { ProgressView("Starting server…").controlSize(.small) }
            HStack {
                Button(chatServerBusy ? "Close" : "Cancel") { showChatServer = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if let session = coordinator.selected, session.id == chatServerSessionID {
                    Button("More settings…") {
                        showChatServer = false
                        openServingReview(session, index: libraryIndex)
                    }.disabled(chatServerBusy)
                }
                if let review = chatServerReview, let sessionID = chatServerSessionID {
                    Button(chatServerHold == nil ? (review.unverified ? "Start unverified server" : "Start server") : "Start anyway") {
                        let overrideMemory = chatServerHold != nil
                        Task { await confirmChatServer(review, sessionID: sessionID, overrideMemory: overrideMemory) }
                    }.buttonStyle(.workbenchPrimary).disabled(chatServerBusy || appHost.endpoint.isChanging)
                }
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(width: 460)
        .accessibilityIdentifier("use-start-server")
    }
    private func confirmChatServer(_ review: EndpointChangeReview, sessionID: UUID, overrideMemory: Bool) async {
        guard !chatServerBusy, showChatServer, let session = coordinator.selected, session.id == sessionID else { return }
        chatServerBusy = true
        defer { chatServerBusy = false }
        chatServerError = nil
        chatServerHold = nil
        let result = await EndpointChanges(appHost: appHost).confirm(review, overrideMemory: overrideMemory)
        if result == .completed { await workflow.refreshServers() }
        guard showChatServer, coordinator.selected?.id == sessionID else { return }
        switch result {
        case .memoryHold(let summary):
            chatServerHold = summary
        case .refused(let message):
            chatServerError = message
            updateChatServerReview(modelPath: session.modelPath)
        case .completed:
            let candidates = workflow.servers.filter { UseChatClient.matches($0, modelPath: session.modelPath) && UseChatClient.supports($0) }
            guard workflow.serversError == nil, candidates.contains(where: {
                $0.port == review.port && $0.matchesUnadaptedModel(review.slot?.modelPath ?? session.modelPath)
                    && $0.apiKeySHA256 == review.slot?.apiKeySHA256 && ($0.jit == true) == review.loadOnRequest
            }) else {
                chatServerError = workflow.serversError ?? "Serving did not report a running Chat connection for this endpoint. Check its status in Serving."
                updateChatServerReview(modelPath: session.modelPath)
                return
            }
            if candidates.count == 1, let server = candidates.first {
                do { try await coordinator.setEndpoint(server, forSessionID: sessionID) }
                catch { chatServerError = AppHost.render(error); return }
            }
            showChatServer = false
        }
    }
    private func updateChatServerReview(modelPath: String) {
        if let model = libraryIndex.model(for: modelPath),
           case .review(let review) = UseChatServerSetup.review(model: model, appHost: appHost) {
            chatServerReview = review
        } else {
            chatServerReview = nil
        }
    }
    private func chat(_ session: UseSession, index: UseLibraryIndex) -> some View {
        let modelName = index.displayName(for: session)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                        if session.turns.isEmpty {
                            Text("What would you like to work on?").font(WorkbenchTypography.title)
                                .foregroundStyle(WorkbenchColor.muted).padding(.vertical, WorkbenchSpacing.xl)
                        }
                        ForEach(session.turns) { turn in
                            UseTurnView(turn: turn, modelName: modelName, isLast: session.turns.last?.id == turn.id,
                                        canRetry: coordinator.canChange) { coordinator.retryLastTurn() }
                        }
                        Color.clear.frame(height: WorkbenchSpacing.hairline).id("use-tail")
                    }
                    .frame(maxWidth: WorkbenchSize.Use.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(WorkbenchSpacing.md)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: session.id) { _, _ in proxy.scrollTo("use-tail", anchor: .bottom) }
                .accessibilityIdentifier("use-transcript")
            }
            Divider()
            composer(session, index: index)
        }
    }
    private func composer(_ session: UseSession, index: UseLibraryIndex) -> some View {
        let selected = index.model(for: session.modelPath)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if !session.draftImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) {
                        ForEach(session.draftImages) { image in
                            HStack(spacing: WorkbenchSpacing.xs) {
                                Label(image.name, systemImage: "photo").lineLimit(1)
                                Button { Task { await coordinator.removeImage(image) } } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("Remove " + image.name)
                            }.font(WorkbenchTypography.secondary)
                        }
                    }
                }.disabled(!coordinator.canChange)
            }
            TextEditor(text: Binding(get: { session.draft }, set: { coordinator.updateDraft($0) }))
                .font(WorkbenchTypography.body)
                .frame(minHeight: WorkbenchSize.Use.composerMinimum, maxHeight: WorkbenchSize.Use.composerMaximum)
                .scrollContentBackground(.hidden)
                .padding(WorkbenchSpacing.xs)
                .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                .overlay(RoundedRectangle(cornerRadius: WorkbenchRadius.control).strokeBorder(WorkbenchColor.hairline, lineWidth: 1))
                .accessibilityLabel("Message").accessibilityIdentifier("use-message")
                .disabled(coordinator.isSending || coordinator.isChanging)
            if let reason = sendBlockReason(session, index: index) {
                Text(reason).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("use-send-reason")
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                if UseChatClient.supportsImages(session.endpoint) {
                    Button { chooseImage() } label: { Label("Image", systemImage: "photo.badge.plus") }
                        .disabled(!coordinator.canChange || session.draftImages.count >= 4)
                        .accessibilityIdentifier("use-add-image")
                }
                Spacer(minLength: 0)
                if coordinator.isSending {
                    Button("Stop waiting") { coordinator.stop() }.accessibilityIdentifier("use-stop")
                } else {
                    Button("Send") { coordinator.send() }
                        .buttonStyle(.workbenchPrimary)
                        .disabled(!isRouteActive || !coordinator.canSend || selected == nil || workflow.serversError != nil)
                        .accessibilityIdentifier("use-send")
                }
            }
            if selected == nil {
                Button("Find this model in Library") { onRouteSelection(.library) }
            }
        }
        .frame(maxWidth: WorkbenchSize.Use.readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(WorkbenchSpacing.md)
    }
    @ViewBuilder
    private func tasks(_ session: UseSession, index: UseLibraryIndex) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                if let model = index.model(for: session.modelPath) {
                    if UseMode.modes(for: model).count > 1 {
                        Button("New chat with this model") { Task { await create(model, mode: .chat) } }
                    }
                    TaskDestinationPanel(appHost: appHost, model: model,
                        initialOrigin: session.endpoint.flatMap { try? ServedTaskOrigin(server: $0) },
                        onEngineSetup: { onRouteSelection(.health) },
                        onDestinationChange: { try await coordinator.setEndpoint($0?.server) })
                        .id(session.id)
                } else {
                    Text("This model is unavailable. Recorded jobs and their verified artifacts remain inspectable.")
                        .font(WorkbenchTypography.body)
                    if let endpoint = session.endpoint {
                        if let origin = try? ServedTaskOrigin(server: endpoint), let tasks = servedTasks.coordinator(for: origin) {
                            UseTaskHistory(coordinator: tasks, modelPath: session.modelPath)
                        }
                    } else { UseTaskHistory(coordinator: appHost.inferenceTasks, modelPath: session.modelPath) }
                }
            }.padding(WorkbenchSpacing.md)
        }
    }
    private func create(_ model: LibraryModel, mode: UseMode? = nil) async {
        do {
            let mode = mode ?? UseMode.modes(for: model).first ?? .tasks
            let servers = workflow.servers.filter { server in
                guard UseChatClient.matches(server, modelPath: model.item.path) else { return false }
                return mode == .chat ? UseChatClient.supports(server) : (try? ServedTaskOrigin(server: server)) != nil
            }
            try await coordinator.create(modelPath: model.item.path, modelName: model.displayName, mode: mode,
                                         endpoint: servers.count == 1 ? servers.first : nil)
        } catch { coordinator.showError(error) }
    }
    private func consumeHandoff() async {
        guard let request = appHost.handoffs[.useModel], coordinator.hasLoaded, appHost.librarySnapshot != nil else { return }
        guard let model = libraryIndex.model(for: request.modelPath) else {
            coordinator.showError(UseSessionError.modelUnavailable)
            appHost.handoffs.finish(request, as: .useModel)
            return
        }
        do {
            if coordinator.sessions.contains(where: { Quarantine.resolve($0.modelPath) == Quarantine.resolve(model.item.path) }) || request.server != nil {
                try await coordinator.open(model: model, server: request.server)
            } else { await create(model) }
            appHost.handoffs.finish(request, as: .useModel)
        } catch { coordinator.showError(error) }
    }
    private func gated(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { isRouteActive && binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        filePanelPresented = true
        panel.begin { response in
            filePanelPresented = false
            if response == .OK, let url = panel.url { Task { await coordinator.addImage(url) } }
        }
    }
    private func export(json: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = json ? [.json] : [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "conversation." + (json ? "json" : "md")
        filePanelPresented = true
        panel.begin { response in
            filePanelPresented = false
            if response == .OK, let url = panel.url {
                Task { do { try await coordinator.export(to: url, json: json) } catch { coordinator.showError(error) } }
            }
        }
    }
}

struct UseLibraryIndex {
    let usable: [LibraryModel]
    private let byPath: [String: LibraryModel]

    init(_ models: [LibraryModel]) {
        var usable: [LibraryModel] = []
        var byPath: [String: LibraryModel] = [:]
        usable.reserveCapacity(models.count)
        byPath.reserveCapacity(models.count)
        for model in models where !UseMode.modes(for: model).isEmpty {
            usable.append(model)
            let key = HFRepoID.serveIdentity(for: model.item.path)
            if byPath[key] == nil { byPath[key] = model }
        }
        self.usable = usable
        self.byPath = byPath
    }

    func model(for path: String) -> LibraryModel? {
        byPath[HFRepoID.serveIdentity(for: path)]
    }

    func displayName(for session: UseSession) -> String {
        model(for: session.modelPath)?.displayName ?? session.modelName
    }
}

/// Reviews an existing Chat endpoint or a new load-on-request server.
enum UseChatServerSetup {
    @MainActor
    static func review(model: LibraryModel, appHost: AppHost) -> EndpointChanges.AddOutcome {
        let changes = EndpointChanges(appHost: appHost)
        let saved = appHost.endpoint.fleet.slots.filter { ServedModelsSelection.matches($0, model: model) }
        if !saved.isEmpty {
            let matching = saved.filter { !$0.isTrainedAdapter && $0.modelPath == model.item.path }
            guard matching.count == 1, let slot = matching.first else {
                return .portRejected("Open More settings to choose a saved endpoint for this model.")
            }
            return .review(changes.review(slot: slot, remove: false))
        }
        guard let port = changes.nextAvailablePort() else {
            return .portRejected("No available port for a new server. Open More settings to choose a port.")
        }
        return changes.reviewAdd(model: model, portText: "", suggestedPort: port, role: nil, loadOnRequest: true,
                                 keepLoaded: false, requireKey: false)
    }
}
