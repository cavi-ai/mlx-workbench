import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One retained model per comparable task cohort, with the evidence easy to scan.
struct ModelReplacementChainCard: View {
    let chain: ModelReplacementChain

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(WorkbenchColor.success)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Keep \(chain.keeper.name)").font(WorkbenchTypography.roundedHeading)
                    Text(chain.task).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.accent)
                }
                Spacer()
                Text("\(chain.replaced.count) to review").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            }
            memberRow(chain.keeper, symbol: "checkmark", color: WorkbenchColor.success)
            ForEach(chain.replaced, id: \.path) { member in
                memberRow(member, symbol: "arrow.turn.up.right", color: WorkbenchColor.muted)
            }
            DisclosureGroup("Review \(ByteCountFormatter.string(fromByteCount: chain.replaced.reduce(0) { $0 + $1.diskBytes }, countStyle: .file)) · evidence and paths") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("The keeper is no worse on reviewed quality, speed, latency, estimated memory and disk in this task. Other tasks may need the replaced models. These suggestions require review; model folders require manual cleanup.")
                        .font(WorkbenchTypography.secondary)
                    Text(chain.source).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
                    ForEach([chain.keeper] + chain.replaced, id: \.path) { member in
                        Text(member.path).font(WorkbenchTypography.value).textSelection(.enabled)
                    }
                }.padding(.top, WorkbenchSpacing.xs)
            }.font(WorkbenchTypography.secondary)
        }
        .padding(WorkbenchSpacing.sm)
        .background(WorkbenchColor.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: WorkbenchRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: WorkbenchRadius.surface).stroke(WorkbenchColor.accent.opacity(0.2), lineWidth: WorkbenchSpacing.hairline))
    }

    private func memberRow(_ member: ModelReplacementMember, symbol: String, color: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.xs) {
                Label(member.name, systemImage: symbol).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: WorkbenchSpacing.sm)
                Text(metrics(member)).foregroundStyle(WorkbenchColor.muted)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Label(member.name, systemImage: symbol)
                Text(metrics(member)).foregroundStyle(WorkbenchColor.muted)
            }
        }.font(WorkbenchTypography.secondary).foregroundStyle(color)
    }

    private func metrics(_ member: ModelReplacementMember) -> String {
        String(format: "%d/5 · %.1f tok/s · %.2f s first token · %@", member.qualityScore, member.tokensPerSecond, member.firstTokenSeconds,
            ByteCountFormatter.string(fromByteCount: member.diskBytes, countStyle: .file))
    }
}

