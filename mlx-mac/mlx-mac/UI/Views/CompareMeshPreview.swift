import Foundation
import SceneKit
import SwiftUI
import simd

/// The single-buffer, indexed triangle GLB emitted by `convert mesh`.
/// Parse off the main actor and validate every range before creating geometry.
struct ComparisonMeshData: Sendable {
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "This file is not a supported mesh preview. Reveal the GLB to inspect it in a 3D application." }
    }

    nonisolated static func read(_ url: URL) throws -> Self {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, (28...100_000_000).contains(size) else { throw ReadError.invalid }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data)
    }

    nonisolated static func read(_ data: Data) throws -> Self {
        guard (28...100_000_000).contains(data.count) else { throw ReadError.invalid }
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw ReadError.invalid }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard try word(0) == 0x46546C67, try word(4) == 2, try Int(word(8)) == data.count,
              try word(16) == 0x4E4F534A else { throw ReadError.invalid }
        let jsonLength = Int(try word(12)), binaryHeader = 20 + jsonLength
        guard jsonLength > 0, binaryHeader <= data.count - 8,
              let document = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<binaryHeader)) as? [String: Any],
              let views = document["bufferViews"] as? [[String: Any]],
              let accessors = document["accessors"] as? [[String: Any]], accessors.count == 2,
              accessors[0]["type"] as? String == "VEC3", accessors[0]["componentType"] as? Int == 5126,
              accessors[1]["type"] as? String == "SCALAR", accessors[1]["componentType"] as? Int == 5125,
              try word(binaryHeader + 4) == 0x004E4942 else { throw ReadError.invalid }
        let binaryStart = binaryHeader + 8
        let binaryLength = Int(try word(binaryHeader))
        guard binaryLength == data.count - binaryStart else { throw ReadError.invalid }
        func range(_ accessor: [String: Any], stride: Int) throws -> (Int, Int) {
            guard let count = accessor["count"] as? Int, count > 0, count <= 10_000_000,
                  let viewIndex = accessor["bufferView"] as? Int, views.indices.contains(viewIndex),
                  views[viewIndex]["buffer"] as? Int == 0,
                  let length = views[viewIndex]["byteLength"] as? Int else { throw ReadError.invalid }
            let offset = views[viewIndex]["byteOffset"] as? Int ?? 0
            guard offset >= 0, length >= count * stride, offset <= binaryLength - length,
                  (accessor["byteOffset"] as? Int ?? 0) == 0, views[viewIndex]["byteStride"] == nil else { throw ReadError.invalid }
            return (binaryStart + offset, count)
        }
        let (positionsStart, vertexCount) = try range(accessors[0], stride: 12)
        let (indicesStart, indexCount) = try range(accessors[1], stride: 4)
        guard indexCount % 3 == 0 else { throw ReadError.invalid }
        let positions: [SIMD3<Float>] = try (0..<vertexCount).map { index in
            let offset = positionsStart + index * 12
            let value = try SIMD3(Float(bitPattern: word(offset)), Float(bitPattern: word(offset + 4)), Float(bitPattern: word(offset + 8)))
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { throw ReadError.invalid }
            return value
        }
        let indices = try (0..<indexCount).map { try word(indicesStart + $0 * 4) }
        guard indices.allSatisfy({ UInt64($0) < UInt64(vertexCount) }) else { throw ReadError.invalid }
        var normals = Array(repeating: SIMD3<Float>.zero, count: vertexCount)
        for index in stride(from: 0, to: indexCount, by: 3) {
            let a = Int(indices[index]), b = Int(indices[index + 1]), c = Int(indices[index + 2])
            let normal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += normal; normals[b] += normal; normals[c] += normal
        }
        normals = normals.map { simd_length_squared($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        return Self(positions: positions, normals: normals, indices: indices)
    }

    /// The mesh lit in the accent color with a camera that frames its bounds.
    @MainActor func stage() -> ComparisonMeshStage {
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions.map { SCNVector3($0) }),
                                            SCNGeometrySource(normals: normals.map { SCNVector3($0) })],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.controlAccentColor
        material.isDoubleSided = true
        geometry.materials = [material]
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        let low = positions.dropFirst().reduce(positions[0], simd_min)
        let high = positions.dropFirst().reduce(positions[0], simd_max)
        let center = (low + high) / 2, radius = max(simd_length(high - low) / 2, 1e-3)
        // Clip range and zoom limits scale with the mesh, so a close view shows the surface instead of slicing it.
        let camera = SCNCamera()
        camera.fieldOfView = 35
        camera.zNear = Double(radius) * 0.001
        camera.zFar = Double(radius) * 100
        let distance = radius / sin(Float(camera.fieldOfView) * .pi / 360) * 1.05
        let node = SCNNode()
        node.camera = camera
        node.simdPosition = center + simd_normalize(SIMD3<Float>(2.5, 1.5, 3)) * distance
        node.simdLook(at: center)
        scene.rootNode.addChildNode(node)
        return ComparisonMeshStage(scene: scene, camera: node,
                                   zoom: ComparisonMeshZoom(center: center, distances: radius...distance * 4,
                                                            fieldsOfView: 5...camera.fieldOfView))
    }
}

struct ComparisonMeshStage {
    let scene: SCNScene
    let camera: SCNNode
    let zoom: ComparisonMeshZoom
}

