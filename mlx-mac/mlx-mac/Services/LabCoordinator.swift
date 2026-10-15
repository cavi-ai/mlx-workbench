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
        store = chosen
        defaults.set(store.path, forKey: "mlx-workbench.lab-store")
        snapshot = LabResponse()
        studies = []
        await refresh()
    }
    func recover() async {
        guard runningJobID == nil else { return }
        do {
            _ = try await request(LabRequest(operation: "recover", workerID: reviewerID))
            await refresh()
        } catch { self.error = AppHost.render(error) }
    }
    func request(_ request: LabRequest) async throws -> LabResponse {
        try await api.labWorkspace(request: request, store: store, reviewer: reviewerID)
    }
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await request(LabRequest(operation: "snapshot"))
            let response = try await request(LabRequest(operation: "study-list"))
            studies = response.studies?.compactMap(LabStudyRow.init(value:)) ?? []
            error = nil
        }
        catch { self.error = AppHost.render(error) }
    }
    func run(_ job: LabJob) async {
        guard runningJobID == nil else { return }
        runningJobID = job.id
        defer { runningJobID = nil }
        do {
            let result = try await request(LabRequest(operation: "run", jobID: job.id, workerID: reviewerID))
            let failure = result.status == "failed" ? (result.errorMessage ?? result.errorCode ?? "Generation failed.") : nil
            notice = "Job " + (result.status ?? "returned")
            await refresh()
            if let failure { error = failure }
        } catch { self.error = AppHost.render(error) }
    }
    func cancel(_ job: LabJob) async {
        do { _ = try await request(LabRequest(operation: "cancel", jobID: job.id)); await refresh() }
        catch { self.error = AppHost.render(error) }
    }
}
