import Foundation

// MARK: - IntakeAPI
//
// Closure seam over WorkbenchAPI so the coordinator is testable without a
// subprocess. `stub(...)` defaults every closure to a throwing placeholder.

struct IntakeAPI {
    var resolve: (String) async throws -> IntakeResolution
    var backends: () async throws -> BackendList
    var installPreview: (String) async throws -> [String: Any]
    var installStart: (String, String) async throws -> [String: Any]
    var fetchPreview: (IntakeFetchRequest) async throws -> [String: Any]
    var fetchStart: (IntakeFetchRequest, String) async throws -> [String: Any]
    var fetchStatus: () async throws -> [FetchJob]
    var portAnalysis: (String) async throws -> PortAnalysis
    var portPlan: (String, String, String) async throws -> PortPlanResult
    var serveStatus: () async throws -> [ServerInfo]

    static func live(api: WorkbenchAPI) -> IntakeAPI {
        IntakeAPI(
            resolve: { try await api.intakeResolve(source: $0) },
            backends: { try await api.backendList() },
            installPreview: { try await api.backendInstallPreview(id: $0) },
            installStart: { try await api.backendInstallStart(id: $0, previewHash: $1) },
            fetchPreview: { try await api.intakeFetchPreview($0) },
            fetchStart: { try await api.intakeFetchStart($0, previewHash: $1) },
            fetchStatus: { try await api.intakeStatus() },
            portAnalysis: { try await api.portAnalysis(source: $0) },
            portPlan: { try await api.portPlan(source: $0, endpoint: $1, model: $2) },
            serveStatus: { try await api.serveStatus() }
        )
    }

    static func stub(
        resolve: @escaping (String) async throws -> IntakeResolution = { _ in throw IntakeStubError.unused },
        backends: @escaping () async throws -> BackendList = { throw IntakeStubError.unused },
        installPreview: @escaping (String) async throws -> [String: Any] = { _ in throw IntakeStubError.unused },
        installStart: @escaping (String, String) async throws -> [String: Any] = { _, _ in throw IntakeStubError.unused },
        fetchPreview: @escaping (IntakeFetchRequest) async throws -> [String: Any] = { _ in throw IntakeStubError.unused },
        fetchStart: @escaping (IntakeFetchRequest, String) async throws -> [String: Any] = { _, _ in throw IntakeStubError.unused },
        fetchStatus: @escaping () async throws -> [FetchJob] = { [] },
        portAnalysis: @escaping (String) async throws -> PortAnalysis = { _ in throw IntakeStubError.unused },
        portPlan: @escaping (String, String, String) async throws -> PortPlanResult = { _, _, _ in throw IntakeStubError.unused },
        serveStatus: @escaping () async throws -> [ServerInfo] = { [] }
    ) -> IntakeAPI {
        IntakeAPI(resolve: resolve, backends: backends, installPreview: installPreview, installStart: installStart,
                  fetchPreview: fetchPreview, fetchStart: fetchStart, fetchStatus: fetchStatus,
                  portAnalysis: portAnalysis, portPlan: portPlan, serveStatus: serveStatus)
    }
}

enum IntakeStubError: LocalizedError {
    case unused
    var errorDescription: String? { "Not available." }
}

// MARK: - IntakeCoordinator

@MainActor
final class IntakeCoordinator: ObservableObject {
    enum Activity: Equatable {
        case idle
        case resolving
        case installing(backend: String)
        case downloading(repo: String)
        case analyzing
        case drafting
        case failed(String)
    }

    @Published var sourceText = ""
    @Published var selectedGGUF: String?
    @Published private(set) var resolution: IntakeResolution?
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var logTail: [String] = []
    @Published private(set) var downloadedPath: String?
    @Published private(set) var analysis: PortAnalysis?
    @Published private(set) var draft: PortPlanResult?
    @Published private(set) var draftServer: ServerInfo?

    private let api: IntakeAPI
    private let pollInterval: Duration
    private let pollLimit: Int
    private static let maxLogLines = 40

    init(api: IntakeAPI, pollInterval: Duration = .seconds(2), pollLimit: Int = 1800) {
        self.api = api
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
    }

