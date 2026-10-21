import AppKit
import Foundation

// MARK: - UpdateCoordinator
//
// In-app updates for an app built from its checkout
// (WorkbenchPython.buildCheckoutRoot(); an installed build is never rebuilt
// from the checkout its agent path points at). Two
// channels, mirroring the repo's own provenance rules:
//
//   official — check out the newest `v*` release tag (detached HEAD at the
//              tag is the release identity), then sync submodules.
//   beta     — fast-forward main to origin/main, then sync submodules.
//
// Checking is read-only and previewed (current -> target, dirty-file count);
// updating refuses a dirty working tree, streams git output into a log tail,
// and never runs a shell — every git invocation is argv tokens through an
// injectable runner so tests never touch the real repository.
//
// An installed build (no checkout) updates from GitHub releases instead; see
// ReleaseUpdater.swift. The channels map to the latest release and the
// nightly prerelease built from main.

@MainActor
final class UpdateCoordinator: ObservableObject {
    enum Channel: String, CaseIterable, Identifiable, Sendable {
        case official
        case beta

        var id: String { rawValue }

        var title: String {
            switch self {
            case .official: return "Releases"
            case .beta: return "Nightly (main)"
            }
        }

        var blurb: String {
            switch self {
            case .official: return "Track tagged releases. Most stable; the app checks out the release tag exactly as published."
            case .beta: return "Track main as it lands. Newest fixes first; expect occasional rough edges."
            }
        }

        var releaseBlurb: String {
            switch self {
            case .official: return "Install the latest published release: notarized, Developer ID signed."
            case .beta: return "Install the nightly build of main. Newest fixes first; expect occasional rough edges."
            }
        }
    }

    /// The running app bundle and how to replace it from a release.
    struct InstalledApp {
        let bundle: URL
        let build: InstalledBuild
        let installer: ReleaseInstalling

        static func running() -> InstalledApp {
            InstalledApp(
                bundle: Bundle.main.bundleURL,
                build: .from(infoDictionary: Bundle.main.infoDictionary ?? [:]),
                installer: DMGReleaseInstaller()
            )
        }
    }

    struct Offer: Equatable, Sendable {
        let target: String
        let current: String
        let dirtyFiles: Int
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(Offer)
        case applying
        case updated(target: String)
        case failed(String)
    }

    static let channelKey = "mlx-workbench.updateChannel"
    static let maxTailLines = 200

    @Published private(set) var phase: Phase = .idle
    @Published var channel: Channel {
        didSet {
            defaults.set(channel.rawValue, forKey: Self.channelKey)
            if channel != oldValue {
                checkGeneration = UUID(); reviewedCheckout = nil; releaseOffer = nil
                activeGitCancellation?.cancel()
                if phase != .applying { phase = .idle }
            }
        }
    }
    @Published private(set) var logTail: [String] = []

    private let defaults: UserDefaults
    /// The checkout the updater operates on.
    let repoRoot: URL?
    /// The installed bundle, when there is no checkout to update.
    let installed: InstalledApp?
    private var releaseOffer: ReleaseOffer?
    private var checkGeneration = UUID()
    private struct ReviewedCheckout: Sendable {
        let channel: Channel
        let offer: Offer
        let currentRevision: String
        let targetRevision: String
    }
    private var reviewedCheckout: ReviewedCheckout?
    /// Injected git runner: argv in, stdout out; throws on non-zero exit.
    private let runGit: (@Sendable ([String]) throws -> String)?
    private var activeGitCancellation: CLIInvocationCancellation?

    init(
        repoRoot: URL? = WorkbenchPython.buildCheckoutRoot(),
        installed: InstalledApp? = nil,
        defaults: UserDefaults = .standard,
        runGit: (@Sendable ([String]) throws -> String)? = nil
    ) {
        self.repoRoot = repoRoot
        self.installed = repoRoot == nil ? installed : nil
        self.defaults = defaults
        self.runGit = runGit
        self.channel = Channel(rawValue: defaults.string(forKey: Self.channelKey) ?? "") ?? .official
    }

