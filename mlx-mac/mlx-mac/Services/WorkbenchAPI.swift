import Foundation

// MARK: - WorkbenchAPI
//
// Typed wrapper over CLIProcess mirroring mlx_workbench/bridge.py. Every method
// runs one mlx-agent subcommand, then decodes the unwrapped `data` payload.

actor WorkbenchAPI {
    private let cli: CLIProcess
    private var agentPath: String

    init(cli: CLIProcess, agentPath: String) {
        self.cli = cli
        self.agentPath = agentPath
    }

    func setAgentPath(_ path: String) {
        agentPath = path
    }

    var resolvedAgentPath: String { agentPath }

    // MARK: - Raw

    func raw(_ argv: [String], isScout: Bool = false, timeout: TimeInterval? = nil) throws -> [String: Any] {
        return try cli.run(agentPath: agentPath, argv: argv, isScout: isScout, timeout: timeout)
    }

    func health() -> (ok: Bool, path: String, cli: String, message: String) {
        return cli.agentHealth(agentPath: agentPath)
    }

    // MARK: - Scan

    func scan(ggufRoots: [String], mlxRoots: [String], signatures: Bool,
              limit: Int? = nil) throws -> ScanResult {
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
        let data = try raw(argv)
        guard let json = try? JSONSerialization.data(withJSONObject: data) else {
            throw BridgeError.skillOutputUnreadable
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ScanResult.self, from: json)
        } catch {
            // Manual fallback for shape drift.
            return Self.scanFallback(data)
        }
    }

    // MARK: - Convert

    func convertPreview(ggufPath: String, qBits: Int, out: String?) throws -> [String: Any] {
        var argv = ["convert", "start", "--gguf", ggufPath, "--q-bits", String(qBits)]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try raw(argv)
    }

    func convertRepoPreview(repo: String, qBits: Int, out: String?,
                            hfCache: String?) throws -> [String: Any] {
        var argv = ["convert", "start", "--repo", repo, "--q-bits", String(qBits)]
        if let out { argv.append(contentsOf: ["--out", out]) }
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        return try raw(argv)
    }

    func convertStart(ggufPath: String, qBits: Int, out: String?,
                      previewHash: String) throws -> [String: Any] {
        var argv = [
            "convert", "start", "--gguf", ggufPath, "--q-bits", String(qBits),
            "--confirm", "--preview-hash", previewHash,
        ]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try raw(argv)
    }

    func convertRepoStart(repo: String, qBits: Int, out: String?,
                          hfCache: String?, previewHash: String) throws -> [String: Any] {
        var argv = [
            "convert", "start", "--repo", repo, "--q-bits", String(qBits),
            "--confirm", "--preview-hash", previewHash,
        ]
        if let out { argv.append(contentsOf: ["--out", out]) }
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        return try raw(argv)
    }

    // MARK: - Jobs

    func convertStatus() throws -> [Job] {
        let data = try raw(["convert", "status"])
        return Self.jobs(from: data) ?? []
    }

    func serveStatus() throws -> [ServerInfo] {
        let data = try raw(["serve", "status"])
        return Self.servers(from: data) ?? []
    }

    func allJobs() throws -> [Job] {
        let data = try raw(["convert", "status"])
        return Self.jobs(from: data, key: "jobs") ?? []
    }

    // MARK: - Discover

    func discover(role: String?, limit: Int?, fast: Bool, new: Bool) throws -> DiscoverResult {
        var argv = ["discover"]
        if let role { argv.append(contentsOf: ["--role", role]) }
        if let limit { argv.append(contentsOf: ["--limit", String(limit)]) }
        if fast { argv.append("--fast") }
        if new { argv.append("--new") }
        let data = try raw(argv, isScout: true)
        return DiscoverResult(candidates: Self.candidates(from: data))
    }

    // MARK: - Doctor

    func doctor(wiredRoots: [String], hfCache: String?) throws -> DoctorResult {
        var argv = ["doctor", "models"]
        for root in wiredRoots {
            argv.append(contentsOf: ["--wired-root", root])
        }
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        let data = try raw(argv)
        return Self.doctor(from: data)
    }

    func doctorPrunePreview(hfCache: String?) throws -> DoctorResult {
        var argv = ["doctor", "models", "--prune"]
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        let data = try raw(argv)
        return Self.doctor(from: data)
    }

    func doctorPruneConfirm(previewHash: String, hfCache: String?) throws -> DoctorResult {
        var argv = [
            "doctor", "models", "--prune",
            "--confirm", "--preview-hash", previewHash,
        ]
        if let hfCache { argv.append(contentsOf: ["--hf-cache", hfCache]) }
        let data = try raw(argv)
        return Self.doctor(from: data)
    }

    // MARK: - Adopt

    func adoptStart(role: String?, state: String?, fast: Bool, offline: Bool) throws -> AdoptResult {
        var argv = ["adopt", "start"]
        if let role { argv.append(contentsOf: ["--role", role]) }
        if let state { argv.append(contentsOf: ["--state", state]) }
        if fast { argv.append("--fast") }
        if offline { argv.append("--offline") }
        let data = try raw(argv, isScout: true)
        return Self.adopt(from: data)
    }

    func adoptStatus(state: String) throws -> AdoptResult {
        let data = try raw(["adopt", "status", "--state", state])
        return Self.adopt(from: data)
    }

    static func adopt(from data: [String: Any]) -> AdoptResult {
        let s = (data["state"] as? [String: Any]) ?? data
        let request = (s["request"] as? [String: Any]) ?? [:]
        let role = (request["roles"] as? [String])?.first ?? s.string("role")
        let recommendations = (s["recommendations"] as? [[String: Any]]) ?? []
        let model = recommendations.first?.string("repo")
            ?? s.string("model")
            ?? (s["shortlist"] as? [[String: Any]])?.first?.string("repo")
        let message: String?
        if let status = s.string("status"), let phase = s.string("phase") {
            message = "status: \(status), phase: \(phase)"
        } else {
            message = data.string("message")
        }
        return AdoptResult(
            state: s.string("workflow_id") ?? s.string("state"),
            role: role,
            model: model,
            status: s.string("status"),
            message: message,
            manager: s.string("manager")
        )
    }

    // MARK: - Wire

    func wirePreview(model: String, path: String, target: String) throws -> WireResult {
        let data = try raw(["wire", "apply", model, "--path", path, "--target", target])
        let preview = (data["preview"] as? [String: Any]) ?? data
        return WireResult(preview_hash: preview.string("preview_hash"),
                          config: preview["config"] as? [String: Any]
                              ?? (preview["diff"] as? [String: Any]),
                          applied: data.bool("applied"))
    }

    func wireApply(model: String, path: String, previewHash: String,
                   target: String) throws -> WireResult {
        let data = try raw([
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

    // MARK: - Serve

    func servePreview(repo: String, runtime: String, port: Int?) throws -> [String: Any] {
        var argv = ["serve", "start", "--repo", repo, "--runtime", runtime]
        if let port { argv.append(contentsOf: ["--port", String(port)]) }
        return try raw(argv)
    }

    func serveStart(repo: String, runtime: String, port: Int?,
                    previewHash: String) throws -> [String: Any] {
        var argv = [
            "serve", "start", "--repo", repo, "--runtime", runtime,
            "--confirm", "--preview-hash", previewHash,
        ]
        if let port { argv.append(contentsOf: ["--port", String(port)]) }
        return try raw(argv)
    }

    func serveStop(port: Int) throws -> [String: Any] {
        return try raw(["serve", "stop", "--port", String(port)])
    }

    // MARK: - LoRA / Fuse

    func loraPreview(repo: String, data: String, iters: Int?, out: String?) throws -> [String: Any] {
        var argv = ["lora", "start", "--repo", repo, "--data", data]
        if let iters { argv.append(contentsOf: ["--iters", String(iters)]) }
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try raw(argv)
    }

    func loraStart(repo: String, data: String, previewHash: String,
                   iters: Int?, out: String?) throws -> [String: Any] {
        var argv = [
            "lora", "start", "--repo", repo, "--data", data,
            "--confirm", "--preview-hash", previewHash,
        ]
        if let iters { argv.append(contentsOf: ["--iters", String(iters)]) }
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try raw(argv)
    }

    func fusePreview(repo: String, adapter: String, out: String?) throws -> [String: Any] {
        var argv = ["fuse", "start", "--repo", repo, "--adapter", adapter]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try raw(argv)
    }

    func fuseStart(repo: String, adapter: String, previewHash: String,
                   out: String?) throws -> [String: Any] {
        var argv = [
            "fuse", "start", "--repo", repo, "--adapter", adapter,
            "--confirm", "--preview-hash", previewHash,
        ]
        if let out { argv.append(contentsOf: ["--out", out]) }
        return try raw(argv)
    }

    // MARK: - Generic

    func runCLI(_ argv: [String]) throws -> [String: Any] {
        guard !argv.isEmpty else { throw BridgeError.skillFailed }
        return try raw(argv)
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
            ServerInfo(
                repo: r.string("repo"),
                runtime: r.string("runtime"),
                port: r.int("port"),
                pid: r.int("pid"),
                state: r.string("state"),
                logPath: r.string("log_path"),
                startedAt: r.string("started_at"),
                receipt: r.string("receipt")
            )
        }
    }

    static func candidates(from data: [String: Any], key: String = "candidates") -> [DiscoverCandidate]? {
        var raw: [[String: Any]] = []
        if let list = data[key] as? [[String: Any]] {
            raw = list
        } else if let roles = data["roles"] as? [String: Any] {
            for (_, value) in roles {
                if let items = value as? [[String: Any]] {
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
                    ?? r.int("bytes").map(Int64.init)
            )
        }
    }

    static func doctor(from data: [String: Any]) -> DoctorResult {
        // `doctor models` emits findings directly; `--prune` wraps its plan in `{plan, requires_confirmation}`.
        let plan = (data["plan"] as? [String: Any]) ?? data
        let findings = Self.findings(from: plan)
            ?? Self.findings(from: plan, key: "models")
        let candidates = (plan["candidates"] as? [[String: Any]]) ?? []
        let pruneCount = plan.int("prune_count") ?? (findings?.count ?? candidates.count)
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
            removed: removedItems
        )
    }

    static func scanFallback(_ data: [String: Any]) -> ScanResult {
        let modelsRaw = (data["models"] as? [[String: Any]]) ?? []
        let models = modelsRaw.map { raw -> ModelItem in
            return ModelItem(
                path: raw.string("path") ?? "",
                name: raw.string("name") ?? "",
                bytes: Int64(raw.int("bytes") ?? 0),
                modifiedAt: raw.int("modified_at"),
                shard: raw.string("shard"),
                modelKey: raw.string("model_key"),
                architecture: raw.string("architecture"),
                quantization: raw.string("quantization"),
                parameters: raw.string("parameters"),
                structure: raw.string("structure"),
                signature: raw.string("signature"),
                companion: raw["companion"] as? Bool,
                readable: raw["readable"] as? Bool,
                status: raw.string("status") ?? "pending",
                outputs: (raw["outputs"] as? [String]) ?? [],
                tensorCount: raw.int("tensor_count"),
                error: raw.string("error")
            )
        }
        let outputsRaw = (data["outputs"] as? [[String: Any]]) ?? []
        let outputs = outputsRaw.compactMap { r -> MLXOutput? in
            guard let path = r.string("path") else { return nil }
            let q = r["quantization"] as? [String: Any]
            return MLXOutput(
                path: path,
                name: r.string("name") ?? "",
                modelKey: r.string("model_key"),
                quantization: QuantInfo(
                    bits: q?["bits"] as? Int ?? 0,
                    groupSize: q?["group_size"] as? Int,
                    modelType: q?["model_type"] as? String
                ),
                provenance: r.string("provenance")
            )
        }
        let totalsDict = (data["totals"] as? [String: Any]) ?? [:]
        let totals = ScanTotals(
            gguf: totalsDict.int("gguf") ?? models.count,
            pending: totalsDict.int("pending") ?? 0,
            converted: totalsDict.int("converted") ?? 0,
            unreadable: totalsDict.int("unreadable") ?? 0,
            bytes: Int64(totalsDict.int("bytes") ?? 0),
            reclaimableBytes: Int64(totalsDict.int("reclaimable_bytes") ?? 0)
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
        return ScanResult(
            roots: nil,
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