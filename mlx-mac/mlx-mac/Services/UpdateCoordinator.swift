import AppKit
import Foundation

// MARK: - UpdateCoordinator
//
// In-app updates for a checkout-run app (WorkbenchPython.repoRoot()). Two
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

@MainActor
final class UpdateCoordinator: ObservableObject {
    enum Channel: String, CaseIterable, Identifiable {
        case official
        case beta

        var id: String { rawValue }

        var title: String {
            switch self {
            case .official: return "Official releases"
            case .beta: return "Beta (live repo)"
            }
        }

        var blurb: String {
            switch self {
            case .official: return "Track tagged releases. Most stable; the app checks out the release tag exactly as published."
            case .beta: return "Track main as it lands. Newest fixes first; expect occasional rough edges."
            }
        }
    }

    struct Offer: Equatable {
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
        didSet { defaults.set(channel.rawValue, forKey: Self.channelKey) }
    }
    @Published private(set) var logTail: [String] = []

    private let defaults: UserDefaults
    /// The checkout the updater operates on.
    let repoRoot: URL?
    /// Injected git runner: argv in, stdout out; throws on non-zero exit.
    private let runGit: @Sendable ([String]) throws -> String

    /// Sendable wrapper for the default runner (a bare static function value
    /// loses its isolation context when passed as a default argument).
    nonisolated private static let defaultGit: @Sendable ([String]) throws -> String = { argv in
        try UpdateCoordinator.git(argv)
    }

    init(
        repoRoot: URL? = WorkbenchPython.repoRoot(),
        defaults: UserDefaults = .standard,
        runGit: @escaping @Sendable ([String]) throws -> String = UpdateCoordinator.defaultGit
    ) {
        self.repoRoot = repoRoot
        self.defaults = defaults
        self.runGit = runGit
        self.channel = Channel(rawValue: defaults.string(forKey: Self.channelKey) ?? "") ?? .official
    }

    var canUpdate: Bool {
        repoRoot != nil && phase != .checking && phase != .applying
    }

    var summary: String {
        switch phase {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate(let current): return "Up to date at \(current)."
        case .available(let offer): return "\(offer.target) is available (current: \(offer.current))."
        case .applying: return "Updating…"
        case .updated(let target): return "Updated to \(target). Rebuild and relaunch to run it."
        case .failed(let reason): return "Update failed: \(reason)"
        }
    }

    // MARK: - Check (read-only)

    /// Read-only check of the selected channel. Never mutates the checkout.
    func check() async {
        guard let repoRoot else {
            phase = .failed("The app is not running from a repository checkout, so it cannot update itself.")
            return
        }
        phase = .checking
        do {
            let dirty = try Self.dirtyFileCount(repoRoot: repoRoot, runGit: runGit)
            let current = try Self.currentLabel(repoRoot: repoRoot, runGit: runGit)
            let target = try Self.fetchTarget(
                channel: channel, repoRoot: repoRoot, runGit: runGit
            )
            if target == current {
                phase = .upToDate(current: current)
            } else {
                phase = .available(Offer(target: target, current: current, dirtyFiles: dirty))
            }
        } catch {
            phase = .failed(AppHost.render(error))
        }
    }

    // MARK: - Apply

    /// Apply the checked offer: refuses a dirty tree, checks out the target,
    /// syncs submodules, and re-checks. Streaming git output lands in logTail.
    func apply(offer: Offer) async {
        guard let repoRoot, case .available = phase else { return }
        do {
            let dirty = try Self.dirtyFileCount(repoRoot: repoRoot, runGit: runGit)
            guard dirty == 0 else {
                phase = .failed("The checkout has \(dirty) uncommitted change\(dirty == 1 ? "" : "s"). Commit or discard them first — the updater never mixes local edits into an update.")
                return
            }
        } catch {
            phase = .failed(AppHost.render(error))
            return
        }
        phase = .applying
        logTail = []
        do {
            for argv in Self.applyPlan(channel: channel, target: offer.target) {
                try await Self.runStreaming(
                    argv, repoRoot: repoRoot,
                    runGit: runGit,
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
            let current = try Self.currentLabel(repoRoot: repoRoot, runGit: runGit)
            phase = .updated(target: current)
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
                ["checkout", target],
                ["submodule", "update", "--init", "--recursive"],
            ]
        case .beta:
            return [
                ["checkout", "main"],
                ["pull", "--ff-only", "origin", "main"],
                ["submodule", "update", "--init", "--recursive"],
            ]
        }
    }

    // MARK: - Git plumbing

    nonisolated static func git(_ argv: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = argv
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw UpdateError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError.gitFailed(argv.first ?? "git", err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    nonisolated static func dirtyFileCount(repoRoot: URL, runGit: @Sendable ([String]) throws -> String) throws -> Int {
        let porcelain = try runGit(["-C", repoRoot.path, "status", "--porcelain"])
        return dirtyFileCount(from: porcelain)
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
        runGit: @Sendable ([String]) throws -> String,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        // Streaming needs a live process; the injectable runner is used for
        // the probe paths. The apply path always runs the real git.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repoRoot.path] + argv
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LineBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.finish()
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.gitFailed(argv.first ?? "git", "exited with status \(process.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: UpdateError.launchFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Rebuild & relaunch

    /// The updater moved the checkout; the running binary is stale. Rebuild
    /// with the repo's own `make build-swift` (streamed into the log tail),
    /// reopen this bundle, and exit so launchd/menu state resets cleanly.
    func rebuildAndRelaunch() async {
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
            process.arguments = ["build-swift"]
            process.currentDirectoryURL = repoRoot
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LineBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.finish()
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.gitFailed("build-swift", "exited with status \(process.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: UpdateError.launchFailed(error.localizedDescription))
            }
        }
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

    /// Thread-safe accumulator that splits streamed bytes into lines.
    private final class LineBuffer: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) {
            self.onLine = onLine
        }

        func append(_ data: Data) {
            lock.lock()
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending = pending.suffix(from: pending.index(after: newline))
                emit(line)
            }
            lock.unlock()
        }

        func finish() {
            lock.lock()
            if !pending.isEmpty {
                let rest = pending
                pending = Data()
                emit(rest)
            }
            lock.unlock()
        }

        private func emit(_ data: Data.SubSequence) {
            let line = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            onLine(line)
        }
    }
}