    /// True when updates come from GitHub releases instead of a checkout.
    var installsReleases: Bool { installed != nil }

    var canUpdate: Bool {
        (repoRoot != nil || installed != nil) && phase != .checking && phase != .applying
    }

    var summary: String {
        switch phase {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate(let current): return "Up to date at \(current)."
        case .available(let offer): return "\(offer.target) is available (current: \(offer.current))."
        case .applying: return "Updating…"
        case .updated(let target):
            return installsReleases
                ? "Installed \(target). Relaunch to run it."
                : "Updated to \(target). Rebuild and relaunch to run it."
        case .failed(let reason): return "Update failed: \(reason)"
        }
    }

    // MARK: - Check (read-only)

    /// Read-only check of the selected channel. Never mutates the checkout.
    func check() async {
        guard phase != .checking, phase != .applying else { return }
        let generation = UUID(); checkGeneration = generation
        defer { if checkGeneration == generation, phase == .checking { phase = .idle } }
        let selectedChannel = channel
        if let installed {
            await checkRelease(installed, channel: selectedChannel, generation: generation)
            return
        }
        guard let repoRoot else {
            phase = .failed("The app is neither running from a repository checkout nor installed from a release, so it cannot update itself.")
            return
        }
        phase = .checking; reviewedCheckout = nil
        let result: Result<ReviewedCheckout, Error>
        do { result = .success(try await gitWork { runner in
            let dirty = try Self.dirtyFileCount(repoRoot: repoRoot, runGit: runner)
            let current = try Self.currentLabel(repoRoot: repoRoot, runGit: runner)
            let currentRevision = try Self.revision("HEAD", root: repoRoot, runGit: runner)
            let target = try Self.fetchTarget(channel: selectedChannel, repoRoot: repoRoot, runGit: runner)
            let targetRevision = try Self.revision(target, root: repoRoot, runGit: runner)
            return ReviewedCheckout(channel: selectedChannel,
                offer: Offer(target: target, current: current, dirtyFiles: dirty),
                currentRevision: currentRevision, targetRevision: targetRevision)
        }) } catch { result = .failure(error) }
        guard !Task.isCancelled, checkGeneration == generation, channel == selectedChannel else { return }
        do {
            let checked = try result.get()
            if checked.targetRevision == checked.currentRevision { phase = .upToDate(current: checked.offer.current) }
            else { reviewedCheckout = checked; phase = .available(checked.offer) }
        } catch { phase = .failed(AppHost.render(error)) }
    }

    // MARK: - Apply

    /// Apply the checked offer: refuses a dirty tree, checks out the target,
    /// syncs submodules, and re-checks. Streaming git output lands in logTail.
    func apply(offer: Offer) async {
        if let installed {
            await applyRelease(offer: offer, installed: installed)
            return
        }
        guard let repoRoot, case .available(let currentOffer) = phase, currentOffer == offer,
              let reviewed = reviewedCheckout, reviewed.offer == offer, reviewed.channel == channel else { return }
        phase = .applying
        do {
            try await gitWork { runner in
                let dirty = try Self.dirtyFileCount(repoRoot: repoRoot, runGit: runner)
                guard dirty == 0 else { throw UpdateError.gitFailed("status", "The checkout has uncommitted changes. Commit or discard them before updating.") }
                guard try Self.revision("HEAD", root: repoRoot, runGit: runner) == reviewed.currentRevision else {
                    throw UpdateError.gitFailed("update", "The checkout changed. Review the update again.")
                }
                if reviewed.channel == .beta {
                    _ = try runner(["-C", repoRoot.path, "merge-base", "--is-ancestor", "main", reviewed.targetRevision])
                }
            }
            guard !Task.isCancelled, reviewed.channel == channel else { throw CancellationError() }
        } catch { phase = .failed(AppHost.render(error)); return }
        logTail = []
        do {
            for argv in Self.applyPlan(channel: reviewed.channel, target: reviewed.targetRevision) {
                try Task.checkCancellation()
                guard reviewed.channel == channel else { throw CancellationError() }
                try await Self.runStreaming(
                    argv, repoRoot: repoRoot,
                    onLine: { [weak self] line in
                        guard let self else { return }
                        Task { @MainActor in
                            self.logTail.append(line)
                            if self.logTail.count > Self.maxTailLines {
                                self.logTail.removeFirst(self.logTail.count - Self.maxTailLines)
                            }
                        }
                    }
                )
            }
            let current = try await gitWork { runner in
                guard try Self.revision("HEAD", root: repoRoot, runGit: runner) == reviewed.targetRevision else {
                    throw UpdateError.gitFailed("update", "The checkout no longer matches the reviewed revision.")
                }
                return try Self.currentLabel(repoRoot: repoRoot, runGit: runner)
            }
            reviewedCheckout = nil
            phase = .updated(target: current)
        } catch {
            phase = .failed(AppHost.render(error))
        }
    }

