import SwiftUI

// MARK: - LMStudioView
// Import GGUF files from LM Studio model directories.

struct LMStudioView: View {
    @ObservedObject var appHost: AppHost

    @State private var sourceDir = ""
    @State private var isScanning = false
    @State private var models: [LMSModel] = []
    @State private var errorMessage: String?

    struct LMSModel: Identifiable {
        let path: String
        let name: String
        let size: Int64
        var id: String { path }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    TextField("Optional source dir", text: $sourceDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Scan LM Studio") { scan() }
                        .disabled(isScanning)
                    Spacer()
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
                            HStack {
                                Text(model.name).font(.body)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        Text("Use the Convert tab to convert a chosen GGUF.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding()
        }
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
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                found.append((url.path, url.lastPathComponent, Int64(size)))
            }
        }
        return found
    }
}