struct ComparisonInsightsView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject var comparison: ComparisonCoordinator
    @ObservedObject var workflow: WorkflowEvidenceStore
    let models: [LibraryModel]
    let promptSetID: String
    let mode: ComparisonMode
    let onReclaim: () -> Void
    @State private var contextTokens = 8192
    @State private var memory: MemorySnapshot?
    @State private var capturedAt: Date?
    @State private var message: String?
    @State private var error: String?

    private var environment: String? { appHost.watch.currentFingerprintDescription }
    private var replacements: [ReclaimOpportunity] {
        ComparisonInsights.superseded(models: appHost.librarySnapshot?.models ?? [], runs: comparison.runs, workflow: workflow.records, environment: environment, protected: appHost.occupiedModelPaths, contextTokens: contextTokens)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SectionTitle(text: "On this Mac")
            Text(appHost.hardwareProfile.summary).font(WorkbenchTypography.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { memoryControls }
                VStack(alignment: .leading) { memoryControls }
            }
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    ForEach(models, id: \.item.path) { model in decisionRow(model) }
                }.frame(minWidth: 640, alignment: .leading)
            }
            Text("Speed and first-token latency below use the selected prompt set. Compare within the same run; human task reviews and limited validation do not establish general model quality. Fit is an estimate, including context and your configured reserve. GPU utilization and disk I/O are not measured.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            ForEach(ComparisonInsights.taskTradeoffs(models: models, runs: comparison.runs.filter { $0.promptSetID == promptSetID }, environment: environment).prefix(1), id: \.self) { text in
                Text(text).font(WorkbenchTypography.secondary)
            }
            if !replacements.isEmpty {
                ForEach(replacements) { item in
                    if let chain = item.replacement { ModelReplacementChainCard(chain: chain) }
                }
                Button("Review space in Reclaim") { appHost.analyzeReclaim(); onReclaim() }
            }
            DisclosureGroup("Workflow reports and agent evidence") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    Text("Import a report from Claude, OpenClaw, OpenCode or your own workflow. Reports require exact model and environment identities plus a receipt/session source. Import only timings and task scores; omit secrets and transcripts. No harness is connected automatically.")
                        .font(WorkbenchTypography.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { reportControls }
                        VStack(alignment: .leading) { reportControls }
                    }
                    if workflow.records.isEmpty {
                        Text("No workflow measurements imported. Save the empty template for the report contract; export the available local evidence for an agent to analyze.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ForEach(workflow.records.sorted { $0.measuredAt > $1.measuredAt }) { record in
                        workflowRow(record)
                    }
                    if let message { Text(message).font(WorkbenchTypography.secondary) }
                    ErrorBanner(text: error ?? workflow.lastError)
                }.padding(.top, WorkbenchSpacing.xs)
            }
        }
        .formSection {}
        .task { await refreshMemory() }
    }

    @ViewBuilder private var memoryControls: some View {
        Picker("Context", selection: $contextTokens) {
            ForEach([2048, 8192, 32768, 65536], id: \.self) { Text("\($0) tokens").tag($0) }
        }.frame(width: 220)
        Button("Refresh headroom") { Task { await refreshMemory() } }
        Text(capturedAt.map { "Captured \($0.formatted(date: .omitted, time: .standard)) · available \(bytes(memory?.availableBytes)) · reserve \(String(format: "%.1f", appHost.config.fitReserveGB)) GB" } ?? "Memory capture pending")
            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
    }

    @ViewBuilder private func decisionRow(_ model: LibraryModel) -> some View {
        let measured = ComparisonInsights.currentResult(model: model, runs: comparison.runs, environment: environment, promptSetID: promptSetID)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                Text(model.displayName).font(WorkbenchTypography.body).frame(width: 200, alignment: .leading)
                VStack(alignment: .leading) {
                    if mode == .chat {
                        Text("\(metric(measured?.1.aggregateTokensPerSecond, unit: "tok/s")) · first token \(metric(measured?.1.aggregateTTFTSeconds, unit: "s"))")
                    } else {
                        Text("\(mode.primaryMetric.title): \(ComparisonInsights.positive(measured?.1.aggregateMetric).map { mode.primaryMetric.format($0) } ?? "unknown")")
                    }
                    Text("Disk \(bytes(model.item.bytes)) · \(fit(model).summary)")
                }.font(WorkbenchTypography.secondary)
            }
            if let (run, result) = measured {
                Text("\(run.promptSetName) · run \(run.id.uuidString.prefix(8)) · \((run.finishedAt ?? run.startedAt).formatted())")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Text(ComparisonInsights.limitedValidation(result)).font(WorkbenchTypography.secondary)
                if let peak = result.samples.compactMap(\.peakMemoryGB).compactMap({ ComparisonInsights.nonnegative($0) }).max() {
                    Text(String(format: "Recorded sample peak %.2f GB at %@; not a current fit guarantee.", peak, (run.finishedAt ?? run.startedAt).formatted()))
                        .font(WorkbenchTypography.secondary)
                }
                Picker("Human task outcome", selection: Binding<Int?>(get: { comparison.runs.first { $0.id == run.id }?.qualityReviews?[model.item.path]?.score }, set: { comparison.reviewQuality(runID: run.id, modelPath: model.item.path, score: $0) })) {
                    Text("Unreviewed").tag(Int?.none)
                    ForEach(1...5, id: \.self) { Text("\($0) / 5").tag(Optional($0)) }
                }.frame(width: 300).disabled(comparison.activeRunID != nil)
                Text(ComparisonQualityReview.rubric).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                Text("No current comparable measurement for this prompt set. Historical runs remain below; missing or changed signature/environment is insufficient evidence.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }.padding(.vertical, WorkbenchSpacing.xxs)
    }

    private func fit(_ model: LibraryModel) -> FitVerdict {
        guard mode == .chat else { return .unknown(reason: "media pipeline memory not modeled") }
        guard capturedAt != nil, memory != nil else { return .unknown(reason: "live memory unavailable") }
        return ComparisonInsights.fitEstimate(model: model, hardware: appHost.hardwareProfile, memory: memory, contextTokens: contextTokens, reserveGB: appHost.config.fitReserveGB)
    }

    @ViewBuilder private var reportControls: some View {
        Button("Import workflow report…", action: importReport)
        Button("Save report template…") { save(WorkflowReport.template, name: "workflow-report-template.json") }
        Button("Export agent evidence…", action: exportEvidence)
    }

    private func workflowCurrent(_ record: WorkflowEvidence) -> Bool {
        ComparisonInsights.knownEnvironment(environment) && environment == record.environmentFingerprint && modelsForEvidence.contains { $0.item.path == record.modelPath && $0.item.signature == record.modelSignature }
    }
    private var modelsForEvidence: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    private func workflowRow(_ record: WorkflowEvidence) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("\(record.harness) · \(record.workloadID) · \(ComparePresentation.displayName(for: record.modelPath, models: modelsForEvidence))")
            Text("\(record.sampleCount) samples · total \(metric(record.totalSeconds, unit: "s")) · inference \(metric(record.inferenceSeconds, unit: "s")) · tools \(metric(record.toolSeconds, unit: "s")) · queue \(metric(record.queueSeconds, unit: "s"))")
            Text("\(metric(record.tokensPerSecond, unit: "tok/s")) · first token \(metric(record.timeToFirstTokenSeconds, unit: "s")) · task outcome \(record.qualityScore.map { "\($0)/5 (\(record.rubricID ?? ""))" } ?? "unknown")")
            Text("\(record.measuredAt.formatted()) · source \(record.source) · \(workflowCurrent(record) ? "current identity/environment" : "historical or identity/environment unavailable")")
            Text(record.unattributedSeconds.map { "Unattributed \(metric($0, unit: "s")); cannot attribute this to GPU, disk or network." } ?? "Overhead unknown: additive inference, tool and queue durations are required. GPU/disk bottlenecks cannot be inferred.")
        }.font(WorkbenchTypography.secondary).padding(.vertical, WorkbenchSpacing.xxs)
    }

    private func refreshMemory() async {
        memory = await Task.detached { MemorySnapshot.probe() }.value
        capturedAt = Date()
    }
    private func bytes(_ value: Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown" }
    private func metric(_ value: Double?, unit: String) -> String { ComparisonInsights.nonnegative(value).map { String(format: "%.2f %@", $0, unit) } ?? "unknown" }

    private func importReport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let count = try workflow.importFile(url); message = "Imported \(count) new report records."; error = nil }
        catch { self.error = AppHost.render(error) }
    }

    private func save<Value: Encodable>(_ value: Value, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONStore<WorkflowEvidence>.refuseSymlink(url, fileManager: .default); try WorkflowEvidenceStore.encode(value).write(to: url, options: .atomic); message = "Saved \(url.lastPathComponent)."; error = nil }
        catch { self.error = AppHost.render(error) }
    }

    private func exportEvidence() {
        let evidence = ComparisonInsights.agentEvidence(models: modelsForEvidence, runs: comparison.runs, workflow: workflow.records, environment: environment, hardware: appHost.hardwareProfile, memory: memory, capturedAt: capturedAt, contextTokens: contextTokens, reserveGB: appHost.config.fitReserveGB, protected: appHost.occupiedModelPaths)
        save(evidence, name: "mlx-workbench-agent-evidence.json")
    }
}
