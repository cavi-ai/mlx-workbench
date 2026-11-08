import SwiftUI

enum ModelUpdateReviewPresentation {
    static func bitWidths(_ review: ModelUpdateReview) -> [Int] {
        guard let recipe = review.conversion else { return [] }
        let supported = recipe.kind == .gguf ? Array(Config.Q_BITS_CHOICES) : review.resolution.qBits ?? [4, 8]
        return Array(Set(supported)).filter { [4, 5, 6, 8, 32].contains($0) && (recipe.kind != .gguf || $0 != 32) }.sorted()
    }

    static func downloadTitle(_ review: ModelUpdateReview?) -> String {
        review?.needsPreparation == true ? "Download source for preparation" : "Download and verify update"
    }

    static func preparationTitle(_ preparation: ModelUpdatePreparationReview) -> String {
        switch preparation.operation {
        case .installBackend: "Review converter installation"
        case .convert: "Review local conversion"
        case .observeConversion: "Review saved conversion"
        }
    }

    static func preparationAction(_ preparation: ModelUpdatePreparationReview) -> String {
        switch preparation.operation {
        case .installBackend: "Install converter and review preparation"
        case .convert: "Convert and verify update"
        case .observeConversion: "Continue preparation and verification"
        }
    }

    static func recoveryAction(_ recovery: ModelUpdateRecoveryReview) -> String {
        recovery.snapshots.isEmpty ? "Retry failed preparation" : "Quarantine failed files and retry"
    }

    static func settingsLocked(isLoading: Bool, isPreparing: Bool, isRunning: Bool, accepted: Bool) -> Bool {
        isLoading || isPreparing || isRunning || accepted
    }

    static func canDownload(review: ModelUpdateReview?, settingsLocked: Bool) -> Bool {
        guard !settingsLocked, let review else { return false }
        return review.missingSelectionReason == nil
    }

    static func companionChoices(_ review: ModelUpdateReview) -> [IntakeGGUFFile] {
        review.resolution.files.gguf.filter {
            $0.name != review.resolution.source.file && $0.name != review.projectorFile &&
                !ModelUpdateGGUFSelection.isShard($0.name)
        }
    }

    static func companionSelection(_ review: ModelUpdateReview, selected: [String]?) -> [String] {
        let available = Set(companionChoices(review).map(\.name))
        return Array(Set(selected ?? review.additionalFiles ?? []).intersection(available)).sorted()
    }

    static func preparationRevisionBits(_ review: ModelUpdateReview, selected: Int?) -> Int? {
        let supported = bitWidths(review)
        if let selected, supported.contains(selected) { return selected }
        if let current = review.conversion?.qBits, supported.contains(current) { return current }
        return supported.first
    }

    static func canReviewPreparationSettings(_ review: ModelUpdateReview, bits: Int?,
                                            canRevise: Bool, isBusy: Bool, recoveryPending: Bool) -> Bool {
        guard canRevise, !isBusy, !recoveryPending, let recipe = review.conversion, let bits else { return false }
        return bitWidths(review).contains(bits) && bits != recipe.qBits
    }
}

struct ModelUpdateReviewSheet: View {
    @ObservedObject var coordinator: ModelUpdateCoordinator
    let addFromHuggingFace: (String) -> Void
    @State private var quarantinePrevious = false
    @State private var revisedBits: Int?

