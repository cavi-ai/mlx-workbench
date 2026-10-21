import AppKit
import SwiftUI
import XCTest
@testable import mlx_workbench

@MainActor
final class HostedModelsRenderTests: XCTestCase {
    func testLibrarySourceMenuSelectsExactHostsAndRetainsSetupAfterRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = HostSummaryReads()
        let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent("hosts.json")),
            readToken: { _ in nil }, writeToken: { _, _ in }, fetch: { host, _ in
                try await reads.fetch(host, instances: ["context-4096", "context-8192"])
            })
        let connections = [
            ModelHost(name: "Shared", provider: .ollama, baseURL: "http://127.0.0.1:11434"),
            ModelHost(name: "Shared", provider: .lmStudio, baseURL: "http://127.0.0.1:1234"),
            ModelHost(name: "Images", provider: .comfyUI, baseURL: "http://127.0.0.1:8188")
        ]
        for connection in connections.prefix(2) { try hosts.save(connection, token: nil, replaceToken: false) }
        let app = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", configPath: root.appendingPathComponent("config.json").path,
            agentHealth: .notConfigured, runtimeReport: report(), modelHosts: hosts)
        let originalConfig = app.config
        let hosting = NSHostingView(rootView: LibraryWorkspace(appHost: app, sourceHome: root).frame(width: 950, height: 820)
            .background(WorkbenchColor.canvas).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func controls() -> [NSPopUpButton] {
            return descendants(hosting).compactMap { $0 as? NSPopUpButton }
        }
        func sourcePicker() throws -> NSPopUpButton {
            try XCTUnwrap(controls().first { $0.itemTitles.contains("All local models") && $0.itemTitles.contains("Hosted models") })
        }
        func select(_ title: String) async throws {
            let picker = try sourcePicker()
            let menu = try XCTUnwrap(picker.menu)
            let item = try XCTUnwrap(picker.item(withTitle: title))
            menu.performActionForItem(at: menu.index(of: item))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try sourcePicker().selectedItem?.title, title)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(try sourcePicker().itemTitles.contains("Images · ComfyUI"))
        try hosts.save(connections[2], token: nil, replaceToken: false)
        try await Task.sleep(for: .milliseconds(100))
        for connection in connections {
            let title = LibrarySource.host(connection.id).title(in: connections)
            XCTAssertTrue(try sourcePicker().itemTitles.contains(title))
            try await select(title)
            XCTAssertTrue(controls().contains { $0.itemTitles.contains("Select a host") && $0.selectedItem?.title == title },
                "The displayed host and top source must share the exact selection")
        }
        let hostPicker = try XCTUnwrap(controls().first { $0.itemTitles.contains("Select a host") })
        let hostMenu = try XCTUnwrap(hostPicker.menu)
        let hostItem = try XCTUnwrap(hostPicker.item(withTitle: "Shared · Ollama"))
        hostMenu.performActionForItem(at: hostMenu.index(of: hostItem))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try sourcePicker().selectedItem?.title, "Shared · Ollama")
        var requested = await reads.requested
        XCTAssertEqual(requested, [])
        await hosts.refresh(connections[1].id)
        try await select("Shared · LM Studio")
        let table = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 2 })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        let instances = try XCTUnwrap(controls().first { $0.itemTitles.contains("Choose instance") })
        let instanceMenu = try XCTUnwrap(instances.menu)
        let instanceItem = try XCTUnwrap(instances.item(withTitle: "context-8192"))
        instanceMenu.performActionForItem(at: instanceMenu.index(of: instanceItem))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(instances.selectedItem?.title, "context-8192")
        try await select("All local models")
        try await select("LM Studio files")
        try await select("Shared · LM Studio")
        XCTAssertEqual(table.selectedRow, 0, "Leaving the hosted workspace must retain its selected model")
        XCTAssertEqual(try XCTUnwrap(controls().first { $0.itemTitles.contains("Choose instance") }).selectedItem?.title, "context-8192",
            "Returning to the same host must retain the selected loaded instance")
        for width in [950, 740] {
            window.setContentSize(NSSize(width: width, height: 820))
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.rootView = LibraryWorkspace(appHost: app, sourceHome: root).frame(width: CGFloat(width), height: 820)
                    .background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: image)
                let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                let name = "library-sources-\(dark ? "dark" : "light")-\(width)"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                if let destination = ProcessInfo.processInfo.environment["MLX_HOST_RENDER_DIR"] {
                    try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
                }
            }
        }
        try await select("Images · ComfyUI")
        let selected = connections[2]
        try hosts.remove(selected.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try sourcePicker().selectedItem?.title, "Hosted models")
        XCTAssertFalse(try sourcePicker().itemTitles.contains("Images · ComfyUI"))
        XCTAssertTrue(controls().contains { $0.selectedItem?.title == "Select a host" })
        app.hostedLibraryHostRequest = selected
        app.hostedLibraryRequested = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try sourcePicker().selectedItem?.title, "Hosted models")
        XCTAssertNil(app.hostedLibraryHostRequest)
        var edited = connections[1]; edited.name = "Renamed"
        try hosts.save(edited, token: nil, replaceToken: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try sourcePicker().itemTitles.contains("Renamed · LM Studio"))
        app.hostedLibraryHostRequest = connections[0]
        app.hostedLibraryRequested = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try sourcePicker().selectedItem?.title, "Shared · Ollama")
        XCTAssertNil(app.hostedLibraryHostRequest)
        XCTAssertEqual(app.config, originalConfig)
        XCTAssertNil(app.hostedComparison.activeRunID)
        requested = await reads.requested
        XCTAssertEqual(requested, [connections[1].id])
    }

    func testDeviceMemoryRendersSharedPartialEmptyAndUnknownReadings() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let date = Date(timeIntervalSince1970: 1_792_512_000)
        let known = HostDeviceMemorySnapshot(capturedAt: date, devices: [
            HostDeviceMemory(name: "Apple M4 Max shared memory", type: "mps", index: nil, totalBytes: 64_000_000_000, freeBytes: 0),
            HostDeviceMemory(name: "A device with a deliberately long repeated name", type: "cuda", index: 0, totalBytes: 24_000_000_000, freeBytes: 8_000_000_000),
            HostDeviceMemory(name: "A device with a deliberately long repeated name", type: "cuda", index: 1, totalBytes: nil, freeBytes: nil)])
        for (state, snapshot) in [("known", Optional(known)), ("empty", HostDeviceMemorySnapshot(capturedAt: date, devices: [])), ("unknown", nil)] {
            for dark in [false, true] {
                try await capture(HostDeviceMemoryView(snapshot: snapshot).padding(WorkbenchSpacing.pageInset),
                    name: "device-memory-" + state, dark: dark, width: 380)
            }
        }
    }

    func testInspectedModelDetailsRenderKnownEmptyAndUnknownMetadata() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        var model = HostedModel(hostID: UUID(), modelID: "selected-model-with-a-long-installed-tag:latest", name: "Selected",
            digest: String(repeating: "a", count: 64), family: "llama", format: "gguf", isLoaded: true,
            contextLength: 4096, maximumContextLength: 131072, memoryBytes: 4_000_000_000,
            capabilities: ["completion", "vision", "tools", "thinking"], detailsCapturedAt: Date(timeIntervalSince1970: 1_792_512_000))
        for state in ["known", "empty", "unknown"] {
            if state == "empty" { model.capabilities = [] }
            if state == "unknown" { model.capabilities = nil; model.maximumContextLength = nil; model.detailsCapturedAt = nil }
            for dark in [false, true] {
                try await capture(HostedModelDetailsView(model: model).padding(WorkbenchSpacing.pageInset),
                    name: "ollama-model-details-" + state, dark: dark, width: 740)
            }
        }
    }

    func testRunningWeightsRenderWithoutInstalledActions() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let hostID = UUID()
        let models = [
            HostedModel(hostID: hostID, modelID: "changed", name: "A replaced model tag", digest: String(repeating: "a", count: 64), isLoaded: true, contextLength: 4096, memoryBytes: 4_000_000_000),
            HostedModel(hostID: hostID, modelID: "orphan", name: "A running model absent from the installed tags with a deliberately long name", digest: "orphan-digest", isLoaded: true)
        ]
        for dark in [false, true] {
            try await capture(HostedRunningModelsView(models: models).padding(WorkbenchSpacing.pageInset), name: "ollama-running-weights", dark: dark, width: 740)
            try await capture(HostedRunningModelsView(models: []).padding(WorkbenchSpacing.pageInset), name: "ollama-running-empty", dark: dark, width: 740)
        }
    }

    func testRecordedComparisonConditionStatesRender() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let host = ModelHost(name: "Local development host with a long saved connection name", provider: .comfyUI, baseURL: "http://127.0.0.1:8188")
        let selected = HostedModel(hostID: host.id, modelID: "selected", name: "Selected model", isLoaded: true)
        let other = HostedModel(hostID: host.id, modelID: "another", name: "Another loaded model", isLoaded: true, memoryBytes: 4_000_000_000)
        let date = Date(timeIntervalSince1970: 1_792_512_000)
        let run = ComparisonRun(id: UUID(), promptSetID: "p", promptSetName: "Test", useCase: nil, variants: [selected.id],
            results: [], startedAt: date, finishedAt: date, state: .completed)
        for state in ["recorded", "unknown", "legacy"] {
            let conditions = HostedLaneConditions(targetID: selected.id, memoryCapturedAt: date,
                systemMemory: state == "unknown" ? nil : MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 2_000_000_000),
                reserveBytes: FitAdvisor.reserveBytes, inventoryCapturedAt: date,
                activity: state == "unknown" ? nil : HostActivity(state: .busy, checkedAt: date, runningCount: 1, pendingCount: 2, detail: "Observed from the host queue."),
                loadedModels: state == "unknown" ? [] : [selected, other], unknownResidencyCount: state == "unknown" ? 12 : 1,
                inventoryWarnings: ["Some model metadata is unavailable."],
                deviceMemory: state == "recorded" ? HostDeviceMemorySnapshot(capturedAt: date, devices: [
                    HostDeviceMemory(name: "Apple M4", type: "mps", index: nil, totalBytes: 32_000_000_000, freeBytes: 0)]) : nil)
            let record = HostedComparisonRecord(run: run, targets: [HostedComparisonTarget(host: host, model: selected, capturedAt: date)],
                temperature: 0, workflow: nil, submissions: [], conditions: state == "legacy" ? nil : [conditions])
            for dark in [false, true] {
                try await capture(ScrollView { HostedRunConditionsView(record: record).padding(WorkbenchSpacing.pageInset).frame(maxWidth: .infinity, alignment: .leading) },
                    name: "comparison-conditions-" + state, dark: dark, width: 740)
            }
        }
    }

    func testHostNavigationConsumesExactConnectionAndRejectsChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent("hosts.json")),
            readToken: { _ in nil }, writeToken: { _, _ in })
        let first = ModelHost(name: "Same name", provider: .ollama, baseURL: "http://127.0.0.1:11434")
        var second = ModelHost(name: "Same name", provider: .ollama, baseURL: "http://127.0.0.1:11435")
        try hosts.save(first, token: nil, replaceToken: false)
        try hosts.save(second, token: nil, replaceToken: false)
        let host = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", configPath: root.appendingPathComponent("config.json").path,
            agentHealth: .notConfigured, runtimeReport: report(), modelHosts: hosts)
        host.hostedLibraryHostRequest = second
        XCTAssertEqual(try host.consumeHostedLibraryHostRequest(), second)
        XCTAssertNil(try host.consumeHostedLibraryHostRequest())
        host.hostedLibraryHostRequest = second
        second.baseURL = "http://127.0.0.1:11436"
        try hosts.save(second, token: nil, replaceToken: false)
        XCTAssertThrowsError(try host.consumeHostedLibraryHostRequest())
        XCTAssertNil(host.hostedLibraryHostRequest)
        host.hostedLibraryHostRequest = first
        try hosts.remove(first.id)
        XCTAssertThrowsError(try host.consumeHostedLibraryHostRequest())
        XCTAssertNil(host.hostedLibraryHostRequest)
    }

    func testMemoryPanelReadsNoHostsUntilExplicitRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = HostSummaryReads()
        let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent("hosts.json")),
            readToken: { _ in nil }, writeToken: { _, _ in }, fetch: { host, _ in try await reads.fetch(host) })
        let first = ModelHost(name: "First", provider: .ollama, baseURL: "http://127.0.0.1:11434")
        let second = ModelHost(name: "Second", provider: .lmStudio, baseURL: "http://127.0.0.1:1234")
        for host in [first, second] { try hosts.save(host, token: nil, replaceToken: false) }
        let header = SystemResourceHeader(resources: SystemResourceMonitor(probe: { nil }), endpoint: endpoint(root: root), hosts: hosts,
            onUnload: { _ in XCTFail("Rendering must not unload"); return false })
        let hosting = NSHostingView(rootView: header.panel)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 620)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        var requested = await reads.requested
        XCTAssertEqual(requested, [])
        await hosts.refresh(second.id)
        requested = await reads.requested
        XCTAssertEqual(requested, [second.id])
        XCTAssertNil(hosts.inventories[first.id])
        let previous = hosts.inventories[second.id]
        await hosts.refresh(second.id)
        XCTAssertEqual(hosts.inventories[second.id], previous)
        XCTAssertNotNil(hosts.errors[second.id])
    }

    func testSavedHostsMemoryPanelStatesRender() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for state in ["unrefreshed", "loaded", "error"] {
            let reads = HostSummaryReads()
            let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent(state + ".json")),
                readToken: { _ in nil }, writeToken: { _, _ in }, fetch: { host, _ in try await reads.fetch(host) })
            let connection = ModelHost(name: "Development models with a deliberately long connection name", provider: .ollama, baseURL: "http://127.0.0.1:11434")
            try hosts.save(connection, token: nil, replaceToken: false)
            if state != "unrefreshed" { await hosts.refresh(connection.id) }
            if state == "error" { await hosts.refresh(connection.id) }
            let resources = SystemResourceMonitor(probe: { MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 6_000_000_000) })
            await resources.refreshMemory(); await resources.refreshServers()
            let header = SystemResourceHeader(resources: resources, endpoint: endpoint(root: root), hosts: hosts, onUnload: { _ in false })
            for dark in [false, true] {
                try await capture(header.panel, name: "memory-hosts-" + state, dark: dark, width: 740)
            }
        }
    }

    func testNativeRequestsReturnFromHostedWorkspaceWithoutStartingWork() async throws {
        let host = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", configPath: "/state/config.json",
            agentHealth: .notConfigured, runtimeReport: report())
        host.compareHostedModels = true
        let hosting = NSHostingView(rootView: ComparisonWorkspace(appHost: host).frame(width: 1100, height: 820))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let model = LibraryModel(item: ModelItem(path: "/Models/native", name: "Native", bytes: 100, modifiedAt: nil,
            shard: nil, modelKey: "native", architecture: nil, quantization: "q4", parameters: nil, structure: nil,
            signature: "sha", companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil,
            task: ModelTask(type: .textLLM, useCases: [], source: "registry", confidence: "confirmed")), readiness: .ready)
        host.librarySnapshot = LibrarySnapshot(models: [model], groups: [], hardware: .current(), generatedAt: Date())
        host.modelComparisonRequest = try XCTUnwrap(ComparisonModelRequest(model: model))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(host.compareHostedModels)
        XCTAssertNil(host.modelComparisonRequest)
        XCTAssertNil(host.comparison.activeRunID)
        host.compareHostedModels = true
        let baseline = ServingProfile(id: UUID(), name: "Baseline", modelPath: model.item.path, options: StrataComparisonOptions())
        let candidate = ServingProfile(id: UUID(), name: "Candidate", modelPath: model.item.path, options: StrataComparisonOptions(speculation: true))
        host.servingProfileComparisonRequest = try ServingProfileComparisonSetup(baseline: baseline, candidate: candidate)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(host.compareHostedModels)
        XCTAssertNil(host.comparison.activeRunID)
        XCTAssertNil(host.hostedComparison.activeRunID)
    }

    func testHostInventoryAndComparisonStatesRender() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = ModelHost(name: "Ollama", provider: .ollama, baseURL: "http://127.0.0.1:11434")
        let installed = (1...12).map { index in
            HostedModel(hostID: connection.id, modelID: "model-\(index):q4", name: "Qwen model \(index)", digest: "digest-\(index)",
                family: "qwen", parameters: "8B", quantization: "Q4_K_M", format: "gguf", sizeBytes: 4_500_000_000,
                isLoaded: index == 1, contextLength: index == 1 ? 8192 : nil, memoryBytes: index == 1 ? 5_000_000_000 : nil)
        }
        let inventory = HostInventory(host: connection, models: installed,
            capturedAt: Date(timeIntervalSince1970: 1_792_512_000), runtimeVersion: "0.12",
            runningModels: [installed[0], HostedModel(hostID: connection.id, modelID: "running-only", name: "Running-only weights", digest: "running-only-digest", isLoaded: true)])
        let hosts = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent("hosts.json")),
            readToken: { _ in nil }, writeToken: { _, _ in }, fetch: { _, _ in inventory })
        let host = AppHost(config: .defaults(ggufRoots: []), discoveredRoots: [], vendorAgentPath: "", configPath: root.appendingPathComponent("config.json").path,
            agentHealth: .notConfigured, runtimeReport: report(), modelHosts: hosts)
        for dark in [false, true] {
            try await capture(HostedModelsView(appHost: host), name: "hosts-empty", dark: dark)
        }
        try hosts.save(connection, token: nil, replaceToken: false)
        for dark in [false, true] {
            try await capture(HostedModelsView(appHost: host), name: "hosts-unrefreshed", dark: dark)
        }
        await hosts.refresh(connection.id)
        host.hostedComparisonTargets = inventory.models.prefix(2).map { HostedComparisonTarget(host: connection, model: $0, capturedAt: inventory.capturedAt) }
        for dark in [false, true] {
            try await capture(HostedModelsView(appHost: host), name: "hosts-populated", dark: dark)
            try await capture(HostedModelsView(appHost: host), name: "hosts-minimum", dark: dark, width: 740)
            try await capture(HostedComparisonView(appHost: host), name: "hosted-compare-setup", dark: dark)
            try await capture(QuantView(appHost: host), name: "native-compare-preserved", dark: dark)
        }
    }

    private func report() -> RuntimeReport {
        RuntimeReport(convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready"),
            serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready"), install: "make install", ok: true)
    }

    private func endpoint(root: URL) -> EndpointSupervisor {
        let world = FakeServeWorld()
        return EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore(fileURL: root.appendingPathComponent("endpoints.json")))
    }

    func testHostResourceConfirmationStatesRender() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for state in [HostActivityState.idle, .busy, .unknown] {
            let host = ModelHost(name: state == .unknown ? "LM Studio" : "ComfyUI", provider: state == .unknown ? .lmStudio : .comfyUI,
                baseURL: "http://127.0.0.1:8188")
            let selection = state == .unknown ? HostResourceSelection(modelID: "qwen-8b", instanceID: "coding-context-8192") : HostResourceSelection()
            let coordinator = ModelHostsCoordinator(store: JSONStore(fileURL: root.appendingPathComponent(state.rawValue + ".json")),
                readToken: { _ in nil }, writeToken: { _, _ in }, inspectResource: { host, selection, _ in
                    HostResourcePreview(host: host, selection: selection,
                        model: host.provider == .comfyUI ? nil : HostedModel(hostID: host.id, modelID: "qwen-8b", name: "Qwen 8B", isLoaded: true, loadedInstanceIDs: ["coding-context-8192"]),
                        activity: HostActivity(state: state, runningCount: state == .unknown ? nil : (state == .busy ? 1 : 0),
                            pendingCount: state == .unknown ? nil : (state == .busy ? 2 : 0),
                            detail: state == .unknown ? "This API does not expose other clients' active requests." : "Observed from the host queue."))
                })
            try coordinator.save(host, token: nil, replaceToken: false)
            for dark in [false, true] {
                try await capture(HostResourceSheet(coordinator: coordinator, hostID: host.id, selection: selection),
                    name: "host-memory-\(state.rawValue)", dark: dark, width: 740)
            }
        }
    }

    private func capture<Content: View>(_ view: Content, name: String, dark: Bool, width: CGFloat = 1100) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 820).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 300_000_000); hosting.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        let filename = "\(name)-\(dark ? "dark" : "light")-\(Int(width))"
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = filename; attachment.lifetime = .keepAlways; add(attachment)
        if let destination = ProcessInfo.processInfo.environment["MLX_HOST_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename + ".png"))
        }
    }
}

private actor HostSummaryReads {
    var requested: [UUID] = []
    func fetch(_ host: ModelHost, instances: [String]? = nil) throws -> HostInventory {
        requested.append(host.id)
        if requested.count > 1 { throw URLError(.cannotConnectToHost) }
        return HostInventory(host: host, models: [
            HostedModel(hostID: host.id, modelID: "loaded", name: "Qwen coding model with a long model name", isLoaded: true, memoryBytes: 5_000_000_000, loadedInstanceIDs: instances),
            HostedModel(hostID: host.id, modelID: "unknown", name: "Unknown residency")
        ], capturedAt: Date(timeIntervalSince1970: 1_792_512_000),
            activity: HostActivity(state: .unknown, checkedAt: Date(timeIntervalSince1970: 1_792_512_000), detail: "Other clients' activity is unavailable."))
    }
}
