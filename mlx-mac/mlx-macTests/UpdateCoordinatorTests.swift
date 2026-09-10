import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class UpdateCoordinatorTests: XCTestCase {
    // MARK: - Pure planners

    func testLatestTagPicksTheHighestVersionTag() {
        // The input mirrors git tag --sort=-v:refname output (version-sorted);
        // the planner simply takes the first v* line.
        XCTAssertEqual(
            UpdateCoordinator.latestTag(from: "v0.10.0\nv0.2.0\nv0.1.0\n"), "v0.10.0"
        )
        XCTAssertNil(UpdateCoordinator.latestTag(from: ""))
        XCTAssertNil(UpdateCoordinator.latestTag(from: "main\nfeature/x\n"))
    }

    func testDirtyFileCountsPorcelainLines() {
        XCTAssertEqual(UpdateCoordinator.dirtyFileCount(from: "?? new\n M changed\n"), 2)
        XCTAssertEqual(UpdateCoordinator.dirtyFileCount(from: ""), 0)
    }

    func testApplyPlansUseArgvTokensAndSyncSubmodules() {
        let official = UpdateCoordinator.applyPlan(channel: .official, target: "v0.3.0")
        XCTAssertEqual(official, [
            ["checkout", "v0.3.0"],
            ["submodule", "update", "--init", "--recursive"],
        ])
        let beta = UpdateCoordinator.applyPlan(channel: .beta, target: "abc1234")
        XCTAssertEqual(beta, [
            ["checkout", "main"],
            ["pull", "--ff-only", "origin", "main"],
            ["submodule", "update", "--init", "--recursive"],
        ])
    }

    // MARK: - Channel persistence

    func testChannelPersistsAcrossInstances() {
        let suite = "mlx-workbench-update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = UpdateCoordinator(repoRoot: nil, defaults: defaults, runGit: { _ in "" })
        first.channel = .beta

        let second = UpdateCoordinator(repoRoot: nil, defaults: defaults, runGit: { _ in "" })
        XCTAssertEqual(second.channel, .beta)
    }

    // MARK: - Check phases (injected runner, no real git)

    func testCheckReportsUpToDateWhenTargetEqualsCurrent() async {
        let (coordinator, _) = makeCoordinator(git: { argv in
            if argv.contains("status") { return "" }
            if argv.contains("--exact-match") { throw TestGitError.exited(128) }
            if argv.suffix(2) == ["--short", "HEAD"] { return "abc1234" }
            if argv.last == "origin/main" { return "abc1234" }
            if argv.contains("tag") { return "v0.2.0\nv0.1.0\n" }
            return ""
        })

        coordinator.channel = .beta
        await coordinator.check()

        XCTAssertEqual(coordinator.phase, .upToDate(current: "abc1234"))
    }

    func testCheckOffersUpdateWhenTargetDiffers() async {
        let (coordinator, _) = makeCoordinator(git: { argv in
            if argv.contains("status") { return "?? stray\n" }
            if argv.contains("--exact-match") { throw TestGitError.exited(128) }
            if argv.suffix(2) == ["--short", "HEAD"] { return "abc1234" }
            if argv.last == "origin/main" { return "def5678" }
            if argv.contains("tag") { return "v0.2.0\nv0.1.0\n" }
            return ""
        })

        coordinator.channel = .beta
        await coordinator.check()

        XCTAssertEqual(
            coordinator.phase,
            .available(UpdateCoordinator.Offer(target: "def5678", current: "abc1234", dirtyFiles: 1))
        )
    }

    func testCheckWithoutRepoRootFailsWithGuidance() async {
        let coordinator = UpdateCoordinator(repoRoot: nil, defaults: .standard, runGit: { _ in "" })
        await coordinator.check()
        guard case .failed(let reason) = coordinator.phase else {
            return XCTFail("expected failed, got \(coordinator.phase)")
        }
        XCTAssertTrue(reason.contains("checkout"), reason)
    }

    // MARK: - Apply against a real throwaway repository

    /// seed repo (two tagged commits) -> bare origin -> clone pinned back to
    /// v0.1.0. check() then offers v0.2.0 through the official channel, and
    /// apply() must move the checkout to the tag, submodules included.
    func testApplyChecksOutTheTargetTagEndToEnd() throws {
        let root = try makeThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree")

        let coordinator = UpdateCoordinator(repoRoot: worktree, defaults: .standard, runGit: { try UpdateCoordinator.git($0) })
        await_on_main { await coordinator.check() }

        guard case .available(let offer) = coordinator.phase else {
            return XCTFail("expected available, got \(coordinator.phase)")
        }
        XCTAssertEqual(offer.target, "v0.2.0")
        XCTAssertEqual(offer.current, "v0.1.0")
        XCTAssertEqual(offer.dirtyFiles, 0)

        let applied = XCTestExpectation(description: "apply")
        Task { @MainActor in
            await coordinator.apply(offer: offer)
            applied.fulfill()
        }
        wait(for: [applied], timeout: 120)

        guard case .updated(let target) = coordinator.phase else {
            return XCTFail("expected updated, got \(coordinator.phase)")
        }
        XCTAssertEqual(target, "v0.2.0")
        let head = try UpdateCoordinator.git(["-C", worktree.path, "describe", "--tags", "--exact-match"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, "v0.2.0")
        XCTAssertFalse(coordinator.logTail.isEmpty)
    }

    func testApplyRefusesADirtyTreeWithoutTouchingTheCheckout() throws {
        let root = try makeThrowawayRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree")
        try Data("local edit".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))

        let coordinator = UpdateCoordinator(repoRoot: worktree, defaults: .standard, runGit: { try UpdateCoordinator.git($0) })
        await_on_main { await coordinator.check() }

        guard case .available(let offer) = coordinator.phase, offer.dirtyFiles == 1 else {
            return XCTFail("expected offer with one dirty file, got \(coordinator.phase)")
        }

        let applied = XCTestExpectation(description: "apply-dirty")
        Task { @MainActor in
            await coordinator.apply(offer: offer)
            applied.fulfill()
        }
        wait(for: [applied], timeout: 60)

        guard case .failed(let reason) = coordinator.phase else {
            return XCTFail("expected dirty refusal, got \(coordinator.phase)")
        }
        XCTAssertTrue(reason.contains("uncommitted"), reason)
        let head = try UpdateCoordinator.git(["-C", worktree.path, "describe", "--tags", "--exact-match"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(head, "v0.1.0", "a refused update must not move the checkout")
    }

    // MARK: - Helpers

    private enum TestGitError: Error { case exited(Int) }

    /// Run an async @MainActor body synchronously from this sync test.
    private nonisolated func await_on_main(_ body: @escaping @MainActor () async -> Void) {
        let done = XCTestExpectation(description: "main-actor body")
        Task { @MainActor in
            await body()
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
    }

    private func makeCoordinator(
        git: @escaping @Sendable ([String]) throws -> String
    ) -> (UpdateCoordinator, UserDefaults) {
        let suite = "mlx-workbench-update-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-update-\(UUID().uuidString)", isDirectory: true)
        let coordinator = UpdateCoordinator(repoRoot: root, defaults: defaults, runGit: git)
        return (coordinator, defaults)
    }

    /// Seed repo (two tagged commits) -> bare origin -> a worktree clone
    /// pinned back at v0.1.0, so check()/apply() exercise the official
    /// channel end to end: fetch, resolve newest tag, checkout, submodule
    /// sync. Returns the parent directory containing origin.git/ and
    /// worktree/.
    private func makeThrowawayRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-update-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)

        _ = try UpdateCoordinator.git(["-C", seed.path, "init", "-q", "-b", "main"])
        _ = try UpdateCoordinator.git(["-C", seed.path, "config", "user.email", "test@example.com"])
        _ = try UpdateCoordinator.git(["-C", seed.path, "config", "user.name", "Test"])
        try Data("one".utf8).write(to: seed.appendingPathComponent("tracked.txt"))
        _ = try UpdateCoordinator.git(["-C", seed.path, "add", "."])
        _ = try UpdateCoordinator.git(["-C", seed.path, "commit", "-q", "-m", "one"])
        _ = try UpdateCoordinator.git(["-C", seed.path, "tag", "v0.1.0"])
        try Data("two".utf8).write(to: seed.appendingPathComponent("tracked.txt"))
        _ = try UpdateCoordinator.git(["-C", seed.path, "add", "."])
        _ = try UpdateCoordinator.git(["-C", seed.path, "commit", "-q", "-m", "two"])
        _ = try UpdateCoordinator.git(["-C", seed.path, "tag", "v0.2.0"])

        _ = try UpdateCoordinator.git(["clone", "-q", "--bare", seed.path, root.appendingPathComponent("origin.git").path])
        _ = try UpdateCoordinator.git(["clone", "-q", root.appendingPathComponent("origin.git").path, root.appendingPathComponent("worktree").path])
        _ = try UpdateCoordinator.git(["-C", root.appendingPathComponent("worktree").path, "checkout", "-q", "v0.1.0"])
        return root
    }
}
