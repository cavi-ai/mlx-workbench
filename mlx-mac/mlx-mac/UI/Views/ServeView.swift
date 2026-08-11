import SwiftUI

// MARK: - ServeView
// Preview / confirm a serve plan, list running servers, stop.

struct ServeView: View {
    @ObservedObject var appHost: AppHost

    @State private var repo = ""
    @State private var runtime = "mlx_lm"
    @State private var portText = ""
    @State private var isPreviewing = false
    @State private var preview: [String: Any]?
    @State private var servers: [ServerInfo] = []
    @State private var errorMessage: String?
    @State private var notice: String?

    private var previewHash: String? {
        if let h = preview?["preview_hash"] as? String { return h }
        if let plan = preview?["plan"] as? [String: Any], let h = plan["preview_hash"] as? String { return h }
        return nil
    }

    private var port: Int? {
        Int(portText.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                formSection
                if let preview {
                    planSection
                }
                ErrorBanner(text: errorMessage)
                if let notice {
                    Text(notice).font(.caption).foregroundColor(.green)
                }
                serversSection
                Spacer()
            }
            .padding()
        }
        .onAppear { refreshServers() }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Launch")
            HStack {
                TextField("Repo id or local path", text: $repo)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("Runtime", selection: $runtime) {
                    Text("mlx_lm").tag("mlx_lm")
                    Text("mlx-vlm").tag("mlx-vlm")
                }
                .frame(width: 160)
                TextField("Port (optional)", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Spacer()
            }
            HStack {
                Button("Preview Plan") {
                    previewPlan()
                }
                .disabled(repo.isEmpty || isPreviewing)
                Spacer()
            }
        }
        .formSection {}
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Plan")
                Spacer()
                Button("Confirm & Serve") {
                    confirmServe()
                }
                .disabled(previewHash == nil)
            }
            PreviewDictView(value: preview ?? [:])
        }
        .formSection {}
    }

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Running servers")
                Spacer()
                Button("Refresh") { refreshServers() }
            }
            if servers.isEmpty {
                Text("No active servers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(servers) { server in
                    HStack {
                        StatusPill(state: server.state ?? "unknown")
                        VStack(alignment: .leading) {
                            Text(server.repo ?? "server")
                            if let runtime = server.runtime {
                                Text(runtime).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if let port = server.port {
                            Text(":\(port)").font(.caption)
                        }
                        Button("Stop") {
                            stop(server)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formSection {}
    }

    private func previewPlan() {
        errorMessage = nil
        notice = nil
        isPreviewing = true
        let r = repo, rt = runtime, p = port
        Task {
            defer { isPreviewing = false }
            do {
                preview = try await appHost.api.servePreview(repo: r, runtime: rt, port: p)
            } catch let error as BridgeError {
                preview = nil
                errorMessage = error.errorDescription
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmServe() {
        guard let hash = previewHash else { return }
        errorMessage = nil
        let r = repo, rt = runtime, p = port
        Task {
            do {
                let result = try await appHost.api.serveStart(repo: r, runtime: rt, port: p, previewHash: hash)
                notice = result["message"] as? String ?? "Serve started."
                preview = nil
                refreshServers()
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stop(_ server: ServerInfo) {
        guard let port = server.port else { return }
        errorMessage = nil
        Task {
            do {
                _ = try await appHost.api.serveStop(port: port)
                refreshServers()
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshServers() {
        Task {
            do {
                servers = try await appHost.api.serveStatus()
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}