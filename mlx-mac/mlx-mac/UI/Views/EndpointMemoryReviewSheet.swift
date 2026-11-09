import SwiftUI

struct EndpointMemoryPolicyDraft: Equatable {
    var idleTimeoutSeconds: Int
    var keepLoaded: Bool
    var releaseAfterRequest: Bool?
    var reserveEnabled: Bool
    var reserveGB: String
    var budgetEnabled: Bool
    var budgetGB: String
    var pressureEnabled: Bool
    var contextEnabled: Bool
    var contextTokens: String

    init(policy: EndpointMemoryPolicy) {
        idleTimeoutSeconds = policy.idleTimeoutSeconds
        keepLoaded = policy.keepLoaded
        releaseAfterRequest = policy.releaseAfterRequest
        reserveEnabled = policy.minimumHeadroomGB != nil
        reserveGB = policy.minimumHeadroomGB.map { String($0) } ?? "2"
        budgetEnabled = policy.modelMemoryBudgetGB != nil
        budgetGB = policy.modelMemoryBudgetGB.map { String($0) } ?? ""
        pressureEnabled = policy.unloadUnderPressure == true
        contextEnabled = policy.contextTokens != nil
        contextTokens = policy.contextTokens.map { String($0) } ?? String(FitAdvisor.defaultContextTokens)
    }

    mutating func setKeepLoaded(_ enabled: Bool) {
        keepLoaded = enabled
        if enabled {
            pressureEnabled = false
            if releaseAfterRequest == true { releaseAfterRequest = false }
        }
    }

    mutating func setReleaseAfterRequest(_ enabled: Bool) {
        releaseAfterRequest = enabled
        if enabled { keepLoaded = false; idleTimeoutSeconds = 0 }
    }

    mutating func setReserve(_ enabled: Bool) {
        reserveEnabled = enabled
        if !enabled { pressureEnabled = false; contextEnabled = false }
    }

    mutating func setPressure(_ enabled: Bool) {
        pressureEnabled = enabled
        if enabled { keepLoaded = false; reserveEnabled = true }
    }

    mutating func setBudget(_ enabled: Bool) {
        budgetEnabled = enabled
        if enabled { reserveEnabled = true }
    }

    mutating func setContext(_ enabled: Bool) {
        contextEnabled = enabled
        if enabled { reserveEnabled = true }
    }

