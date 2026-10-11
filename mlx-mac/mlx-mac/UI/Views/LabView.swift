import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct LabPanel: View {
    @ObservedObject var lab: LabCoordinator
    @ObservedObject var installer: RuntimeInstaller
    let agentPath: String
    @State private var authoring = false
    @State private var adopting = false
    @State private var review: LabReviewContext?
    @State private var isOpeningReview = false

    var body: some View {
        WorkbenchCard("Controlled studies", systemImage: "square.split.2x1") {
            Text("Compare one change at a time, then review the clips without seeing candidate identities.")
                .foregroundStyle(WorkbenchColor.muted)
            HStack {
                Button("New experiment…") { authoring = true }.buttonStyle(.borderedProminent)
                Button("Import workspace…") { adopting = true }
                Button("Recover interrupted jobs") { Task { await lab.recover() } }.disabled(lab.runningJobID != nil)
                Button("Refresh") { Task { await lab.refresh() } }.disabled(lab.isRefreshing)
                if lab.isRefreshing { ProgressView().controlSize(.small) }
            }
            HStack {
                Text(lab.store.path).font(WorkbenchTypography.metadata).textSelection(.enabled)
                Spacer()
                Button("Workspace…") { Task { await lab.chooseStore() } }.disabled(lab.runningJobID != nil)
            }
            DisclosureGroup("Runtime setup") {
                Text("Study tools are lightweight. Video generation adds the optional Torch runtime.").font(WorkbenchTypography.metadata)
                HStack {
                    Button("Install study tools") { Task { await installer.install(labAgentPath: agentPath); await lab.refresh() } }
                    Button("Install video runtime") { Task { await installer.install(labAgentPath: agentPath, inference: true); await lab.refresh() } }
                }.disabled(!installer.canInstall)
                Text(installer.summary).font(WorkbenchTypography.metadata)
                ForEach(Array(installer.logTail.suffix(5).enumerated()), id: \.offset) { _, line in
                    Text(line).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                }
            }
            ErrorBanner(text: lab.error)
            if let notice = lab.notice { Text(notice).font(WorkbenchTypography.secondary) }
            if let history = lab.snapshot.history {
                if history.items.isEmpty { Text("No controlled experiments in this workspace.").foregroundStyle(WorkbenchColor.muted) }
                ForEach(history.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.id).font(WorkbenchTypography.compactValue)
                            Text(item.states.joined(separator: " · ")).font(WorkbenchTypography.secondary)
                        }
                        Spacer()
                        Text(item.sealed ? "Identity sealed" : "Reviewed").foregroundStyle(WorkbenchColor.muted)
                        Button("Blind review…") { Task { await openReview(item.id, reviewed: !item.sealed) } }
                            .disabled(isOpeningReview || !item.states.allSatisfy { $0 == "completed" })
                    }
                }
            }
            AdaptiveStudiesPanel(lab: lab)
            LabJobRows(lab: lab)
        }
        .task { await lab.refresh() }
        .sheet(isPresented: $adopting) { LabAdoptSheet(lab: lab) }
        .sheet(isPresented: $authoring) { LabAuthorSheet(lab: lab) }
        .sheet(item: $review) { context in LabReviewSheet(lab: lab, context: context) }
    }
    private func openReview(_ id: String, reviewed: Bool) async {
        isOpeningReview = true
        defer { isOpeningReview = false }
        do {
            let session = try await lab.request(LabRequest(operation: "review-start", experimentID: id))
            guard let sessionID = session.sessionID else { throw BridgeError.skillOutputUnreadable }
            let media = try await lab.request(LabRequest(operation: "review-media", sessionID: sessionID))
            guard let left = media.left, let right = media.right else { throw BridgeError.skillOutputUnreadable }
            review = LabReviewContext(id: sessionID, prompt: session.prompt ?? "", left: URL(fileURLWithPath: left), right: URL(fileURLWithPath: right), reviewed: reviewed)
        } catch { lab.error = AppHost.render(error) }
    }
}

