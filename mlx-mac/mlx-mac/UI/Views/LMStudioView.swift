import SwiftUI

// MARK: - LMStudioView
// Find GGUF files in LM Studio model directories and hand them to Prepare.

struct LMStudioView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (String) -> Void

    @State private var sourceDir = ""
    @State private var isScanning = false
    @State private var models: [LMSModel] = []
    @State private var errorMessage: String?

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
    }

    struct LMSModel: Identifiable {
        let path: String
        let name: String
        let size: Int64
        var id: String { path }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { scanControls }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { scanControls }
                }
                if isScanning {
                    ProgressView("Scanning…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ErrorBanner(text: errorMessage)
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: "Found \(models.count) GGUF models")
                        ForEach(models) { model in
                            HStack(spacing: WorkbenchSpacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name).font(.body)
                                    Text(model.path)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button("Prepare…") { prepare(model) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                        Text("Prepare opens a conversion preview for the chosen GGUF.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    @ViewBuilder
    private var scanControls: some View {
        TextField("Optional source dir", text: $sourceDir)
            .textFieldStyle(.roundedBorder)
        Button("Scan LM Studio") { scan() }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.fluxTeal)
            .disabled(isScanning)
    }

    /// Hand a discovered GGUF to the Prepare flow as if the library scan had
    /// surfaced it: pending conversion status, no outputs yet.
    private func prepare(_ model: LMSModel) {
        let item = ModelItem(
            path: model.path,
            name: model.name,
            bytes: model.size,
            modifiedAt: nil,
            shard: nil,
            modelKey: nil,
            architecture: nil,
            quantization: nil,
            parameters: nil,
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: "pending",
            outputs: [],
            tensorCount: nil,
            error: nil
        )
        appHost.selectedModelPath = model.path
        appHost.modelWorkflow.inspect(source: item, snapshot: appHost.librarySnapshot)
        onRouteSelection(AppRoute.prepare.rawValue)
    }

    private func scan() {
        errorMessage = nil
        isScanning = true
        Task {
            defer { isScanning = false }
            do {
                let models = try await Self.discoverLMStudio(sourceDir: sourceDir.isEmpty ? nil : sourceDir)
                    .map {
                        LMSModel(path: $0.path, name: $0.name, size: $0.size)
                    }
                self.models = models
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    static func discoverLMStudio(sourceDir: String?) async throws -> [(path: String, name: String, size: Int64)] {
        var dirs: [URL] = []
        let home = URL(fileURLWithPath: NSHomeDirectory())
        dirs.append(home.appendingPathComponent(".lmstudio/models"))
        dirs.append(home.appendingPathComponent(".cache/lm-studio/models"))
        if let sourceDir, !sourceDir.isEmpty {
            dirs.insert(URL(fileURLWithPath: sourceDir), at: 0)
        }
        var found: [(path: String, name: String, size: Int64)] = []
        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            while let item = enumerator.nextObject() {
                guard let url = item as? URL else { continue }
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                found.append((url.path, url.lastPathComponent, Int64(size)))
            }
        }
        return found
    }
}
