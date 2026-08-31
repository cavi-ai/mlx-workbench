import Foundation
import Darwin

// MARK: - ServeProbe
//
// Shared harness for the Conversion Quality Gate (and later Measured
// Comparisons): serve one model on an ephemeral loopback port through the
// existing mlx-agent preview/confirm flow, probe it over the OpenAI-compatible
// HTTP API, and always stop the server afterwards. No new mlx-agent
// subcommands; serving stays inside the argv boundary.

struct ProbeSample: Equatable, Sendable {
    let text: String
    let completionTokens: Int?
    let timeToFirstTokenSeconds: Double?
    let durationSeconds: Double
    /// True when `completionTokens` was estimated from text length because
    /// the server did not report usage.
    let metricsEstimated: Bool
}

struct ProbeRunResult: Equatable, Sendable {
    let port: Int
    /// Prompt id → sample. Guaranteed to contain every requested prompt id.
    let samples: [String: ProbeSample]
}

/// One prompt to send through a probed endpoint. The canary suite and
/// comparison prompt sets both reduce to this.
struct ProbePrompt: Equatable, Sendable {
    let id: String
    let prompt: String
    let maxTokens: Int
}

protocol EndpointProbing: Sendable {
    func isReady(baseURL: URL) async -> Bool
    func chat(baseURL: URL, prompt: String, maxTokens: Int) async throws -> ProbeSample
}

enum ServeProbeError: LocalizedError {
    case noEphemeralPort
    case servePreviewMissingHash
    case serverNeverReady(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noEphemeralPort:
            return "Could not reserve an ephemeral loopback port for the verification server."
        case .servePreviewMissingHash:
            return "The serve preview did not include a preview hash."
        case .serverNeverReady(let timeout):
            return "The verification server did not become ready within \(Int(timeout)) seconds."
        }
    }
}

/// Injectable serve lifecycle so tests never touch mlx-agent or the network.
struct ServeLifecycle: Sendable {
    var preview: @Sendable (_ modelPath: String, _ port: Int) async throws -> String
    var start: @Sendable (_ modelPath: String, _ port: Int, _ previewHash: String) async throws -> Void
    var stop: @Sendable (_ port: Int) async throws -> Void
}

extension ServeLifecycle {
    /// Production lifecycle: mlx-agent serve preview/start/stop, runtime mlx.
    static func live(api: WorkbenchAPI, runtime: String = "mlx") -> ServeLifecycle {
        ServeLifecycle(
            preview: { modelPath, port in
                let response = try await api.servePreview(repo: modelPath, runtime: runtime, port: port)
                return response.string("preview_hash") ?? ""
            },
            start: { modelPath, port, previewHash in
                _ = try await api.serveStart(repo: modelPath, runtime: runtime, port: port, previewHash: previewHash)
            },
            stop: { port in
                _ = try await api.serveStop(port: port)
            }
        )
    }
}

struct ServeProbe: Sendable {
    let lifecycle: ServeLifecycle
    let prober: any EndpointProbing
    var readyTimeout: TimeInterval = 120
    var readyPollIntervalNanoseconds: UInt64 = 1_000_000_000
    var pickPort: @Sendable () -> Int? = EphemeralPort.pick

    /// Serves `modelPath` on an ephemeral loopback port, runs the canary
    /// suite sequentially, and stops the server even when a probe throws.
    func run(modelPath: String) async throws -> ProbeRunResult {
        try await run(modelPath: modelPath, prompts: CanarySuite.cases.map {
            ProbePrompt(id: $0.id, prompt: $0.prompt, maxTokens: $0.maxTokens)
        })
    }

    /// Serves `modelPath` on an ephemeral loopback port, runs `prompts`
    /// sequentially, and stops the server even when a probe throws.
    func run(modelPath: String, prompts: [ProbePrompt]) async throws -> ProbeRunResult {
        guard let port = pickPort() else { throw ServeProbeError.noEphemeralPort }
        let hash = try await lifecycle.preview(modelPath, port)
        guard !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
        try await lifecycle.start(modelPath, port, hash)

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        do {
            guard await waitUntilReady(baseURL: baseURL) else {
                throw ServeProbeError.serverNeverReady(timeout: readyTimeout)
            }
            var samples: [String: ProbeSample] = [:]
            for prompt in prompts {
                try Task.checkCancellation()
                samples[prompt.id] = try await prober.chat(
                    baseURL: baseURL,
                    prompt: prompt.prompt,
                    maxTokens: prompt.maxTokens
                )
            }
            try? await lifecycle.stop(port)
            return ProbeRunResult(port: port, samples: samples)
        } catch {
            // A crashed probe must never leave an orphan server behind.
            try? await lifecycle.stop(port)
            throw error
        }
    }

    private func waitUntilReady(baseURL: URL) async -> Bool {
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if await prober.isReady(baseURL: baseURL) { return true }
            try? await Task.sleep(nanoseconds: readyPollIntervalNanoseconds)
        }
        return false
    }
}

// MARK: - EphemeralPort

enum EphemeralPort {
    /// Reserve a free loopback port by binding port 0 and reading back the
    /// assignment. There is an inherent race before the server binds it; a
    /// lost race fails loudly at serve start, never silently.
    static func pick() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(fd, rebound, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}

// MARK: - OpenAIEndpointProber

enum ProbeHTTPError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The verification server returned HTTP \(code)."
        case .invalidResponse:
            return "The verification server returned an unreadable response."
        }
    }
}

/// Live prober against an mlx_lm.server OpenAI-compatible endpoint.
/// Streaming is used so time-to-first-token is measured honestly; when the
/// server omits usage, token counts are estimated and flagged as such.
struct OpenAIEndpointProber: EndpointProbing {
    private let session: URLSession
    private let requestTimeout: TimeInterval

    init(session: URLSession = .shared, requestTimeout: TimeInterval = 180) {
        self.session = session
        self.requestTimeout = requestTimeout
    }

    func isReady(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 5
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    func chat(baseURL: URL, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "probe",
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": true,
            "stream_options": ["include_usage": true],
        ])

        let startedAt = Date()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProbeHTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProbeHTTPError.httpStatus(http.statusCode) }

        var text = ""
        var completionTokens: Int?
        var firstTokenAt: Date?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let usage = chunk["usage"] as? [String: Any],
               let count = usage["completion_tokens"] as? Int {
                completionTokens = count
            }
            if let choices = chunk["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                if firstTokenAt == nil { firstTokenAt = Date() }
                text += content
            }
        }

        let finishedAt = Date()
        let estimated: Bool
        let tokens: Int?
        if let completionTokens {
            tokens = completionTokens
            estimated = false
        } else {
            // Rough chars-per-token estimate; flagged on the sample so reports
            // never present estimates as measurements.
            tokens = text.isEmpty ? nil : max(1, text.count / 4)
            estimated = true
        }
        return ProbeSample(
            text: text,
            completionTokens: tokens,
            timeToFirstTokenSeconds: firstTokenAt.map { $0.timeIntervalSince(startedAt) },
            durationSeconds: finishedAt.timeIntervalSince(startedAt),
            metricsEstimated: estimated
        )
    }
}
