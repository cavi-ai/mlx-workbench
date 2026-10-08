import CryptoKit
import Foundation
import XCTest

@testable import mlx_workbench

/// Installed-build updates from GitHub releases: feed decoding, channel
/// decisions, digest and signature verification, and the coordinator flow
/// through an injected installer (no network, disk images or bundle swaps).
final class ReleaseUpdaterTests: XCTestCase {
    private let release040 = InstalledBuild(version: "0.4.0", commit: "63a02a61d1e7", channel: "release")

    // MARK: - Feed

    func testDecodesGitHubReleaseJSON() throws {
        let entry = try JSONDecoder().decode(ReleaseEntry.self, from: Data(Self.releaseJSON.utf8))
        XCTAssertEqual(entry.tagName, "v0.5.0")
        XCTAssertFalse(entry.prerelease)
        XCTAssertEqual(entry.assets.first?.name, "mlx-workbench-0.5.0.dmg")
        XCTAssertEqual(entry.assets.first?.digest, "sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(
            entry.assets.first?.downloadURL.absoluteString,
            "https://github.com/cavi-ai/mlx-workbench/releases/download/v0.5.0/mlx-workbench-0.5.0.dmg"
        )
    }

    func testEndpointsPerChannel() {
        XCTAssertEqual(
            ReleaseFeed.endpoint(for: .official).absoluteString,
            "https://api.github.com/repos/cavi-ai/mlx-workbench/releases/latest"
        )
        XCTAssertEqual(
            ReleaseFeed.endpoint(for: .beta).absoluteString,
            "https://api.github.com/repos/cavi-ai/mlx-workbench/releases/tags/nightly"
        )
    }

    func testVersionOrdering() {
        XCTAssertTrue(ReleaseFeed.isNewer("v0.5.0", than: "0.4.0"))
        XCTAssertTrue(ReleaseFeed.isNewer("v0.4.10", than: "0.4.9"))
        XCTAssertTrue(ReleaseFeed.isNewer("v1.0", than: "0.9.9"))
        XCTAssertFalse(ReleaseFeed.isNewer("v0.4.0", than: "0.4.0"))
        XCTAssertFalse(ReleaseFeed.isNewer("v0.3.9", than: "0.4.0"))
        XCTAssertFalse(ReleaseFeed.isNewer("nightly", than: "0.4.0"))
        XCTAssertFalse(ReleaseFeed.isNewer("v0.5.0", than: ""))
    }

    func testNightlyCommitComesFromTheAssetName() {
        XCTAssertEqual(ReleaseFeed.nightlyCommit(assetName: "mlx-workbench-nightly-abc123def456.dmg"), "abc123def456")
        XCTAssertNil(ReleaseFeed.nightlyCommit(assetName: "mlx-workbench-nightly-.dmg"))
        XCTAssertNil(ReleaseFeed.nightlyCommit(assetName: "mlx-workbench-0.4.0.dmg"))
    }

    // MARK: - Decisions

    func testOfficialOffersANewerReleaseOnly() {
        XCTAssertEqual(
            ReleaseFeed.decide(channel: .official, release: release("v0.5.0", "mlx-workbench-0.5.0.dmg"), installed: release040),
            .available(ReleaseOffer(target: "v0.5.0", asset: asset("mlx-workbench-0.5.0.dmg")))
        )
        XCTAssertEqual(
            ReleaseFeed.decide(channel: .official, release: release("v0.4.0", "mlx-workbench-0.4.0.dmg"), installed: release040),
            .current
        )
    }

    func testOfficialReturnsANightlyToItsRelease() {
        let nightly = InstalledBuild(version: "0.4.0", commit: "abc123def456", channel: "nightly")
        XCTAssertEqual(
            ReleaseFeed.decide(channel: .official, release: release("v0.4.0", "mlx-workbench-0.4.0.dmg"), installed: nightly),
            .available(ReleaseOffer(target: "v0.4.0", asset: asset("mlx-workbench-0.4.0.dmg")))
        )
        let ahead = InstalledBuild(version: "0.5.0", commit: "abc123def456", channel: "nightly")
        XCTAssertEqual(
            ReleaseFeed.decide(channel: .official, release: release("v0.4.0", "mlx-workbench-0.4.0.dmg"), installed: ahead),
            .current
        )
    }

