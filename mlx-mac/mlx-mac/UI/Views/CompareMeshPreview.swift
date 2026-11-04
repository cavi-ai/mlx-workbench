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

    @MainActor func scene() -> SCNScene {
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions.map { SCNVector3($0) }),
                                            SCNGeometrySource(normals: normals.map { SCNVector3($0) })],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.controlAccentColor
        material.isDoubleSided = true
        geometry.materials = [material]
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(2.5, 1.5, 3)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        return scene
    }
}

struct ComparisonMeshPreview: View {
    let url: URL
    @State private var scene: SCNScene?
    @State private var error: String?

    var body: some View {
        Group {
            if let scene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .accessibilityLabel("3D mesh preview. Drag to rotate and scroll to zoom.")
            } else if let error {
                Text(error).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } else { ProgressView("Loading mesh") }
        }
        .task(id: url) {
            scene = nil; error = nil
            do {
                let mesh = try await Task.detached(priority: .userInitiated) { try ComparisonMeshData.read(url) }.value
                try Task.checkCancellation()
                scene = mesh.scene()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}
