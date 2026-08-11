import SwiftUI

// MARK: - WireView
// Preview / apply runtime wiring for a model into a target config.

struct WireView: View {
    @ObservedObject var appHost: AppHost

    @State private var model = ""
    @State private var path = ""
    @State private var target = "mlx_lm"
    @State private var isPreviewing = false
    @State private var preview: [String: Any]?
    @State private var previewHash: String?
    @State private var result: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                formSection
                ErrorBanner(text: errorMessage)
                if let result {
                    Text(result).font(.caption).foregroundColor(.green)
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
                        PreviewDictView(value: preview)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding()
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Wire a model")
            HStack {
                TextField("Model repo id", text: $model)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Config file path", text: $path)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Picker("Target", selection: $target) {
                    Text("mlx_lm").tag("mlx_lm")
                    Text("mlx-vlm").tag("mlx-vlm")
                    Text("ollama").tag("ollama")
                    Text("lmstudio").tag("lmstudio")
                    Text("litellm").tag("litellm")
                }
                .frame(width: 180)
                Spacer()
                Button("Preview Wire") {
                    previewWire()
                }
                .disabled(model.isEmpty || path.isEmpty || isPreviewing)
            }
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