    func testOfficialWithoutTheDiskImageIsUnavailable() {
        guard case .unavailable = ReleaseFeed.decide(
            channel: .official, release: release("v0.5.0", "mlx-workbench-docs-v0.5.0.tar.gz"), installed: release040
        ) else { return XCTFail("expected unavailable") }
        guard case .unavailable = ReleaseFeed.decide(
            channel: .official, release: release("v0.5.0", "mlx-workbench-0.5.0.dmg", draft: true), installed: release040
        ) else { return XCTFail("expected unavailable for a draft") }
    }

    func testNightlyOffersADifferentCommit() {
        let nightlyRelease = release("nightly", "mlx-workbench-nightly-fedcba987654.dmg", prerelease: true)
        XCTAssertEqual(
            ReleaseFeed.decide(channel: .beta, release: nightlyRelease, installed: release040),
            .available(ReleaseOffer(target: "nightly fedcba987654", asset: asset("mlx-workbench-nightly-fedcba987654.dmg")))
        )
        let same = InstalledBuild(version: "0.4.0", commit: "fedcba987654", channel: "nightly")
        XCTAssertEqual(ReleaseFeed.decide(channel: .beta, release: nightlyRelease, installed: same), .current)
        guard case .unavailable = ReleaseFeed.decide(
            channel: .beta, release: release("nightly", "notes.txt", prerelease: true), installed: release040
        ) else { return XCTFail("expected unavailable") }
    }

    func testInstalledLabels() {
        XCTAssertEqual(release040.label, "v0.4.0")
        XCTAssertEqual(InstalledBuild(version: "0.4.0", commit: "abc", channel: "nightly").label, "nightly abc")
        XCTAssertEqual(
            InstalledBuild.from(infoDictionary: [
                "CFBundleShortVersionString": "0.4.0", "MLXWorkbenchCommit": "abc", "MLXWorkbenchChannel": "nightly",
            ]),
            InstalledBuild(version: "0.4.0", commit: "abc", channel: "nightly")
        )
    }

    // MARK: - Verification