    // MARK: - Installed builds (GitHub releases)

    private func checkRelease(_ installed: InstalledApp, channel selectedChannel: Channel, generation: UUID) async {
        releaseOffer = nil
        if let refusal = ReleaseFeed.installRefusal(bundle: installed.bundle) {
            phase = .failed(refusal)
            return
        }
        phase = .checking
        do {
            let release = try await installed.installer.fetchRelease(ReleaseFeed.endpoint(for: selectedChannel))
            guard !Task.isCancelled, generation == checkGeneration, selectedChannel == channel else { return }
            switch ReleaseFeed.decide(channel: selectedChannel, release: release, installed: installed.build) {
            case .current:
                phase = .upToDate(current: installed.build.label)
            case .available(let offer):
                releaseOffer = offer
                phase = .available(Offer(target: offer.target, current: installed.build.label, dirtyFiles: 0))
            case .unavailable(let reason):
                phase = .failed(reason)
            }
        } catch {
            if generation == checkGeneration { phase = .failed(AppHost.render(error)) }
        }
    }

    private func applyRelease(offer: Offer, installed: InstalledApp) async {
        guard case .available = phase, let releaseOffer, releaseOffer.target == offer.target else { return }
        phase = .applying
        logTail = []
        do {
            let build = try await installed.installer.install(
                releaseOffer, replacing: installed.bundle,
                log: { [weak self] line in
                    Task { @MainActor in self?.logTail.append(line) }
                }
            )
            self.releaseOffer = nil
            phase = .updated(target: build.label)
        } catch {
            phase = .failed(AppHost.render(error))
        }
    }

    // MARK: - Pure planning (tested directly)

