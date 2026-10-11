import AppKit
import SwiftUI

// MARK: - LMStudioView
// Find GGUF files in LM Studio model directories and hand them to Prepare.

enum LMStudioScanState: Equatable {
    case notRun
    case running
    case completed([LMStudioView.LMSModel])
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var models: [LMStudioView.LMSModel] {
        if case .completed(let models) = self { return models }
        return []
    }
    var symbol: String {
        switch self {
        case .notRun, .running: return "square.and.arrow.down"
        case .completed: return "folder.badge.questionmark"
        case .failed: return "exclamationmark.triangle"
        }
    }
    var message: String {
        switch self {
        case .notRun: return "Scan LM Studio's model folders for GGUF files, or choose an additional source directory."
        case .running: return "Scanning LM Studio model folders…"
        case .completed: return "No GGUF files found. Choose another source directory, then scan again."
        case .failed(let message): return "Scan failed. \(message) Check the source directory, then scan again."
        }
    }
}

struct LMStudioView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (AppRoute) -> Void

    @State private var sourceDir = ""
    @State private var scanState: LMStudioScanState = .notRun

    private var isScanning: Bool { scanState.isRunning }
    private var models: [LMSModel] { scanState.models }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
    }

    struct LMSModel: Identifiable, Equatable {
        let path: String
        let name: String
        let size: Int64
        var id: String { path }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                sourceSection
                if models.isEmpty {
                    scanNotice
                }
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        SectionTitle(text: "Found \(models.count) GGUF models")
                        ForEach(models) { model in
                            HStack(spacing: WorkbenchSpacing.sm) {
                                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                                    Text(model.name).font(WorkbenchTypography.body)
                                    Text(model.path)
                                        .font(WorkbenchTypography.secondary)
                                        .foregroundStyle(WorkbenchColor.muted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))
                                    .font(WorkbenchTypography.secondary)
                                    .foregroundStyle(WorkbenchColor.muted)
                                Button("Prepare…") { prepare(model) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            .padding(.vertical, WorkbenchSpacing.xxxs)
                        }
                        Text("Prepare opens a conversion preview for the chosen GGUF.")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            SectionTitle(text: "Find GGUF models")
            Text("Scans ~/.lmstudio/models and ~/.cache/lm-studio/models. Add a source directory to scan another folder as well.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("Additional source directory (optional)")
                .font(WorkbenchTypography.label)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { scanControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { scanControls }
            }
        }
        .formSection {}
    }

    private var scanNotice: some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            if isScanning {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Scanning LM Studio model folders")
            } else {
                Image(systemName: scanState.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            Text(scanState.message)
                .font(WorkbenchTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .foregroundStyle(scanState.isFailed ? WorkbenchColor.failure : WorkbenchColor.muted)
    }

    @ViewBuilder
    private var scanControls: some View {
        TextField("Optional source dir", text: $sourceDir)
            .textFieldStyle(.roundedBorder)
            .disabled(isScanning)
        Button("Choose…") { chooseSourceDirectory() }
            .buttonStyle(.bordered)
            .disabled(isScanning)
        Button("Scan LM Studio") { scan() }
            .buttonStyle(.borderedProminent)
            .disabled(isScanning)
    }

    private func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let path = sourceDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { sourceDir = url.path }
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
        onRouteSelection(.prepare)
    }

    private func scan() {
        guard !isScanning else { return }
        let path = sourceDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedSource = path.isEmpty ? nil : path
        scanState = .running
        Task {
            do {
                let models = try await Self.discoverLMStudio(sourceDir: requestedSource)
                    .map {
                        LMSModel(path: $0.path, name: $0.name, size: $0.size)
                    }
                scanState = .completed(models)
            } catch {
                scanState = .failed(error.localizedDescription)
            }
        }
    }

    static func discoverLMStudio(sourceDir: String?) async throws -> [(path: String, name: String, size: Int64)] {
        var dirs: [URL] = []
        let home = URL(fileURLWithPath: NSHomeDirectory())
        dirs.append(home.appendingPathComponent(".lmstudio/models"))
        dirs.append(home.appendingPathComponent(".cache/lm-studio/models"))
        if let sourceDir, !sourceDir.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceDir, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: sourceDir) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                    NSLocalizedDescriptionKey: "The source directory is unavailable or unreadable: \(sourceDir)"
                ])
            }
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
