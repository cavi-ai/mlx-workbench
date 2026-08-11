import SwiftUI

// MARK: - JobsView
// List conversion jobs with state and log linkage.

struct JobsView: View {
    @ObservedObject var appHost: AppHost

    @State private var jobs: [Job] = []
    @State private var servers: [ServerInfo] = []
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var selectedLog: LogSelection?

    struct LogSelection: Identifiable {
        let id: String
        let path: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jobs").font(.title2)
                Spacer()
                Button("Refresh") { refresh() }
                    .disabled(isRefreshing)
            }
            ErrorBanner(text: errorMessage)

            if !servers.isEmpty {
                Section("Servers") {
                    ForEach(servers) { server in
                        row {
                            StatusPill(state: server.state ?? "unknown")
                            Text(server.repo ?? "server").font(.body)
                                .lineLimit(1)
                            Spacer()
                            if let port = server.port {
                                Text(":\(port)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Conversions") {
                if jobs.isEmpty {
                    Text("No conversion jobs yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                } else {
                    ForEach(jobs) { job in
                        jobRow(job)
                    }
                }
            }
            Spacer()
        }
        .padding()
        .sheet(item: $selectedLog) { selection in
            LogSheet(path: selection.path)
        }
        .onAppear { refresh() }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.vertical, 4)
    }

    private func jobRow(_ job: Job) -> some View {
        HStack(spacing: 10) {
            StatusPill(state: job.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.body)
                Text(job.repo ?? job.out ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let started = job.startedAt {
                    Text(started)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let q = job.qBits {
                Text("\(q)bit").font(.caption).foregroundColor(.secondary)
            }
            if let logPath = job.logPath {
                Button("Log") { selectedLog = LogSelection(id: logPath, path: logPath) }
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        errorMessage = nil
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do {
                jobs = try await appHost.api.convertStatus()
                servers = try await appHost.api.serveStatus()
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - LogSheet

struct LogSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading…"
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(path).font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            if truncated {
                Text("(truncated to the tail)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(width: 720, height: 480)
        .onAppear { load() }
    }

    private func load() {
        Task {
            let maxBytes = 64 * 1024
            let url = URL(string: path).flatMap { parsed in
                parsed.scheme == "file" ? parsed : nil
            } ?? URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: url.path) {
                text = "Invalid log path."
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                text = "Log not readable yet."
                return
            }
            truncated = data.count > maxBytes
            let chunk = truncated ? data.suffix(maxBytes) : data
            text = (truncated ? "…\n" : "") + String(decoding: chunk, as: UTF8.self)
        }
    }
}
