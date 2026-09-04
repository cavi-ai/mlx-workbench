import AppKit
import SwiftUI

// MARK: - TrainingView
// LoRA preview/confirm training on a cached base model.

struct TrainingView: View {
    @ObservedObject var appHost: AppHost

    @State private var repo = ""
    @State private var data = ""
    @State private var itersText = "100"
    @State private var out = ""
    @State private var isPreviewing = false
    @State private var preview: [String: Any]?
    @State private var notice: String?
    @State private var errorMessage: String?

    private var previewHash: String? {
        if let h = preview?["preview_hash"] as? String { return h }
        if let plan = preview?["plan"] as? [String: Any], let h = plan["preview_hash"] as? String { return h }
        return nil
    }

    private var iters: Int? {
        Int(itersText.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                formSection
                if preview != nil {
                    planSection
                }
                ErrorBanner(text: errorMessage)
                if let notice {
                    Text(notice).font(.caption).foregroundColor(WorkbenchColor.verifiedGreen)
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "LoRA fine-tune")
            if !cachedRepoIdentities.isEmpty {
                Picker("Cached base model", selection: cachedRepoSelection) {
                    Text("Custom repo id…").tag("")
                    ForEach(cachedRepoIdentities, id: \.self) { identity in
                        Text(identity).tag(identity)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            HStack {
                TextField("Base model repo id", text: $repo)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: WorkbenchSpacing.xs) {
                TextField("Dataset path", text: $data)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseDataset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { trainingControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { trainingControls }
            }
        }
        .formSection {}
    }

    /// Hugging Face repo ids for models already in the local cache, so the
    /// base model can be picked instead of typed.
    private var cachedRepoIdentities: [String] {
        let models = appHost.librarySnapshot?.models ?? []
        var identities: Set<String> = []
        for model in models {
            for path in [model.item.path] + model.outputPaths {
                if let repoID = HFRepoID.forPath(path) {
                    identities.insert(repoID)
                }
            }
        }
        return identities.sorted()
    }

    private var cachedRepoSelection: Binding<String> {
        Binding(
            get: { cachedRepoIdentities.contains(repo) ? repo : "" },
            set: { if !$0.isEmpty { repo = $0 } }
        )
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Training plan")
                Spacer()
                Button("Confirm & Train") { confirmTraining() }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchColor.fluxTeal)
                    .disabled(previewHash == nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                planRow("Base model", repo)
                planRow("Dataset", data)
                planRow("Iterations", itersText)
                if !out.isEmpty {
                    planRow("Output", out)
                }
            }
            if let preview {
                RawJSONDisclosure("Raw plan payload", value: preview)
            }
        }
        .formSection {}
    }

    private func planRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trainingControls: some View {
        TextField("Iterations", text: $itersText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        TextField("Output (optional)", text: $out)
            .textFieldStyle(.roundedBorder)
            if previewHash == nil {
                Button("Preview Training") { previewTraining() }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchColor.fluxTeal)
                    .disabled(repo.isEmpty || data.isEmpty || isPreviewing)
            } else {
                Button("Preview Training") { previewTraining() }
                    .buttonStyle(.bordered)
                    .disabled(repo.isEmpty || data.isEmpty || isPreviewing)
            }
    }

    private func chooseDataset() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmed)
        }
        if panel.runModal() == .OK, let url = panel.url {
            data = url.path
        }
    }

    private func previewTraining() {        errorMessage = nil
        notice = nil
        isPreviewing = true
        let r = repo, d = data, i = iters, o = out.isEmpty ? nil : out
        Task {
            defer { isPreviewing = false }
            do {
                preview = try await appHost.api.loraPreview(repo: r, data: d, iters: i, out: o)
            } catch let error as BridgeError {
                preview = nil
                errorMessage = error.errorDescription
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmTraining() {
        guard let hash = previewHash else { return }
        errorMessage = nil
        notice = nil
        let r = repo, d = data, i = iters, o = out.isEmpty ? nil : out
        Task {
            do {
                _ = try await appHost.api.loraStart(repo: r, data: d, previewHash: hash, iters: i, out: o)
                notice = "Training submitted. See Jobs."
                preview = nil
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