    private var accepted: Bool { coordinator.activeRecord != nil }
    private var displayedReview: ModelUpdateReview? { coordinator.activeRecord?.review ?? coordinator.review }
    private var settingsLocked: Bool {
        ModelUpdateReviewPresentation.settingsLocked(isLoading: coordinator.isLoading, isPreparing: coordinator.isPreparing,
            isRunning: coordinator.isRunning, accepted: accepted || coordinator.recoveryReview != nil)
    }
    private var selectedPrevious: ModelUpdatePreviousModel? {
        displayedReview?.previous ?? coordinator.candidates.first { $0.path == coordinator.selectedPreviousPath }
    }
    private var settings: ModelUpdateSettings {
        ModelUpdateSettings(qBits: coordinator.selectedBits, ggufFile: coordinator.selectedFile,
            projectorFile: coordinator.selectedProjector, sourceConfirmed: coordinator.sourceConfirmed,
            additionalFiles: coordinator.selectedCompanions)
    }
    private var preparationRevisionPending: Bool {
        guard coordinator.canRevisePreparation, let review = displayedReview,
              let selected = ModelUpdateReviewPresentation.preparationRevisionBits(review, selected: revisedBits) else { return false }
        return selected != review.conversion?.qBits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Review model update").font(WorkbenchTypography.title)
            Text(coordinator.repo).font(WorkbenchTypography.cardTitle).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    Text("The new revision downloads to a separate folder. Managed endpoints switch after verification.")
                        .foregroundStyle(WorkbenchColor.muted)
                    previousSelection
                    if let previous = selectedPrevious, previous.needsSourceConfirmation == true { sourceConfirmation(previous) }
                    if coordinator.isPreparing { ProgressView("Preparing update review…") }
                    if let review = displayedReview {
                        preparationSelection(review)
                        if coordinator.canRevisePreparation, review.conversion != nil { preparationCorrection(review) }
                        reviewDetails(review)
                    }
                    if let recovery = coordinator.recoveryReview { recoveryDetails(recovery) }
                    else if let preparation = coordinator.preparationReview { preparationDetails(preparation) }
                    if let record = coordinator.activeRecord { recordStatus(record) }
                    savedUpdates
                    ErrorBanner(text: coordinator.persistenceError)
                    if coordinator.error != coordinator.persistenceError { ErrorBanner(text: coordinator.error) }
                    if !coordinator.isLoading && !coordinator.isPreparing && !coordinator.isRunning &&
                        coordinator.candidates.isEmpty && !accepted && coordinator.recoveryReview == nil {
                        Button("Add as a new model…") {
                            let repo = coordinator.repo
                            coordinator.close()
                            addFromHuggingFace(repo)
                        }
                    }
                }
                .font(WorkbenchTypography.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(WorkbenchSpacing.lg)
        .frame(width: 680, height: 680)
        .onChange(of: coordinator.repo) { _, _ in quarantinePrevious = false }
        .onChange(of: coordinator.activeRecordID) { _, _ in revisedBits = nil }
        .onChange(of: coordinator.activeRecord?.review.conversion?.qBits) { _, _ in revisedBits = nil }
        .onChange(of: coordinator.review?.previous.canQuarantine) { _, allowed in
            if !accepted && allowed != true { quarantinePrevious = false }
        }
        .onChange(of: coordinator.review?.cleanupPath) { _, path in
            if !accepted && path == nil { quarantinePrevious = false }
        }
        .interactiveDismissDisabled(coordinator.isRunning)
        .onDisappear { if !coordinator.isRunning { coordinator.cancelRecovery() } }
    }

