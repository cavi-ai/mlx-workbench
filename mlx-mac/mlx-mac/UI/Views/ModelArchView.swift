import SwiftUI

// MARK: - ModelArchView
// Architecture summary for a chosen model from the scan metadata.

struct ModelArchView: View {
    @ObservedObject var appHost: AppHost

    @State private var selectedModel: ModelItem?
    @State private var showingPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { modelPickerControls }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { modelPickerControls }
                }
                if let model = selectedModel {
                    archCard(model)
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .sheet(isPresented: $showingPicker) {
            ModelPickerSheet(appHost: appHost, selected: $selectedModel)
        }
    }

    @ViewBuilder
    private var modelPickerControls: some View {
        Button("Choose Model…") { showingPicker = true }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.fluxTeal)
        Text(selectedModel?.name ?? "No model selected")
            .font(WorkbenchTypography.monoUtility)
            .foregroundColor(selectedModel == nil ? WorkbenchColor.graphiteMuted : WorkbenchColor.graphiteInk)
            .textSelection(.enabled)
    }

    private func archCard(_ model: ModelItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: model.name)
            archRow("Architecture", model.architecture ?? "unknown")
            archRow("Parameters", model.parameters ?? "unknown")
            archRow("Quantization", model.quantization ?? "unknown")
            archRow("Model key", model.modelKey ?? "unknown")
            archRow("Status", model.status)
            archRow("Size", ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
            if let tensors = model.tensorCount {
                archRow("Tensors", "\(tensors)")
            }
            if let shard = model.shard {
                archRow("Shard", shard)
            }
            Divider()
            Text(model.path)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .formSection {}
    }

    private func archRow(_ label: String, _ value: String) -> some View {
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
