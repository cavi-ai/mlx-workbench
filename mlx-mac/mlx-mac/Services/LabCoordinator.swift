import Foundation
import AppKit

@MainActor
final class LabCoordinator: ObservableObject {
    @Published private(set) var snapshot = LabResponse()
    @Published private(set) var studies: [LabStudyRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var runningJobID: String?
    @Published var error: String?
    @Published var notice: String?
    private let api: WorkbenchAPI
    private let defaults: UserDefaults
    private var workspaceRevision = 0
    private var refreshRevision = 0
    @Published private(set) var store: URL
    let reviewerID: String

    init(api: WorkbenchAPI, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        let defaultStore = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mlx-agent/lab", isDirectory: true)
        store = defaults.string(forKey: "mlx-workbench.lab-store").map { URL(fileURLWithPath: $0) } ?? defaultStore
        if let identity = defaults.string(forKey: "mlx-workbench.lab-reviewer") { reviewerID = identity }
        else {
            reviewerID = "workbench-" + UUID().uuidString
            defaults.set(reviewerID, forKey: "mlx-workbench.lab-reviewer")
        }
    }
    func chooseStore() async {
        guard runningJobID == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use workspace"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        await useStore(chosen.resolvingSymlinksInPath())
    }
    func useStore(_ chosen: URL) async {
        workspaceRevision += 1
        refreshRevision += 1
        isRefreshing = false
        store = chosen
        defaults.set(store.path, forKey: "mlx-workbench.lab-store")
        snapshot = LabResponse()
        studies = []
        error = nil
        notice = nil
        await refresh()
    }
    func recover() async {
        guard runningJobID == nil else { return }
        let revision = workspaceRevision
        do {
            _ = try await request(LabRequest(operation: "recover", workerID: reviewerID))
            guard revision == workspaceRevision else { return }
            await refresh()
        } catch {
            guard revision == workspaceRevision else { return }
            self.error = AppHost.render(error)
        }
    }
    func request(_ request: LabRequest) async throws -> LabResponse {
        try await api.labWorkspace(request: request, store: store, reviewer: reviewerID)
    }
    func refresh() async {
        guard !isRefreshing else { return }
        refreshRevision += 1
        let revision = refreshRevision, workspace = store
        isRefreshing = true
        defer { if revision == refreshRevision { isRefreshing = false } }
        do {
            let nextSnapshot = try await api.labWorkspace(request: LabRequest(operation: "snapshot"), store: workspace, reviewer: reviewerID)
            guard revision == refreshRevision else { return }
            let response = try await api.labWorkspace(request: LabRequest(operation: "study-list"), store: workspace, reviewer: reviewerID)
            guard revision == refreshRevision else { return }
            snapshot = nextSnapshot
            studies = response.studies?.compactMap(LabStudyRow.init(value:)) ?? []
            error = nil
        }
        catch {
            guard revision == refreshRevision, !(error is CancellationError) else { return }
            self.error = AppHost.render(error)
        }
    }
    func run(_ job: LabJob) async {
        guard runningJobID == nil else { return }
        let revision = workspaceRevision
        runningJobID = job.id
        defer { runningJobID = nil }
        do {
            let result = try await request(LabRequest(operation: "run", jobID: job.id, workerID: reviewerID))
            guard revision == workspaceRevision else { return }
            let failure = result.status == "failed" ? (result.errorMessage ?? result.errorCode ?? "Generation failed.") : nil
            notice = "Job " + (result.status ?? "returned")
            await refresh()
            guard revision == workspaceRevision else { return }
            if let failure { error = failure }
        } catch {
            guard revision == workspaceRevision else { return }
            self.error = AppHost.render(error)
        }
    }
    func cancel(_ job: LabJob) async {
        let revision = workspaceRevision
        do {
            _ = try await request(LabRequest(operation: "cancel", jobID: job.id))
            guard revision == workspaceRevision else { return }
            await refresh()
        } catch {
            guard revision == workspaceRevision else { return }
            self.error = AppHost.render(error)
        }
    }
}
