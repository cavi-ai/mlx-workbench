import AppKit
import SwiftUI

// MARK: - Resolve key and loader

/// What the folder resolution depends on; a change, or a finished scan, resolves again.
struct LMStudioResolveKey: Equatable {
    let scannedAt: Date?
    let isRouteActive: Bool
    let scannedRoots: ScanRoots?
    let ggufRoots: [String]
    let mlxRoots: [String]
    let outputDir: String
    let scansFinished: Int

    /// The finished-scan count after `isScanning` changes from `wasScanning`.
    static func scansFinished(_ count: Int, wasScanning: Bool, isScanning: Bool) -> Int {
        wasScanning && !isScanning ? count + 1 : count
    }
}

/// Holds the latest folder resolution. A resolve that is cancelled, or that an inactive route asked for, publishes nothing.
@MainActor
final class LMStudioResolutionLoader: ObservableObject {
    @Published private(set) var resolution: LMStudioShelfResolver.Resolution?

    func load(isActive: Bool, resolver: () async -> LMStudioShelfResolver.Resolution) async {
        guard isActive else { return }
        let result = await resolver()
        guard !Task.isCancelled else { return }
        resolution = result
    }
}

// MARK: - LMStudioView
// What LM Studio holds, by fit on this Mac: MLX models that run here and GGUF files that need converting.

struct LMStudioView: View {
    @ObservedObject var appHost: AppHost
    private let resources: SystemResourceMonitor
    private let home: URL
    private let fixedResolution: LMStudioShelfResolver.Resolution?
    private let onRouteSelection: (AppRoute) -> Void

    @StateObject private var loader = LMStudioResolutionLoader()
    @State private var scansFinished = 0
    @State private var index: LMStudioShelfIndex?
    @State private var layout = LMStudioLayout()
    @Environment(\.isRouteActive) private var isRouteActive

    /// `resources` and `resolution` let a render hold the page at a fixed budget and folder set.
    init(
        appHost: AppHost,
        resources: SystemResourceMonitor? = nil,
        home: URL = WorkbenchStatePaths.userHome(),
        resolution: LMStudioShelfResolver.Resolution? = nil,
        onRouteSelection: @escaping (AppRoute) -> Void = { _ in }
    ) {
        self.appHost = appHost
        self.resources = resources ?? appHost.resources
        self.home = home
        self.fixedResolution = resolution
        self.onRouteSelection = onRouteSelection
    }

    private var resolveKey: LMStudioResolveKey {
        LMStudioResolveKey(
            scannedAt: appHost.librarySnapshot?.generatedAt, isRouteActive: isRouteActive, scannedRoots: appHost.scannedRoots,
            ggufRoots: appHost.config.ggufRoots, mlxRoots: appHost.config.mlxRoots, outputDir: appHost.config.outputDir,
            scansFinished: scansFinished
        )
    }

    private var resolution: LMStudioShelfResolver.Resolution? { fixedResolution ?? loader.resolution }

    private struct IndexKey: Equatable {
        let generatedAt: Date?
        let resolution: LMStudioShelfResolver.Resolution?
    }