    private func preparationCorrection(_ review: ModelUpdateReview) -> some View {
        let bits = ModelUpdateReviewPresentation.preparationRevisionBits(review, selected: revisedBits)
        let busy = coordinator.isRunning || coordinator.isLoading || coordinator.isPreparing
        let pendingRecovery = coordinator.recoveryReview != nil
        return GroupBox("Correct preparation settings") {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Text("Change the conversion bit width for the downloaded source. Review the new output folder and conversion plan before starting.")
                    .foregroundStyle(WorkbenchColor.muted)
                Picker("New conversion bit width", selection: Binding(get: { bits ?? 0 }, set: { revisedBits = $0 })) {
                    ForEach(ModelUpdateReviewPresentation.bitWidths(review), id: \.self) { width in
                        Text("\(width)-bit").tag(width)
                    }
                }
                .disabled(busy || pendingRecovery)
                .accessibilityIdentifier("model-update-revised-bits")
                Button("Review preparation settings") {
                    guard let bits else { return }
                    Task { _ = await coordinator.revisePreparation(bits: bits) }
                }
                .disabled(!ModelUpdateReviewPresentation.canReviewPreparationSettings(review, bits: bits,
                    canRevise: coordinator.canRevisePreparation, isBusy: busy, recoveryPending: pendingRecovery))
                .accessibilityIdentifier("model-update-review-preparation-settings")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var previousSelection: some View {
        if coordinator.isLoading {
            ProgressView("Finding local versions…")
        } else {
            if coordinator.candidates.contains(where: { $0.needsSourceConfirmation == true }) {
                Toggle("Include models without a recorded repository source", isOn: Binding(get: {
                    coordinator.includesUnattributedModels
                }, set: { include in
                    guard !settingsLocked else { return }
                    coordinator.includesUnattributedModels = include
                    if !include, selectedPrevious?.needsSourceConfirmation == true {
                        quarantinePrevious = false
                        Task { await coordinator.selectPrevious(path: nil) }
                    }
                }))
                .disabled(settingsLocked)
                .accessibilityIdentifier("model-update-include-unattributed")
            }
            let candidates = coordinator.activeRecord.map { [$0.review.previous] } ?? coordinator.visibleCandidates
            if !candidates.isEmpty {
                Picker("Previous version", selection: Binding(get: {
                    coordinator.activeRecord?.review.previous.path ?? coordinator.selectedPreviousPath ?? ""
                }, set: { path in
                    guard !settingsLocked else { return }
                    quarantinePrevious = false
                    Task { await coordinator.selectPrevious(path: path.isEmpty ? nil : path) }
                })) {
                    Text("Choose a local model").tag("")
                    ForEach(candidates) { candidate in Text(candidate.displayName + " · " + candidate.path).tag(candidate.path) }
                }
                .disabled(settingsLocked).accessibilityIdentifier("model-update-previous")
            } else if !coordinator.candidates.isEmpty {
                Text("No local version has a recorded source for this repository. Include other local models only if you can confirm their source.")
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    private func sourceConfirmation(_ previous: ModelUpdatePreviousModel) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("This model has no recorded repository source.").foregroundStyle(WorkbenchColor.warning)
            Text(previous.path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            Toggle("I confirm this model came from \(coordinator.repo)", isOn: Binding(get: {
                coordinator.activeRecord?.review.sourceConfirmed ?? coordinator.sourceConfirmed
            }, set: { confirmed in
                var next = settings; next.sourceConfirmed = confirmed; select(next)
            }))
            .disabled(settingsLocked).accessibilityIdentifier("model-update-confirm-source")
        }
    }

    @ViewBuilder private func preparationSelection(_ review: ModelUpdateReview) -> some View {
        if review.conversion != nil || review.resolution.verdict == .gguf {
            GroupBox("Update settings") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    if review.resolution.verdict == .gguf {
                        Picker("Main GGUF file", selection: Binding(get: {
                            accepted ? review.resolution.source.file ?? "" : coordinator.selectedFile ?? review.resolution.source.file ?? ""
                        }, set: { file in
                            var next = settings
                            next.ggufFile = file
                            if (next.projectorFile ?? review.projectorFile) == file { next.projectorFile = "" }
                            select(next)
                        })) {
                            Text("Choose a GGUF file").tag("")
                            ForEach(review.resolution.files.gguf) { file in
                                Text(file.name + " · " + LibraryTablePresentation.byteCount(file.bytes)).tag(file.name)
                            }
                        }.accessibilityIdentifier("model-update-gguf-file")
                        if review.requiresProjector == true || review.projectorFile != nil || review.resolution.files.gguf.count > 1 {
                            Picker(review.requiresProjector == true ? "Vision projector" : "Vision projector (optional)", selection: Binding(get: {
                                accepted ? review.projectorFile ?? "" : coordinator.selectedProjector ?? review.projectorFile ?? ""
                            }, set: { projector in
                                var next = settings; next.projectorFile = projector; select(next)
                            })) {
                                Text(review.requiresProjector == true ? "Choose a vision projector" : "No projector").tag("")
                                ForEach(review.resolution.files.gguf.filter {
                                    $0.name != review.resolution.source.file && !ModelUpdateGGUFSelection.isShard($0.name)
                                }) { file in
                                    Text(file.name + " · " + LibraryTablePresentation.byteCount(file.bytes)).tag(file.name)
                                }
                            }.accessibilityIdentifier("model-update-projector")
                        }
                        companionSelection(review)
                    }
                    if let recipe = review.conversion {
                        let supportedBits = ModelUpdateReviewPresentation.bitWidths(review)
                        let currentBits = accepted ? recipe.qBits : coordinator.selectedBits ?? recipe.qBits
                        Picker("Conversion bit width", selection: Binding(get: {
                            currentBits
                        }, set: { bits in
                            var next = settings; next.qBits = bits; select(next)
                        })) {
                            if !supportedBits.contains(currentBits) { Text("\(currentBits)-bit · not supported by this revision").tag(currentBits) }
                            ForEach(supportedBits, id: \.self) { bits in Text("\(bits)-bit").tag(bits) }
                        }.accessibilityIdentifier("model-update-bits")
                        Text(recipe.kind == .gguf ? "GGUF to MLX conversion" : "Converter: " + (recipe.backend ?? "Not reported"))
                            .foregroundStyle(WorkbenchColor.muted)
                        if review.resolution.backendInstalled == false, let backend = recipe.backend {
                            Text("\(backend) needs installation. Its installation will be reviewed after the source download.")
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                    if let reason = review.missingSelectionReason { Text(reason).foregroundStyle(WorkbenchColor.warning) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(settingsLocked)
        }
    }

    @ViewBuilder private func companionSelection(_ review: ModelUpdateReview) -> some View {
        let choices = ModelUpdateReviewPresentation.companionChoices(review)
        let selected = ModelUpdateReviewPresentation.companionSelection(review,
            selected: accepted ? review.additionalFiles : coordinator.selectedCompanions)
        let shards = ModelUpdateGGUFSelection.shards(main: review.resolution.source.file,
            available: review.resolution.files.gguf.map(\.name)).files
        if !shards.isEmpty {
            Text("Required split GGUF shards").font(WorkbenchTypography.cardTitle)
            ForEach(shards, id: \.self) { file in
                Text(file).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            }
            Text("All declared shards download together.").foregroundStyle(WorkbenchColor.muted)
        }
        if !choices.isEmpty || review.requiredCompanionSelection == true {
            Text("Additional GGUF companion files").font(WorkbenchTypography.cardTitle)
            Text("Choose the additional files this model requires. The main file, projector and split shards are reviewed separately.")
                .foregroundStyle(WorkbenchColor.muted)
            ForEach(choices) { file in
                Toggle(file.name + " · " + LibraryTablePresentation.byteCount(file.bytes), isOn: Binding(get: {
                    selected.contains(file.name)
                }, set: { include in
                    var files = Set(selected)
                    if include { files.insert(file.name) } else { files.remove(file.name) }
                    var next = settings; next.additionalFiles = files.sorted(); select(next)
                }))
                .accessibilityIdentifier("model-update-companion-\(file.name)")
            }
            if review.requiredCompanionSelection == true {
                let available = Set(review.resolution.files.gguf.map(\.name))
                let missing = (review.previous.additionalFiles ?? []).filter {
                    $0 != review.previous.projectorFile && $0 != review.previous.convertedOrigin?.projectorFile &&
                        !ModelUpdateGGUFSelection.isShard($0) && !available.contains($0)
                }
                if !missing.isEmpty {
                    Text("Previously recorded companions missing from this revision:").foregroundStyle(WorkbenchColor.warning)
                    ForEach(missing, id: \.self) { file in
                        Text(file).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    }
                }
                Button("Confirm companion files") {
                    var next = settings; next.additionalFiles = selected; select(next)
                }.accessibilityIdentifier("model-update-confirm-companions")
            }
        }
    }

    private func reviewDetails(_ review: ModelUpdateReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            GroupBox("Previous version") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(review.previous.path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    if let revision = review.previous.revision { Text("Revision " + revision).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("New revision") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text(review.targetRevision).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    pathLine("Downloaded source", review.downloadedModelPath)
                    if review.downloadedModelPath != review.destinationPath { pathLine("Prepared model", review.destinationPath) }
                    if let bytes = review.downloadBytes { Text("Download: " + LibraryTablePresentation.byteCount(bytes)) }
                    ForEach(review.additionalFiles ?? [], id: \.self) { file in
                        pathLine(file == review.projectorFile ? "Vision projector" : "Companion file",
                            URL(fileURLWithPath: review.sourceDirectory).appendingPathComponent(file).path)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let dependencies = review.dependencies, !dependencies.isEmpty {
                GroupBox("Required source dependencies") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        ForEach(dependencies, id: \.modelPath) { dependency in
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                Text(dependency.resolution.source.repo).font(WorkbenchTypography.label)
                                Text("Revision " + dependency.resolution.source.fetchRevision).textSelection(.enabled)
                                Text(dependency.modelPath).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if review.endpointSummary.isEmpty {
                Text("No managed endpoint currently uses the previous version.").foregroundStyle(WorkbenchColor.muted)
            } else {
                Text("Endpoints to switch after verification").font(WorkbenchTypography.cardTitle)
                ForEach(review.endpointSummary, id: \.self) { Text($0) }
            }
            Toggle("Move the previous version to Quarantine after the update", isOn: Binding(get: {
                coordinator.activeRecord?.quarantinePrevious ?? quarantinePrevious
            }, set: { if !accepted { quarantinePrevious = $0 } }))
                .disabled(!review.previous.canQuarantine || review.cleanupPath == nil || settingsLocked)
                .accessibilityIdentifier("model-update-quarantine-previous")
            if let path = review.cleanupPath {
                pathLine("Previous files selected for Quarantine", path)
                if let files = review.cleanupFiles, !files.isEmpty {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        Text("GGUF files in this selection").font(WorkbenchTypography.label)
                        ForEach(files, id: \.self) { file in Text(file).font(WorkbenchTypography.compactValue).textSelection(.enabled) }
                    }
                }
            } else if review.previous.canQuarantine {
                Text("No cleanup selection is available. The previous version will stay in place.").foregroundStyle(WorkbenchColor.muted)
            }
            if let reason = review.previous.retentionReason { Text(reason).foregroundStyle(WorkbenchColor.muted) }
            Text("Quarantine keeps a recoverable copy. Shared Hugging Face caches and models owned by other apps stay in place.")
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    private func preparationDetails(_ preparation: ModelUpdatePreparationReview) -> some View {
        GroupBox(ModelUpdateReviewPresentation.preparationTitle(preparation)) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                if preparation.operation == .installBackend {
                    Text("Converter: " + (preparation.backendInstallID ?? preparation.recipe.backend ?? "Not reported"))
                        .font(WorkbenchTypography.label)
                    if let installation = preparation.backendInstallation {
                        Text("Package: " + installation.package + " · " + installation.version)
                        pathLine("Installation location", installation.target)
                        Text("Download hosts: " + installation.network.joined(separator: ", "))
                    }
                    Text("Install this converter, then review the local conversion before it starts. The previous version stays in place.")
                } else {
                    Text(preparation.recipe.title).font(WorkbenchTypography.label)
                    Text("Confirm this preparation of the downloaded source. Verification and endpoint switching follow only after it succeeds.")
                }
                pathLine("Local source", preparation.sourcePath)
                pathLine("Prepared output", preparation.outputPath)
                if let projector = preparation.projectorPath { pathLine("Vision projector", projector) }
                DisclosureGroup("Downloaded source files checked") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        ForEach(preparation.sourceFiles, id: \.path) { source in
                            Text(source.path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                        }
                    }.padding(.top, WorkbenchSpacing.xs)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("model-update-preparation-review")
    }

    private func recordStatus(_ record: ModelUpdateRecord) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSpacing.xs) {
                if coordinator.isRunning { ProgressView().controlSize(.small) }
                Text(record.stage.title).font(WorkbenchTypography.label)
                if record.state == .failed || record.state == .interrupted { Text("Needs review").foregroundStyle(WorkbenchColor.warning) }
            }
            if record.state == .completed {
                Text(record.quarantinePrevious ? "The new revision is verified. The previous version is in Quarantine."
                     : "The new revision is verified. The previous version remains in its folder.").foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    private func recoveryDetails(_ recovery: ModelUpdateRecoveryReview) -> some View {
        GroupBox(recovery.snapshots.isEmpty ? "Review failed preparation retry" : "Review failed staging cleanup") {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                if let record = coordinator.records.first(where: { $0.id == recovery.recordID }) {
                    pathLine("Previous version retained", record.review.previous.path)
                    Text("Pinned revision " + record.review.targetRevision).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                }
                if recovery.snapshots.isEmpty {
                    Text("No staging files will be moved. Retry the saved update using its pinned source and settings.")
                } else {
                    Text("Only these failed staging files will move to Quarantine. The previous version stays in place.")
                    ForEach(recovery.snapshots, id: \.path) { snapshot in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            Text(snapshot.path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            Text(LibraryTablePresentation.byteCount(snapshot.bytes)).foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                }
                if !recovery.queueItems.isEmpty {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        Text("Failed queued jobs to cancel").font(WorkbenchTypography.label)
                        ForEach(recovery.queueItems, id: \.self) { item in Text(item).font(WorkbenchTypography.compactValue).textSelection(.enabled) }
                    }
                }
                if !recovery.failedReceipts.isEmpty {
                    DisclosureGroup("Failed job records checked") {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            ForEach(recovery.failedReceipts, id: \.self) { receipt in
                                Text(receipt).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            }
                        }.padding(.top, WorkbenchSpacing.xs)
                    }
                }
                Text(recovery.resetsDownload ? "The pinned source revision will download again."
                     : "The saved download is retained. If conversion is needed, review its new plan before it starts.")
                    .foregroundStyle(WorkbenchColor.muted)
                Text("Quarantine keeps a recoverable copy. No model files are permanently deleted.").foregroundStyle(WorkbenchColor.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("model-update-recovery-review")
    }

    @ViewBuilder private var savedUpdates: some View {
        let records = coordinator.resumableRecords.filter {
            $0.review.repo.caseInsensitiveCompare(coordinator.repo) == .orderedSame &&
                ($0.id != coordinator.activeRecordID || $0.state != .inProgress)
        }
        if !records.isEmpty {
            GroupBox("Saved updates") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            Text(record.review.previous.path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            Text(record.stage.title + " · " + record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(WorkbenchColor.muted)
                            Text("Revision " + record.review.targetRevision).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            HStack {
                                Button("Continue saved update") { Task { await coordinator.resume(recordID: record.id) } }
                                    .accessibilityIdentifier("model-update-resume-\(record.id)")
                                Button("Review failed staging files…") { Task { await coordinator.reviewRecovery(recordID: record.id) } }
                                    .accessibilityIdentifier("model-update-review-recovery-\(record.id)")
                            }
                            .disabled(coordinator.isRunning || coordinator.isPreparing || coordinator.isLoading ||
                                coordinator.activeRecord?.state == .inProgress || coordinator.recoveryReview != nil)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(coordinator.recoveryReview != nil ? "Cancel review" : accepted || coordinator.isRunning ? "Close" : "Cancel") {
                if coordinator.recoveryReview != nil { coordinator.cancelRecovery() }
                else { coordinator.close() }
            }
                .keyboardShortcut(.cancelAction)
                .disabled(coordinator.recoveryReview != nil && coordinator.isRunning)
            Spacer()
            if let recovery = coordinator.recoveryReview {
                Button(ModelUpdateReviewPresentation.recoveryAction(recovery)) {
                    Task { await coordinator.confirmRecovery(recovery) }
                }
                .buttonStyle(.workbenchPrimary).disabled(coordinator.isRunning || coordinator.isPreparing)
                .accessibilityIdentifier("model-update-confirm-recovery")
            } else if let preparation = coordinator.preparationReview {
                Button(ModelUpdateReviewPresentation.preparationAction(preparation)) {
                    Task { await coordinator.confirmPreparation(preparation) }
                }
                .buttonStyle(.workbenchPrimary).disabled(coordinator.isRunning || coordinator.isPreparing || preparationRevisionPending)
                .accessibilityIdentifier("model-update-confirm-preparation")
            } else if !accepted {
                Button(ModelUpdateReviewPresentation.downloadTitle(displayedReview)) {
                    Task { await coordinator.confirm(quarantinePrevious: quarantinePrevious) }
                }
                .buttonStyle(.workbenchPrimary)
                .disabled(!ModelUpdateReviewPresentation.canDownload(review: displayedReview, settingsLocked: settingsLocked))
                .accessibilityIdentifier("model-update-download")
            }
        }
    }

    private func select(_ settings: ModelUpdateSettings) {
        guard !settingsLocked else { return }
        Task { await coordinator.selectPreparation(bits: settings.qBits, file: settings.ggufFile,
            projector: settings.projectorFile, sourceConfirmed: settings.sourceConfirmed, additionalFiles: settings.additionalFiles) }
    }

    private func pathLine(_ label: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(label).foregroundStyle(WorkbenchColor.muted)
            Text(path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
        }
    }
}
