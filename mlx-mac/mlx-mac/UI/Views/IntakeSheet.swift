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

    /// A slim row on the page canvas; the explanation lives in the help tag.
    var body: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Text("Add from Hugging Face")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
            TextField("Paste a model link or org/name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
            Button("Check", action: open)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .help("Shows what the model is and how it converts before anything downloads. ⇧⌘V opens this from anywhere.")
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
    let resources: SystemResourceMonitor
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var readyPaths: Set<String> = []
    @State private var logOverride: Bool?

    /// `resources` lets a render hold the window at a fixed memory budget.
    init(
        intake: IntakeCoordinator,
        appHost: AppHost,
        resources: SystemResourceMonitor? = nil,
        onRouteSelection: @escaping (AppRoute) -> Void
    ) {
        self.intake = intake
        self.appHost = appHost
        self.resources = resources ?? appHost.resources
        self.onRouteSelection = onRouteSelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
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
                        actions(resolution)
                        if let analysis = intake.analysis {
                            PortAnalysisPanel(intake: intake, analysis: analysis)
                        }
                    } else if intake.activity == .idle {
                        Text(IntakeActivityPresentation.idleSentence)
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if IntakeLogPresentation.isVisible(activity: intake.activity, lines: intake.logTail) {
                        IntakeLogDisclosure(
                            title: IntakeLogPresentation.title(intake.activity),
                            lines: intake.logTail,
                            isExpanded: logBinding
                        )
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
        .frame(
            minWidth: WorkbenchSize.Intake.minWidth, idealWidth: WorkbenchSize.Intake.idealWidth,
            minHeight: WorkbenchSize.Intake.minHeight, idealHeight: WorkbenchSize.Intake.idealHeight
        )
        .onChange(of: appHost.librarySnapshot?.generatedAt, initial: true) {
            readyPaths = IntakeLibraryMatch.readyPaths(in: appHost.librarySnapshot)
        }
        .onChange(of: intake.activity) {
            logOverride = IntakeLogPresentation.override(logOverride, after: intake.activity)
        }
    }

    private func isInLibrary(_ resolution: IntakeResolution) -> Bool {
        IntakeLibraryMatch.path(for: resolution, readyPaths: readyPaths) != nil
    }

    private var logBinding: Binding<Bool> {
        Binding(
            get: {
                IntakeLogPresentation.isExpanded(override: logOverride, activity: intake.activity, lines: intake.logTail)
            },
            set: { logOverride = $0 }
        )
    }

    @ViewBuilder
    private var activityLine: some View {
        if let sentence = IntakeActivityPresentation.sentence(intake.activity) {
            HStack(spacing: WorkbenchSpacing.xs) {
                ProgressView().controlSize(.small)
                Text(sentence)
            }
        } else if case .failed(let message) = intake.activity {
            InlineMessage(kind: .error, text: message)
        }
    }

    private func summary(_ resolution: IntakeResolution) -> some View {
        let inLibrary = isInLibrary(resolution)
        let verdict = IntakeVerdictLine.make(resolution, inLibrary: inLibrary)
        let components = IntakePresentation.componentRows(resolution)
        return WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                    Text(resolution.source.reference)
                        .font(WorkbenchTypography.section)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: WorkbenchSpacing.sm)
                    if inLibrary {
                        Label("In Library", systemImage: "checkmark.circle.fill")
                            .font(WorkbenchTypography.emphasis)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(WorkbenchColor.success)
                            .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                    Image(systemName: verdict.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(verdict.tone.color)
                        .accessibilityHidden(true)
                    Text(verdict.sentence)
                        .font(WorkbenchTypography.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                ReclaimFlowLayout(spacing: WorkbenchSpacing.lg, lineSpacing: WorkbenchSpacing.sm) {
                    ForEach(IntakePresentation.items(resolution, qBits: appHost.config.qBits)) { item in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            Text(item.figure)
                                .font(item.isNumeric ? WorkbenchTypography.tabular : WorkbenchTypography.body)
                                .foregroundStyle(WorkbenchColor.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.label)
                                .font(WorkbenchTypography.metadata)
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                IntakeFitView(
                    resources: resources, resolution: resolution, qBits: appHost.config.qBits,
                    selectedGGUF: intake.selectedGGUF,
                    reserveGB: appHost.config.fitReserveGB, hardware: appHost.hardwareProfile
                )
                ForEach(IntakePresentation.reasonTexts(resolution), id: \.self) { text in
                    InlineMessage(kind: .warning, text: text)
                }
                if !components.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        SectionTitle(text: "Components")
                        ForEach(components) { row in
                            IntakeComponentLine(
                                role: row.role, type: row.type, detail: row.detail,
                                detailColor: row.isMatched ? WorkbenchColor.muted : WorkbenchColor.warning
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ resolution: IntakeResolution) -> some View {
        ReclaimFlowLayout(spacing: WorkbenchSpacing.sm, lineSpacing: WorkbenchSpacing.xs) {
            switch resolution.verdict {
            case .convertibleAfterInstall:
                Button("Install \(resolution.backend ?? "backend")") { Task { await intake.installBackend() } }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(intake.isBusy)
            case .convertible:
                Button("Download and prepare") { Task { await finish(resolution) } }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(intake.isBusy)
            case .alreadyMLX:
                if let backend = resolution.backend, !resolution.backendInstalled {
                    Button("Install \(backend)") { Task { await intake.installBackend() } }
                        .buttonStyle(.workbenchPrimary)
                        .disabled(intake.isBusy)
                } else {
                    Button(isInLibrary(resolution) ? "Show in Library" : "Download") { Task { await finish(resolution) } }
                        .buttonStyle(.workbenchPrimary)
                        .disabled(intake.isBusy)
                }
            case .gguf:
                Picker("File", selection: $intake.selectedGGUF) {
                    ForEach(resolution.files.gguf) { file in
                        Text("\(file.name) · \(LibraryTablePresentation.byteCount(file.bytes))").tag(Optional(file.name))
                    }
                }
                .frame(maxWidth: 420)
                Button("Download and prepare") { Task { await finish(resolution) } }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(intake.isBusy || intake.selectedGGUF == nil)
            case .unknown:
                Button("Retry") { Task { await intake.resolve() } }
                    .disabled(intake.isBusy)
            case .blocked, .unsupported:
                EmptyView()
            }
            Link("Open on Hugging Face", destination: URL(string: resolution.source.url) ?? URL(string: "https://huggingface.co")!)
        }
    }

    private func finish(_ resolution: IntakeResolution) async {
        if let route = await appHost.reuseIntake(resolution) {
            dismiss()
            onRouteSelection(route)
            return
        }
        let directory = appHost.intakeDownloadDirectory(for: resolution)
        guard let path = await intake.download(localDir: directory) else { return }
        if let route = await appHost.finishIntake(resolution, downloadedPath: path, selectedFile: intake.selectedGGUF) {
            dismiss()
            onRouteSelection(route)
        }
    }
}

// MARK: - Fit

/// The estimated output's fit now. The only intake view that observes the memory monitor.
struct IntakeFitView: View {
    @ObservedObject var resources: SystemResourceMonitor
    let resolution: IntakeResolution
    let qBits: Int
    let selectedGGUF: String?
    let reserveGB: Double
    let hardware: HardwareProfile

    var body: some View {
        if let fit = IntakeFit.make(
            resolution, qBits: qBits, selectedGGUF: selectedGGUF, memory: resources.memory, hasProbed: resources.hasProbed,
            contextTokens: resources.contextTokens, reserveGB: reserveGB, hardware: hardware
        ) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text("Fit on this Mac")
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                HStack(spacing: WorkbenchSpacing.xs) {
                    Image(systemName: fit.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(fit.tone.color)
                        .accessibilityHidden(true)
                    Text(fit.word)
                        .font(WorkbenchTypography.emphasis)
                        .foregroundStyle(fit.tone == .fits ? WorkbenchColor.ink : (fit.tone == .neutral ? WorkbenchColor.muted : fit.tone.color))
                        .redacted(reason: fit.state == .redacted ? .placeholder : [])
                }
                if fit.showsTrack {
                    DiscoverFitBar(fill: fit.fill, tone: fit.tone)
                        .frame(maxWidth: WorkbenchSize.Discover.barWidth)
                }
                Text(fit.detail)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(fit.accessibilityLabel)
        }
    }
}

// MARK: - Components

/// A component's role and type with what implements it; the detail wraps beneath when the row is narrow.
struct IntakeComponentLine: View {
    let role: String
    let type: String
    let detail: String
    let detailColor: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                identity
                Spacer(minLength: WorkbenchSpacing.sm)
                detailText
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                identity
                detailText
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            Text(role)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.ink)
            Text(type)
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.ink)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var detailText: some View {
        Text(detail)
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(detailColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Log

struct IntakeLogDisclosure: View {
    let title: String
    let lines: [String]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(lines.isEmpty ? "No log output yet." : lines.joined(separator: "\n"))
                    .font(WorkbenchTypography.value)
                    .foregroundStyle(WorkbenchColor.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: WorkbenchSize.Prepare.logMaximumHeight)
        } label: {
            Text(title)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.ink)
        }
    }
}

// MARK: - Tone

extension IntakeVerdictLine.Tone {
    var color: Color {
        switch self {
        case .positive: return WorkbenchColor.success
        case .neutral: return WorkbenchColor.accent
        case .warning: return WorkbenchColor.warning
        case .failure: return WorkbenchColor.failure
        }
    }
}