struct LabJobRows: View {
    @ObservedObject var lab: LabCoordinator
    var body: some View {
        ForEach(lab.snapshot.queue ?? []) { job in
            HStack {
                Text(job.id).font(WorkbenchTypography.compactValue)
                Text(job.state).foregroundStyle(WorkbenchColor.muted)
                Spacer()
                if job.state == "queued" {
                    Button("Run") { Task { await lab.run(job) } }.disabled(lab.runningJobID != nil)
                }
                if !["completed", "failed", "cancelled"].contains(job.state) {
                    Button("Cancel") { Task { await lab.cancel(job) } }
                }
            }
            if let error = job.error { Text(error).foregroundStyle(WorkbenchColor.failure).font(WorkbenchTypography.metadata) }
        }
    }
}

struct LabAuthorSheet: View {
    @ObservedObject var lab: LabCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: LabValue?
    @State private var recipeName = ""
    @State private var prompt = ""
    @State private var variable = "inference_steps"
    @State private var alternate = "8"
    @State private var previewed: Data?
    @State private var busy = false
    @State private var error: String?

    private var draft: LabDraft? {
        guard var fields = baseline?.object, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = Double(alternate), value.isFinite else { return nil }
        fields["prompt"] = .string(prompt)
        let alternateValue: LabValue
        if variable == "guidance_scale" { alternateValue = .number(value) }
        else {
            guard let integer = Int(alternate) else { return nil }
            alternateValue = .integer(integer)
        }
        return LabDraft(baseline: .object(fields), variablePath: variable, alternateValue: alternateValue)
    }
    private var request: LabRequest? { draft.map { LabRequest(operation: "preview", draft: $0) } }
    private var fingerprint: Data? { request.flatMap { try? JSONEncoder().encode($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("New controlled experiment").font(WorkbenchTypography.title)
            Button(recipeName.isEmpty ? "Choose generation recipe…" : recipeName) { chooseRecipe() }
            Text("Use a frozen recipe from the engine. Model and runtime identities stay attached to both candidates.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            TextField("Shared prompt", text: $prompt, axis: .vertical).lineLimit(3...6)
            Picker("Change", selection: $variable) {
                Text("Inference steps").tag("inference_steps")
                Text("Guidance").tag("guidance_scale")
                Text("Seed").tag("seed")
            }
            if let value = baseline?.object?[variable]?.decimal { Text("Baseline: " + value.formatted()) }
            TextField("Alternate value", text: $alternate)
            ErrorBanner(text: error)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Validate pair") { Task { await validate() } }.disabled(request == nil || busy)
                Button("Create experiment") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(previewed == nil || previewed != fingerprint || busy)
            }
            if busy { ProgressView() }
        }.padding(WorkbenchSpacing.pageInset).frame(minWidth: 540, idealWidth: 620)
    }
    private func chooseRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 1_048_576 else { throw BridgeError.skillOutputUnreadable }
            let decoded = try JSONDecoder().decode(LabValue.self, from: Data(contentsOf: url))
            let recipe = decoded.object?["baseline"] ?? decoded
            guard let fields = recipe.object, let text = fields["prompt"]?.text,
                  fields["model_id"]?.text != nil, fields["adapter_id"]?.text != nil else { throw BridgeError.skillOutputUnreadable }
            baseline = recipe; prompt = text; recipeName = url.lastPathComponent; previewed = nil; error = nil
        } catch { self.error = AppHost.render(error) }
    }
    private func validate() async {
        guard let request, let captured = fingerprint else { return }
        busy = true; defer { busy = false }
        do { _ = try await lab.request(request); previewed = captured; error = nil }
        catch { previewed = nil; self.error = AppHost.render(error) }
    }
    private func create() async {
        guard let draft, previewed == fingerprint else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await lab.request(LabRequest(operation: "create", draft: draft))
            await lab.refresh(); dismiss()
        } catch { self.error = AppHost.render(error) }
    }
}

struct LabReviewContext: Identifiable {
    let id: String
    let prompt: String
    let left: URL
    let right: URL
    var reviewed = false
    var studyID: String? = nil
}

