import SwiftUI

// MARK: - ConvertView
// GGUF → MLX conversion: pick a source, preview the plan, confirm with hash.

struct ConvertView: View {
    @ObservedObject var appHost: AppHost

    @State private var selectedModel: ModelItem?
    @State private var qBits: Int = 4
    @State private var out: String = ""
    @State private var isPreviewing = false
    @State private var preview: [String: Any]?
    @State private var confirmResult: String?
    @State private var errorMessage: String?
    @State private var showingPicker = false

    private var previewHash: String? {
        guard let dict = preview else { return nil }
        if let h = dict["preview_hash"] as? String { return h }
        if let plan = dict["plan"] as? [String: Any], let h = plan["preview_hash"] as? String { return h }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceSection
                if let preview {
                    planSection
                }
                ErrorBanner(text: errorMessage)
                if let confirmResult {
                    Text(confirmResult)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingPicker) {
            ModelPickerSheet(appHost: appHost, selected: $selectedModel)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Source")
            HStack {
                Button("Choose GGUF…") { showingPicker = true }
                Text(selectedModel?.name ?? "No model selected")
                    .foregroundColor(selectedModel == nil ? .secondary : .primary)
                Spacer()
            }
            HStack {
                Picker("Quantization", selection: $qBits) {
                    Text("4-bit").tag(4)
                    Text("8-bit").tag(8)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
            }
            HStack {
                TextField("Output dir (optional)", text: $out)
                    .textFieldStyle(.roundedBorder)
                Button("Preview") {
                    previewPlan()
                }
                .disabled(selectedModel == nil || isPreviewing)
            }
        }
        .formSection {}
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Plan")
                Spacer()
                Button("Confirm & Convert") {
                    confirm()
                }
                .disabled(previewHash == nil)
            }
            PreviewDictView(value: preview ?? [:])
        }
        .formSection {}
    }

    private func previewPlan() {
        guard let model = selectedModel else { return }
        errorMessage = nil
        confirmResult = nil
        isPreviewing = true
        let targetQ = qBits
        let targetOut = out.isEmpty ? nil : out
        Task {
            defer { isPreviewing = false }
            do {
                preview = try await appHost.api.convertPreview(
                    ggufPath: model.path, qBits: targetQ, out: targetOut
                )
            } catch let error as BridgeError {
                preview = nil
                errorMessage = error.errorDescription
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirm() {
        guard let model = selectedModel, let hash = previewHash else { return }
        errorMessage = nil
        confirmResult = nil
        let targetQ = qBits
        let targetOut = out.isEmpty ? nil : out
        Task {
            do {
                let result = try await appHost.api.convertStart(
                    ggufPath: model.path, qBits: targetQ, out: targetOut, previewHash: hash
                )
                confirmResult = "Conversion submitted. See Jobs."
                preview = nil
                _ = result
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - ModelPickerSheet

struct ModelPickerSheet: View {
    @ObservedObject var appHost: AppHost
    @Binding var selected: ModelItem?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var models: [ModelItem] {
        let all = appHost.scanResult?.models ?? []
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.modelKey?.localizedCaseInsensitiveContains(search) == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a GGUF").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            List(models) { item in
                Button {
                    selected = item
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.modelKey ?? item.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if let q = item.quantization {
                            Text(q).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
        .onAppear {
            if appHost.scanResult == nil {
                Task { await appHost.rescan() }
            }
        }
    }
}