/// Pinch zoom with fixed limits. Zooming in moves the camera along its view axis to the mesh's bounding
/// sphere, then narrows the lens; zooming out widens the lens back to the framing lens, then backs away.
/// The camera never enters the mesh bounds and the lens never goes wider than the framing lens.
struct ComparisonMeshZoom {
    let center: SIMD3<Float>
    let distances: ClosedRange<Float>
    let fieldsOfView: ClosedRange<CGFloat>

    func apply(_ magnification: CGFloat, to camera: SCNNode) {
        guard let lens = camera.camera, magnification.isFinite, magnification > -0.9, magnification != 0 else { return }
        let scale = 1 + magnification
        let offset = camera.simdWorldPosition - center, front = camera.simdWorldFront
        let distance = simd_length(offset)
        let moves = scale > 1 ? distance > distances.lowerBound * 1.0001 : lens.fieldOfView >= fieldsOfView.upperBound
        if moves {
            let goal = min(max(distance / Float(scale), distances.lowerBound), distances.upperBound)
            let lateral = offset - front * simd_dot(offset, front)
            camera.simdWorldPosition = center + lateral - front * sqrt(max(goal * goal - simd_length_squared(lateral), 0))
        } else {
            let field = atan(tan(lens.fieldOfView * .pi / 360) / scale) * 360 / .pi
            lens.fieldOfView = min(max(field, fieldsOfView.lowerBound), fieldsOfView.upperBound)
        }
    }
}

/// SceneKit camera control for rotate and pan, with pinch routed through `ComparisonMeshZoom`.
final class ComparisonMeshSceneView: SCNView {
    private var zoom: ComparisonMeshZoom?
    var scrollsPage = false

    convenience init(stage: ComparisonMeshStage) {
        self.init(frame: .zero, options: nil)
        allowsCameraControl = true
        autoenablesDefaultLighting = true
        antialiasingMode = .multisampling4X
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("3D mesh preview. Drag to rotate, pinch to zoom and scroll to pan.")
        show(stage)
    }

    func show(_ stage: ComparisonMeshStage) {
        scene = stage.scene
        pointOfView = stage.camera
        zoom = stage.zoom
    }

    override func magnify(with event: NSEvent) {
        guard let zoom, let camera = pointOfView else { return super.magnify(with: event) }
        zoom.apply(event.magnification, to: camera)
    }

    override func scrollWheel(with event: NSEvent) {
        if scrollsPage, let scrollView = enclosingScrollView { scrollView.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

private struct ComparisonMeshSceneRepresentable: NSViewRepresentable {
    let stage: ComparisonMeshStage
    var scrollsPage = false

    func makeNSView(context: Context) -> ComparisonMeshSceneView {
        let view = ComparisonMeshSceneView(stage: stage)
        view.scrollsPage = scrollsPage
        return view
    }

    func updateNSView(_ view: ComparisonMeshSceneView, context: Context) {
        view.scrollsPage = scrollsPage
        view.setAccessibilityLabel(scrollsPage ? "3D mesh preview. Drag to rotate and pinch to zoom." : "3D mesh preview. Drag to rotate, pinch to zoom and scroll to pan.")
        if view.scene !== stage.scene { view.show(stage) }
    }
}

/// One mesh opened from a Compare cell into its own full-screen window.
struct ComparisonMeshInspection: Codable, Hashable {
    static let windowID = "comparison-mesh"
    let url: URL
    let title: String
}

struct ComparisonMeshPreview: View {
    let url: URL
    var verifiedMesh: ComparisonMeshData? = nil
    var scrollsPage = false
    /// Shows the full-screen button when set.
    var inspection: ComparisonMeshInspection?
    @Environment(\.openWindow) private var openWindow
    @State private var stage: ComparisonMeshStage?
    @State private var error: String?

    var body: some View {
        Group {
            if let stage {
                ComparisonMeshSceneRepresentable(stage: stage, scrollsPage: scrollsPage)
                    .accessibilityLabel(scrollsPage ? "3D mesh preview. Drag to rotate and pinch to zoom." : "3D mesh preview. Drag to rotate, pinch to zoom and scroll to pan.")
                    .overlay(alignment: .topTrailing) {
                        if let inspection {
                            Button { openWindow(value: inspection) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(WorkbenchSpacing.xs)
                            .help("Open full screen")
                            .accessibilityLabel("Open \(inspection.title) full screen")
                        }
                    }
            } else if let error {
                Text(error).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } else { ProgressView("Loading mesh") }
        }
        .task(id: url) {
            stage = nil; error = nil
            do {
                let mesh: ComparisonMeshData
                if let verifiedMesh { mesh = verifiedMesh }
                else { mesh = try await Task.detached(priority: .userInitiated) { try ComparisonMeshData.read(url) }.value }
                try Task.checkCancellation()
                stage = mesh.stage()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}

/// A Compare mesh at screen size, for grading surface detail.
struct ComparisonMeshInspector: View {
    let inspection: ComparisonMeshInspection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Text(inspection.title).font(WorkbenchTypography.cardTitle).lineLimit(1)
                Spacer()
                Text("Drag to rotate, pinch to zoom, scroll to pan")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Button("Reveal mesh", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([inspection.url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ComparisonMeshPreview(url: inspection.url).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(WorkbenchSpacing.pageInset)
        .background(FullScreenOnOpen())
        .navigationTitle(inspection.title)
    }
}

/// Puts its window into macOS full screen when the window first appears.
private struct FullScreenOnOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
        }
    }
}
