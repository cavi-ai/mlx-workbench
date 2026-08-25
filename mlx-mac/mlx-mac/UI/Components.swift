import SwiftUI

// MARK: - Shared UI helpers for the workbench views

struct ErrorBanner: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.footnote)
                .foregroundColor(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
        }
    }
}

struct StatusPill: View {
    let state: String

    var body: some View {
        Text(state)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(pillColor.opacity(0.18))
            .foregroundColor(pillColor)
            .cornerRadius(4)
    }

    private var pillColor: Color {
        switch state.lowercased() {
        case "running", "ok", "ready", "started", "pending", "converted": return .green
        case "failed", "error", "unreadable": return .red
        case "waiting", "queued", "stopped", "gone": return .orange
        default: return .secondary
        }
    }
}

struct PreviewDictView: View {
    let value: [String: Any]
    var maxDepth: Int = 3

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text(for: value, depth: 0))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func text(for object: Any, depth: Int) -> String {
        if depth > maxDepth {
            return "<…>\n"
        }
        guard let dict = object as? [String: Any] else {
            return "\(nullSafe(object))\n"
        }
        var lines = ""
        let indent = String(repeating: "  ", count: depth)
        for key in dict.keys.sorted() {
            let value = dict[key]
            if let nested = value as? [String: Any] {
                lines += "\(indent)\(key):\n"
                lines += text(for: nested, depth: depth + 1)
            } else if let array = value as? [Any] {
                lines += "\(indent)\(key): [\(array.count) items]\n"
            } else {
                lines += "\(indent)\(key): \(nullSafe(value))\n"
            }
        }
        return lines
    }

    private func nullSafe(_ value: Any?) -> String {
        guard let value else { return "null" }
        if value is NSNull { return "null" }
        return "\(value)"
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundColor(.secondary)
    }
}

extension View {
    func formSection<SupplementalContent: View>(@ViewBuilder content: () -> SupplementalContent) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                self
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}
