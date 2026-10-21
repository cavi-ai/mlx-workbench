import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Both workspaces stay mounted so changing source preserves the native setup and results.
struct ComparisonWorkspace: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var native: ComparisonCoordinator
    @ObservedObject private var hosted: HostedComparisonCoordinator
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var active
    @State private var visitedHosted = false

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost; self.onRouteSelection = onRouteSelection
        _native = ObservedObject(wrappedValue: appHost.comparison)
        _hosted = ObservedObject(wrappedValue: appHost.hostedComparison)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Compare source", selection: $appHost.compareHostedModels) {
                Text("Local models").tag(false)
                Text("Hosted & mixed").tag(true)
            }.pickerStyle(.segmented).frame(maxWidth: 350)
                .padding(.horizontal, WorkbenchSpacing.pageInset).padding(.top, WorkbenchSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(native.activeRunID != nil || hosted.activeRunID != nil)
                .help("Finish or cancel the active run before changing comparison source.")
                .accessibilityIdentifier("compare-source")
            ZStack {
                QuantView(appHost: appHost, onRouteSelection: onRouteSelection)
                    .environment(\.isRouteActive, active && !appHost.compareHostedModels)
                    .opacity(appHost.compareHostedModels ? 0 : 1)
                    .allowsHitTesting(!appHost.compareHostedModels).accessibilityHidden(appHost.compareHostedModels)
                if visitedHosted || appHost.compareHostedModels {
                    HostedComparisonView(appHost: appHost, onRouteSelection: onRouteSelection)
                        .environment(\.isRouteActive, active && appHost.compareHostedModels)
                        .opacity(appHost.compareHostedModels ? 1 : 0)
                        .allowsHitTesting(appHost.compareHostedModels).accessibilityHidden(!appHost.compareHostedModels)
                }
            }
        }.onChange(of: appHost.compareHostedModels, initial: true) { _, selected in if selected { visitedHosted = true } }
        .onChange(of: appHost.handoffs[.compareModel], initial: true) { _, _ in routeNativeRequest() }
        .onChange(of: appHost.handoffs[.compareServingProfiles], initial: true) { _, _ in routeNativeRequest() }
        .onChange(of: hosted.activeRunID) { _, _ in routeNativeRequest() }
    }

    private func routeNativeRequest() {
        guard hosted.activeRunID == nil,
              appHost.handoffs[.compareModel] != nil || appHost.handoffs[.compareServingProfiles] != nil else { return }
        appHost.compareHostedModels = false
    }
}