    /// First `v*` tag from a version-sorted tag list.
    nonisolated static func latestTag(from output: String) -> String? {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("v") }
    }

    nonisolated static func dirtyFileCount(from porcelain: String) -> Int {
        porcelain.split(separator: "\n").count
    }

    /// The git argv sequence that moves the checkout to the channel target.
    nonisolated static func applyPlan(channel: Channel, target: String) -> [[String]] {
        switch channel {
        case .official:
            return [
                ["checkout", "--detach", target],
                ["submodule", "update", "--init", "--recursive"],
            ]
        case .beta:
            return [
                ["checkout", "main"],
                ["merge", "--ff-only", target],
                ["submodule", "update", "--init", "--recursive"],
            ]
        }
    }

    // MARK: - Git plumbing

    private func gitWork<Value: Sendable>(_ operation: @escaping @Sendable (@Sendable ([String]) throws -> String) throws -> Value) async throws -> Value {
        let token = CLIInvocationCancellation()
        activeGitCancellation = token
        defer { if activeGitCancellation === token { activeGitCancellation = nil } }
        let runner = runGit ?? { try Self.git($0, cancellation: token) }
        return try await withTaskCancellationHandler {
            try await WorkbenchIO.perform { Result { try operation(runner) } }.get()
        } onCancel: { token.cancel() }
    }

    nonisolated static func git(_ argv: [String], cancellation: CLIInvocationCancellation = CLIInvocationCancellation()) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try BoundedProcessCapture.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: argv, environment: environment, timeout: 60, cancellation: cancellation)
        guard result.status == 0 else {
            throw UpdateError.gitFailed(argv.first ?? "git", result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    nonisolated static func dirtyFileCount(repoRoot: URL, runGit: @Sendable ([String]) throws -> String) throws -> Int {
        let porcelain = try runGit(["-C", repoRoot.path, "status", "--porcelain"])
        return dirtyFileCount(from: porcelain)
    }

    nonisolated private static func revision(_ reference: String, root: URL, runGit: @Sendable ([String]) throws -> String) throws -> String {
        let hash = try runGit(["-C", root.path, "rev-parse", "--verify", reference + "^{commit}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (hash.count == 40 || hash.count == 64), hash.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.gitFailed("rev-parse", "The update did not resolve to a complete commit identity.")
        }
        return hash
    }

    /// Tag when HEAD is exactly on a `v*` tag, else the short commit.
    nonisolated static func currentLabel(repoRoot: URL, runGit: @Sendable ([String]) throws -> String) throws -> String {
        let describe = (try? runGit(["-C", repoRoot.path, "describe", "--tags", "--exact-match"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let describe, describe.hasPrefix("v") { return describe }
        return try runGit(["-C", repoRoot.path, "rev-parse", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch and resolve the channel target without touching the worktree.
    nonisolated static func fetchTarget(
        channel: Channel, repoRoot: URL, runGit: @Sendable ([String]) throws -> String
    ) throws -> String {
        switch channel {
        case .official:
            _ = try runGit(["-C", repoRoot.path, "fetch", "--tags", "origin"])
            let tags = try runGit(["-C", repoRoot.path, "tag", "-l", "v*", "--sort=-v:refname"])
            guard let tag = latestTag(from: tags) else {
                throw UpdateError.noReleases
            }
            return tag
        case .beta:
            _ = try runGit(["-C", repoRoot.path, "fetch", "origin"])
            return try runGit(["-C", repoRoot.path, "rev-parse", "--short", "origin/main"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Stream one git invocation's combined output into the log tail.
    static func runStreaming(
        _ argv: [String],
        repoRoot: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        do {
            try await RuntimeInstaller.runInstall(repoRoot: repoRoot, executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: argv, environment: environment, timeout: 120, onLine: onLine)
        } catch { throw UpdateError.gitFailed(argv.first ?? "git", error.localizedDescription) }
    }

    // MARK: - Rebuild & relaunch

    /// The updater moved the checkout; the running binary is stale. Rebuild
    /// with the repo's own `make build-swift` (streamed into the log tail),
    /// reopen this bundle, and exit so launchd/menu state resets cleanly.
    func rebuildAndRelaunch() async {
        if let installed {
            installed.installer.relaunch(installed.bundle)
            return
        }
        guard let repoRoot else { return }
        phase = .applying
        do {
            try await Self.runMakeBuildSwift(repoRoot: repoRoot) { [weak self] line in
                guard let self else { return }
                Task { @MainActor in
                    self.logTail.append(line)
                    if self.logTail.count > Self.maxTailLines {
                        self.logTail.removeFirst(self.logTail.count - Self.maxTailLines)
                    }
                }
            }
            phase = .updated(target: "rebuilt")
        } catch {
            phase = .failed(AppHost.render(error))
            return
        }
        let bundle = Bundle.main.bundleURL
        NSWorkspace.shared.open(bundle)
        NSApp.terminate(nil)
    }

    /// Runs `make build-swift` in the repo root, streaming combined output.
    nonisolated static func runMakeBuildSwift(
        repoRoot: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        try await RuntimeInstaller.runInstall(repoRoot: repoRoot, executable: URL(fileURLWithPath: "/usr/bin/make"),
            arguments: ["build-swift"], timeout: 1800, onLine: onLine)
    }

    enum UpdateError: LocalizedError {
        case launchFailed(String)
        case gitFailed(String, String)
        case noReleases

        var errorDescription: String? {
            switch self {
            case .launchFailed(let detail):
                return "git could not be launched: \(detail)"
            case .gitFailed(let command, let detail):
                return "git \(command) failed: \(detail)"
            case .noReleases:
                return "No release tags were found on origin."
            }
        }
    }

}