struct LabVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct LabReviewSheet: View {
    @ObservedObject var lab: LabCoordinator
    let context: LabReviewContext
    @Environment(\.dismiss) private var dismiss
    @State private var leftPlayer = AVPlayer()
    @State private var rightPlayer = AVPlayer()
    @State private var duration = 0.0
    @State private var position = 0.0
    @State private var frameRate = 0.0
    @State private var preference = ""
    @State private var scores = Array(repeating: 0, count: 10)
    @State private var notes = ""
    @State private var busy = false
    @State private var receipt: String?
    @State private var reveal: LabResponse?
    @State private var error: String?
    private let dimensions = ["prompt_adherence", "visual_quality", "motion_quality", "temporal_consistency", "character_consistency"]
    private let labels = ["Prompt adherence", "Visual quality", "Motion quality", "Temporal consistency", "Character consistency"]

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Blind video review").font(WorkbenchTypography.title)
            Text(context.prompt)
            HStack {
                VStack { Text("Left"); LabVideoSurface(player: leftPlayer) }
                VStack { Text("Right"); LabVideoSurface(player: rightPlayer) }
            }.frame(height: 260)
            HStack {
                Button("Play together") {
                    let start = CMTime(seconds: position, preferredTimescale: 600)
                    let hostTime = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(seconds: 0.1, preferredTimescale: 600)
                    leftPlayer.setRate(1, time: start, atHostTime: hostTime)
                    rightPlayer.setRate(1, time: start, atHostTime: hostTime)
                }.disabled(duration == 0)
                Button("Pause") { leftPlayer.pause(); rightPlayer.pause(); position = max(0, leftPlayer.currentTime().seconds) }
                Button("Previous frame") { stepFrame(-1) }.disabled(frameRate <= 0)
                Button("Next frame") { stepFrame(1) }.disabled(frameRate <= 0)
                Slider(value: $position, in: 0...max(duration, 0.01), onEditingChanged: { editing in
                    leftPlayer.pause(); rightPlayer.pause()
                    if !editing {
                        let time = CMTime(seconds: position, preferredTimescale: 600)
                        leftPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                        rightPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                })
            }
            if receipt == nil {
                Picker("Preference", selection: $preference) {
                    Text("Choose…").tag("")
                    Text("Left").tag("left")
                    Text("Tie").tag("tie")
                    Text("Right").tag("right")
                }.pickerStyle(.segmented)
                if context.studyID == nil {
                Grid(alignment: .leading) {
                    GridRow { Text("Score"); Text("Left"); Text("Right") }
                    ForEach(0..<5, id: \.self) { row in
                        GridRow {
                            Text(labels[row])
                            scorePicker(row)
                            scorePicker(row + 5)
                        }
                    }
                }
                TextField("Review notes (optional)", text: $notes)
                }
            } else {
                Text(receipt ?? "").textSelection(.enabled)
                if let reveal {
                    Text("Left: " + (reveal.canonicalByDisplay?["left"] ?? "") + " · Right: " + (reveal.canonicalByDisplay?["right"] ?? ""))
                    let variable = reveal.variablePath ?? ""
                    let baseline = reveal.baselineValue?.jsonText ?? ""
                    let alternate = reveal.alternateValue?.jsonText ?? ""
                    Text("\(variable): \(baseline) → \(alternate)")
                    DisclosureGroup("Frozen manifests") {
                        ForEach((reveal.manifests ?? [:]).keys.sorted(), id: \.self) { key in
                            Text(key + "\n" + (reveal.manifests?[key]?.jsonText ?? "")).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                        }
                    }
                } else {
                    Button("Reveal candidate identities") { Task { await showReveal() } }.disabled(busy || context.studyID != nil)
                }
            }
            ErrorBanner(text: error)
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if receipt == nil {
                    Button("Submit immutable review") { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(preference.isEmpty || (context.studyID == nil && scores.contains(0)) || busy)
                }
            }
        }.padding(WorkbenchSpacing.pageInset).frame(minWidth: 700, idealWidth: 900)
        .task {
            leftPlayer.replaceCurrentItem(with: AVPlayerItem(url: context.left))
            rightPlayer.replaceCurrentItem(with: AVPlayerItem(url: context.right))
            if context.reviewed { await showReveal() }
            do {
                let left = try await AVURLAsset(url: context.left).load(.duration).seconds
                let right = try await AVURLAsset(url: context.right).load(.duration).seconds
                if left.isFinite && right.isFinite { duration = min(left, right) }
                let tracks = try await AVURLAsset(url: context.left).loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let rate = try await track.load(.nominalFrameRate)
                    if rate.isFinite && rate > 0 { frameRate = Double(rate) }
                }
            } catch { self.error = AppHost.render(error) }
        }
        .onDisappear { leftPlayer.pause(); rightPlayer.pause() }
    }
    private func stepFrame(_ direction: Double) {
        leftPlayer.pause(); rightPlayer.pause()
        position = min(duration, max(0, leftPlayer.currentTime().seconds + direction / frameRate))
        let time = CMTime(seconds: position, preferredTimescale: 60_000)
        leftPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        rightPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func scorePicker(_ index: Int) -> some View {
        Picker(labels[index % 5], selection: $scores[index]) {
            Text("—").tag(0)
            ForEach(1...5, id: \.self) { score in Text(String(score)).tag(score) }
        }.labelsHidden().frame(width: 80)
    }
    private func showReveal() async {
        busy = true; defer { busy = false }
        do {
            reveal = try await lab.request(LabRequest(operation: "reveal", sessionID: context.id))
            receipt = "Review saved: " + (reveal?.reviewID ?? "") + " · revision " + String(reveal?.revision ?? 1)
        } catch { self.error = AppHost.render(error) }
    }
    private func submit() async {
        busy = true; defer { busy = false }
        do {
            if let studyID = context.studyID {
                _ = try await lab.request(LabRequest(operation: "study-submit", sessionID: context.id,
                    preference: preference, studyID: studyID))
                receipt = "Preference retained for this comparison."
                await lab.refresh()
                return
            }
            let rubric = scores.enumerated().map { index, value in
                LabScore(displayPosition: index < 5 ? "left" : "right", dimension: dimensions[index % 5], score: value)
            }
            let result = try await lab.request(LabRequest(operation: "review-submit", sessionID: context.id,
                preference: preference, scores: rubric, notes: notes.isEmpty ? nil : notes))
            receipt = "Review saved: " + (result.reviewID ?? "") + " · revision " + String(result.revision ?? 1)
            await lab.refresh()
        } catch { self.error = AppHost.render(error) }
    }
}