struct HostedComparisonView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var hosts: ModelHostsCoordinator
    @ObservedObject private var comparison: HostedComparisonCoordinator
    @ObservedObject private var native: ComparisonCoordinator
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var active
    @State private var mode: ComparisonMode = .chat
    @State private var promptSetID = BuiltinPromptSets.coding.id
    @State private var promptText = "A small wooden boat on a calm lake at sunrise"
    @State private var workflowJSON: String?
    @State private var workflowName = ""
    @State private var checkpointNode = ""
    @State private var promptNode = ""
    @State private var outputNode = ""
    @State private var selectedRunID: UUID?
    @State private var error: String?
    @State private var readingWorkflow = false
    @State private var width: CGFloat = 900

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost; self.onRouteSelection = onRouteSelection
        _hosts = ObservedObject(wrappedValue: appHost.modelHosts)
        _comparison = ObservedObject(wrappedValue: appHost.hostedComparison)
        _native = ObservedObject(wrappedValue: appHost.comparison)
    }

    private var workflow: ComfyWorkflow? {
        workflowJSON.map { ComfyWorkflow(apiJSON: $0, checkpointNodeID: checkpointNode, promptNodeID: promptNode, outputNodeID: outputNode) }
    }
    private var promptSet: PromptSet? {
        if mode == .chat { return native.promptSets.first { $0.id == promptSetID && $0.effectiveMode == .chat } }
        return PromptSet(id: "comfy-workflow", name: workflowName.isEmpty ? "ComfyUI workflow" : workflowName,
            useCase: nil, prompts: [PromptEntry(id: "image-prompt", text: promptText, maxTokens: 512)], origin: .userCreated, mode: .imageGeneration)
    }
    private var shown: HostedComparisonRecord? {
        comparison.records.first { $0.id == comparison.activeRunID }
            ?? comparison.records.first { $0.id == selectedRunID } ?? comparison.records.first
    }
    private var unavailable: String? {
        if comparison.activeRunID != nil { return "Wait for the active run and any native server cleanup." }
        if native.activeRunID != nil { return "Finish the local comparison first." }
        if let storage = comparison.storageError { return storage }
        if readingWorkflow { return "Wait for the workflow file to finish reading." }
        if appHost.hostedComparisonTargets.isEmpty { return "Add models from a refreshed host inventory or the local Library." }
        do {
            for target in appHost.hostedComparisonTargets { try target.validate(mode: mode) }
            if mode == .imageGeneration {
                guard let workflow else { return "Import a ComfyUI API workflow and choose its input and output nodes." }
                try workflow.validated()
                if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter an image prompt." }
            }
        } catch { return AppHost.render(error) }
        return promptSet == nil ? "Choose a prompt set." : nil
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    setup
                    ErrorBanner(text: error ?? comparison.storageError ?? comparison.lastError)
                    if let record = shown { results(record) }
                    else {
                        ContentUnavailableView("No hosted comparisons yet", systemImage: "chart.bar.xaxis",
                            description: Text("Choose models and prompts, then run to record their outputs and source metadata."))
                    }
                }.padding(WorkbenchSpacing.pageInset)
            }.onChange(of: geometry.size.width, initial: true) { _, value in width = max(320, value - 2 * WorkbenchSpacing.pageInset) }
        }
        .accessibilityIdentifier("hosted-comparison-workspace")
        .onChange(of: appHost.hostedComparisonTargets, initial: true) { _, targets in
            if !targets.isEmpty, targets.allSatisfy({ $0.host?.provider == .comfyUI }) { mode = .imageGeneration }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Picker("Task", selection: $mode) {
                Text("Text").tag(ComparisonMode.chat)
                Text("ComfyUI images").tag(ComparisonMode.imageGeneration)
            }.pickerStyle(.segmented).frame(maxWidth: 350).disabled(comparison.activeRunID != nil)
            HStack {
                addModelMenu
                Button("Manage hosts…") { appHost.handoffs.send(HostedModelsRequest(), as: .openHostedModels); onRouteSelection(.library) }
                Spacer()
                if let id = comparison.activeRunID {
                    ProgressView().controlSize(.small)
                    if comparison.cleanupPending { Button("Retry native cleanup") { comparison.retryCleanup() }.disabled(comparison.cancelling) }
                    else { Button(comparison.cancelling ? "Cancelling…" : "Cancel") { comparison.cancel() }.disabled(comparison.cancelling) }
                    Text(id.uuidString.prefix(8)).font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted)
                } else {
                    Button("Run comparison") { start() }.buttonStyle(.workbenchPrimary)
                        .disabled(unavailable != nil).help(unavailable ?? "Run these prompts sequentially against the selected models.")
                        .accessibilityIdentifier("run-hosted-comparison")
                }
            }
            ForEach(Array(appHost.hostedComparisonTargets.enumerated()), id: \.element.id) { index, target in
                HStack(alignment: .top) {
                    Text(String(UnicodeScalar(65 + index)!)).font(WorkbenchTypography.section).foregroundStyle(WorkbenchColor.accent)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text(target.displayName).font(WorkbenchTypography.emphasis).textSelection(.enabled)
                        Text(target.host?.baseURL ?? target.localPath ?? "Unavailable").font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted).lineLimit(2)
                        if target.host != nil { Text("Captured \(target.capturedAt.formatted()) · identity \(target.signature == nil ? "not reported" : "recorded")").font(WorkbenchTypography.secondary) }
                    }
                    Spacer()
                    Button { appHost.hostedComparisonTargets.removeAll { $0.id == target.id } } label: { Label("Remove lane \(index + 1)", systemImage: "minus.circle") }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(comparison.activeRunID != nil)
                }
            }
            if mode == .chat {
                Picker("Prompt set", selection: $promptSetID) {
                    ForEach(native.promptSets.filter { $0.effectiveMode == .chat }) { Text($0.name).tag($0.id) }
                }.disabled(comparison.activeRunID != nil)
                Text("Requests use temperature 0 and each prompt's output-token limit. Context, templates and other defaults are host-managed. Latency includes transport and any loading; tokenizer differences affect tokens per second.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else { workflowSetup }
            if let progress = comparison.progress { Text(progress).font(WorkbenchTypography.secondary) }
            else if let unavailable { Label(unavailable, systemImage: "info.circle").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
        }
    }

    private var addModelMenu: some View {
        Menu("Add model") {
            if mode == .chat {
                Section("MLX Workbench") {
                    ForEach(ComparePresentation.candidates(from: appHost.librarySnapshot?.models ?? []), id: \.item.path) { model in
                        Button(model.displayName) { append(HostedComparisonTarget(local: model, capturedAt: appHost.librarySnapshot?.generatedAt ?? Date())) }
                    }
                }
            }
            ForEach(hosts.hosts) { host in
                if let inventory = hosts.inventories[host.id], hosts.errors[host.id] == nil {
                    Section(host.name) {
                        ForEach(inventory.models.filter { model in
                            (try? HostedComparisonTarget(host: host, model: model, capturedAt: inventory.capturedAt).validate(mode: mode)) != nil
                        }) { model in
                            Button(model.name) { append(HostedComparisonTarget(host: host, model: model, capturedAt: inventory.capturedAt, runtimeVersion: inventory.runtimeVersion)) }
                        }
                    }
                }
            }
        }.disabled(comparison.activeRunID != nil || appHost.hostedComparisonTargets.count >= 4)
        .help("Choose up to four distinct models. Refresh hosts in Library to list them here.")
    }

    private var workflowSetup: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Button(readingWorkflow ? "Reading…" : "Import API workflow…") { importWorkflow() }.disabled(readingWorkflow || comparison.activeRunID != nil)
                Text(workflowName).font(WorkbenchTypography.secondary)
            }
            if workflowJSON != nil {
                nodePicker("Checkpoint node", selection: $checkpointNode, classes: ["CheckpointLoaderSimple", "CheckpointLoader"])
                nodePicker("Positive text node", selection: $promptNode, classes: ["CLIPTextEncode"])
                nodePicker("Image output node", selection: $outputNode, classes: ["SaveImage"])
                TextField("Image prompt", text: $promptText, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                DisclosureGroup("Review imported API graph") { TextEditor(text: .constant(workflowJSON ?? "")).font(WorkbenchTypography.value).frame(height: 180) }
            }
            Text("Export API format from ComfyUI. Only the selected checkpoint and positive text are replaced; seeds, samplers and other settings stay in the graph. Standard local image nodes are supported. Running may load models. Cancel stops observation; submitted jobs may continue on their host.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }.disabled(comparison.activeRunID != nil)
    }

    private func nodePicker(_ title: String, selection: Binding<String>, classes: Set<String>) -> some View {
        let graph = workflowJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
        let nodes = graph.keys.filter { classes.contains(graph[$0]?["class_type"] as? String ?? "") }.sorted()
        return Picker(title, selection: selection) {
            Text("Choose node").tag("")
            ForEach(nodes, id: \.self) { id in Text("\(id) · \(graph[id]?["class_type"] as? String ?? "")").tag(id) }
        }
    }

    private func results(_ record: HostedComparisonRecord) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Picker("Recorded run", selection: Binding(get: { shown?.id }, set: { selectedRunID = $0 })) {
                ForEach(comparison.records) { saved in
                    Text("\(saved.run.startedAt.formatted()) · \(saved.run.promptSetName) · \(saved.run.state.rawValue)").tag(Optional(saved.id))
                }
            }
            Text("Recorded host comparisons · \(record.run.state.rawValue)").font(WorkbenchTypography.section)
            if let notice = record.conditionsNotice {
                Text(notice).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                    .accessibilityIdentifier("hosted-conditions-notice")
            }
            if record.run.effectiveMode == .chat {
                ChatComparisonResultsView(run: record.run, store: comparison.outputStore, contentWidth: width,
                    name: { name($0, in: record) }, onReview: { comparison.review(runID: record.id, targetID: $0, score: $1) },
                    reviewError: comparison.lastError, onPromote: { _ in }, allowsPromotion: false,
                    laneActions: { lane in Text(name(lane.resultKey, in: record)).font(WorkbenchTypography.secondary) })
                    .id(record.id)
            } else {
                Text("Elapsed times include queue wait, loading and execution. Cached ComfyUI nodes can affect timing; per-step speed is unknown.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                MediaRunResultsView(run: record.run, store: comparison.outputStore, contentWidth: width, isRouteActive: active,
                    name: { name($0, in: record) }, onReview: { comparison.review(runID: record.id, targetID: $0, score: $1) }, reviewError: comparison.lastError,
                    laneActions: { lane in
                        if let seconds = record.run.results.first(where: { $0.id == lane.resultKey })?.samples.first?.seconds {
                            Text("Elapsed \(seconds, specifier: "%.2f") s including queue").font(WorkbenchTypography.secondary)
                        }
                    }).id(record.id)
            }
            DisclosureGroup("Recorded sources and settings") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    ForEach(record.targets) { target in
                        Text("\(target.displayName) · \(target.signature ?? "Weight identity unknown") · Runtime \(target.runtimeVersion ?? "unknown")")
                    }
                    ForEach(record.observedTargets ?? []) { target in
                        Text("Before inference: \(target.displayName) · \(target.capturedAt.formatted()) · Runtime \(target.runtimeVersion ?? "unknown") · \(target.deviceSummary ?? "Device unknown")")
                    }
                    HostedRunConditionsView(record: record)
                    ForEach(record.submissions) { submission in
                        DisclosureGroup("ComfyUI prompt \(submission.remotePromptID)") {
                            Text(submission.graphJSON).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                        }
                    }
                }.font(WorkbenchTypography.secondary)
            }
        }
    }

    private func name(_ id: String, in record: HostedComparisonRecord) -> String { record.targets.first { $0.id == id }?.displayName ?? id }
    private func append(_ target: HostedComparisonTarget) {
        guard !appHost.hostedComparisonTargets.contains(where: { $0.id == target.id }) else { return }
        appHost.hostedComparisonTargets.append(target)
    }
    private func start() {
        guard unavailable == nil, var promptSet else { return }
        promptSet.prompts = promptSet.prompts.map { entry in
            var copy = entry; copy.maxTokens = min(entry.maxTokens, appHost.config.comparisonMaxTokens); return copy
        }
        do { try comparison.start(targets: appHost.hostedComparisonTargets, promptSet: promptSet, workflow: mode == .imageGeneration ? workflow : nil); error = nil }
        catch { self.error = AppHost.render(error) }
    }
    private func importWorkflow() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readingWorkflow = true
        Task {
            do {
                let json = try await Task.detached {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 1_048_576 else {
                        throw HostedIntegrationError.invalid("Choose a regular API JSON file of at most 1 MB.")
                    }
                    return try String(contentsOf: url, encoding: .utf8)
                }.value
                workflowJSON = json; workflowName = url.lastPathComponent
                checkpointNode = ""; promptNode = ""; outputNode = ""; error = nil
            } catch { self.error = AppHost.render(error) }
            readingWorkflow = false
        }
    }
}