    func testDigestMustMatchThePublishedSHA256() throws {
        let file = try makeRoot().appendingPathComponent("payload.dmg")
        try Data("mlx".utf8).write(to: file)
        let hex = SHA256.hash(data: Data("mlx".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try ReleaseFeed.verifyDigest(of: file, expected: "sha256:\(hex)"))
        XCTAssertThrowsError(try ReleaseFeed.verifyDigest(of: file, expected: "sha256:" + String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? ReleaseUpdateError, .digestMismatch("payload.dmg"))
        }
        XCTAssertThrowsError(try ReleaseFeed.verifyDigest(of: file, expected: hex))
    }

    func testRequirementPinsBundleTeamAndNotarization() {
        XCTAssertTrue(ReleaseFeed.requirement.contains("identifier \"com.cavi.mlxworkbench\""))
        XCTAssertTrue(ReleaseFeed.requirement.contains("certificate leaf[subject.OU] = \"Y76GMV87GM\""))
        XCTAssertTrue(ReleaseFeed.requirement.contains("anchor apple generic"))
        XCTAssertTrue(ReleaseFeed.requirement.hasSuffix("and notarized"))
    }

    func testSignatureCheckRejectsCodeFromAnyoneElse() {
        // Apple-signed system code is valid, but not this team's app.
        XCTAssertThrowsError(try ReleaseFeed.verifySignature(of: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertThrowsError(try ReleaseFeed.verifySignature(of: URL(fileURLWithPath: "/usr/bin/true")))
    }

    func testInstallRefusesTranslocatedAndUnwritableLocations() throws {
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/MLX Workbench.app")
        XCTAssertNotNil(ReleaseFeed.installRefusal(bundle: translocated))
        XCTAssertNotNil(ReleaseFeed.installRefusal(bundle: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        let writable = try makeRoot().appendingPathComponent("MLX Workbench.app")
        XCTAssertNil(ReleaseFeed.installRefusal(bundle: writable))
    }

    // MARK: - Live install (opt-in)

    /// Set TEST_RUNNER_MLX_WORKBENCH_RELEASE_DMG to a notarized release DMG.
    /// Installs it over a stand-in bundle in a temp folder through the real
    /// download (file URL), digest, mount, signature and swap path.
    func testLiveInstallFromANotarizedReleaseDiskImage() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_RELEASE_DMG"] else {
            throw XCTSkip("set TEST_RUNNER_MLX_WORKBENCH_RELEASE_DMG to a notarized release DMG")
        }
        let dmg = URL(fileURLWithPath: path)
        let hex = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
        let root = try makeRoot()
        let bundle = root.appendingPathComponent("MLX Workbench.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let discarded = root.appendingPathComponent("discarded", isDirectory: true)
        try FileManager.default.createDirectory(at: discarded, withIntermediateDirectories: true)
        let installer = DMGReleaseInstaller(
            workRoot: root.appendingPathComponent("work", isDirectory: true),
            discard: { try FileManager.default.moveItem(at: $0, to: discarded.appendingPathComponent($0.lastPathComponent)) }
        )
        let asset = ReleaseAsset(name: dmg.lastPathComponent, downloadURL: dmg, size: 0, digest: "sha256:\(hex)")

        let tampered = ReleaseAsset(name: dmg.lastPathComponent, downloadURL: dmg, size: 0, digest: "sha256:" + String(repeating: "0", count: 64))
        do {
            _ = try await installer.install(ReleaseOffer(target: "tampered", asset: tampered), replacing: bundle, log: { _ in })
            XCTFail("a digest mismatch must refuse the install")
        } catch {
            XCTAssertEqual(error as? ReleaseUpdateError, .digestMismatch(dmg.lastPathComponent))
        }
        // Bundle(url:) caches per path, so read the plist file itself.
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))

        let build = try await installer.install(ReleaseOffer(target: "release", asset: asset), replacing: bundle, log: { _ in })
        XCTAssertFalse(build.version.isEmpty)
        XCTAssertNoThrow(try ReleaseFeed.verifySignature(of: bundle))
        let installedInfo = NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]
        XCTAssertEqual(InstalledBuild.from(infoDictionary: installedInfo).version, build.version)
        XCTAssertTrue(FileManager.default.fileExists(atPath: discarded.appendingPathComponent("MLX Workbench (previous).app").path))
    }

    // MARK: - Coordinator

    @MainActor
    func testCoordinatorOffersInstallsAndRelaunchesARelease() async throws {
        let bundle = try makeRoot().appendingPathComponent("MLX Workbench.app")
        let installer = FakeInstaller(release: release("v0.5.0", "mlx-workbench-0.5.0.dmg"))
        let coordinator = UpdateCoordinator(
            repoRoot: nil,
            installed: .init(bundle: bundle, build: release040, installer: installer),
            defaults: try makeDefaults(), runGit: { _ in "" }
        )
        XCTAssertTrue(coordinator.installsReleases)
        XCTAssertTrue(coordinator.canUpdate)

        await coordinator.check()
        guard case .available(let offer) = coordinator.phase else {
            return XCTFail("expected available, got \(coordinator.phase)")
        }
        XCTAssertEqual(offer, .init(target: "v0.5.0", current: "v0.4.0", dirtyFiles: 0))
        XCTAssertEqual(installer.fetched, [ReleaseFeed.endpoint(for: .official)])

        await coordinator.apply(offer: offer)
        XCTAssertEqual(coordinator.phase, .updated(target: "v0.5.0"))
        XCTAssertEqual(installer.installed, ["mlx-workbench-0.5.0.dmg"])
        XCTAssertTrue(coordinator.summary.contains("Relaunch"))

        await coordinator.rebuildAndRelaunch()
        XCTAssertEqual(installer.relaunched, [bundle])
    }

    @MainActor
    func testCoordinatorReportsCurrentAndInstallFailures() async throws {
        let bundle = try makeRoot().appendingPathComponent("MLX Workbench.app")
        let current = FakeInstaller(release: release("v0.4.0", "mlx-workbench-0.4.0.dmg"))
        let coordinator = UpdateCoordinator(
            repoRoot: nil, installed: .init(bundle: bundle, build: release040, installer: current),
            defaults: try makeDefaults(), runGit: { _ in "" }
        )
        await coordinator.check()
        XCTAssertEqual(coordinator.phase, .upToDate(current: "v0.4.0"))

        let failing = FakeInstaller(release: release("v0.5.0", "mlx-workbench-0.5.0.dmg"), failure: .digestMismatch("x.dmg"))
        let rejecting = UpdateCoordinator(
            repoRoot: nil, installed: .init(bundle: bundle, build: release040, installer: failing),
            defaults: try makeDefaults(), runGit: { _ in "" }
        )
        await rejecting.check()
        guard case .available(let offer) = rejecting.phase else { return XCTFail("expected available") }
        await rejecting.apply(offer: offer)
        guard case .failed(let reason) = rejecting.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(reason.contains("sha256"), reason)
        XCTAssertTrue(failing.relaunched.isEmpty)
    }

    @MainActor
    func testNightlyChannelChecksTheNightlyRelease() async throws {
        let bundle = try makeRoot().appendingPathComponent("MLX Workbench.app")
        let installer = FakeInstaller(release: release("nightly", "mlx-workbench-nightly-fedcba987654.dmg", prerelease: true))
        let defaults = try makeDefaults()
        defaults.set(UpdateCoordinator.Channel.beta.rawValue, forKey: UpdateCoordinator.channelKey)
        let coordinator = UpdateCoordinator(
            repoRoot: nil, installed: .init(bundle: bundle, build: release040, installer: installer),
            defaults: defaults, runGit: { _ in "" }
        )
        await coordinator.check()
        XCTAssertEqual(installer.fetched, [ReleaseFeed.endpoint(for: .beta)])
        guard case .available(let offer) = coordinator.phase else { return XCTFail("expected available") }
        XCTAssertEqual(offer.target, "nightly fedcba987654")
    }

    @MainActor
    func testACheckoutIgnoresTheInstalledBundle() throws {
        let root = try makeRoot()
        let installer = FakeInstaller(release: release("v0.5.0", "mlx-workbench-0.5.0.dmg"))
        let coordinator = UpdateCoordinator(
            repoRoot: root, installed: .init(bundle: root, build: release040, installer: installer),
            defaults: try makeDefaults(), runGit: { _ in "" }
        )
        XCTAssertFalse(coordinator.installsReleases)
        XCTAssertNil(coordinator.installed)
    }

    // MARK: - Helpers

    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(
            name: name,
            downloadURL: URL(string: "https://github.com/cavi-ai/mlx-workbench/releases/download/x/\(name)")!,
            size: 1, digest: "sha256:" + String(repeating: "a", count: 64)
        )
    }