struct LabAdoptSheet: View {
    @ObservedObject var lab: LabCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var database = ""
    @State private var artifacts = ""
    @State private var destination = ""
    @State private var preview: LabResponse?
    @State private var previewed: Data?
    @State private var busy = false
    @State private var error: String?
    private var request: LabRequest {
        LabRequest(operation: "adopt-preview", sourceDatabase: database, sourceArtifacts: artifacts, destination: destination)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Import a Video Lab workspace").font(WorkbenchTypography.title)
            Text("Stop the source workspace before importing. The import preserves identities, videos and review history and retains an exact database backup.")
            HStack {
                TextField("Source SQLite database", text: $database).textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseDatabase() }
            }
            HStack {
                TextField("Source artifact folder", text: $artifacts).textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseArtifacts() }
            }
            HStack {
                TextField("New workspace folder", text: $destination).textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseDestination() }
            }
            if let preview {
                Text("\(preview.artifactCount ?? 0) artifacts · \(ByteCountFormatter.string(fromByteCount: preview.artifactBytes ?? 0, countStyle: .file))")
                Text("Source database: " + (preview.sourceDatabaseDigest ?? "")).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                Text("Backup: " + destination + "/before-adoption.sqlite3").font(WorkbenchTypography.metadata).textSelection(.enabled)
            }
            ErrorBanner(text: error)
            HStack {
                Button("Cancel") { dismiss() }.disabled(busy)
                Spacer()
                Button("Validate import") { Task { await validate() } }
                    .disabled(busy || database.isEmpty || artifacts.isEmpty || destination.isEmpty)
                Button("Import with backup") { Task { await adopt() } }.buttonStyle(.borderedProminent)
                    .disabled(busy || previewed == nil || previewed != (try? JSONEncoder().encode(request)))
                if busy { ProgressView().controlSize(.small) }
            }
        }.padding(WorkbenchSpacing.pageInset).frame(width: 740)
    }
    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            database = url.resolvingSymlinksInPath().path
            artifacts = url.deletingLastPathComponent().appendingPathComponent("artifacts").resolvingSymlinksInPath().path
            previewed = nil
        }
    }
    private func chooseArtifacts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { artifacts = url.resolvingSymlinksInPath().path; previewed = nil }
    }
    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Imported Video Lab"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { destination = url.path; previewed = nil }
    }
    private func validate() async {
        busy = true; defer { busy = false }
        do {
            preview = try await lab.request(request)
            previewed = try JSONEncoder().encode(request)
            error = nil
        } catch { self.error = AppHost.render(error); previewed = nil }
    }
    private func adopt() async {
        guard previewed == (try? JSONEncoder().encode(request)), let hash = preview?.previewHash else { return }
        busy = true; defer { busy = false }
        do {
            var confirmed = request
            confirmed.operation = "adopt"
            confirmed.previewHash = hash
            let result = try await lab.request(confirmed)
            guard let path = result.storePath else { throw BridgeError.skillOutputUnreadable }
            await lab.useStore(URL(fileURLWithPath: path))
            dismiss()
        } catch { self.error = AppHost.render(error) }
    }
}