    var isBusy: Bool {
        switch activity {
        case .idle, .failed: return false
        default: return true
        }
    }

    static func looksLikeHFLink(_ text: String?) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 2048 else { return false }
        let lowered = trimmed.lowercased()
        let prefixes = ["https://huggingface.co/", "http://huggingface.co/", "https://www.huggingface.co/",
                        "https://hf.co/", "huggingface.co/", "hf.co/"]
        if prefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        }
    }

    func open(with text: String?) {
        if let text { sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        resolution = nil
        analysis = nil
        draft = nil
        draftServer = nil
        downloadedPath = nil
        logTail = []
        activity = .idle
        if Self.looksLikeHFLink(sourceText) {
            Task { await resolve() }
        }
    }

    func resolve() async {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        activity = .resolving
        analysis = nil
        draft = nil
        do {
            let result = try await api.resolve(text)
            resolution = result
            selectedGGUF = result.source.file ?? result.files.gguf.first?.name
            activity = .idle
            if result.verdict == .unsupported {
                await analyze()
            }
        } catch {
            activity = .failed(AppHost.render(error))
        }
    }

    func installBackend() async {
        guard let backend = resolution?.backend else { return }
        activity = .installing(backend: backend)
        logTail = []
        do {
            let plan = try await api.installPreview(backend)
            guard let hash = plan["preview_hash"] as? String, !hash.isEmpty else {
                activity = .failed("The install preview did not include a preview hash.")
                return
            }
            _ = try await api.installStart(backend, hash)
            for _ in 0..<pollLimit {
                let list = try await api.backends()
                guard let entry = list.backends.first(where: { $0.id == backend }) else { break }
                logTail = Self.tail(of: entry.logPath)
                switch entry.state {
                case .installing:
                    try await Task.sleep(for: pollInterval)
                case .installed:
                    activity = .idle
                    await resolve()
                    return
                case .failed, .absent:
                    activity = .failed("Installing \(backend) failed. See \(entry.logPath ?? "the install log").")
                    return
                }
            }
            activity = .failed("Installing \(backend) did not finish in time.")
        } catch {
            activity = .failed(AppHost.render(error))
        }
    }

    func download(localDir: String?) async -> String? {
        guard let resolution else { return nil }
        let request = IntakeFetchRequest(
            source: resolution.source.repo,
            revision: resolution.source.revision,
            file: resolution.verdict == .gguf ? selectedGGUF : nil,
            localDir: localDir
        )
        activity = .downloading(repo: resolution.source.repo)
        logTail = []
        do {
            let plan = try await api.fetchPreview(request)
            guard let hash = plan["preview_hash"] as? String, !hash.isEmpty else {
                activity = .failed("The download preview did not include a preview hash.")
                return nil
            }
            _ = try await api.fetchStart(request, hash)
            for _ in 0..<pollLimit {
                let job = try await api.fetchStatus().last { $0.repo == request.source && $0.file == request.file }
                logTail = Self.tail(of: job?.logPath)
                switch job?.state {
                case "done":
                    activity = .idle
                    downloadedPath = job?.path
                    return job?.path
                case "failed":
                    activity = .failed("The download failed. See \(job?.logPath ?? "the download log").")
                    return nil
                default:
                    try await Task.sleep(for: pollInterval)
                }
            }
            activity = .failed("The download did not finish in time.")
        } catch {
            activity = .failed(AppHost.render(error))
        }
        return nil
    }

    func analyze() async {
        guard let resolution else { return }
        activity = .analyzing
        do {
            analysis = try await api.portAnalysis(resolution.source.repo)
            draftServer = try? await api.serveStatus().first { $0.state?.lowercased() == "running" && $0.port != nil }
            activity = .idle
        } catch {
            activity = .failed(AppHost.render(error))
        }
    }

    func draftPlan() async {
        guard let resolution, let server = draftServer, let port = server.port else { return }
        activity = .drafting
        do {
            draft = try await api.portPlan(resolution.source.repo, "http://127.0.0.1:\(port)", server.modelIdentity)
            activity = .idle
        } catch {
            activity = .failed(AppHost.render(error))
        }
    }

    static func tail(of path: String?) -> [String] {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(maxLogLines).map(String.init))
    }
}