    private func release(_ tag: String, _ assetName: String, prerelease: Bool = false, draft: Bool = false) -> ReleaseEntry {
        ReleaseEntry(tagName: tag, draft: draft, prerelease: prerelease, assets: [asset(assetName)])
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "mlx-workbench-release-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private static let releaseJSON = """
        {
          "tag_name": "v0.5.0", "draft": false, "prerelease": false,
          "assets": [{
            "name": "mlx-workbench-0.5.0.dmg", "size": 2727273,
            "digest": "sha256:\(String(repeating: "a", count: 64))",
            "browser_download_url": "https://github.com/cavi-ai/mlx-workbench/releases/download/v0.5.0/mlx-workbench-0.5.0.dmg"
          }]
        }
        """
}

private final class FakeInstaller: ReleaseInstalling, @unchecked Sendable {
    private let release: ReleaseEntry
    private let failure: ReleaseUpdateError?
    private let lock = NSLock()
    private var _fetched: [URL] = []
    private var _installed: [String] = []
    private var _relaunched: [URL] = []

    init(release: ReleaseEntry, failure: ReleaseUpdateError? = nil) {
        self.release = release
        self.failure = failure
    }

    var fetched: [URL] { lock.withLock { _fetched } }
    var installed: [String] { lock.withLock { _installed } }
    var relaunched: [URL] { lock.withLock { _relaunched } }

    func fetchRelease(_ url: URL) async throws -> ReleaseEntry {
        lock.withLock { _fetched.append(url) }
        return release
    }

    func install(
        _ offer: ReleaseOffer, replacing bundle: URL, log: @escaping @Sendable (String) -> Void
    ) async throws -> InstalledBuild {
        if let failure { throw failure }
        lock.withLock { _installed.append(offer.asset.name) }
        log("installed \(offer.target)")
        let version = offer.target.hasPrefix("v") ? String(offer.target.dropFirst()) : "0.4.0"
        return InstalledBuild(version: version, commit: "", channel: "release")
    }

    func relaunch(_ bundle: URL) {
        lock.withLock { _relaunched.append(bundle) }
    }
}
