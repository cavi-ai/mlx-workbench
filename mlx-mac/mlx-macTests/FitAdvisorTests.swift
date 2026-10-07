import Foundation
import XCTest
import AppKit
import SwiftUI

@testable import mlx_workbench

final class FitAdvisorTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    @MainActor
    func testResourceHeaderAndServingControlsRender() async throws {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/Qwen3-8B-4bit", port: 8766)
        let monitor = SystemResourceMonitor(probe: { MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 12_000_000_000) },
            statusProvider: { try world.status() })
        await monitor.refreshMemory()
        await monitor.refreshServers()
        let store = JSONStore<EndpointConfig>(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("endpoint.json"))
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() }, store: store)
        let header = SystemResourceHeader(resources: monitor, endpoint: supervisor, onUnload: { await supervisor.unloadServer($0) })
        let root = VStack(spacing: 20) {
            HStack { Text("Compare").font(.headline); Spacer(); header }.padding(16)
            header.panel
            Spacer()
        }.frame(width: 670, height: 520).background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Memory header and serving controls"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHeaderRefusesInvalidMemoryAndClearsFailedServerReading() async {
        let invalid = SystemResourceMonitor(probe: { MemorySnapshot(totalBytes: 32, availableBytes: 33) })
        await invalid.refreshMemory()
        XCTAssertNil(invalid.memory)
        XCTAssertNil(invalid.capturedAt)
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766)
        let monitor = SystemResourceMonitor(statusProvider: { try world.status() })
        await monitor.refreshServers()
        XCTAssertEqual(monitor.servers?.count, 1)
        world.statusError = NSError(domain: "test", code: 1)
        await monitor.refreshServers()
        XCTAssertNil(monitor.servers)
        XCTAssertNotNil(monitor.serverError)
    }

    @MainActor
    func testHeaderMemoryCaptureKeepsUnknownValuesAndCaptureTime() async {
        let date = Date(timeIntervalSince1970: 1234)
        let monitor = SystemResourceMonitor(probe: { MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 12_000_000_000) }, now: { date })
        await monitor.refreshMemory()
        XCTAssertEqual(monitor.memory?.availableBytes, 12_000_000_000)
        XCTAssertEqual(monitor.capturedAt, date)
        XCTAssertEqual(monitor.memory?.unavailableBytes, 20_000_000_000)
        let missing = SystemResourceMonitor(probe: { nil }, now: { date })
        await missing.refreshMemory()
        XCTAssertNil(missing.memory)
        XCTAssertNil(missing.capturedAt)
    }

    // MARK: - Parameter parsing

    func testParameterBillionsParsesCommonShapes() {
        XCTAssertEqual(FitAdvisor.parameterBillions("8B"), 8.0)
        XCTAssertEqual(FitAdvisor.parameterBillions("70.6B"), 70.6)
        XCTAssertEqual(FitAdvisor.parameterBillions("3.2b"), 3.2)
        XCTAssertEqual(FitAdvisor.parameterBillions("350M"), 0.35)
        XCTAssertNil(FitAdvisor.parameterBillions(nil))
        XCTAssertNil(FitAdvisor.parameterBillions("unknown"))
    }

    // MARK: - Verdict thresholds

    func testSmallModelOnLargeMemoryFits() {
        // 5 GB weights on 16 GB budget (20 GB available − 4 GB reserve).
        let verdict = FitAdvisor.verdict(
            modelBytes: 5 * gb, contextTokens: 8192, parameters: "8B",
            availableBytes: 20 * gb, reserveBytes: 4 * gb
        )
        guard case .fits(let headroom) = verdict else {
            return XCTFail("expected fits, got \(verdict)")
        }
        XCTAssertGreaterThan(headroom, 8)
    }

    func testModelNearBudgetIsTight() {
        // Needed: 12 GB weights + ~1.3 GB KV + 1.5 GB overhead ≈ 14.8 GB;
        // budget 16 GB → inside budget but above the 85% line.
        let verdict = FitAdvisor.verdict(
            modelBytes: 12 * gb, contextTokens: 8192, parameters: "8B",
            availableBytes: 20 * gb, reserveBytes: 4 * gb
        )
        guard case .tight = verdict else {
            return XCTFail("expected tight, got \(verdict)")
        }
    }

    func testOversizedModelWontFitWithSuggestion() {
        // 40 GB weights on a 32 GB machine, 32k context requested.
        let verdict = FitAdvisor.verdict(
            modelBytes: 40 * gb, contextTokens: 32768, parameters: "70B",
            availableBytes: 28 * gb, reserveBytes: 4 * gb
        )
        guard case .wontFit(let deficit, let suggestion) = verdict else {
            return XCTFail("expected wontFit, got \(verdict)")
        }
        XCTAssertGreaterThan(deficit, 15)
        // Even 2k context cannot fix a 16 GB structural deficit.
        XCTAssertNil(suggestion)
    }

    func testContextReductionRescuesBorderlineFit() {
        // 14 GB weights, 14B-class KV (~280 KB/token); budget 24 GB
        // (fits line 20.4 GB): 32k context blows the budget outright,
        // 16k fits.
        let verdict = FitAdvisor.verdict(
            modelBytes: 14 * gb, contextTokens: 32768, parameters: "14B",
            availableBytes: 28 * gb, reserveBytes: 4 * gb
        )
        guard case .wontFit(_, let suggestion) = verdict else {
            return XCTFail("expected wontFit, got \(verdict)")
        }
        XCTAssertEqual(suggestion, 16384)
        // The suggestion must actually fit.
        let check = FitAdvisor.verdict(
            modelBytes: 14 * gb, contextTokens: suggestion ?? 0, parameters: "14B",
            availableBytes: 28 * gb, reserveBytes: 4 * gb
        )
        guard case .fits = check else {
            return XCTFail("suggested context does not fit: \(check)")
        }
    }

    // MARK: - Inputs missing

    func testUnknownModelSize() {
        let verdict = FitAdvisor.verdict(
            modelBytes: nil, contextTokens: 8192, parameters: "8B",
            hardware: HardwareProfile.current(), memory: nil
        )
        guard case .unknown = verdict else {
            return XCTFail("expected unknown, got \(verdict)")
        }
    }

    func testProbeFailureFallsBackToTotalMemoryEstimate() {
        let hardware = HardwareProfile(chip: "M4", model: "Mac", memoryBytes: 32 * gb, macOSVersion: "26", summary: "test")
        let verdict = FitAdvisor.verdict(
            modelBytes: 5 * gb, contextTokens: 8192, parameters: "8B",
            hardware: hardware, memory: nil
        )
        // Fallback: 60% of 32 GB = 19.2 GB available → comfortably fits.
        guard case .fits = verdict else {
            return XCTFail("expected fits from fallback estimate, got \(verdict)")
        }
    }

    func testKVHeuristicScalesWithParameters() {
        let small = FitAdvisor.kvBytesPerToken(parameters: "8B")
        let large = FitAdvisor.kvBytesPerToken(parameters: "70B")
        XCTAssertGreaterThan(large, small)
        XCTAssertEqual(small, Int64(8e9 * 2e-5))
    }

    func testMemorySnapshotProbeReturnsSaneValues() {
        guard let snapshot = MemorySnapshot.probe() else {
            XCTFail("memory probe failed on a real machine")
            return
        }
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertGreaterThan(snapshot.availableBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.availableBytes, snapshot.totalBytes)
    }
}
