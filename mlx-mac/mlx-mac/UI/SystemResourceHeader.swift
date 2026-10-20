import AppKit
import SwiftUI

/// One compact toolbar entry; model controls and estimation settings live
/// in its popover so charts keep their space.
struct SystemResourceHeader: View {
    @ObservedObject var resources: SystemResourceMonitor
    @ObservedObject var endpoint: EndpointSupervisor
    var protectedModels: Set<String> = []
    let onUnload: (ServerInfo) async -> Bool
    @State private var expanded = false
    @State private var inspectingProcesses = false
    @State private var unloadError: String?

    private func gb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1e9) }

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: WorkbenchSpacing.xs) {
                Image(systemName: "memorychip")
                    .foregroundStyle(WorkbenchColor.muted)
                if let memory = resources.memory {
                    Text("~\(gb(memory.availableBytes)) GB available")
                        .foregroundStyle(memory.availableBytes < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.ink)
                        .contentTransition(.numericText())
                } else {
                    Text("RAM unavailable").foregroundStyle(WorkbenchColor.muted)
                }
            }
            .font(WorkbenchTypography.label.monospacedDigit())
            .lineLimit(1)
            .workbenchAnimation(value: resources.memory?.availableBytes)
        }
        .buttonStyle(.plain)
        .help("Live memory headroom and serving model controls")
        .accessibilityIdentifier("system-memory-header")
        .popover(isPresented: $expanded, arrowEdge: .bottom) { panel }
        .sheet(isPresented: $inspectingProcesses) { ProcessMemorySheet(resources: resources) }
    }

    var panel: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            CardHeader("Memory & serving", systemImage: "memorychip") {
                Button { Task { await resources.refreshMemory(); await resources.refreshServers() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh readings and serving status")
                .disabled(resources.refreshingServers || endpoint.isUnloading)
            }
            if let memory = resources.memory {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.md) {
                    memoryValue("Available headroom", bytes: memory.availableBytes, color: WorkbenchColor.accent)
                    memoryValue("Estimated in use", bytes: memory.unavailableBytes, color: WorkbenchColor.ink)
                }
                ProgressView(value: Double(memory.unavailableBytes), total: Double(memory.totalBytes))
                    .tint(memory.availableBytes < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.accent)
                Text("\(gb(memory.totalBytes)) GB unified memory · system-wide estimates including reclaimable pages. Per-model GPU allocation is unavailable.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if let date = resources.capturedAt {
                    Text("Read \(date.formatted(date: .omitted, time: .standard))")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            } else {
                Text("Memory readings unavailable").foregroundStyle(WorkbenchColor.muted)
            }
            ProcessMemoryButton {
                expanded = false
                inspectingProcesses = true
            }
            Picker("Context for model fit", selection: $resources.contextTokens) {
                ForEach(SystemResourceMonitor.contextOptions, id: \.self) { tokens in
                    Text(RunContext.title(tokens)).tag(tokens)
                }
            }
            .font(WorkbenchTypography.metadata)
            Text("Used for model-fit reviews; does not change a running server’s context limit.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Divider()
            Text("Serving models").font(WorkbenchTypography.metadata.weight(.semibold))
                .foregroundStyle(WorkbenchColor.muted)
            if let error = resources.serverError {
                Text(error).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            } else if let servers = resources.servers {
                if servers.isEmpty { Text("No serving models").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
                ForEach(servers) { server in
                    HStack(spacing: WorkbenchSpacing.sm) {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            Text((HFRepoID.forPath(server.modelIdentity) ?? URL(fileURLWithPath: server.modelIdentity).lastPathComponent)
                                + (server.adapterSummary.map { " · " + $0 } ?? ""))
                                .font(WorkbenchTypography.label).lineLimit(1)
                                .help(server.modelIdentity)
                            Text("Port \(server.port.map(String.init) ?? "unknown") · PID \(server.pid.map(String.init) ?? "unknown")")
                                .font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted)
                            Text(server.residencySummary + ((server.activeRequests ?? 0) > 0 ? " · \(server.activeRequests ?? 0) active" : ""))
                                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        }
                        Spacer()
                        Button(server.jit == true ? "Unload" : "Stop server") {
                            Task {
                                unloadError = nil
                                if !(await onUnload(server)) { unloadError = endpoint.lastError ?? "Unload failed." }
                                await resources.refreshServers()
                                await resources.refreshMemory()
                            }
                        }
                        .controlSize(.small)
                        .disabled(endpoint.isUnloading || resources.refreshingServers || server.port == nil ||
                                  server.modelState == "unloaded" || server.modelState == "loading" || server.modelState == "unloading" ||
                                  (server.activeRequests ?? 0) > 0 ||
                                  AppHost.isProtectedServer(server, protected: protectedModels))
                        .help(server.jit == true
                              ? "Release model weights while keeping this endpoint reachable. The next request loads the same local files."
                              : "Stop this server and disable automatic restart. Enable Load on request in Run for JIT unload.")
                    }
                }
            } else {
                Text("Reading serving status…").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            if !protectedModels.isEmpty {
                Text("Models in an active comparison or verification cannot be unloaded here. Finish or cancel that run first.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            if endpoint.isUnloading { ProgressView("Unloading…").controlSize(.small) }
            if let unloadError { Text(unloadError).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning) }
        }
        .padding(WorkbenchSpacing.md)
        .frame(width: 420)
        .task {
            while !Task.isCancelled {
                await resources.refreshServers()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
    }

    private func memoryValue(_ label: String, bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(label).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Text("~\(gb(bytes)) GB").font(WorkbenchTypography.display)
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .workbenchAnimation(value: bytes)
        }
    }
}

/// Shared entry point from Run and the toolbar resource popover.
struct ProcessMemoryButton: View {
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            Label("What’s using memory…", systemImage: "list.bullet.rectangle")
        }
        .buttonStyle(.borderless)
        .font(WorkbenchTypography.secondary)
        .accessibilityIdentifier("inspect-process-memory")
        .help("Read the largest processes by resident memory without stopping anything")
    }
}

