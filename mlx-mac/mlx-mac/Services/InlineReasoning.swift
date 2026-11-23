import Foundation

/// Reasoning a server streams inline as `<think>…</think>` content (no reasoning
/// parser), separated from the answer the model gives after it.
enum InlineReasoning {
    private static let open = "<think>"
    private static let close = "</think>"

    /// Splits text that starts with an inline reasoning block; nil when it has none.
    /// Reasoning cut off before its closing tag leaves an empty answer.
    static func split(_ text: String) -> (reasoning: String, answer: String)? {
        let body = text.drop(while: \.isWhitespace)
        guard body.hasPrefix(open) else { return nil }
        let inner = body.dropFirst(open.count)
        guard let end = inner.range(of: close) else { return (String(inner), "") }
        return (String(inner[..<end.lowerBound]), String(inner[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True while streamed content is still inside an opening reasoning block.
    static func isInside(_ text: String) -> Bool {
        guard let parts = split(text) else { return false }
        return parts.answer.isEmpty
    }
    /// Tracks only delimiter progress, so each incoming scalar is visited once.
    /// Incomplete opening tags remain ambiguous until content establishes an answer.
    struct StreamTracker {
        private enum Phase { case opening, reasoning, afterReasoning, answer }
        private var phase = Phase.opening
        private var matched = 0
        private var bytesRead = 0
        private var reasoningStart: Int?
        private var reasoningEnd: Int?
        private(set) var hasAnswer = false
        private static let opening = Array(InlineReasoning.open.unicodeScalars)
        private static let closing = Array(InlineReasoning.close.unicodeScalars)

        mutating func consume(_ fragment: String) {
            guard !hasAnswer else { return }
            for scalar in fragment.unicodeScalars {
                bytesRead += scalar.utf8.count
                switch phase {
                case .opening:
                    if matched == 0 && scalar.properties.isWhitespace { continue }
                    guard scalar == Self.opening[matched] else {
                        phase = .answer; hasAnswer = true; return
                    }
                    matched += 1
                    if matched == Self.opening.count {
                        reasoningStart = bytesRead
                        phase = .reasoning; matched = 0
                    }
                case .reasoning:
                    if scalar == Self.closing[matched] {
                        matched += 1
                        if matched == Self.closing.count {
                            reasoningEnd = bytesRead - Self.closing.count
                            phase = .afterReasoning; matched = 0
                        }
                    } else { matched = scalar == Self.closing[0] ? 1 : 0 }
                case .afterReasoning:
                    if !scalar.properties.isWhitespace { phase = .answer; hasAnswer = true; return }
                case .answer:
                    return
                }
            }
        }

        /// Slices the accumulated content at the delimiters already seen.
        func parts(in text: String) -> (reasoning: String, answer: String)? {
            guard let reasoningStart else { return nil }
            let bytes = text.utf8
            let start = bytes.index(bytes.startIndex, offsetBy: reasoningStart)
            guard let reasoningEnd else { return (String(decoding: bytes[start...], as: UTF8.self), "") }
            let end = bytes.index(start, offsetBy: reasoningEnd - reasoningStart)
            let answer = bytes.index(end, offsetBy: Self.closing.count)
            return (String(decoding: bytes[start..<end], as: UTF8.self),
                    String(decoding: bytes[answer...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
