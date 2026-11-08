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
    @Published private(set) var completedFetch: FetchJob?
    @Published private(set) var downloadedPath: String?
    @Published private(set) var analysis: PortAnalysis?
    @Published private(set) var draft: PortPlanResult?
    @Published private(set) var draftServer: ServerInfo?

    private let api: IntakeAPI
    private let pollInterval: Duration
    private let pollLimit: Int
    private let validateDestination: (String) async throws -> Void
    private static let maxLogLines = 40

    init(api: IntakeAPI, pollInterval: Duration = .seconds(2), pollLimit: Int = 1800,
         validateDestination: @escaping (String) async throws -> Void = { path in
             try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.refuseLinks(in: path) } }.get()
         }) {
        self.api = api
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
        self.validateDestination = validateDestination
    }

    var isBusy: Bool {
        switch activity {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// Only the exact immutable snapshot can satisfy a resolved source.
    nonisolated static func readyCachePath(repo: String, revision: String, readyPaths: Set<String>) -> String? {
        guard ModelUpdateReview.isCommit(revision) else { return nil }
        return readyPaths.sorted().first { path in
            HFRepoID.forPath(path)?.caseInsensitiveCompare(repo) == .orderedSame &&
            (path.contains("/snapshots/\(revision.lowercased())/") || path.hasSuffix("/snapshots/\(revision.lowercased())"))
        }
    }

    static func existingModelPath(_ resolution: IntakeResolution, qBits: Int, history: [ConversionWorkflow], readyPaths: Set<String>, selectedFile: String? = nil) -> String? {
        if resolution.verdict == .gguf {
            guard let file = resolution.source.file ?? selectedFile else { return nil }
            return readyPaths.sorted().first { sourceMatches($0, resolution: resolution, selectedFile: file) }
        }
        if resolution.verdict == .alreadyMLX {
            return readyPaths.sorted().first { sourceMatches($0, resolution: resolution) }
        }
        return existingConversion(resolution, qBits: qBits, history: history, readyPaths: readyPaths)
            .map { $0.completedModelPath ?? $0.outputPath }
    }

    /// The newest finished conversion of this repo at the resolved width whose output is still ready.
    static func existingConversion(_ resolution: IntakeResolution, qBits: Int, history: [ConversionWorkflow], readyPaths: Set<String>) -> ConversionWorkflow? {
        guard resolution.verdict == .convertible else { return nil }
        let bits = ModelWorkflowCoordinator.allowedBits(qBits, allowed: resolution.qBits)
        return history.sorted { $0.updatedAt > $1.updatedAt }.first { record in
            record.sourcePath == "hf://\(resolution.source.reference)" && record.destinationBits == bits &&
            record.localSourcePath.map { sourceMatches($0, resolution: resolution) } == true &&
            (record.state == .verified || record.state == .completed || record.state == .existingModelFound) &&
            readyPaths.contains(record.completedModelPath ?? record.outputPath)
        }
    }

    nonisolated static func sourceMatches(_ path: String, resolution: IntakeResolution, selectedFile: String? = nil) -> Bool {
        let source = resolution.source
        let file = source.file ?? selectedFile
        guard ModelUpdateReview.isCommit(source.fetchRevision) else { return false }
        if let cached = ManagedModelInstallStore.cacheSelection(path: path, repo: source.repo) {
            return cached.revision.lowercased() == source.fetchRevision.lowercased() &&
                cached.file == file && cached.subfolder == source.subfolder
        }
        guard let directory = ManagedModelInstallStore.directory(root: "/intake", source: source, file: file) else { return false }
        let suffix = String(directory.dropFirst("/intake".count)) + ((file ?? source.subfolder).map { "/" + $0 } ?? "")
        return path.hasSuffix(suffix)
    }

    /// A recorded download of `resolution`'s source while it is still the cached snapshot of the resolved revision.
    nonisolated static func reusableSource(_ path: String?, for resolution: IntakeResolution, fileManager: FileManager = .default) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var snapshotPath = path
        if let subfolder = resolution.source.subfolder, !subfolder.isEmpty {
            guard path.hasSuffix("/" + subfolder) else { return nil }
            snapshotPath = String(path.dropLast(subfolder.count + 1))
        }
        let snapshot = URL(fileURLWithPath: snapshotPath)
        let snapshots = snapshot.deletingLastPathComponent()
        guard snapshots.lastPathComponent == "snapshots" else { return nil }
        let revision = resolution.source.fetchRevision
        let ref = snapshots.deletingLastPathComponent().appendingPathComponent("refs").appendingPathComponent(revision)
        let current = revision == snapshot.lastPathComponent
            ? revision
            : (try? String(contentsOf: ref, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard current == snapshot.lastPathComponent,
              fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
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
        guard !isBusy else { return }
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
        guard !isBusy else { return }
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
                case .unknown:
                    activity = .failed("The engine returned an unknown installation state for \(backend). Refresh its status before retrying.")
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
        return try? await download(resolution: resolution, localDir: localDir, previewHash: nil)
    }

    func download(resolution: IntakeResolution, localDir: String?, previewHash: String?, additionalFiles: [String] = []) async throws -> String {
        guard !isBusy else { throw WorkflowEvidenceError.invalid("Another intake operation is active.") }
        let request = IntakeFetchRequest(
            source: resolution.source.reference,
            revision: resolution.source.fetchRevision,
            file: resolution.source.file ?? (resolution.verdict == .gguf ? selectedGGUF : nil),
            localDir: localDir,
            modelType: resolution.verdict == .gguf ? nil : resolution.modelType,
            additionalFiles: additionalFiles.sorted()
        )
        activity = .downloading(repo: resolution.source.repo)
        completedFetch = nil
        logTail = []
        do {
            if let localDir {
                try await validateDestination(localDir)
            }
            let plan = try await api.fetchPreview(request)
            guard let hash = plan["preview_hash"] as? String, !hash.isEmpty,
                  previewHash == nil || previewHash == hash else {
                throw WorkflowEvidenceError.invalid("The download preview changed. Review the current source before continuing.")
            }
            let storage = plan["storage"] as? [String: Any]
            let reusing = storage?["mode"] as? String == "reuse"
            let effectiveDirectory = plan["local_dir"] as? String ?? request.localDir
            if let localDir, FileManager.default.fileExists(atPath: localDir), !reusing {
                throw WorkflowEvidenceError.invalid("The destination already exists. Use the current library copy or review a separate update instead of overwriting it.")
            }
            if let effectiveDirectory, effectiveDirectory != localDir { try await validateDestination(effectiveDirectory) }
            let started = try await api.fetchStart(request, hash)
            guard let receipt = started["receipt"] as? [String: Any],
                  let slug = receipt["slug"] as? String, !slug.isEmpty,
                  let startedAt = receipt["started_at"] as? String, !startedAt.isEmpty,
                  (receipt["repo"] as? String)?.caseInsensitiveCompare(resolution.source.repo) == .orderedSame,
                  receipt["revision"] as? String == request.revision,
                  receipt["file"] as? String == request.file,
                  (receipt["additional_files"] as? [String] ?? []) == request.additionalFiles,
                  receipt["subfolder"] as? String == resolution.source.subfolder,
                  receipt["local_dir"] as? String == effectiveDirectory else {
                throw WorkflowEvidenceError.invalid("The download receipt did not match this request. Refresh download status before retrying.")
            }
            if started["status"] as? String == "reused" {
                guard reusing, let payload = started["reused_fetch"] as? [String: Any] else {
                    throw WorkflowEvidenceError.invalid("The engine did not bind reuse to the reviewed source.")
                }
                let job = try JSONDecoder().decode(FetchJob.self, from: JSONSerialization.data(withJSONObject: payload))
                guard job.receipt == storage?["receipt"] as? String, job.state == "done",
                      job.repo == receipt["repo"] as? String, job.revision == request.revision,
                      job.file == request.file, job.subfolder == resolution.source.subfolder,
                      (job.additionalFiles ?? []) == request.additionalFiles,
                      job.localDir == effectiveDirectory, job.path == effectiveDirectory,
                      job.startedAt == startedAt, job.previewHash == receipt["preview_hash"] as? String,
                      job.previewHash?.isEmpty == false,
                      URL(fileURLWithPath: job.receipt).deletingPathExtension().lastPathComponent == slug else {
                    throw WorkflowEvidenceError.invalid("The reused source does not match its original completed receipt.")
                }
                guard let path = job.path else { throw WorkflowEvidenceError.invalid("The reused source has no path.") }
                activity = .idle; downloadedPath = path; completedFetch = job
                return path
            }
            guard !reusing else { throw WorkflowEvidenceError.invalid("The engine started a download instead of reusing the reviewed source.") }
            for _ in 0..<pollLimit {
                let job = try await api.fetchStatus().last {
                    URL(fileURLWithPath: $0.receipt).deletingPathExtension().lastPathComponent == slug &&
                    $0.startedAt == startedAt && $0.repo == resolution.source.repo && $0.revision == request.revision &&
                    $0.file == request.file && ($0.additionalFiles ?? []) == request.additionalFiles &&
                    $0.subfolder == resolution.source.subfolder && $0.localDir == effectiveDirectory
                }
                logTail = Self.tail(of: job?.logPath)
                switch job?.state {
                case "done":
                    activity = .idle
                    guard let path = job?.path else { throw WorkflowEvidenceError.invalid("The finished download has no path.") }
                    downloadedPath = path
                    completedFetch = job
                    return path
                case "failed":
                    throw WorkflowEvidenceError.invalid("The download failed. See \(job?.logPath ?? "the download log").")
                default:
                    try await Task.sleep(for: pollInterval)
                }
            }
            throw WorkflowEvidenceError.invalid("The download did not finish in time. Refresh its status before retrying.")
        } catch {
            activity = .failed(AppHost.render(error))
            throw error
        }
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
