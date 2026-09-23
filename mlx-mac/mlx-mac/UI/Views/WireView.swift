import SwiftUI

// MARK: - WireView
// Preview / apply runtime wiring for a model into a target config.

struct WireView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var wiring: WiringCoordinator

    @State private var model = ""
    @State private var path = ""
    @State private var target = "mlx_lm"
    @State private var isPreviewing = false
    @State private var preview: [String: Any]?
    @State private var previewHash: String?
    @State private var result: String?
    @State private var errorMessage: String?

    @State private var selectedServerID: String?
    @State private var wiringResult: String?
    @State private var wiringResultHasIssues = false

    init(appHost: AppHost) {
        self.appHost = appHost
        _wiring = ObservedObject(wrappedValue: appHost.wiring)
    }

    private var runningServers: [ServerInfo] {
        appHost.modelWorkflow.servers.filter { $0.state?.lowercased() == "running" }
    }

    private var selectedEndpoint: WireEndpoint? {
        guard let server = runningServers.first(where: { $0.id == selectedServerID }),
              let port = server.port, let repo = server.repo else { return nil }
        return WireEndpoint(
            baseURL: "http://127.0.0.1:\(port)/v1",
            modelName: URL(fileURLWithPath: repo).deletingPathExtension().lastPathComponent
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                clientWiringSection
                formSection
                ErrorBanner(text: errorMessage)
                if let result {
                    Text(result).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
                }
                if let preview {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionTitle(text: "Preview")
                            Spacer()
                            Button("Apply Wiring") {
                                apply()
                            }
                            .disabled(previewHash == nil)
                        }
                        RawJSONDisclosure("Raw wiring payload", value: preview)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .onAppear { wiring.detect() }
    }

    // MARK: - Cross-client wiring

    private var clientWiringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Client wiring")
            Text("Point installed clients at a running local server. Each client's own config is written atomically with backup and rollback.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)

            if runningServers.isEmpty {
                Text("No authoritative running server. Start one in Run first.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                Picker("Endpoint", selection: $selectedServerID) {
                    Text("Choose a running server…").tag(String?.none)
                    ForEach(runningServers) { server in
                        Text("\(server.repo.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "server") :\(server.port.map(String.init) ?? "?")")
                            .tag(String?.some(server.id))
                    }
                }
                .frame(width: 340)
            }

            if wiring.installations.isEmpty {
                Text("No supported clients detected (opencode, Continue, Zed, Aider).")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                ForEach(wiring.installations, id: \.clientID) { installation in
                    HStack {
                        Text(installation.displayName).font(WorkbenchTypography.secondary)
                        Spacer()
                        if installation.advisoryOnly {
                            Text(installation.advisoryNote ?? "Advisory only")
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        } else {
                            Text(installation.configPath ?? "")
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { wiringActions }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { wiringActions }
            }

            ErrorBanner(text: wiring.lastError)
            ErrorBanner(text: wiring.persistenceError)

            if !wiring.plans.isEmpty, let hash = wiring.previewHash {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "Wiring preview")
                    ForEach(wiring.plans) { plan in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(plan.redactedDiff.enumerated()), id: \.offset) { _, line in
                                    Text(diffText(line))
                                        .font(WorkbenchTypography.value)
                                        .foregroundStyle(diffColor(line.kind))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack {
                                Text(plan.displayName).font(WorkbenchTypography.emphasis)
                                if plan.rewritesFile {
                                    Text("reformats file").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                                }
                                Spacer()
                                Text(plan.summary).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            }
                        }
                    }
                    Button("Confirm client wiring") {
                        if let endpoint = selectedEndpoint {
                            let transaction = wiring.confirm(endpoint: endpoint, previewHash: hash)
                            if let transaction {
                                wiringResultHasIssues = !transaction.failures.isEmpty
                                wiringResult = transaction.failures.isEmpty
                                    ? "Wired \(transaction.receipts.count) client(s) to \(transaction.modelName)."
                                    : "Wired with issues: \(transaction.failures.joined(separator: "; "))"
                            } else {
                                wiringResult = nil
                                wiringResultHasIssues = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(wiring.isApplying)
                }
                .formSection {}
            }

            if let wiringResult {
                Text(wiringResult)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(wiringResultHasIssues ? WorkbenchColor.failure : WorkbenchColor.success)
            }
        }
        .formSection {}
    }

    @ViewBuilder
    private var wiringActions: some View {
        Button("Preview client wiring") {
            if let endpoint = selectedEndpoint { wiring.preview(endpoint: endpoint) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedEndpoint == nil || wiring.installations.allSatisfy(\.advisoryOnly))
        if wiring.rollbackAvailable {
            Button("Roll back last wiring") { wiring.rollback() }
                .buttonStyle(.bordered)
        }
    }

    private func diffText(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: return "  \(line.text)"
        case .added: return "+ \(line.text)"
        case .removed: return "- \(line.text)"
        }
    }

    private func diffColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .context: return WorkbenchColor.ink
        case .added: return WorkbenchColor.success
        case .removed: return WorkbenchColor.failure
        }
    }

    @ViewBuilder
    private var manualWireControls: some View {
        Picker("Target", selection: $target) {
            Text("mlx_lm").tag("mlx_lm")
            Text("mlx-vlm").tag("mlx-vlm")
            Text("ollama").tag("ollama")
            Text("lmstudio").tag("lmstudio")
            Text("litellm").tag("litellm")
        }
        .frame(maxWidth: 180, alignment: .leading)
        Button("Preview Wire") { previewWire() }
            .buttonStyle(.borderedProminent)
            .disabled(model.isEmpty || path.isEmpty || isPreviewing)
    }


    private var formSection: some View {
        // Legacy single-file wiring. Cross-client wiring above is the
        // supported path; this stays available but collapsed.
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Model repo id", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    TextField("Config file path", text: $path)
                        .textFieldStyle(.roundedBorder)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { manualWireControls }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { manualWireControls }
                }
            }
            .padding(.top, WorkbenchSpacing.xs)
        } label: {
            Text("Advanced: manual single-file wiring")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
        }
        .formSection {}
    }

    private func previewWire() {
        errorMessage = nil
        result = nil
        isPreviewing = true
        let m = model, p = path, t = target
        Task {
            defer { isPreviewing = false }
            do {
                let wire = try await appHost.api.wirePreview(model: m, path: p, target: t)
                preview = wire.config ?? ["preview_hash": wire.preview_hash ?? ""]
                previewHash = wire.preview_hash
            } catch let error as BridgeError {
                preview = nil
                previewHash = nil
                errorMessage = error.errorDescription
            } catch {
                preview = nil
                previewHash = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply() {
        guard let previewHash else { return }
        errorMessage = nil
        result = nil
        let m = model, p = path, t = target, h = previewHash
        Task {
            do {
                let wire = try await appHost.api.wireApply(model: m, path: p, previewHash: h, target: t)
                result = "Wiring applied."
                preview = wire.config
                self.previewHash = wire.preview_hash
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
