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
            VStack(alignment: .leading, spacing: 16) {
                formSection
                if preview != nil {
                    planSection
                }
                ErrorBanner(text: errorMessage)
                if let notice {
                    Text(notice).font(.caption).foregroundColor(.green)
                }
                Spacer()
            }
            .padding()
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "LoRA fine-tune")
            HStack {
                TextField("Base model repo id", text: $repo)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Dataset path", text: $data)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Iterations", text: $itersText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Output (optional)", text: $out)
                    .textFieldStyle(.roundedBorder)
                Spacer()
                Button("Preview Training") { previewTraining() }
                    .disabled(repo.isEmpty || data.isEmpty || isPreviewing)
            }
        }
        .formSection {}
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Training plan")
                Spacer()
                Button("Confirm & Train") { confirmTraining() }
                    .disabled(previewHash == nil)
            }
            PreviewDictView(value: preview ?? [:])
        }
        .formSection {}
    }

    private func previewTraining() {
        errorMessage = nil
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
