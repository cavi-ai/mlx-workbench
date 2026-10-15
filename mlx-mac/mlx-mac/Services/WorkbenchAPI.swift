import Foundation
import Darwin

// MARK: - WorkbenchAPI
//
// Typed wrapper over CLIProcess mirroring mlx_workbench/bridge.py. Every method
// runs one mlx-agent subcommand, then decodes the unwrapped `data` payload.

actor WorkbenchAPI {
    /// One blocking mlx-agent invocation returning the unwrapped `data` payload.
    typealias AgentCommand = @Sendable (_ agentPath: String, _ argv: [String], _ isScout: Bool, _ timeout: TimeInterval?) throws -> [String: Any]

    private let cli: CLIProcess
    private let command: AgentCommand?
    private var agentPath: String
    private let receiptDirectory: String

    init(
        cli: CLIProcess,
        agentPath: String,
        receiptDirectory: String = WorkbenchStatePaths.applicationSupport().path,
        command: AgentCommand? = nil
    ) {
        self.cli = cli
        self.command = command
        self.agentPath = agentPath
        self.receiptDirectory = receiptDirectory
    }

    func setAgentPath(_ path: String) {
        agentPath = path
    }

    var resolvedAgentPath: String { agentPath }

    // MARK: - Raw

    /// Blocking subprocess waits belong on a dispatch worker, not Swift's cooperative pool.
    /// Suspending this actor also lets serve status, scan and endpoint reconciliation proceed.
    func raw(_ argv: [String], isScout: Bool = false, timeout: TimeInterval? = nil, cancellable: Bool = false) async throws -> [String: Any] {
        let command = self.command
        let cli = self.cli
        let agentPath = self.agentPath
        let cancellation = cancellable ? CLIInvocationCancellation() : nil
        return try await withTaskCancellationHandler {
            if cancellable { try Task.checkCancellation() }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        if cancellation?.isRequested == true { throw CancellationError() }
                        let result: [String: Any]
                        if let command { result = try command(agentPath, argv, isScout, timeout) }
                        else { result = try cli.run(agentPath: agentPath, argv: argv, isScout: isScout, timeout: timeout, cancellation: cancellation) }
                        if cancellation?.isRequested == true { throw CancellationError() }
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation?.cancel() }
    }

    private func runOffActor<T: Decodable & Sendable>(_ type: T.Type, _ argv: [String], timeout: TimeInterval) async throws -> T {
        try Self.decode(type, from: await raw(argv, timeout: timeout, cancellable: true))
    }

    func health() -> (ok: Bool, path: String, cli: String, message: String) {
        return cli.agentHealth(agentPath: agentPath)
    }

    /// Experiment operations share the agent's durable store and sealed projections.
    func labWorkspace(request: LabRequest, store: URL, reviewer: String) async throws -> LabResponse {
        let requestDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: requestDirectory) }
        let file = requestDirectory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        return try await runOffActor(LabResponse.self, [
            "lab", "--database", store.appendingPathComponent("experiments.sqlite3").path,
            "--artifacts", store.appendingPathComponent("artifacts").path,
            "--reviewer-id", reviewer, "workspace", "--request", file.path
        ], timeout: ["run", "training-evaluate", "study-run"].contains(request.operation) ? 86_400 : 300)
    }

    func conversionQueue(_ request: LabValue) async throws -> QueueResponse {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        return try await runOffActor(QueueResponse.self, [
            "lab", "queue", "--receipts-dir", receiptDirectory, "--request", file.path
        ], timeout: 300)
    }

    // MARK: - Scan

    func scan(ggufRoots: [String], mlxRoots: [String], signatures: Bool,
              limit: Int? = nil) async throws -> ScanResult {
        var argv = ["convert", "scan"]
        for root in ggufRoots {
            argv.append(contentsOf: ["--gguf-root", root])
        }
        for root in mlxRoots {
            argv.append(contentsOf: ["--mlx-root", root])
        }
        if !signatures {
            argv.append("--no-signature")
        }
        if let limit {
            argv.append(contentsOf: ["--limit", String(limit)])
        }
        let data = try await raw(argv)
        return try Self.decodeScan(data)
    }

    // MARK: - Convert

    /// Convert/serve/lora/fuse previews wrap their plan in
    /// `{plan, requires_confirmation}` (observed mlx-agent ≥ v0.5.x); the
    /// preview hash and plan fields live inside `plan`. Older agents returned
    /// the fields at the top level — accept both.
    static func unwrapPlan(_ data: [String: Any]) -> [String: Any] {
        if let plan = data["plan"] as? [String: Any], plan["preview_hash"] != nil {
            return plan
        }
        return data
    }

    func convertPreview(ggufPath: String, qBits: Int, out: String?) async throws -> [String: Any] {
        var argv = ["convert", "start", "--gguf", ggufPath, "--q-bits", String(qBits)]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return Self.unwrapPlan(try await raw(argv))
    }

    func convertRepoPreview(repo: String, qBits: Int, out: String?,
                            hfCache: String?, backend: String? = nil, modelType: String? = nil,
                            subfolder: String? = nil, sourcePath: String? = nil) async throws -> [String: Any] {
        var argv = ["convert", "start", "--repo", repo, "--q-bits", String(qBits)]
        if let out { argv.append(contentsOf: ["--out", out]) }
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        if let backend { argv.append(contentsOf: ["--backend", backend]) }
        if let modelType { argv.append(contentsOf: ["--model-type", modelType]) }
        if let subfolder { argv.append(contentsOf: ["--subfolder", subfolder]) }
        if let sourcePath { argv.append(contentsOf: ["--source-path", sourcePath]) }
        return Self.unwrapPlan(try await raw(argv))
    }

    func convertStart(ggufPath: String, qBits: Int, out: String?,
                      previewHash: String) async throws -> [String: Any] {
        var argv = [
            "convert", "start", "--gguf", ggufPath, "--q-bits", String(qBits),
            "--confirm", "--preview-hash", previewHash,
            // Without this the agent derives its receipts dir from the CWD,
            // which for a GUI app is "/" — a read-only filesystem.
            "--receipts-dir", receiptDirectory,
        ]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try await raw(argv)
    }

    func convertRepoStart(repo: String, qBits: Int, out: String?,
                          hfCache: String?, previewHash: String,
                          backend: String? = nil, modelType: String? = nil, subfolder: String? = nil, sourcePath: String? = nil) async throws -> [String: Any] {
        var argv = [
            "convert", "start", "--repo", repo, "--q-bits", String(qBits),
            "--confirm", "--preview-hash", previewHash,
            "--receipts-dir", receiptDirectory,
        ]
        if let out { argv.append(contentsOf: ["--out", out]) }
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        if let backend { argv.append(contentsOf: ["--backend", backend]) }
        if let modelType { argv.append(contentsOf: ["--model-type", modelType]) }
        if let subfolder { argv.append(contentsOf: ["--subfolder", subfolder]) }
        if let sourcePath { argv.append(contentsOf: ["--source-path", sourcePath]) }
        return try await raw(argv)
    }

    // MARK: - Intake

    static func decode<T: Decodable>(_ type: T.Type, from data: [String: Any]) throws -> T {
        let json = try JSONSerialization.data(withJSONObject: data)
        return try JSONDecoder().decode(T.self, from: json)
    }

    /// One clip through a converted speech model (`convert transcribe`, read-only).
    func transcribe(path: String, audio: String, language: String?) async throws -> TranscriptionResult {
        var argv = ["convert", "transcribe", "--path", path, "--audio", audio]
        if let language { argv += ["--language", language] }
        return try await runOffActor(TranscriptionResult.self, argv, timeout: 600)
    }

    /// Typed questions about a state answered by a converted classification model (`convert decide`, read-only).
    func decide(path: String, request: String) async throws -> DecisionResult {
        try await runOffActor(DecisionResult.self, ["convert", "decide", "--path", path, "--request", request], timeout: 600)
    }

    /// One prompt rendered to a new PNG by a converted image model (`convert generate`).
    func generate(path: String, out: String, request: ImageRequest) async throws -> GenerationResult {
        try await runOffActor(GenerationResult.self, [
            "convert", "generate", "--path", path, "--prompt", request.prompt, "--out", out,
            "--width", String(request.size), "--height", String(request.size),
            "--steps", String(request.steps), "--seed", String(request.seed), "--timeout", "3600",
        ], timeout: 3700)
    }

    static func speakArguments(path: String, text: String, out: String) -> [String] {
        ["convert", "speak", "--path", path, "--text=\(text)", "--out", out, "--timeout", "600"]
    }

    static func musicArguments(path: String, caption: String, out: String, parameters: MediaParameters) -> [String] {
        ["convert", "music", "--path", path, "--caption=\(caption)", "--lyrics=\(parameters.lyrics ?? "[instrumental]")",
         "--out", out, "--duration", String(parameters.durationSeconds ?? 15), "--steps", String(parameters.steps ?? 30),
         "--seed", String(parameters.seed ?? 42), "--timeout", "3600"]
    }

    func music(path: String, caption: String, out: String, parameters: MediaParameters) async throws -> SpeakResult {
        try await runOffActor(SpeakResult.self, Self.musicArguments(path: path, caption: caption, out: out, parameters: parameters), timeout: 3700)
    }

    /// One sentence spoken into a new WAV by a converted text-to-speech model (`convert speak`).
    /// The text is one `--text=` token so a sentence that starts with a dash still parses.
    func speak(path: String, text: String, out: String) async throws -> SpeakResult {
        try await runOffActor(SpeakResult.self, Self.speakArguments(path: path, text: text, out: out), timeout: 700)
    }

    /// Videos shrink to this many pixels per frame: at the agent's default cap the 3B vision model mis-describes the clip.
    static let describeVideoMaxPixels = 200_704

    static func describeArguments(path: String, prompt: String, image: String?, video: String?, maxTokens: Int) -> [String] {
        var argv = [
            "convert", "describe", "--path", path, "--prompt=\(prompt)",
            "--max-tokens", String(maxTokens), "--timeout", "900",
        ]
        if let image { argv += ["--image", image] }
        if let video { argv += ["--video", video, "--max-pixels", String(describeVideoMaxPixels)] }
        return argv
    }

    /// One question about an image or a video answered by a converted vision-language model (`convert describe`).
    func describe(path: String, prompt: String, image: String?, video: String?, maxTokens: Int) async throws -> DescribeResult {
        try await runOffActor(
            DescribeResult.self,
            Self.describeArguments(path: path, prompt: prompt, image: image, video: video, maxTokens: maxTokens),
            timeout: 1000
        )
    }

    static func videoArguments(path: String, prompt: String, out: String, parameters: MediaParameters) -> [String] {
        var argv = ["convert", "video", "--path", path, "--prompt=\(prompt)", "--out", out, "--timeout", "3600"]
        if let width = parameters.width ?? parameters.size { argv += ["--width", String(width)] }
        if let height = parameters.height ?? parameters.size { argv += ["--height", String(height)] }
        if let frames = parameters.frames { argv += ["--frames", String(frames)] }
        if let fps = parameters.fps { argv += ["--fps", String(fps)] }
        if let steps = parameters.steps { argv += ["--steps", String(steps)] }
        if let seed = parameters.seed { argv += ["--seed", String(seed)] }
        return argv
    }

    /// One prompt rendered into a new MP4 by a converted video model (`convert video`).
    func video(path: String, prompt: String, out: String, parameters: MediaParameters) async throws -> VideoResult {
        try await runOffActor(
            VideoResult.self,
            Self.videoArguments(path: path, prompt: prompt, out: out, parameters: parameters),
            timeout: 3700
        )
    }

    func intakeResolve(source: String) async throws -> IntakeResolution {
        try Self.decode(IntakeResolution.self, from: await raw(["intake", "resolve", source], timeout: 45))
    }

    func backendList() async throws -> BackendList {
        try Self.decode(BackendList.self, from: await raw(["backend", "list", "--receipts-dir", receiptDirectory]))
    }

    func backendInstallPreview(id: String) async throws -> [String: Any] {
        Self.unwrapPlan(try await raw(["backend", "install", id, "--receipts-dir", receiptDirectory]))
    }

    func backendInstallStart(id: String, previewHash: String) async throws -> [String: Any] {
        try await raw(["backend", "install", id, "--confirm", "--preview-hash", previewHash,
                       "--receipts-dir", receiptDirectory])
    }

    private static func fetchArguments(_ request: IntakeFetchRequest) -> [String] {
        var argv = ["intake", "fetch", request.source, "--revision", request.revision]
        if let file = request.file { argv += ["--file", file] }
        if let localDir = request.localDir { argv += ["--local-dir", localDir] }
        if request.file == nil, let modelType = request.modelType { argv += ["--model-type", modelType] }
        return argv
    }

    func intakeFetchPreview(_ request: IntakeFetchRequest) async throws -> [String: Any] {
        Self.unwrapPlan(try await raw(Self.fetchArguments(request) + ["--receipts-dir", receiptDirectory]))
    }

    func intakeFetchStart(_ request: IntakeFetchRequest, previewHash: String) async throws -> [String: Any] {
        try await raw(Self.fetchArguments(request) + ["--confirm", "--preview-hash", previewHash,
                                                      "--receipts-dir", receiptDirectory])
    }

    func intakeStatus() async throws -> [FetchJob] {
        let data = try await raw(["intake", "status", "--receipts-dir", receiptDirectory])
        let jobs = (data["jobs"] as? [[String: Any]]) ?? []
        return try jobs.map { try Self.decode(FetchJob.self, from: $0) }
    }

    func portAnalysis(source: String) async throws -> PortAnalysis {
        try Self.decode(PortAnalysis.self, from: await raw(["intake", "port-analysis", source], timeout: 90))
    }

    func portPlan(source: String, endpoint: String, model: String) async throws -> PortPlanResult {
        try Self.decode(PortPlanResult.self, from: await raw(
            ["intake", "port-plan", source, "--endpoint", endpoint, "--model", model],
            timeout: 960
        ))
    }

    // MARK: - Jobs

    func convertStatus() async throws -> [Job] {
        let data = try await raw(["convert", "status", "--receipts-dir", receiptDirectory])
        return Self.jobs(from: data) ?? []
    }

    func serveStatus() async throws -> [ServerInfo] {
        let data = try await raw(["serve", "status", "--receipts-dir", receiptDirectory])
        return Self.servers(from: data) ?? []
    }

    /// Removal cannot treat an unreadable status response as an empty fleet.
    func servingPathsForRemoval() async throws -> [String] {
        try Self.servingPathsForRemoval(from: await raw(["serve", "status", "--receipts-dir", receiptDirectory]))
    }

    static func servingPathsForRemoval(from data: [String: Any]) throws -> [String] {
        guard let servers = Self.servers(from: data), servers.allSatisfy({ !$0.modelIdentity.isEmpty }) else {
            throw BridgeError.remote(code: "invalid_serve_status", message: "Serving status could not be read safely; model deletion was refused.", remediation: "Refresh Health and retry.")
        }
        return servers.map(\.modelIdentity)
    }

    func allJobs() async throws -> [Job] {
        let data = try await raw(["convert", "status", "--receipts-dir", receiptDirectory])
        return Self.jobs(from: data, key: "jobs") ?? []
    }

    // MARK: - Discover

    func discover(role: String?, limit: Int?, fast: Bool, new: Bool) async throws -> DiscoverResult {
        var argv = ["discover"]
        if let role { argv.append(contentsOf: ["--role", role]) }
        if let limit { argv.append(contentsOf: ["--limit", String(limit)]) }
        if fast { argv.append("--fast") }
        if new { argv.append("--new") }
        let data = try await raw(argv, isScout: true)
        return DiscoverResult(candidates: Self.candidates(from: data))
    }

    // MARK: - Doctor

    func doctor(wiredRoots: [String], hfCache: String?) async throws -> DoctorResult {
        var argv = ["doctor", "models"]
        for root in wiredRoots {
            argv.append(contentsOf: ["--wired-root", root])
        }
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        let data = try await raw(argv)
        return Self.doctor(from: data)
    }

    func doctorPrunePreview(hfCache: String?) async throws -> DoctorResult {
        var argv = ["doctor", "models", "--prune"]
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        let data = try await raw(argv)
        return Self.doctor(from: data)
    }

    func doctorPruneConfirm(previewHash: String, hfCache: String?) async throws -> DoctorResult {
        var argv = [
            "doctor", "models", "--prune",
            "--confirm", "--preview-hash", previewHash,
        ]
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        let data = try await raw(argv)
        return Self.doctor(from: data)
    }

    // MARK: - Adopt

    func adoptStart(role: String?, state: String, fast: Bool, offline: Bool) async throws -> AdoptResult {
        let parent = URL(fileURLWithPath: state).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var argv = ["adopt", "start"]
        if let role { argv.append(contentsOf: ["--role", role]) }
        argv.append(contentsOf: ["--state", state])
        if fast { argv.append("--fast") }
        if offline { argv.append("--offline") }
        let data = try await raw(argv, isScout: true)
        return Self.adopt(from: data, statePath: state)
    }

    func adoptStatus(state: String) async throws -> AdoptResult {
        let data = try await raw(["adopt", "status", "--state", state])
        return Self.adopt(from: data, statePath: state)
    }

    static func adopt(from data: [String: Any], statePath: String? = nil) -> AdoptResult {
        let nestedState = data["state"] as? [String: Any]
        let s = nestedState ?? data
        let request = (s["request"] as? [String: Any]) ?? [:]
        let role = (request["roles"] as? [String])?.first ?? s.string("role")
        let recommendations = (s["recommendations"] as? [[String: Any]]) ?? []
        let model = recommendations.first?.string("repo")
            ?? (nestedState == nil ? s.string("model") : nil)
        return AdoptResult(
            state: statePath ?? (nestedState == nil ? s.string("state") : nil),
            role: role,
            model: model,
            status: s.string("status"),
            message: s.string("message") ?? data.string("message"),
            manager: s.string("manager"),
            workflowID: s.string("workflow_id"),
            phase: s.string("phase"),
            evidenceStrength: recommendations.first?.string("evidence_strength")
        )
    }

    // MARK: - Wire

    func wirePreview(model: String, path: String, target: String) async throws -> WireResult {
        let data = try await raw(["wire", "apply", model, "--path", path, "--target", target])
        let preview = (data["preview"] as? [String: Any]) ?? data
        return WireResult(preview_hash: preview.string("preview_hash"),
                          config: preview["config"] as? [String: Any]
                              ?? (preview["diff"] as? [String: Any]),
                          applied: data.bool("applied"))
    }

    func wireApply(model: String, path: String, previewHash: String,
                   target: String) async throws -> WireResult {
        let data = try await raw([
            "wire", "apply", model, "--path", path, "--target", target,
            "--confirm", "--preview-hash", previewHash,
        ])
        let preview = (data["preview"] as? [String: Any]) ?? data
        let applied = data.bool("applied") ?? (data["receipt"] != nil)
        return WireResult(preview_hash: preview.string("preview_hash"),
                          config: preview["config"] as? [String: Any]
                              ?? (preview["diff"] as? [String: Any]),
                          applied: applied)
    }

    // MARK: - Fleet router (spec 09 P4)

    /// Render the per-role router config without mutating anything.
    /// Requires an mlx-agent with `--port-map` support (fleet ≥ the
    /// port-map change); older agents fail the call with a classified
    /// argparse error the UI surfaces as "update mlx-agent".
    func fleetRender(path: String, assignments: [(role: String, repo: String, port: Int)]) async throws -> [String: Any] {
        try await raw(fleetArgv("render", path: path, assignments: assignments))
    }

    /// Preview the router-config write (no --confirm): data carries
    /// `preview.preview_hash` and `preview.diff` for review.
    func fleetApplyPreview(path: String, assignments: [(role: String, repo: String, port: Int)]) async throws -> [String: Any] {
        try await raw(fleetArgv("apply", path: path, assignments: assignments))
    }

    /// Apply a previously reviewed preview; the hash must match exactly.
    func fleetApplyConfirm(path: String, assignments: [(role: String, repo: String, port: Int)],
                           previewHash: String) async throws -> [String: Any] {
        try await raw(fleetArgv("apply", path: path, assignments: assignments,
                                extra: ["--confirm", "--preview-hash", previewHash]))
    }

    private func fleetArgv(_ action: String, path: String,
                           assignments: [(role: String, repo: String, port: Int)],
                           extra: [String] = []) -> [String] {
        var argv = ["fleet", action, "--path", path]
        for assignment in assignments {
            argv.append(contentsOf: ["--assign", "\(assignment.role)=\(assignment.repo)"])
        }
        for assignment in assignments {
            argv.append(contentsOf: ["--port-map", "\(assignment.role)=\(assignment.port)"])
        }
        // Models are served locally by our own endpoints; the agent's
        // inventory check runs against HF-cache/runtime inventories and may
        // not see them — record a reviewed warning instead of failing.
        argv.append("--allow-missing")
        argv.append(contentsOf: extra)
        return argv
    }

    // MARK: - Serve

    /// Preserve the selected local directory, including its cache and revision.
    /// Replacing a snapshot with a repo id can resolve a different revision or
    /// cache and cause the runtime to fetch a second copy.
    static func serveModelArguments(for model: String) -> [String] {
        if model.hasPrefix("/") || model.hasPrefix("~") { return ["--path", model] }
        return ["--repo", model]
    }

    func servePreview(repo: String, runtime: String, port: Int?, jit: Bool = false, memoryPolicy: EndpointMemoryPolicy? = nil,
                      strataOptions: StrataComparisonOptions? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        var argv = ["serve", "start"]
            + Self.serveModelArguments(for: repo)
            + ["--runtime", runtime, "--receipts-dir", receiptDirectory]
        if let port { argv.append(contentsOf: ["--port", String(port)]) }
        if jit { argv.append("--jit"); argv += memoryPolicy?.arguments ?? [] }
        if let strataOptions {
            if let error = strataOptions.validationError { throw BridgeError.remote(code: "invalid_arguments", message: error, remediation: "Correct the Strata settings.") }
            argv += strataOptions.arguments
        }
        return Self.unwrapPlan(try await raw(argv, timeout: timeout))
    }

    func serveStart(repo: String, runtime: String, port: Int?,
                    previewHash: String, jit: Bool = false, memoryPolicy: EndpointMemoryPolicy? = nil,
                    timeout: TimeInterval? = nil, strataOptions: StrataComparisonOptions? = nil) async throws -> [String: Any] {
        var argv = ["serve", "start"]
            + Self.serveModelArguments(for: repo)
            + [
                "--runtime", runtime,
                "--confirm", "--preview-hash", previewHash,
                "--receipts-dir", receiptDirectory,
            ]
        if let port { argv.append(contentsOf: ["--port", String(port)]) }
        if jit { argv.append("--jit"); argv += memoryPolicy?.arguments ?? [] }
        if let strataOptions {
            if let error = strataOptions.validationError { throw BridgeError.remote(code: "invalid_arguments", message: error, remediation: "Correct the Strata settings.") }
            argv += strataOptions.arguments
        }
        return try await raw(argv, timeout: timeout)
    }

    func serveStop(port: Int) async throws -> [String: Any] {
        return try await raw([
            "serve", "stop", "--port", String(port),
            "--receipts-dir", receiptDirectory,
        ])
    }

    /// Recover a recorded comparison's server through the existing receipt-owned stop boundary.
    func recoverComparisonServer(_ expected: ComparisonServerReceipt,
        mayBeAlive: @Sendable (Int) -> Bool = WorkbenchAPI.processOrGroupMayBeAlive) async throws {
        guard expected.isValid else { throw WorkflowEvidenceError.invalid("Recorded comparison server ownership is invalid.") }
        let data = try await raw(["serve", "status", "--receipts-dir", receiptDirectory])
        guard let rows = data["servers"] as? [[String: Any]], let servers = Self.servers(from: data), rows.count == servers.count,
              servers.allSatisfy({ ($0.pid ?? 0) > 0 && (1...65535).contains($0.port ?? 0) && $0.state != nil }) else {
            throw WorkflowEvidenceError.invalid("Server status is unavailable; comparison cleanup remains pending.")
        }
        let matching = servers.filter { $0.port == expected.port }
        guard matching.count <= 1 else { throw WorkflowEvidenceError.invalid("Server ownership is ambiguous; no process was stopped.") }
        if let server = matching.first, server.pid == expected.pid, server.modelIdentity == expected.modelIdentity,
           server.startedAt == expected.startedAt, ["running", "stopped"].contains(server.state ?? ""),
           server.receipt.map({ URL(fileURLWithPath: $0).standardizedFileURL == URL(fileURLWithPath: receiptDirectory)
                .appendingPathComponent(".mlx-agent-receipts/serve/\(expected.port).json").standardizedFileURL }) == true,
           ServingProfile.matchesReceipt(server, previewHash: expected.previewHash, startedAt: expected.startedAt) {
            do { _ = try await serveStop(port: expected.port); return }
            catch {
                // The stop may have removed its receipt before its reply was lost.
                if !mayBeAlive(expected.pid) { return }
                throw error
            }
        }
        guard !mayBeAlive(expected.pid) else {
            throw WorkflowEvidenceError.invalid("The original comparison server's ownership cannot be confirmed. No process was stopped.")
        }
    }

    nonisolated static func processOrGroupMayBeAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return true }
        if kill(pid_t(pid), 0) == 0 || errno != ESRCH { return true }
        return killpg(pid_t(pid), 0) == 0 || errno != ESRCH
    }

    func serveUnload(port: Int, expectedPID: Int) async throws -> [String: Any] {
        try await raw(["serve", "unload", "--port", String(port), "--expected-pid", String(expectedPID),
                       "--receipts-dir", receiptDirectory])
    }

    func serveMemoryPolicy(port: Int, expectedPID: Int, policy: EndpointMemoryPolicy) async throws -> [String: Any] {
        try await raw(["serve", "policy", "--port", String(port), "--expected-pid", String(expectedPID),
                       "--receipts-dir", receiptDirectory] + policy.arguments)
    }

    // MARK: - LoRA / Fuse

    func loraPreview(repo: String, data: String, iters: Int?, out: String?) async throws -> [String: Any] {
        var argv = ["lora", "start", "--repo", repo, "--data", data, "--receipts-dir", receiptDirectory]
        if let iters { argv.append(contentsOf: ["--iters", String(iters)]) }
        if let out { argv.append(contentsOf: ["--out", out]) }
        return Self.unwrapPlan(try await raw(argv))
    }

    func loraStart(repo: String, data: String, previewHash: String,
                   iters: Int?, out: String?) async throws -> [String: Any] {
        var argv = [
            "lora", "start", "--repo", repo, "--data", data, "--receipts-dir", receiptDirectory,
            "--confirm", "--preview-hash", previewHash,
        ]
        if let iters { argv.append(contentsOf: ["--iters", String(iters)]) }
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try await raw(argv)
    }

    func trainingStatus() async throws -> TrainingSnapshot {
        try await runOffActor(TrainingSnapshot.self, ["lora", "status", "--receipts-dir", receiptDirectory], timeout: 30)
    }

    func trainingStop(pid: Int) async throws -> [String: Any] {
        try await raw(["lora", "stop", "--pid", String(pid), "--receipts-dir", receiptDirectory])
    }

    func fusePreview(repo: String, adapter: String, out: String?) async throws -> [String: Any] {
        var argv = ["fuse", "start", "--repo", repo, "--adapter", adapter]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return Self.unwrapPlan(try await raw(argv))
    }

    func fuseStart(repo: String, adapter: String, previewHash: String,
                   out: String?) async throws -> [String: Any] {
        var argv = [
            "fuse", "start", "--repo", repo, "--adapter", adapter,
            "--confirm", "--preview-hash", previewHash,
        ]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try await raw(argv)
    }

    // MARK: - Generic

    func runCLI(_ argv: [String]) async throws -> [String: Any] {
        guard !argv.isEmpty else { throw BridgeError.skillFailed }
        return try await raw(argv)
    }

    // MARK: - Decoders

    static func jobs(from data: [String: Any], key: String = "jobs") -> [Job]? {
        guard let rawJobs = data[key] as? [[String: Any]] else { return nil }
        return rawJobs.map { raw in
            Job(
                receipt: raw.string("receipt"),
                repo: raw.string("repo"),
                source: raw.string("source"),
                qBits: raw.int("q_bits"),
                out: raw.string("out"),
                pid: raw.int("pid"),
                logPath: raw.string("log_path"),
                startedAt: raw.string("started_at"),
                completedAt: raw.string("completed_at"),
                state: raw.string("state") ?? "unknown"
            )
        }
    }

    static func servers(from data: [String: Any], key: String = "servers") -> [ServerInfo]? {
        guard let raw = data[key] as? [[String: Any]] else { return nil }
        return raw.map { r in
            let adapterFields = r.filter { ["adapter_path", "adapter_identity", "adapter_status"].contains($0.key) }
            let adapter = (try? JSONSerialization.data(withJSONObject: adapterFields))
                .flatMap { try? JSONDecoder().decode(ServerInfo.self, from: $0) }
            return ServerInfo(
                repo: r.string("repo"),
                path: r.string("path"),
                runtime: r.string("runtime"),
                port: r.int("port"),
                pid: r.int("pid"),
                state: Self.serveProcessState(r),
                logPath: r.string("log_path"),
                startedAt: r.string("started_at"),
                receipt: r.string("receipt"),
                jit: r["jit"] as? Bool,
                modelState: r.string("model_state"),
                workerPid: r.int("worker_pid"),
                activeRequests: r.int("active_requests"),
                memoryPolicy: Self.memoryPolicy(from: r["memory_policy"]),
                loadBlockedReason: r.string("load_blocked_reason"),
                adapterPath: adapter?.adapterPath,
                adapterIdentity: adapter?.adapterIdentity,
                adapterStatus: adapter == nil ? "unknown" : adapter?.adapterStatus
            )
        }
    }

    private static func memoryPolicy(from value: Any?) -> EndpointMemoryPolicy? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let policy = try? JSONDecoder().decode(EndpointMemoryPolicy.self, from: data), policy.isValid else { return nil }
        return policy
    }

    private static func serveProcessState(_ row: [String: Any]) -> String? {
        if let alive = row["alive"] as? Bool {
            if !alive { return "stopped" }
            if let matches = row["argv_match"] as? Bool { return matches ? "running" : "mismatch" }
            return nil
        }
        return row.string("state")
    }

    /// The agent's discovery roles in its own order; buckets merge in this order, unknown roles after, alphabetically.
    static let discoveryRoleOrder = ["vision", "embedding", "coding", "reasoning", "general", "tool-use"]

    static func candidates(from data: [String: Any], key: String = "candidates") -> [DiscoverCandidate]? {
        var raw: [[String: Any]] = []
        if let list = data[key] as? [[String: Any]] {
            raw = list
        } else if let roles = data["roles"] as? [String: Any] {
            let order = discoveryRoleOrder
            let rank: (String) -> Int = { order.firstIndex(of: $0) ?? order.count }
            for role in roles.keys.sorted(by: { (rank($0), $0) < (rank($1), $1) }) {
                if let items = roles[role] as? [[String: Any]] {
                    raw.append(contentsOf: items)
                }
            }
        }
        let all = raw.compactMap { r -> DiscoverCandidate? in
            guard let repo = r.string("repo") else { return nil }
            return DiscoverCandidate(
                repo: repo,
                base: r.string("base") ?? r.string("name"),
                roles: (r["roles"] as? [String]) ?? (r["tags"] as? [String]),
                estRamGb: r.double("est_ram_gb") ?? r.double("estimated_ram_gb"),
                fits: r.bool("fits"),
                license: r.string("license"),
                wiring: r.string("wiring"),
                downloads: r.int("downloads"),
                likes: r.int("likes")
            )
        }
        // dedupe by repo id, keep first
        var seen = Set<String>()
        var out: [DiscoverCandidate] = []
        for c in all where !seen.contains(c.repo) {
            seen.insert(c.repo)
            out.append(c)
        }
        return out
    }

    static func findings(from data: [String: Any], key: String = "findings") -> [DoctorFinding]? {
        guard let raw = data[key] as? [[String: Any]] else { return nil }
        return raw.compactMap { r -> DoctorFinding? in
            guard let path = r.string("path") ?? r.string("model") ?? r.string("repo") else { return nil }
            return DoctorFinding(
                path: path,
                kind: r.string("code") ?? r.string("kind"),
                message: r.string("message") ?? r.string("remediation"),
                size: r.int("size").map(Int64.init)
                    ?? r.int("bytes").map(Int64.init),
                model: r.string("model") ?? r.string("repo")
            )
        }
    }

    static func doctor(from data: [String: Any]) -> DoctorResult {
        // `doctor models` emits findings directly; `--prune` wraps its plan in `{plan, requires_confirmation}`.
        let plan = (data["plan"] as? [String: Any]) ?? data
        let findings = Self.findings(from: plan)
            ?? Self.findings(from: plan, key: "models")
        let candidates = (plan["candidates"] as? [[String: Any]]) ?? []
        let pruneCount = plan.int("prune_count")
            ?? (findings.map { $0.filter(\.isIncompleteDownload).count } ?? candidates.count)
        let summary = (plan["summary"] as? [String: Any]).map { raw in
            DoctorSummary(
                models: raw.int("models"),
                hfCacheBytes: raw.int("hf_cache_bytes").map(Int64.init),
                wiredConfigs: raw.int("wired_configs"),
                findings: raw.int("findings")
            )
        }
        var reclaimed: Int64?
        if let bytes = plan.int("total_bytes") {
            reclaimed = Int64(bytes)
        } else if let rc = plan.int("reclaimed_bytes") {
            reclaimed = Int64(rc)
        }
        let removedItems = (plan["removed"] as? [[String: Any]])?
            .compactMap { r -> PrunedItem? in
                PrunedItem(repo: r.string("repo"), removed: r.bool("removed"),
                           bytes: r.int("bytes").map(Int64.init))
            }
        return DoctorResult(
            findings: findings,
            prune_count: pruneCount,
            preview_hash: plan.string("preview_hash"),
            reclaimedBytes: reclaimed,
            removed: removedItems,
            summary: summary
        )
    }

    static func decodeScan(_ data: [String: Any]) throws -> ScanResult {
        guard let modelsRaw = data["models"] as? [[String: Any]] else {
            throw ScanContractError.invalidRequiredField("models")
        }
        let models = try modelsRaw.enumerated().map { index, raw in
            ModelItem(
                path: try raw.requiredString("path", at: "models[\(index)].path"),
                name: try raw.requiredString("name", at: "models[\(index)].name"),
                bytes: try raw.requiredInt64("bytes", at: "models[\(index)].bytes"),
                modifiedAt: raw.int("modified_at"),
                shard: raw.string("shard"),
                modelKey: raw.string("model_key"),
                architecture: raw.string("architecture"),
                quantization: raw.string("quantization"),
                parameters: raw.string("parameters"),
                structure: raw.string("structure"),
                signature: raw.string("signature"),
                companion: raw.bool("companion"),
                readable: raw.bool("readable"),
                status: raw.string("status") ?? "pending",
                outputs: raw["outputs"] as? [String] ?? [],
                tensorCount: raw.int("tensor_count"),
                error: raw.string("error"),
                task: ModelTask(dictionary: raw["task"] as? [String: Any]),
                draft: ModelDraft(dictionary: raw["draft"] as? [String: Any])
            )
        }
        let outputsRaw = (data["outputs"] as? [[String: Any]]) ?? []
        let outputs = outputsRaw.compactMap { raw -> MLXOutput? in
            guard let path = raw.string("path") else { return nil }
            let quantization = raw["quantization"] as? [String: Any]
            let info = quantization.flatMap { value -> QuantInfo? in
                guard let bits = value.int("bits") else { return nil }
                return QuantInfo(
                    bits: bits,
                    groupSize: value.int("group_size"),
                    modelType: value.string("model_type")
                )
            }
            return MLXOutput(
                path: path,
                name: raw.string("name") ?? path,
                modelKey: raw.string("model_key"),
                quantization: info,
                provenance: raw.string("provenance"),
                task: ModelTask(dictionary: raw["task"] as? [String: Any]),
                runtime: raw.string("runtime")
            )
        }
        guard let totalsDict = data["totals"] as? [String: Any] else {
            throw ScanContractError.invalidRequiredField("totals")
        }
        let totals = ScanTotals(
            gguf: totalsDict.int("gguf") ?? models.count,
            pending: totalsDict.int("pending") ?? 0,
            converted: totalsDict.int("converted") ?? 0,
            unreadable: totalsDict.int("unreadable") ?? 0,
            bytes: try totalsDict.requiredInt64("bytes", at: "totals.bytes"),
            reclaimableBytes: try totalsDict.optionalInt64(
                "reclaimable_bytes", at: "totals.reclaimable_bytes"
            ) ?? 0
        )
        let dupRaw = (data["duplicates"] as? [[String: Any]]) ?? []
        let dups = dupRaw.map { d -> DuplicateGroup in
            DuplicateGroup(kind: d.string("kind"), modelKey: d.string("model_key"),
                           quantization: d.string("quantization"),
                           quantizations: d["quantizations"] as? [String],
                           reclaimableBytes: d.int("reclaimable_bytes").map(Int64.init),
                           keep: d.string("keep"),
                           redundant: d["redundant"] as? [String],
                           members: d["members"] as? [String],
                           count: d.int("count"),
                           groupId: d.string("group_id"))
        }
        let roots = (data["roots"] as? [String: Any]).map { raw in
            ScanRoots(
                gguf: raw["gguf"] as? [String] ?? [],
                mlx: raw["mlx"] as? [String] ?? []
            )
        }
        return ScanResult(
            roots: roots,
            models: models,
            outputs: outputs,
            pending: (data["pending"] as? [String]) ?? [],
            duplicates: dups,
            totals: totals
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func bool(_ key: String) -> Bool? {
        guard let v = value(key) else { return nil }
        if let b = v as? Bool { return b }
        if let i = v as? Int { return i != 0 }
        return nil
    }
}
