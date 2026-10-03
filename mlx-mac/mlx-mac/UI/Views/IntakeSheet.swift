import SwiftUI
import AppKit

// MARK: - IntakeWindow

/// The single Add from Hugging Face window; every entry point opens it by id.
enum IntakeWindow {
    static let id = "hf-intake"
}

// MARK: - IntakeMenuCommand

/// ⇧⌘V menu item: loads the pasteboard into the shared coordinator and opens
/// the one intake window.
struct IntakeMenuCommand: View {
    @ObservedObject var intake: IntakeCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Add from Hugging Face…") {
            intake.open(with: NSPasteboard.general.string(forType: .string))
            openWindow(id: IntakeWindow.id)
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
    }
}

// MARK: - IntakeField (Prepare tab)

struct IntakeField: View {
    @ObservedObject var intake: IntakeCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""

    var body: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Add from Hugging Face")
                HStack(spacing: WorkbenchSpacing.sm) {
                    TextField("Paste a model link or org/name", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(open)
                    Button("Check", action: open)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Shows what the model is and how it converts before anything downloads. ⇧⌘V opens this from anywhere.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    private func open() {
        intake.open(with: text)
        openWindow(id: IntakeWindow.id)
    }
}

// MARK: - IntakeSheet

struct IntakeSheet: View {
    @ObservedObject var intake: IntakeCoordinator
    @ObservedObject var appHost: AppHost
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Add from Hugging Face")
                .font(WorkbenchTypography.title)
            HStack(spacing: WorkbenchSpacing.sm) {
                TextField("https://huggingface.co/org/name", text: $intake.sourceText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await intake.resolve() } }
                Button("Check") { Task { await intake.resolve() } }
                    .disabled(intake.isBusy || intake.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    activityLine
                    if let resolution = intake.resolution {
                        summary(resolution)
                        componentsTable(resolution)
                        actions(resolution)
                        if let analysis = intake.analysis {
                            PortAnalysisPanel(intake: intake, analysis: analysis)
                        }
                    }
                    if !intake.logTail.isEmpty {
                        Text(intake.logTail.joined(separator: "\n"))
                            .font(WorkbenchTypography.value)
                            .foregroundStyle(WorkbenchColor.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 640)
        .background(WorkbenchColor.canvas)
    }

    @ViewBuilder
    private var activityLine: some View {
        switch intake.activity {
        case .idle:
            EmptyView()
        case .resolving:
            ProgressView("Reading the model card and config…").controlSize(.small)
        case .installing(let backend):
            ProgressView("Installing \(backend) into its own environment…").controlSize(.small)
        case .downloading(let repo):
            ProgressView("Downloading \(repo)…").controlSize(.small)
        case .analyzing:
            ProgressView("Analyzing the architecture…").controlSize(.small)
        case .drafting:
            ProgressView("Drafting a port plan with a local model…").controlSize(.small)
        case .failed(let message):
            InlineMessage(kind: .error, text: message)
        }
    }

    private func summary(_ resolution: IntakeResolution) -> some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack {
                    Text(resolution.source.reference).font(WorkbenchTypography.section)
                    Spacer()
                    StatusBadge(state: resolution.verdict.rawValue)
                }
                DetailGrid(rows: IntakePresentation.summaryRows(resolution, qBits: appHost.config.qBits))
                ForEach(IntakePresentation.reasonTexts(resolution), id: \.self) { text in
                    InlineMessage(kind: .warning, text: text)
                }
            }
        }
    }

    private func componentsTable(_ resolution: IntakeResolution) -> some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                SectionTitle(text: "Components")
                ForEach(resolution.components) { component in
                    HStack(alignment: .firstTextBaseline) {
                        Text(component.role).font(WorkbenchTypography.label).frame(width: 80, alignment: .leading)
                        Text(component.modelType).font(WorkbenchTypography.value)
                        Spacer()
                        Text(component.matches.first.map { "\($0.module) (\($0.match))" } ?? "no MLX implementation")
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(component.matches.isEmpty ? WorkbenchColor.warning : WorkbenchColor.muted)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ resolution: IntakeResolution) -> some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            switch resolution.verdict {
            case .convertibleAfterInstall:
                Button("Install \(resolution.backend ?? "backend")") { Task { await intake.installBackend() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(intake.isBusy)
            case .convertible:
                Button("Download and prepare") { Task { await finish(resolution) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(intake.isBusy)
            case .alreadyMLX:
                Button("Download") { Task { await finish(resolution) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(intake.isBusy)
            case .gguf:
                Picker("File", selection: $intake.selectedGGUF) {
                    ForEach(resolution.files.gguf) { file in
                        Text("\(file.name) · \(LibraryTablePresentation.byteCount(file.bytes))").tag(Optional(file.name))
                    }
                }
                .frame(maxWidth: 420)
                Button("Download and prepare") { Task { await finish(resolution) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(intake.isBusy || intake.selectedGGUF == nil)
            case .unknown:
                Button("Retry") { Task { await intake.resolve() } }
                    .disabled(intake.isBusy)
            case .blocked, .unsupported:
                EmptyView()
            }
            Spacer()
            Link("Open on Hugging Face", destination: URL(string: resolution.source.url) ?? URL(string: "https://huggingface.co")!)
        }
    }

    private func finish(_ resolution: IntakeResolution) async {
        let directory = appHost.intakeDownloadDirectory(for: resolution)
        guard let path = await intake.download(localDir: directory) else { return }
        if let route = await appHost.finishIntake(resolution, downloadedPath: path, selectedFile: intake.selectedGGUF) {
            dismiss()
            onRouteSelection(route)
        }
    }
}

// MARK: - IntakePresentation

enum IntakePresentation {
    /// `qBits` is the configured width; a source that converts only at other widths shows the one Prepare will use.
    static func summaryRows(_ resolution: IntakeResolution, qBits configured: Int) -> [DetailRow] {
        let qBits = ModelWorkflowCoordinator.allowedBits(configured, allowed: resolution.qBits)
        var rows = [DetailRow("Verdict", resolution.verdict.title)]
        if let task = resolution.task {
            rows.append(DetailRow("Type", task.type.title))
            if !task.useCases.isEmpty {
                rows.append(DetailRow("Use cases", task.useCases.map(ModelTaskPresentation.useCaseTitle).joined(separator: ", ")))
            }
        }
        if let backend = resolution.backend {
            rows.append(DetailRow("Backend", "\(backend)\(resolution.backendInstalled ? "" : " (not installed)")"))
        }
        rows.append(DetailRow("Architecture", resolution.modelType ?? "Unknown"))
        rows.append(DetailRow("Download", LibraryTablePresentation.byteCount(resolution.downloadBytes ?? resolution.bytes)))
        if let estimate = resolution.estimatedOutputBytes?[String(qBits)] {
            rows.append(DetailRow("Estimated \(qBits)-bit output", LibraryTablePresentation.byteCount(estimate)))
        }
        return rows
    }

    static func reasonTexts(_ resolution: IntakeResolution) -> [String] {
        resolution.reasons.map { reason in
            switch reason {
            case "arch_not_in_registry": return "No installed or declared MLX backend implements \(resolution.modelType ?? "this architecture")."
            case "custom_code": return "The repository ships custom modeling code; it is read, never executed."
            case "no_config": return "The repository has no readable config.json."
            case "gated": return "The repository is gated; downloads need a token, which intake does not handle."
            case "not_found_or_private": return "The repository does not exist or is private."
            case "hub_unreachable": return "Hugging Face could not be reached."
            default: return reason
            }
        } + resolution.warnings
    }
}