    private var indexKey: IndexKey { IndexKey(generatedAt: appHost.librarySnapshot?.generatedAt, resolution: resolution) }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    header
                    ErrorBanner(text: LMStudioShelfPresentation.bannerText(snapshot: appHost.librarySnapshot, lastError: appHost.lastError))
                    LMStudioShelf(
                        resources: resources, resolution: resolution, snapshot: appHost.librarySnapshot, index: index,
                        isScanning: appHost.isScanning, lastError: appHost.lastError,
                        reserveGB: appHost.config.fitReserveGB, hardware: appHost.hardwareProfile,
                        layout: layout, home: home, actions: actions
                    )
                }
                .frame(maxWidth: WorkbenchSize.LMStudio.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: viewport.size.width, initial: true) { _, width in
                layout = LMStudioLayout(viewportWidth: width, previous: layout)
            }
        }
        .onChange(of: appHost.isScanning) { was, now in
            scansFinished = LMStudioResolveKey.scansFinished(scansFinished, wasScanning: was, isScanning: now)
        }
        .onChange(of: indexKey, initial: true) { _, key in
            if let snapshot = appHost.librarySnapshot, let resolution = key.resolution {
                index = LMStudioShelfIndex.make(snapshot: snapshot, resolution: resolution)
            } else {
                index = nil
            }
        }
        .task(id: resolveKey) { await resolve() }
    }

    // MARK: Header

    private var header: some View {
        let lines = (resolution?.folders ?? []).map { LMStudioFolderLine.make($0, home: home) }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if layout.headerWraps {
                if let first = lines.first { folderLine(first) }
                scanButton
            } else {
                HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
                    if let first = lines.first { folderLine(first) }
                    Spacer(minLength: WorkbenchSpacing.xs)
                    scanButton
                }
            }
            ForEach(Array(lines.dropFirst())) { line in
                folderLine(line)
            }
        }
    }

    private var scanButton: some View {
        Button(appHost.isScanning ? "Scanning…" : "Scan Again") { scan() }
            .buttonStyle(.bordered)
            .disabled(appHost.isScanning)
    }

    private func folderLine(_ line: LMStudioFolderLine) -> some View {
        ReclaimFlowLayout(spacing: WorkbenchSpacing.xs, lineSpacing: WorkbenchSpacing.xxs) {
            Label {
                Text(line.displayPath)
                    .font(WorkbenchTypography.compactValue)
                    .foregroundStyle(WorkbenchColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "folder").symbolRenderingMode(.hierarchical).accessibilityHidden(true)
            }
            Text(line.sourceCaption)
            Text(line.coverageWord)
        }
        .font(WorkbenchTypography.metadata)
        .foregroundStyle(WorkbenchColor.muted)
        .contextMenu {
            Button("Reveal in Finder") { reveal(line.path) }
            Button("Copy Path") { copy(line.path) }
        }
    }

    // MARK: Resolve

    private func resolve() async {
        guard fixedResolution == nil else { return }
        let config = appHost.config
        let scannedRoots = appHost.scannedRoots
        let home = home
        await loader.load(isActive: isRouteActive) {
            await Task.detached(priority: .utility) {
                let gguf = config.ggufRoots.isEmpty ? Config.discoverGgufRoots(home: home) : config.ggufRoots
                return LMStudioShelfResolver.resolve(
                    home: home, scannedRoots: scannedRoots, configGGUFRoots: gguf,
                    configMLXRoots: AppHost.scanMLXRoots(config, ggufRoots: gguf)
                )
            }.value
        }
    }

    // MARK: Actions

    private var actions: LMStudioShelfActions {
        LMStudioShelfActions(
            openSettings: { onRouteSelection(.settings) },
            prepare: prepare,
            run: run,
            showInLibrary: showInLibrary,
            reveal: reveal,
            copyPath: copy
        )
    }

    private func scan() {
        guard !appHost.isScanning else { return }
        Task { await appHost.rescan() }
    }

    private func prepare(_ path: String) {
        guard let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path }) else { return }
        appHost.selectedModelPath = model.item.path
        appHost.modelWorkflow.inspect(source: model.item, snapshot: appHost.librarySnapshot)
        onRouteSelection(.prepare)
    }

    private func run(_ path: String) {
        guard let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) else { return }
        appHost.selectedModelPath = path
        appHost.modelWorkflow.prepareServe(model: model, exactPath: path)
        onRouteSelection(.run)
    }

    private func showInLibrary(_ path: String) {
        guard appHost.librarySnapshot?.models.contains(where: { $0.item.path == path }) == true else { return }
        appHost.selectedModelPath = path
        onRouteSelection(.library)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path, directoryHint: .inferFromPath)])
    }

    private func copy(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}
