import SwiftUI

// MARK: - AdoptView
// Durable role handoff via `adopt start`.

struct AdoptView: View {
    @ObservedObject var appHost: AppHost

    @State private var role = ""
    @State private var statePath = ""
    @State private var fast = false
    @State private var offline = false
    @State private var isRunning = false
    @State private var result: AdoptResult?
    @State private var statusResult: AdoptResult?
    @State private var errorMessage: String?

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
            HStack {
                TextField("Role (e.g. coding, writing, agent)", text: $role)
                    .textFieldStyle(.roundedBorder)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { adoptionControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { adoptionControls }
            }
        }
        .formSection {}
    }

    @ViewBuilder
    private var adoptionControls: some View {
        TextField("State path (optional)", text: $statePath)
            .textFieldStyle(.roundedBorder)
        Toggle("Fast", isOn: $fast)
        Toggle("Offline", isOn: $offline)
        Button("Start Adoption") { startAdopt() }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.fluxTeal)
            .disabled(role.isEmpty || isRunning)
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
            if let state = result.state {
                Text("State: \(state)").font(.caption).textSelection(.enabled)
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

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: "Adoption status")
                Spacer()
                Button("Check Status") { checkStatus() }
                    .buttonStyle(.bordered)
                    .disabled(statePath.isEmpty || isRunning)
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
            }
        }
        .formSection {}
    }

    private func startAdopt() {
        errorMessage = nil
        result = nil
        isRunning = true
        let r = role, s = statePath.isEmpty ? nil : statePath, f = fast, o = offline
        Task {
            defer { isRunning = false }
            do {
                result = try await appHost.api.adoptStart(role: r, state: s, fast: f, offline: o)
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func checkStatus() {
        guard !statePath.isEmpty else { return }
        errorMessage = nil
        isRunning = true
        let s = statePath
        Task {
            defer { isRunning = false }
            do {
                statusResult = try await appHost.api.adoptStatus(state: s)
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