/// Historical values only; rendering never probes memory or contacts a host.
struct HostedRunConditionsView: View {
    let record: HostedComparisonRecord

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Conditions before each lane").font(WorkbenchTypography.label)
            Text("Memory, inventory and activity are separate snapshots. They do not establish conditions throughout the run or explain the cause of a timing difference.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if record.conditions == nil {
                Text("Not recorded for this comparison.").foregroundStyle(WorkbenchColor.muted)
            } else {
                ForEach(record.targets) { target in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text(target.displayName).font(WorkbenchTypography.label)
                        if let conditions = record.conditions?.first(where: { $0.targetID == target.id }) {
                            conditionDetails(conditions, hosted: target.host != nil, showsDeviceMemory: target.host?.provider == .comfyUI)
                        } else {
                            Text("Not recorded for this lane.").foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                }
            }
        }
        .font(WorkbenchTypography.secondary)
        .textSelection(.enabled)
    }

    private func conditionDetails(_ conditions: HostedLaneConditions, hosted: Bool, showsDeviceMemory: Bool) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Memory checked " + conditions.memoryCapturedAt.formatted(date: .abbreviated, time: .standard))
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let memory = conditions.validMemory {
                Text(String(format: "System headroom: ~%.1f GB of %.1f GB unified memory", Double(memory.availableBytes) / 1e9, Double(memory.totalBytes) / 1e9))
                Text(String(format: "Recorded reserve for model fit: %.1f GB. System-wide estimate, including reclaimable pages; model and GPU allocations are unavailable.", Double(conditions.reserveBytes) / 1e9))
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } else { Text("System headroom unknown").foregroundStyle(WorkbenchColor.muted) }
            if hosted {
                hostDetails(conditions)
            }
            if showsDeviceMemory { HostDeviceMemoryDisclosure(snapshot: conditions.deviceMemory) }
            ForEach(conditions.timingCaveats, id: \.self) { caveat in
                Text(caveat).foregroundStyle(WorkbenchColor.warning)
            }
        }
    }

    private func hostDetails(_ conditions: HostedLaneConditions) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let capturedAt = conditions.inventoryCapturedAt {
                Text("Host inventory read " + capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            if let activity = conditions.activity {
                Text("Host activity: " + activity.state.title)
                Text("Activity checked " + activity.checkedAt.formatted(date: .abbreviated, time: .standard))
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if let running = activity.runningCount, let queued = activity.pendingCount {
                    Text("\(running) running · \(queued) queued")
                }
                Text(activity.detail).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } else { Text("Host activity unknown").foregroundStyle(WorkbenchColor.muted) }
            if let models = conditions.loadedModels {
                Text(conditions.loadedStateSummary)
                Text(conditions.unknownResidencyCount.map { "Residency unknown for \($0) \($0 == 1 ? "model" : "models")" } ?? "Residency reporting unknown")
                    .foregroundStyle(WorkbenchColor.muted)
                if !models.isEmpty {
                    DisclosureGroup("Reported loaded models") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                                ForEach(models) { model in
                                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                                        Text(model.name + (model.id == conditions.targetID ? " · selected lane model" : ""))
                                        Text(model.modelID).font(WorkbenchTypography.compactValue)
                                        Text(model.memoryBytes.map { "Host-reported model memory: " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "Model memory unknown")
                                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 180)
                    }
                }
            } else { Text("Loaded model state unknown").foregroundStyle(WorkbenchColor.muted) }
            ForEach(conditions.inventoryWarnings ?? [], id: \.self) { warning in
                Text(warning).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            }
        }
    }
}
