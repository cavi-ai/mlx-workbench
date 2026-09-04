import SwiftUI

// MARK: - AdoptView
// Durable role handoff via `adopt start`. The state file returned by the
// agent is tracked automatically; users never type internal paths.

struct AdoptView: View {
    @ObservedObject var appHost: AppHost

    @State private var role = ""
    @State private var fast = false
    @State private var offline = false
    @State private var isRunning = false
    @State private var result: AdoptResult?
    @State private var statusResult: AdoptResult?
    @State private var errorMessage: String?

    /// The state path reported by the most recent adopt run. Status checks
    /// use this automatically instead of asking the user for a path.
    private var trackedStatePath: String? {
        result?.state ?? statusResult?.state
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                formSection
                ErrorBanner(text: errorMessage)
                if let result {
                    resultSection(result)
                }
                statusSection
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Adopt a role")
            Text("Pick the role this machine should fill. The agent verifies and wires a model for it.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Role (e.g. coding, writing, agent)", text: $role)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: WorkbenchSpacing.md) {
                Toggle("Fast", isOn: $fast)
                Toggle("Offline", isOn: $offline)
                Spacer()
                Button("Start Adoption") { startAdopt() }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchColor.fluxTeal)
                    .disabled(role.isEmpty || isRunning)
            }
        }
        .formSection {}
    }

    private func resultSection(_ result: AdoptResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Result")
            HStack {
                if let status = result.status {
                    StatusPill(state: status)
                }
                Text(result.message ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            if let model = result.model {
                Text("Model: \(model)").font(.caption).textSelection(.enabled)
            }
            if let manager = result.manager {
                Text("Manager: \(manager)").font(.caption)
            }
        }
        .formSection {}
    }

    @ViewBuilder
    private var statusSection: some View {
        if let statePath = trackedStatePath {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionTitle(text: "Adoption status")
                    Spacer()
                    Button("Refresh Status") { checkStatus(statePath: statePath) }
                        .buttonStyle(.bordered)
                        .disabled(isRunning)
                }
                if let statusResult {
                    if let status = statusResult.status {
                        HStack {
                            StatusPill(state: status)
                            Text(statusResult.message ?? "").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if let model = statusResult.model {
                        Text("Model: \(model)").font(.caption)
                    }
                } else {
                    Text("Adoption is tracked at \(statePath)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formSection {}
        }
    }

    private func startAdopt() {
        errorMessage = nil
        result = nil
        statusResult = nil
        isRunning = true
        let r = role, f = fast, o = offline
        Task {
            defer { isRunning = false }
            do {
                result = try await appHost.api.adoptStart(role: r, state: nil, fast: f, offline: o)
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func checkStatus(statePath: String) {
        errorMessage = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                statusResult = try await appHost.api.adoptStatus(state: statePath)
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
