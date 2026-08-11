import SwiftUI

// MARK: - QuantView
// Compare size/format trade-offs for a model via `convert preview` across bits.

struct QuantView: View {
    @ObservedObject var appHost: AppHost

    @State private var selectedModel: ModelItem?
    @State private var profiles: [Profile] = []
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var showingPicker = false

    struct Profile: Identifiable {
        let id: String
        let bits: Int
        let plan: [String: Any]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button("Choose GGUF…") { showingPicker = true }
                    Text(selectedModel?.name ?? "No model selected")
                        .foregroundColor(selectedModel == nil ? .secondary : .primary)
                    Spacer()
                    Button("Compare 4/8-bit") { compare() }
                        .disabled(selectedModel == nil || isRunning)
                }
                if isRunning {
                    ProgressView("Profiling…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ErrorBanner(text: errorMessage)
                if !profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Quantization plan (size + preview hash)")
                        ForEach(profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(profile.bits)-bit")
                                    .font(.headline)
                                PreviewDictView(value: planSummary(profile.plan))
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingPicker) {
            ModelPickerSheet(appHost: appHost, selected: $selectedModel)
        }
    }

    private func planSummary(_ plan: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["preview_hash", "out", "size", "source", "q_bits"] {
            if let value = plan[key] {
                out[key] = "\(value)"
            }
        }
        if out.isEmpty {
            out["note"] = "Preview returned no structured plan. See Jobs for details."
        }
        return out
    }

    private func compare() {
        guard let model = selectedModel else { return }
        errorMessage = nil
        profiles = []
        isRunning = true
        let path = model.path
        Task {
            for bits in [4, 8] {
                do {
                    let plan = try await appHost.api.convertPreview(ggufPath: path, qBits: bits, out: nil)
                    profiles.append(Profile(id: "\(path)-\(bits)", bits: bits, plan: plan))
                } catch let error as BridgeError {
                    profiles.append(Profile(id: "\(path)-\(bits)", bits: bits,
                                            plan: ["error": error.message]))
                } catch {
                    profiles.append(Profile(id: "\(path)-\(bits)", bits: bits,
                                            plan: ["error": error.localizedDescription]))
                }
            }
            isRunning = false
        }
    }
}