struct ProcessMemorySheet: View {
    @ObservedObject var resources: SystemResourceMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var activityMonitorError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("What’s using memory").font(WorkbenchTypography.title)
                    Text("Largest processes by resident memory")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await resources.refreshProcesses() }
                }
                .disabled(resources.refreshingProcesses)
            }
            Text("Resident memory can include shared pages and omit GPU allocations. These values do not add up to system memory use or change the model-fit estimate.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let error = resources.processError {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                    .accessibilityIdentifier("process-memory-error")
            }
            HStack {
                if resources.refreshingProcesses { ProgressView().controlSize(.small) }
                if let date = resources.processCapturedAt {
                    Text("Read \(date.formatted(date: .omitted, time: .standard)) · Refresh to update")
                        .accessibilityIdentifier("process-memory-timestamp")
                } else { Text(resources.processError == nil ? "Reading processes…" : "No reading available") }
            }
            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Table(Array((resources.processMemory?.processes ?? []).prefix(15))) {
                TableColumn("Process") { process in
                    Text(process.name).lineLimit(1).help(process.name)
                }
                TableColumn("PID") { process in Text(String(process.pid)).monospacedDigit() }
                    .width(65)
                TableColumn("Resident RAM") { process in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: process.residentBytes), countStyle: .memory))
                        .monospacedDigit()
                }.width(110)
            }
            .accessibilityIdentifier("process-memory-table")
            .frame(minHeight: 160, maxHeight: .infinity)
            Text("Up to 15 readable processes. Exited or unreadable processes are omitted. Process names may be shortened by macOS; they do not identify individual models or clients.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let activityMonitorError {
                Text(activityMonitorError).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            }
            HStack {
                Button("Open Activity Monitor") {
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
                        activityMonitorError = "Activity Monitor could not be found."
                        return
                    }
                    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                        Task { @MainActor in
                            activityMonitorError = error == nil ? nil : "Activity Monitor could not be opened."
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 480, idealWidth: 580, maxWidth: 640, minHeight: 460, idealHeight: 520, maxHeight: 560)
        .task { await resources.refreshProcesses() }
    }
}
