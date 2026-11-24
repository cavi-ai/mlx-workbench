import Foundation

// MARK: - FleetRouter
//
// Role router (spec 09 P4 + Phase 2.3): map fleet-slot roles onto running
// endpoints via `mlx-agent fleet render/apply --port-map`, while supporting
// multimodal (audio/media/embedding) roles, authenticated endpoints (via Front
// Door or the managed key environment variable).

enum FleetRouter {
    enum RouteRole: String, CaseIterable, Equatable, Sendable, Identifiable {
        case coding = "coding"
        case general = "general"
        case reasoning = "reasoning"
        case vision = "vision"
        case embedding = "embedding"
        case audio = "audio"
        case media = "media"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .coding: return "Coding"
            case .general: return "General"
            case .reasoning: return "Reasoning"
            case .vision: return "Vision"
            case .embedding: return "Embedding"
            case .audio: return "Audio"
            case .media: return "Media"
            }
        }

        /// Whether `mlx-agent fleet render/apply` currently accepts this role
        /// in `fleet-router.yaml` (`mlx_agent.fleet.ROLE_DEFAULT_RUNTIME`).
        var supportsFleetCLI: Bool {
            switch self {
            case .coding, .general, .reasoning, .vision, .embedding:
                return true
            case .audio, .media:
                return false
            }
        }
    }

    enum AuthMode: Equatable, Sendable {
        case none
        /// Client supplies the endpoint's key via an environment variable; no
        /// raw secret is ever written into `fleet-router.yaml`.
        case envVar(name: String)
        /// Routed through the shared local Front Door on its loopback port.
        case frontDoor(port: Int)

        var guidance: String? {
            switch self {
            case .none:
                return nil
            case .envVar(let name):
                return "Auth via $\(name) (no raw key written)"
            case .frontDoor(let port):
                return "Front Door :\(port) uses $\(FleetRouter.localAPIKeyEnvVar)"
            }
        }
    }

    enum RouteKind: Equatable, Sendable {
        case chat
        case typedTask(kinds: [String])
    }

    struct Assignment: Equatable, Sendable, Identifiable {
        let role: UseCase?
        let routeRole: RouteRole
        let repo: String
        let port: Int
        let authMode: AuthMode
        let routeKind: RouteKind
        let isLocalRoute: Bool

        var id: String { fleetRole }
        var fleetRole: String { routeRole.rawValue }

        /// Backward-compatible initializer for UseCase-based chat routes.
        init(
            role: UseCase,
            repo: String,
            port: Int,
            authMode: AuthMode = .none,
            routeKind: RouteKind = .chat,
            isLocalRoute: Bool = false
        ) {
            self.role = role
            self.routeRole = FleetRouter.routeRole(for: role)
            self.repo = repo
            self.port = port
            self.authMode = authMode
            self.routeKind = routeKind
            self.isLocalRoute = isLocalRoute
        }

        init(
            routeRole: RouteRole,
            role: UseCase? = nil,
            repo: String,
            port: Int,
            authMode: AuthMode = .none,
            routeKind: RouteKind = .chat,
            isLocalRoute: Bool = false
        ) {
            self.role = role
            self.routeRole = routeRole
            self.repo = repo
            self.port = port
            self.authMode = authMode
            self.routeKind = routeKind
            self.isLocalRoute = isLocalRoute
        }
    }

    struct SkippedRole: Equatable, Sendable, Identifiable {
        let role: UseCase?
        let routeRole: RouteRole
        let reason: String

        var id: String { "\(routeRole.rawValue)-\(reason)" }
        var fleetRole: String { routeRole.rawValue }

        init(role: UseCase, reason: String) {
            self.role = role
            self.routeRole = FleetRouter.routeRole(for: role)
            self.reason = reason
        }

        init(routeRole: RouteRole, role: UseCase? = nil, reason: String) {
            self.role = role
            self.routeRole = routeRole
            self.reason = reason
        }
    }

    struct Plan: Equatable, Sendable {
        let assignments: [Assignment]
        let skipped: [SkippedRole]
        let targetPath: String

        var isEmpty: Bool { assignments.isEmpty }

        /// Assignments accepted directly by `mlx-agent fleet render/apply`.
        var cliAssignments: [Assignment] {
            assignments.filter { $0.routeRole.supportsFleetCLI }
        }

        /// Multimodal (audio/media) assignments routed outside the chat-only
        /// `mlx-agent fleet` YAML vocabulary.
        var multimodalAssignments: [Assignment] {
            assignments.filter { !$0.routeRole.supportsFleetCLI }
        }
    }

    /// Where the router config lives. Written exclusively through
    /// `fleet apply`, so the file carries fleet's managed header and later
    /// `fleet` runs (app or CLI) can keep managing it; the path is distinct
    /// from any hand-maintained router config, which fleet would refuse.
    static var defaultTargetPath: String {
        WorkbenchStatePaths.applicationSupport().appendingPathComponent("fleet-router.yaml").path
    }

    static func routeRole(for useCase: UseCase) -> RouteRole {
        switch useCase {
        case .coding: return .coding
        case .generalChat: return .general
        case .reasoning: return .reasoning
        case .vision: return .vision
        }
    }

    /// Infer a multimodal/typed route role from a server's advertised `task_kinds`.
    static func inferredTypedRole(from taskKinds: [String]) -> RouteRole? {
        let lowered = Set(taskKinds.map { $0.lowercased() })
        if !lowered.isDisjoint(with: ["transcribe", "speak", "music_generation", "sound_effects"]) {
            return .audio
        }
        if !lowered.isDisjoint(with: ["video_generation", "image_generation", "mesh_generation"]) {
            return .media
        }
        if !lowered.isDisjoint(with: ["embedding", "classification"]) {
            return .embedding
        }
        return nil
    }

    /// Safe display label for local typed routes outside the fleet renderer.
    static func safeLocalRouteIdentifier(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reject any control character (NUL, newline, tab, etc.).
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }
        // Reject Windows-style separators or traversal segments on the raw path
        // before URL standardization can normalize them away.
        if trimmed.contains("\\") { return nil }
        let rawSegments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if rawSegments.contains(where: { $0 == ".." || $0 == "." }) {
            return nil
        }
        guard let lastComponent = rawSegments.last(where: { !$0.isEmpty }) else {
            return nil
        }
        let rawName = String(lastComponent)
        if rawName.contains("..") { return nil }

        // Sanitize into [A-Za-z0-9._-], collapsing disallowed runs to '-'.
        var slug = ""
        var previousWasDash = false
        for scalar in rawName.unicodeScalars {
            let isAllowed = (scalar.value >= 48 && scalar.value <= 57)   // 0-9
                || (scalar.value >= 65 && scalar.value <= 90)            // A-Z
                || (scalar.value >= 97 && scalar.value <= 122)           // a-z
                || scalar == "." || scalar == "_" || scalar == "-"
            if isAllowed {
                slug.unicodeScalars.append(scalar)
                previousWasDash = (scalar == "-")
            } else if !previousWasDash && !slug.isEmpty {
                slug.append("-")
                previousWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard !slug.isEmpty, slug.count <= 192, !slug.contains("..") else { return nil }
        guard let first = slug.unicodeScalars.first,
              (first.value >= 48 && first.value <= 57)
                || (first.value >= 65 && first.value <= 90)
                || (first.value >= 97 && first.value <= 122) else {
            return nil
        }
        return slug
    }

    /// Environment variable name emitted by `mlx-agent fleet` for authenticated routes.
    static let localAPIKeyEnvVar = "MLX_AGENT_LOCAL_API_KEY"

    static func plan(
        slots: [EndpointSlot],
        states: [UUID: EndpointState],
        servers: [ServerInfo] = [],
        frontDoor: FrontDoorSettings? = nil,
        frontDoorRoutes: Set<String> = [],
        targetPath: String = defaultTargetPath
    ) -> Plan {
        var assignments: [Assignment] = []
        var skipped: [SkippedRole] = []
        var assignedRoles = Set<RouteRole>()
        var rendererKeyDigest: String?

        for slot in slots {
            let matchingServer = servers.first(where: { $0.port == slot.port })
            let taskKinds = matchingServer?.taskKinds ?? []
            let isTypedServer = matchingServer.map { !$0.supportsChatCompletions } ?? false
            let inferredRole = isTypedServer ? inferredTypedRole(from: taskKinds) : nil

            let resolvedRouteRole: RouteRole
            if let inferred = inferredRole {
                resolvedRouteRole = inferred
            } else if let slotRole = slot.role {
                resolvedRouteRole = routeRole(for: slotRole)
            } else {
                // Unassigned chat slot: ignored, not skipped.
                continue
            }

            guard slot.enabled else {
                skipped.append(SkippedRole(routeRole: resolvedRouteRole, role: slot.role, reason: "endpoint disabled"))
                continue
            }
            guard case .running = states[slot.id] else {
                skipped.append(SkippedRole(routeRole: resolvedRouteRole, role: slot.role, reason: "endpoint not running"))
                continue
            }
            guard !assignedRoles.contains(resolvedRouteRole) else {
                skipped.append(SkippedRole(routeRole: resolvedRouteRole, role: slot.role, reason: "role already assigned"))
                continue
            }

            let modelPath = matchingServer?.path ?? slot.modelPath
            let publicName = matchingServer?.path.map(FrontDoorCoordinator.publicModelName(for:))
                ?? matchingServer?.repo ?? FrontDoorCoordinator.publicModelName(for: slot.modelPath)
            let slotDigest = slot.apiKeySHA256 ?? matchingServer?.apiKeySHA256
            let isRoutableRuntime = matchingServer.map { $0.jit == true || $0.runtime == "tasks" } ?? slot.usesJIT
            let routedFrontDoor = frontDoor.flatMap { listener in
                isRoutableRuntime && listener.apiKeySHA256 == slotDigest && frontDoorRoutes.contains(publicName)
                    ? listener : nil
            }
            let upstreamID = routedFrontDoor != nil ? publicName
                : matchingServer?.repo ?? HFRepoID.forPath(modelPath) ?? publicName
            let routeID: String
            if resolvedRouteRole.supportsFleetCLI {
                // The pinned engine validates the exact model ID it sends upstream.
                guard upstreamID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,191}$",
                                       options: .regularExpression) != nil else {
                    skipped.append(SkippedRole(routeRole: resolvedRouteRole, role: slot.role,
                                               reason: "router needs a publisher/model ID served by this endpoint"))
                    continue
                }
                if let slotDigest {
                    if let existingDigest = rendererKeyDigest, existingDigest != slotDigest {
                        skipped.append(SkippedRole(routeRole: resolvedRouteRole, role: slot.role,
                                                   reason: "router config supports one API key; use the same key for these routes"))
                        continue
                    }
                    rendererKeyDigest = slotDigest
                }
                routeID = upstreamID
            } else if let localID = HFRepoID.forPath(modelPath) ?? safeLocalRouteIdentifier(for: modelPath) {
                routeID = localID
            } else {
                skipped.append(SkippedRole(routeRole: resolvedRouteRole, role: slot.role,
                                           reason: "unsafe or invalid local model path"))
                continue
            }

            let authMode: AuthMode
            let effectivePort: Int
            if let routedFrontDoor {
                authMode = .frontDoor(port: routedFrontDoor.port)
                effectivePort = routedFrontDoor.port
            } else {
                authMode = slotDigest != nil ? .envVar(name: localAPIKeyEnvVar) : .none
                effectivePort = slot.port
            }

            let routeKind: RouteKind = isTypedServer ? .typedTask(kinds: taskKinds) : .chat
            assignedRoles.insert(resolvedRouteRole)
            assignments.append(Assignment(
                routeRole: resolvedRouteRole,
                role: slot.role,
                repo: routeID,
                port: effectivePort,
                authMode: authMode,
                routeKind: routeKind,
                isLocalRoute: HFRepoID.forPath(modelPath) == nil
            ))
        }
        return Plan(assignments: assignments, skipped: skipped, targetPath: targetPath)
    }
}