    func policy(for slot: EndpointSlot) throws -> EndpointMemoryPolicy {
        guard slot.usesJIT else { throw WorkflowEvidenceError.invalid("Memory policies require Load on request.") }
        let reserve = reserveEnabled ? Double(reserveGB.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        let budget = budgetEnabled ? Double(budgetGB.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        let context = contextEnabled ? Int(contextTokens.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        guard !reserveEnabled || reserve.map({ $0.isFinite && (0...1024).contains($0) }) == true else {
            throw WorkflowEvidenceError.invalid("Enter a reserve from 0 to 1024 GB.")
        }
        guard !budgetEnabled || budget.map({ $0.isFinite && (1...1024).contains($0) }) == true else {
            throw WorkflowEvidenceError.invalid("Enter a total model budget from 1 to 1024 GB.")
        }
        guard !contextEnabled || context.map({ (1024...1_048_576).contains($0) }) == true else {
            throw WorkflowEvidenceError.invalid("Enter an admission context from 1024 to 1,048,576 tokens.")
        }
        if budgetEnabled && !EndpointMemoryReviewRules.supportsTotalBudget(slot) {
            throw WorkflowEvidenceError.invalid("Total model budgets require a Strata profile without a fixed expert-memory setting.")
        }
        if contextEnabled && slot.servingProfile != nil {
            throw WorkflowEvidenceError.invalid("Strata uses the runtime context in its serving profile; remove the admission context estimate.")
        }
        if budgetEnabled && !reserveEnabled {
            throw WorkflowEvidenceError.invalid("Turn off the total model budget before turning off its headroom reserve.")
        }
        let result = EndpointMemoryPolicy(idleTimeoutSeconds: idleTimeoutSeconds, keepLoaded: keepLoaded,
            minimumHeadroomGB: reserve, modelMemoryBudgetGB: budget,
            unloadUnderPressure: pressureEnabled ? true : nil, contextTokens: context, releaseAfterRequest: releaseAfterRequest)
        guard result.isValid else { throw WorkflowEvidenceError.invalid("Review idle timeout, reserve and pressure settings before previewing.") }
        return result
    }
}

struct EndpointMemoryPolicyReview: Equatable {
    let slot: EndpointSlot
    let draft: EndpointMemoryPolicyDraft
    let policy: EndpointMemoryPolicy
    let previewHash: String
    let allocation: ServingMemoryAllocation?
    let estimatedResidentBytes: Int64?
}

enum EndpointMemoryReviewRules {
    static func supportsTotalBudget(_ slot: EndpointSlot) -> Bool {
        slot.servingProfile != nil && slot.servingProfile?.options.expertMemoryGB == nil
    }

    static func canConfirm(_ review: EndpointMemoryPolicyReview, draft: EndpointMemoryPolicyDraft,
                           slots: [EndpointSlot], freshHash: String) -> Bool {
        !freshHash.isEmpty && freshHash == review.previewHash && draft == review.draft &&
            slots.contains(review.slot) && (try? draft.policy(for: review.slot)) == review.policy
    }
}

struct EndpointMemoryReviewSheet: View {
    let slot: EndpointSlot
    @ObservedObject var endpoint: EndpointSupervisor
    let api: WorkbenchAPI
    private let initialPolicy: EndpointMemoryPolicy
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EndpointMemoryPolicyDraft
    @State private var review: EndpointMemoryPolicyReview?
    @State private var busy = false
    @State private var error: String?
    @State private var actionTask: Task<Void, Never>?

    init(slot: EndpointSlot, endpoint: EndpointSupervisor, api: WorkbenchAPI) {
        self.slot = slot
        self.endpoint = endpoint
        self.api = api
        let initialPolicy = slot.memoryPolicy ?? endpoint.slotMemoryPolicies[slot.id] ?? .legacy
        self.initialPolicy = initialPolicy
        _draft = State(initialValue: EndpointMemoryPolicyDraft(policy: initialPolicy))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Endpoint memory policy").font(WorkbenchTypography.title)
            Text(slot.modelPath).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            Text("Port \(slot.port) · " + (slot.servingProfile?.name ?? "Automatic runtime"))
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    settings.disabled(busy || review != nil)
                    if let review { reviewedEffects(review) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ErrorBanner(text: error)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if review != nil {
                    Button("Change settings") { review = nil; error = nil }.disabled(busy)
                    Button("Apply policy") { actionTask = Task { await confirm() } }
                        .buttonStyle(.workbenchPrimary).disabled(busy || endpoint.isChanging || endpoint.isUnloading)
                        .accessibilityIdentifier("endpoint-memory-confirm")
                } else {
                    Button("Preview policy") { actionTask = Task { await prepare() } }
                        .buttonStyle(.workbenchPrimary).disabled(busy || endpoint.isChanging || endpoint.isUnloading)
                        .accessibilityIdentifier("endpoint-memory-preview")
                }
            }
        }
        .padding(WorkbenchSpacing.lg).frame(width: 560, height: 640)
        .interactiveDismissDisabled(busy)
        .onChange(of: draft) { _, _ in review = nil; error = nil }
        .onDisappear { actionTask?.cancel() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Picker("Unload when idle", selection: $draft.idleTimeoutSeconds) {
                Text("Never").tag(0)
                Text("1 minute").tag(60)
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
                Text("30 minutes").tag(1800)
                Text("1 hour").tag(3600)
                if ![0, 60, 300, 600, 1800, 3600].contains(draft.idleTimeoutSeconds) {
                    Text("\(draft.idleTimeoutSeconds) seconds").tag(draft.idleTimeoutSeconds)
                }
            }.disabled(draft.keepLoaded || draft.releaseAfterRequest == true)
            Toggle("Release weights after each request", isOn: Binding(get: { draft.releaseAfterRequest == true }, set: { draft.setReleaseAfterRequest($0) }))
                .accessibilityIdentifier("endpoint-memory-release-after-request")
            Toggle("Keep loaded after use", isOn: Binding(get: { draft.keepLoaded }, set: { draft.setKeepLoaded($0) }))
                .help("Prevents idle and pressure-based unloading. Manual unload remains available.")
            Divider()
            Toggle("Check memory before loading", isOn: Binding(get: { draft.reserveEnabled }, set: { draft.setReserve($0) }))
                .disabled(draft.budgetEnabled)
                .help(draft.budgetEnabled ? "Turn off the total model budget before disabling its required reserve." : "Check estimated model memory plus the reserve against system headroom before loading.")
            if draft.reserveEnabled {
                LabeledContent("Headroom reserve, GB") {
                    TextField("GB", text: $draft.reserveGB)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("endpoint-memory-reserve")
                }
            }
            Toggle("Unload idle model under memory pressure", isOn: Binding(get: { draft.pressureEnabled }, set: { draft.setPressure($0) }))
                .accessibilityIdentifier("endpoint-memory-pressure")
            Text("Pressure handling checks the reserve before new requests and unloads an idle model when headroom falls below it. Active requests finish first; unavailable headroom blocks new requests.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Divider()
            if EndpointMemoryReviewRules.supportsTotalBudget(slot) {
                Toggle("Set a total model memory budget", isOn: Binding(get: { draft.budgetEnabled }, set: { draft.setBudget($0) }))
                if draft.budgetEnabled {
                    LabeledContent("Total model budget, GB") {
                        TextField("GB", text: $draft.budgetGB)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("endpoint-memory-budget")
                    }
                }
                Text("Strata estimates fixed weights, runtime and context memory, then uses the remaining budget for its expert cache. This allowance is a source estimate, not measured process RAM or a system memory limit.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } else if let expert = slot.servingProfile?.options.expertMemoryGB {
                Text("This profile fixes expert memory at \(expert, specifier: "%.1f") GB. A total model budget cannot be combined with that setting.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if draft.budgetEnabled { Button("Remove total model budget") { draft.setBudget(false) } }
            } else if draft.budgetEnabled {
                Text("Total model budgets require a Strata profile.").font(WorkbenchTypography.metadata)
                Button("Remove total model budget") { draft.setBudget(false) }
            }
            if let profile = slot.servingProfile {
                Text("Runtime context: \(profile.options.contextTokens.formatted()) tokens, set by the serving profile and included in its memory estimate.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if draft.contextEnabled { Button("Remove admission context estimate") { draft.setContext(false) } }
            } else {
                Toggle("Include context cache in loading estimate", isOn: Binding(get: { draft.contextEnabled }, set: { draft.setContext($0) }))
                if draft.contextEnabled {
                    LabeledContent("Admission context, tokens") {
                        TextField("Tokens", text: $draft.contextTokens)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("endpoint-memory-context")
                    }
                }
                Text("Admission context adds an estimated KV cache to the memory check before loading. It does not change the runtime’s context limit. An unknown cache size blocks loading.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }.font(WorkbenchTypography.secondary)
    }

    private func reviewedEffects(_ review: EndpointMemoryPolicyReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Divider()
            Text("Policy preview").font(WorkbenchTypography.cardTitle)
            Text(review.policy.keepLoaded ? "Keep the model loaded after use." : review.policy.idleTimeoutSeconds == 0
                 ? "No timed idle unload." : "Unload after \(review.policy.idleTimeoutSeconds) idle seconds.")
            if let reserve = review.policy.minimumHeadroomGB { Text("Reserve \(reserve, specifier: "%.1f") GB of system headroom.") }
            else { Text("Do not check headroom before loading.") }
            if review.policy.unloadUnderPressure == true { Text("Unload idle weights under memory pressure; check reserve before new requests.") }
            if let context = review.policy.contextTokens { Text("Estimate context cache for \(context.formatted()) tokens; runtime context is unchanged.") }
            if let budget = review.policy.modelMemoryBudgetGB { Text("Total source allowance: \(budget, specifier: "%.1f") GB.") }
            if let bytes = review.estimatedResidentBytes {
                Text("Estimated resident model memory: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory))
            }
            if let allocation = review.allocation {
                if let mode = allocation.mode { Text("Allocation: " + mode) }
                if let expert = allocation.expertMemoryGB { Text("Estimated expert cache allowance: \(expert, specifier: "%.1f") GB.") }
            }
            if review.policy.modelMemoryBudgetGB != initialPolicy.modelMemoryBudgetGB {
                Text("Changing the budget unloads an already loaded model after active requests finish. The next request loads it with the new budget; new requests are refused while unloading is pending.")
            }
            Text("The endpoint and model files stay in place. Preview will be checked again before applying.")
                .foregroundStyle(WorkbenchColor.muted)
        }.font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @MainActor private func preview(_ policy: EndpointMemoryPolicy) async throws -> [String: Any] {
        if let profile = slot.servingProfile { return try await profile.preview(api: api, port: slot.port, jit: true, policy: policy) }
        let options = slot.accelerationOptions
        return try await api.servePreview(repo: slot.modelPath, runtime: "auto", port: slot.port, jit: true,
            memoryPolicy: policy, m5Prefill: options.m5Prefill, promptLookup: options.promptLookup, visionCache: options.visionCache)
    }

    @MainActor private func prepare() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let captured = draft
            let policy = try captured.policy(for: slot)
            guard endpoint.fleet.slots.contains(slot) else { throw WorkflowEvidenceError.invalid("Endpoint settings changed. Close this review and reopen it.") }
            let plan = try await preview(policy)
            try Task.checkCancellation()
            guard draft == captured, endpoint.fleet.slots.contains(slot) else { throw WorkflowEvidenceError.invalid("Endpoint settings changed. Close this review and reopen it.") }
            guard let hash = plan["preview_hash"] as? String, !hash.isEmpty else { throw ServeProbeError.servePreviewMissingHash }
            let allocation = (plan["strata_memory_allocation"] as? [String: Any]).flatMap { value -> ServingMemoryAllocation? in
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(ServingMemoryAllocation.self, from: data)
            }
            let estimate = allocation?.estimatedResidentBytes ?? (plan["strata_memory_estimate_bytes"] as? NSNumber)?.int64Value
            review = EndpointMemoryPolicyReview(slot: slot, draft: captured, policy: policy, previewHash: hash,
                allocation: allocation, estimatedResidentBytes: estimate)
        } catch is CancellationError { }
        catch { self.error = AppHost.render(error) }
    }

    @MainActor private func confirm() async {
        guard !busy, let captured = review else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard endpoint.fleet.slots.contains(slot), draft == captured.draft else {
                throw WorkflowEvidenceError.invalid("Endpoint settings changed. Close this review and reopen it.")
            }
            let fresh = try await preview(captured.policy)
            try Task.checkCancellation()
            guard let hash = fresh["preview_hash"] as? String,
                  EndpointMemoryReviewRules.canConfirm(captured, draft: draft, slots: endpoint.fleet.slots, freshHash: hash) else {
                review = nil
                throw WorkflowEvidenceError.invalid("The memory preview changed. Preview the policy again before applying.")
            }
            await endpoint.setSlotMemoryPolicy(id: slot.id, captured.policy)
            if let message = endpoint.lastError { throw WorkflowEvidenceError.invalid(message) }
            guard endpoint.fleet.slots.first(where: { $0.id == slot.id })?.memoryPolicy == captured.policy else {
                throw WorkflowEvidenceError.invalid("The saved memory policy does not match this review. Refresh the endpoint before retrying.")
            }
            dismiss()
        } catch is CancellationError { }
        catch { self.error = AppHost.render(error) }
    }
}
