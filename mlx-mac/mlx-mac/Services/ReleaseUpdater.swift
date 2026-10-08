import AppKit
import CryptoKit
import Foundation
import Security

// MARK: - Release updates for installed builds
//
// An app installed from the DMG has no checkout, so UpdateCoordinator updates
// it from GitHub releases: the official channel is the latest published
// release, the nightly channel is the rolling `nightly` prerelease built from
// main. A candidate is installed only after the download matches GitHub's
// sha256 digest and the app inside the disk image satisfies the Developer ID
// requirement (bundle identifier, team, notarization). The replaced bundle
// goes to the Trash.

struct ReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let size: Int
    /// `sha256:<hex>` as GitHub reports it.
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case downloadURL = "browser_download_url"
    }
}

struct ReleaseEntry: Decodable, Equatable, Sendable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
    }
}

/// What a bundle's Info.plist says it is.
struct InstalledBuild: Equatable, Sendable {
    let version: String
    /// Commit the distribution build was made from; empty for local builds.
    let commit: String
    /// `release`, `nightly`, or empty for local builds.
    let channel: String

    static func from(infoDictionary: [String: Any]) -> InstalledBuild {
        InstalledBuild(
            version: infoDictionary["CFBundleShortVersionString"] as? String ?? "",
            commit: infoDictionary["MLXWorkbenchCommit"] as? String ?? "",
            channel: infoDictionary["MLXWorkbenchChannel"] as? String ?? ""
        )
    }

    var label: String {
        channel == ReleaseFeed.nightlyTag && !commit.isEmpty ? "nightly \(commit)" : "v\(version)"
    }
}

struct ReleaseOffer: Equatable, Sendable {
    /// `v0.5.0` or `nightly <commit>`.
    let target: String
    let asset: ReleaseAsset
}

enum ReleaseDecision: Equatable {
    case current
    case available(ReleaseOffer)
    case unavailable(String)
}

enum ReleaseUpdateError: LocalizedError, Equatable {
    case noRelease
    case http(Int)
    case missingDigest(String)
    case digestMismatch(String)
    case signatureRejected(String, Int32)
    case commandFailed(String, Int32)
    case missingApp(String)

    var errorDescription: String? {
        switch self {
        case .noRelease:
            return "No release is published for this channel yet."
        case .http(let status):
            return "GitHub answered HTTP \(status)."
        case .missingDigest(let name):
            return "\(name) has no sha256 digest on GitHub, so it cannot be verified."
        case .digestMismatch(let name):
            return "\(name) does not match its published sha256 digest."
        case .signatureRejected(let path, let status):
            return "\(path) is not a notarized Developer ID build of MLX Workbench (code signing status \(status))."
        case .commandFailed(let tool, let status):
            return "\(tool) exited with status \(status)."
        case .missingApp(let name):
            return "The disk image has no \(name)."
        }
    }
}

enum ReleaseFeed {
    static let repository = "cavi-ai/mlx-workbench"
    static let nightlyTag = "nightly"
    static let teamIdentifier = "Y76GMV87GM"
    static let bundleIdentifier = "com.cavi.mlxworkbench"
    static let appName = "MLX Workbench.app"

    /// Only a notarized Developer ID build of this app, signed by this team.
    static let requirement = """
        identifier "\(bundleIdentifier)" and anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)" and notarized
        """

    static func endpoint(for channel: UpdateCoordinator.Channel) -> URL {
        let base = "https://api.github.com/repos/\(repository)/releases"
        switch channel {
        case .official: return URL(string: "\(base)/latest")!
        case .beta: return URL(string: "\(base)/tags/\(nightlyTag)")!
        }
    }

    /// Numeric components of `v1.2.3` or `1.2.3`; nil when not a version.
    static func versionComponents(_ text: String) -> [Int]? {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let lhs = versionComponents(candidate), let rhs = versionComponents(current) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// `mlx-workbench-nightly-<commit>.dmg` → `<commit>`.
    static func nightlyCommit(assetName: String) -> String? {
        let prefix = "mlx-workbench-nightly-"
        let suffix = ".dmg"
        guard assetName.hasPrefix(prefix), assetName.hasSuffix(suffix) else { return nil }
        let commit = String(assetName.dropFirst(prefix.count).dropLast(suffix.count))
        return commit.isEmpty ? nil : commit
    }

    static func decide(
        channel: UpdateCoordinator.Channel,
        release: ReleaseEntry,
        installed: InstalledBuild
    ) -> ReleaseDecision {
        if release.draft { return .unavailable("The release is still a draft.") }
        switch channel {
        case .official:
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard !release.prerelease,
                  let asset = release.assets.first(where: { $0.name == "mlx-workbench-\(version).dmg" })
            else { return .unavailable("\(release.tagName) has no MLX Workbench disk image.") }
            let newer = isNewer(release.tagName, than: installed.version)
            // A nightly returns to the release it was built after.
            let leavingNightly = installed.channel == nightlyTag && !isNewer(installed.version, than: release.tagName)
            return newer || leavingNightly ? .available(ReleaseOffer(target: release.tagName, asset: asset)) : .current
        case .beta:
            guard release.tagName == nightlyTag,
                  let asset = release.assets.first(where: { nightlyCommit(assetName: $0.name) != nil }),
                  let commit = nightlyCommit(assetName: asset.name)
            else { return .unavailable("The nightly release has no MLX Workbench disk image.") }
            if installed.channel == nightlyTag && commit == installed.commit { return .current }
            return .available(ReleaseOffer(target: "nightly \(commit)", asset: asset))
        }
    }

    /// Why this bundle cannot replace itself, or nil when it can.
    static func installRefusal(bundle: URL, fileManager: FileManager = .default) -> String? {
        if bundle.path.contains("/AppTranslocation/") {
            return "macOS is running MLX Workbench from a temporary location. Move it to Applications and reopen it to update."
        }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return "MLX Workbench is running from its disk image. Drag it to Applications and open it from there to update."
        }
        let parent = bundle.deletingLastPathComponent()
        if !fileManager.isWritableFile(atPath: parent.path) {
            return "This account cannot write to \(parent.path), so MLX Workbench cannot replace itself."
        }
        return nil
    }

