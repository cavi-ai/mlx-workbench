import Foundation
import CryptoKit

struct ServingTelemetry: Codable, Equatable {
    struct Request: Codable, Equatable {
        let completedAt: String
        let outcome: String
        let inputTokens: Int?
        let outputTokens: Int?
        let responseSeconds: Double?
        let outputTokensPerSecond: Double?
        /// Stage timing from gateways that measure it: queue and load wait, then prompt
        /// processing until the first streamed token, then decoding.
        var waitSeconds: Double? = nil
        var firstTokenSeconds: Double? = nil
        var promptTokensPerSecond: Double? = nil
        var decodeTokensPerSecond: Double? = nil
        enum CodingKeys: String, CodingKey {
            case outcome
            case completedAt = "completed_at", inputTokens = "input_tokens", outputTokens = "output_tokens"
            case responseSeconds = "response_seconds", outputTokensPerSecond = "output_tokens_per_second"
            case waitSeconds = "wait_seconds", firstTokenSeconds = "first_token_seconds"
            case promptTokensPerSecond = "prompt_tokens_per_second", decodeTokensPerSecond = "decode_tokens_per_second"
        }

        /// Shares of the response time spent waiting, processing the prompt and decoding,
        /// when the gateway reported consistent stage timing.
        var stages: (wait: Double, prompt: Double, decode: Double)? {
            guard let total = responseSeconds, total > 0, let wait = waitSeconds, let first = firstTokenSeconds,
                  wait <= first, first <= total else { return nil }
            return (wait / total, (first - wait) / total, (total - first) / total)
        }
    }
    let schema: Int
    let scope: String
    let startedAt: String
    let capturedAt: String
    let requests: Int
    let completedRequests: Int
    let failedRequests: Int
    let measuredRequests: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let lastRequest: Request?
    enum CodingKeys: String, CodingKey {
        case schema, scope, requests
        case startedAt = "started_at", capturedAt = "captured_at", completedRequests = "completed_requests"
        case failedRequests = "failed_requests", measuredRequests = "measured_requests"
        case inputTokens = "input_tokens", outputTokens = "output_tokens", lastRequest = "last_request"
    }
    init?(raw: LabValue?) {
        guard let raw, let data = try? JSONEncoder().encode(raw),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema == 1, value.scope == "gateway-process",
              [value.requests, value.completedRequests, value.failedRequests, value.measuredRequests].allSatisfy({ $0 >= 0 }),
              value.completedRequests <= value.requests, value.failedRequests <= value.requests - value.completedRequests,
              value.measuredRequests <= value.completedRequests,
              Self.date(value.startedAt) != nil, Self.date(value.capturedAt) != nil,
              [value.inputTokens, value.outputTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
              (value.measuredRequests == 0 ? (value.inputTokens == nil && value.outputTokens == nil) : (value.inputTokens != nil && value.outputTokens != nil)) else { return nil }
        if let last = value.lastRequest {
            guard ["completed", "failed"].contains(last.outcome), Self.date(last.completedAt) != nil,
                  [last.inputTokens, last.outputTokens].compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
                  [last.responseSeconds, last.outputTokensPerSecond, last.waitSeconds, last.firstTokenSeconds,
                   last.promptTokensPerSecond, last.decodeTokensPerSecond].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        }
        self = value
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum ServingRequestDefaults {
    static func matches(_ raw: LabValue?, options: LocalInferenceOptions) -> Bool {
        guard let raw else { return !options.hasRequestDefaults }
        guard let fields = raw.object, Set(fields.keys).isSubset(of: ["temperature", "top_p", "system_prompt_sha256"]) else { return false }
        let expectedHash = options.systemPrompt.isEmpty ? nil : SHA256.hash(data: Data(options.systemPrompt.utf8)).map { String(format: "%02x", $0) }.joined()
        return fields["system_prompt_sha256"]?.text == expectedHash
            && fields["temperature"]?.decimal == options.temperature
            && fields["top_p"]?.decimal == options.topP
    }
}