private struct AdaptiveStudiesPanel: View {
    @ObservedObject var lab: LabCoordinator
    @State private var studies: [LabValue] = []
    @State private var busy = false
    @State private var review: LabReviewContext?
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text("Adaptive guidance studies").font(WorkbenchTypography.cardTitle)
                Spacer()
                Button("Import frozen recipe…") { importRecipe() }.disabled(busy)
                Button("Refresh studies") { Task { await refresh() } }.disabled(busy)
            }
            Text("Each study keeps its prompt and seed fixed. Human preferences guide the next pair; the engine retains the search budget and stopping evidence.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            ForEach(Array(studies.enumerated()), id: \.offset) { _, value in
                if let item = value.object, let id = item["study_id"]?.text {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(id).font(WorkbenchTypography.compactValue)
                            Text(item["state"]?.text ?? "").font(WorkbenchTypography.metadata)
                            Text(item["progress"]?.jsonText ?? "").font(WorkbenchTypography.metadata)
                        }
                        Spacer()
                        let action = item["next_action"]?.text ?? "none"
                        if action == "resume" {
                            Button("Continue") { perform("study-resume", id: id) }.disabled(busy)
                        } else if action == "complete_generation" {
                            Button("Generate pair") { perform("study-run", id: id) }.disabled(busy || lab.runningJobID != nil)
                        } else if action == "record_preference", let session = item["review_id"]?.text {
                            Button("Blind review") { openReview(id, session: session, prompt: item["prompt"]?.text ?? "") }.disabled(busy)
                        }
                    }
                    if item["next_action"]?.text == "none" {
                        DisclosureGroup("Retained study evidence") {
                            Text(value.jsonText).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                        }
                    }
                    Divider()
                }
            }
        }
        .task { await refresh() }
        .sheet(item: $review, onDismiss: { Task { await refresh() } }) { context in LabReviewSheet(lab: lab, context: context) }
    }
    private func refresh() async {
        do { studies = try await lab.request(LabRequest(operation: "study-list")).studies ?? [] }
        catch { lab.error = AppHost.render(error) }
    }
    private func perform(_ operation: String, id: String) {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await lab.request(LabRequest(operation: operation, studyID: id)); await refresh(); await lab.refresh() }
            catch { lab.error = AppHost.render(error) }
        }
    }
    private func importRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      (properties.fileSize ?? Int.max) <= 1_048_576 else { throw BridgeError.skillOutputUnreadable }
                let manifest = try JSONDecoder().decode(LabValue.self, from: Data(contentsOf: url))
                _ = try await lab.request(LabRequest(operation: "study-create", manifest: manifest))
                await refresh()
            } catch { lab.error = AppHost.render(error) }
        }
    }
    private func openReview(_ id: String, session: String, prompt: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await lab.request(LabRequest(operation: "review-media", sessionID: session))
                guard let left = result.left, let right = result.right else { throw BridgeError.skillOutputUnreadable }
                review = LabReviewContext(id: session, prompt: prompt, left: URL(fileURLWithPath: left),
                    right: URL(fileURLWithPath: right), reviewed: false, studyID: id)
            } catch { lab.error = AppHost.render(error) }
        }
    }
}