    static func verifyDigest(of file: URL, expected: String) throws {
        let prefix = "sha256:"
        guard expected.hasPrefix(prefix) else { throw ReleaseUpdateError.missingDigest(file.lastPathComponent) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.dropFirst(prefix.count).lowercased() else {
            throw ReleaseUpdateError.digestMismatch(file.lastPathComponent)
        }
    }

    static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw ReleaseUpdateError.signatureRejected(app.lastPathComponent, status)
        }
        var compiled: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw ReleaseUpdateError.signatureRejected(app.lastPathComponent, status)
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        status = SecStaticCodeCheckValidity(code, flags, compiled)
        guard status == errSecSuccess else {
            throw ReleaseUpdateError.signatureRejected(app.lastPathComponent, status)
        }
    }
}

// MARK: - Installing

/// Network, disk-image and bundle work behind one seam so coordinator tests
/// never touch GitHub, hdiutil or the running app.
protocol ReleaseInstalling: Sendable {
    func fetchRelease(_ url: URL) async throws -> ReleaseEntry
    func install(
        _ offer: ReleaseOffer,
        replacing bundle: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> InstalledBuild
    func relaunch(_ bundle: URL)
}

struct DMGReleaseInstaller: ReleaseInstalling {
    let session: URLSession
    /// Scratch space for downloads and mount points.
    let workRoot: URL
    /// Where the replaced bundle goes (the Trash in the app).
    let discard: @Sendable (URL) throws -> Void

    static let moveToTrash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    init(
        session: URLSession = .shared,
        workRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-updates", isDirectory: true),
        discard: @escaping @Sendable (URL) throws -> Void = DMGReleaseInstaller.moveToTrash
    ) {
        self.session = session
        self.workRoot = workRoot
        self.discard = discard
    }

    func fetchRelease(_ url: URL) async throws -> ReleaseEntry {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw ReleaseUpdateError.noRelease }
        guard (200..<300).contains(status) else { throw ReleaseUpdateError.http(status) }
        return try JSONDecoder().decode(ReleaseEntry.self, from: data)
    }

    func install(
        _ offer: ReleaseOffer,
        replacing bundle: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> InstalledBuild {
        guard let digest = offer.asset.digest else {
            throw ReleaseUpdateError.missingDigest(offer.asset.name)
        }
        let fileManager = FileManager.default
        let work = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        log("Downloading \(offer.asset.name)")
        let (download, _) = try await session.download(from: offer.asset.downloadURL)
        let dmg = work.appendingPathComponent(offer.asset.name)
        try fileManager.moveItem(at: download, to: dmg)
        try await Self.offload { try ReleaseFeed.verifyDigest(of: dmg, expected: digest) }
        log("sha256 matches \(digest)")

        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try await Self.offload {
            try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        }
        do {
            let discard = self.discard
            let build = try await Self.offload { try Self.installMounted(mount, replacing: bundle, discard: discard) }
            _ = try? await Self.offload { try Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            log("Developer ID \(ReleaseFeed.teamIdentifier), notarized: installed \(build.label) at \(bundle.path)")
            return build
        } catch {
            _ = try? await Self.offload { try Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            throw error
        }
    }

    /// Verifies the mounted app, stages a copy beside `bundle`, swaps it in,
    /// and hands the replaced bundle to `discard`.
    static func installMounted(
        _ mount: URL, replacing bundle: URL, discard: (URL) throws -> Void
    ) throws -> InstalledBuild {
        let fileManager = FileManager.default
        let candidate = mount.appendingPathComponent(ReleaseFeed.appName)
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw ReleaseUpdateError.missingApp(ReleaseFeed.appName)
        }
        try ReleaseFeed.verifySignature(of: candidate)
        let build = InstalledBuild.from(infoDictionary: Bundle(url: candidate)?.infoDictionary ?? [:])

        let parent = bundle.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".\(bundle.lastPathComponent).update", isDirectory: true)
        try? fileManager.removeItem(at: staged)
        try run("/usr/bin/ditto", [candidate.path, staged.path])
        let backupName = bundle.deletingPathExtension().lastPathComponent + " (previous).app"
        _ = try fileManager.replaceItemAt(
            bundle, withItemAt: staged, backupItemName: backupName, options: [.withoutDeletingBackupItem]
        )
        let backup = parent.appendingPathComponent(backupName, isDirectory: true)
        if fileManager.fileExists(atPath: backup.path) {
            try? discard(backup)
        }
        return build
    }

    /// Blocking work runs on a dispatch worker, never a Swift cooperative thread.
    static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Reopens the bundle once this process has exited; gives up after 60 s.
    func relaunch(_ bundle: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Fixed script; the pid and bundle path arrive as $0 and $1.
        waiter.arguments = [
            "-c",
            "i=0; while /bin/kill -0 \"$0\" 2>/dev/null && [ $i -lt 300 ]; do /bin/sleep 0.2; i=$((i+1)); done; "
                + "/bin/kill -0 \"$0\" 2>/dev/null || exec /usr/bin/open \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier),
            bundle.path,
        ]
        do {
            try waiter.run()
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.open(bundle)
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReleaseUpdateError.commandFailed(URL(fileURLWithPath: tool).lastPathComponent, process.terminationStatus)
        }
        return process.terminationStatus
    }
}
