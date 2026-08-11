import SwiftUI

// MARK: - ModelsView
// Local GGUF inventory via `convert scan`, with per-model detail.

struct ModelsView: View {
    @ObservedObject var appHost: AppHost
    @State private var selected: ModelItem?
    @State private var limit: String = ""
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    private var models: [ModelItem] {
        appHost.scanResult?.models ?? []
    }

    private var outputs: [MLXOutput] {
        appHost.scanResult?.outputs ?? []
    }

    private var totals: ScanTotals? {
        appHost.scanResult?.totals
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Models")
                    .font(.title2)
                Spacer()
                TextField("Limit e.g. 200", text: $limit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button("Scan") {
                    refresh()
                }
                .disabled(appHost.isScanning || isRefreshing)
            }

            if let totals {
                HStack(spacing: 12) {
                    statCard("GGUF", "\(totals.gguf)")
                    statCard("Pending", "\(totals.pending)")
                    statCard("Converted", "\(totals.converted)")
                    statCard("Unreadable", "\(totals.unreadable)")
                    statCard("Bytes", ByteCountFormatter.string(fromByteCount: totals.bytes, countStyle: .file))
                }
            }

            ErrorBanner(text: errorMessage)

            if appHost.isScanning || isRefreshing {
                ProgressView("Scanning…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else if !models.isEmpty || !outputs.isEmpty {
                List {
                    if !models.isEmpty {
                        Section("GGUF pending & companions") {
                            ForEach(models) { item in
                                modelRow(item)
                            }
                        }
                    }
                    if !outputs.isEmpty {
                        Section("MLX output") {
                            ForEach(outputs) { output in
                                outputRow(output)
                            }
                        }
                    }
                }
            } else {
                Text("No models found. Configure scan roots in Settings, then Scan.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            }
        }
        .padding()
        .sheet(item: $selected) { model in
            ModelDetailSheet(model: model)
        }
        .onAppear {
            if appHost.scanResult == nil {
                refresh()
            }
        }
    }

    private func modelRow(_ item: ModelItem) -> some View {
        Button {
            selected = item
        } label: {
            HStack(alignment: .center, spacing: 10) {
                StatusPill(state: item.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                    Text(item.modelKey ?? item.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let q = item.quantization {
                    Text(q).font(.caption).foregroundColor(.secondary)
                }
                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func outputRow(_ output: MLXOutput) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.box")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(output.path.components(separatedBy: "/").last ?? output.path)
                Text(output.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let q = output.quantization {
                Text("\(q.bits)bit")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title3).fontWeight(.medium)
        }
        .padding(8)
        .frame(minWidth: 90, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func refresh() {
        errorMessage = nil
        appHost.lastError = nil
        isRefreshing = true
        let parsedLimit = Int(limit.trimmingCharacters(in: .whitespaces)) ?? nil
        Task {
            await appHost.rescan(limit: parsedLimit)
            isRefreshing = false
            if appHost.scanResult == nil {
                errorMessage = appHost.lastError ?? "Scan returned no usable payload."
            }
        }
    }
}

// MARK: - ModelDetailSheet

struct ModelDetailSheet: View {
    let model: ModelItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.name).font(.title3)
                Spacer()
                StatusPill(state: model.status)
                Button("Close") { dismiss() }
            }
            Divider()
            detailRow("Path", model.path)
            if let key = model.modelKey { detailRow("Model key", key) }
            if let arch = model.architecture { detailRow("Architecture", arch) }
            if let q = model.quantization { detailRow("Quantization", q) }
            if let params = model.parameters { detailRow("Parameters", params) }
            if let sig = model.signature { detailRow("Signature", sig) }
            detailRow("Size", ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
            if let tensorCount = model.tensorCount { detailRow("Tensors", "\(tensorCount)") }
            if let readable = model.readable { detailRow("Readable", readable ? "yes" : "no") }
            if let error = model.error { detailRow("Error", error) }
            if !model.outputs.isEmpty {
                detailRow("Outputs", model.outputs.joined(separator: "\n"))
            }
            Spacer()
        }
        .padding()
        .frame(width: 520, height: 460)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
