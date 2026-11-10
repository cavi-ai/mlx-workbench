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
    private var controlsPresented: Bool { showHistory || showSettings || filePanelPresented }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void) {
        self.appHost = appHost; self.onRouteSelection = onRouteSelection
        _coordinator = ObservedObject(wrappedValue: appHost.useWorkspace)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _servedTasks = ObservedObject(wrappedValue: appHost.servedTasks)
    }
    private var models: [LibraryModel] { (appHost.librarySnapshot?.models ?? []).filter { !UseMode.modes(for: $0).isEmpty } }
    private var selectedModel: LibraryModel? {
        guard let path = coordinator.selected?.modelPath else { return nil }
        return models.first { Quarantine.resolve($0.item.path) == Quarantine.resolve(path) }
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
        GeometryReader { geometry in
            let wide = geometry.size.width >= WorkbenchSize.Use.historyBreakpoint
            HStack(spacing: 0) {
                if wide {
                    history
                        .frame(width: WorkbenchSize.Use.historyWidth)
                    Divider()
                }
                VStack(spacing: 0) {
                    header(wide: wide)
                    Divider()
                    if let session = coordinator.selected {
                        if session.mode == .chat { chat(session) }
                        else { tasks(session) }
                    } else { emptyState }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(isRouteActive):\(appHost.handoffs[.useModel]?.id.uuidString ?? ""):\(appHost.librarySnapshot?.models.count ?? 0):\(coordinator.isSending)") {
            guard isRouteActive else { return }
            await coordinator.load()
            await servedTasks.load()
            if !coordinator.isSending { await refreshServers() }
            await consumeHandoff()
        }
        .onChange(of: controlsPresented, initial: true) { _, value in coordinator.isPresentingPanel = value }
        .onChange(of: isRouteActive) { _, active in
            if !active { Task { do { try await coordinator.flushDraft() } catch { coordinator.showError(error) } } }
        }
        .sheet(isPresented: gated($showHistory)) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                HStack { Text("Work sessions").font(WorkbenchTypography.title); Spacer(); Button("Done") { showHistory = false } }
                history
            }.padding(WorkbenchSpacing.md)
                .frame(width: WorkbenchSize.Use.settingsWidth, height: WorkbenchSize.Use.historyHeight)
        }
        .sheet(isPresented: gated($showSettings)) {
            if let session = coordinator.selected { UseSettingsSheet(settings: session.settings, coordinator: coordinator) }
        }

    }

    private func header(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.sm) {
                if !wide {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Work sessions").accessibilityIdentifier("use-history")
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text(coordinator.selected?.title ?? "Choose a model")
                        .font(WorkbenchTypography.inspectorTitle).lineLimit(1)
                    if let session = coordinator.selected {
                        Text(session.modelName).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: WorkbenchSpacing.xs)
                newMenu
                if coordinator.selected?.mode == .chat {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Request settings").accessibilityIdentifier("use-settings")
                        .disabled(!coordinator.canChange)
                    Menu {
                        Button("Export Markdown…") { export(json: false) }
                        Button("Export JSON…") { export(json: true) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Export conversation").accessibilityIdentifier("use-export")
                }
            }
            if let session = coordinator.selected, session.mode == .chat {
                connection(session)
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
    private var newMenu: some View {
        Menu {
            ForEach(models, id: \.item.path) { model in
                Button(model.item.name) { Task { await create(model) } }
            }
            if let model = selectedModel, UseMode.modes(for: model).count > 1, coordinator.selected?.mode == .chat {
                Button("New model task") { Task { await create(model, mode: .tasks) } }
            }
            if models.isEmpty { Button("Open Library") { onRouteSelection(.library) } }
        } label: { Label("New", systemImage: "square.and.pencil") }
        .disabled(!coordinator.canChange)
        .accessibilityIdentifier("use-new")
    }
    private var history: some View {
        List(selection: Binding(get: { coordinator.selected?.id }, set: { id in
            guard let id else { return }
            Task {
                do { try await coordinator.select(id: id); showHistory = false }
                catch { coordinator.showError(error) }
            }
        })) {
            ForEach(coordinator.sessions) { session in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(session.title).font(WorkbenchTypography.emphasis).lineLimit(2)
                    Label(session.modelName, systemImage: session.mode == .chat ? "bubble.left" : "tray.full")
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
    private func connection(_ session: UseSession) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.sm) { endpointPicker(session); refreshServersButton; manageServer(session) }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack(spacing: WorkbenchSpacing.sm) { endpointPicker(session); refreshServersButton }
                manageServer(session)
            }
        }
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
    private func manageServer(_ session: UseSession) -> some View {
        Button(session.endpoint == nil ? "Start server…" : "Manage server…") {
            appHost.selectedModelPath = session.modelPath
            if let model = selectedModel { appHost.modelWorkflow.prepareServe(model: model) }
            appHost.handoffs.send(UseServerReviewRequest(sessionID: session.id, modelPath: session.modelPath), as: .returnToUse)
            onRouteSelection(.run)
        }.disabled(coordinator.isSending).accessibilityIdentifier("use-manage-server")
    }
    private func chat(_ session: UseSession) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                        if session.turns.isEmpty {
                            Text("What would you like to work on?").font(WorkbenchTypography.title)
                                .foregroundStyle(WorkbenchColor.muted).padding(.vertical, WorkbenchSpacing.xl)
                        }
                        ForEach(session.turns) { turn in
                            UseTurnView(turn: turn, modelName: session.modelName, isLast: session.turns.last?.id == turn.id,
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
            composer(session)
        }
    }
    private func composer(_ session: UseSession) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
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
                .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                .accessibilityLabel("Message").accessibilityIdentifier("use-message")
                .disabled(coordinator.isSending || coordinator.isChanging)
            HStack(spacing: WorkbenchSpacing.sm) {
                if UseChatClient.supportsImages(session.endpoint) {
                    Button { chooseImage() } label: { Label("Image", systemImage: "photo.badge.plus") }
                        .disabled(!coordinator.canChange || session.draftImages.count >= 4)
                        .accessibilityIdentifier("use-add-image")
                }
                Text("Request: \(session.settings.maximumTokens) tokens · \(session.settings.temperature.formatted()) temperature")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                Spacer(minLength: 0)
                if coordinator.isSending {
                    Button("Stop waiting") { coordinator.stop() }.accessibilityIdentifier("use-stop")
                } else {
                    Button("Send") { coordinator.send() }
                        .buttonStyle(.workbenchPrimary)
                        .disabled(!isRouteActive || !coordinator.canSend || selectedModel == nil || workflow.serversError != nil)
                        .accessibilityIdentifier("use-send")
                }
            }
            if selectedModel == nil {
                Button("Find this model in Library") { onRouteSelection(.library) }
            }
        }.padding(WorkbenchSpacing.md)
    }
    @ViewBuilder
    private func tasks(_ session: UseSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                if let model = selectedModel {
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
            try await coordinator.create(modelPath: model.item.path, modelName: model.item.name, mode: mode,
                                         endpoint: servers.count == 1 ? servers.first : nil)
        } catch { coordinator.showError(error) }
    }
    private func consumeHandoff() async {
        guard let request = appHost.handoffs[.useModel], coordinator.hasLoaded, appHost.librarySnapshot != nil else { return }
        guard let model = models.first(where: { Quarantine.resolve($0.item.path) == Quarantine.resolve(request.modelPath) }) else {
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
