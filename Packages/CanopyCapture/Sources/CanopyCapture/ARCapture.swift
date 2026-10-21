#if os(iOS)
    import ARKit
    import Foundation
    import RealityKit
    import simd

    /// Whether this device can reconstruct a LiDAR mesh. Devices without it get the map, tagging and
    /// verification only.
    public enum LiDAR {
        public static var isAvailable: Bool {
            ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
    }

    /// A raycast hit on the reconstructed mesh.
    public struct MeshHit: Equatable, Sendable {
        /// World position, metres.
        public var position: SIMD3<Float>
        /// Distance from the camera, metres.
        public var distance: Float
        /// Camera position when the hit was made.
        public var cameraPosition: SIMD3<Float>
    }

    /// Owns the AR view: world tracking with LiDAR scene reconstruction, the mesh overlay, raycasts against the
    /// mesh, and mesh snapshots for evidence. Camera frames stay inside ARKit; nothing here reads or keeps an
    /// image.
    @MainActor
    public final class CaptureSession {
        public let view: ARView
        /// True once the session runs with gravity-and-heading alignment (−z is true north).
        public private(set) var isNorthAligned = false

        public init() {
            view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
            view.renderOptions.insert(.disableMotionBlur)
            view.environment.sceneUnderstanding.options = [.collision, .occlusion]
            view.debugOptions.insert(.showSceneUnderstanding)
        }

        public func start() {
            guard LiDAR.isAvailable else { return }
            let configuration = ARWorldTrackingConfiguration()
            configuration.sceneReconstruction =
                ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                ? .meshWithClassification : .mesh
            configuration.worldAlignment = .gravityAndHeading
            configuration.planeDetection = [.horizontal]
            configuration.environmentTexturing = .none
            isNorthAligned = true
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }

        public func pause() {
            view.session.pause()
        }

        /// The current camera position in world coordinates, if tracking.
        public var cameraPosition: SIMD3<Float>? {
            guard let frame = view.session.currentFrame, case .normal = frame.camera.trackingState else { return nil }
            let t = frame.camera.transform.columns.3
            return SIMD3(t.x, t.y, t.z)
        }

        /// Casts a ray through a point in the view against the reconstructed mesh.
        public func raycast(at point: CGPoint, maxDistance: Float = 10) -> MeshHit? {
            guard let ray = view.ray(through: point), let camera = cameraPosition else { return nil }
            let hits = view.scene.raycast(
                origin: ray.origin, direction: ray.direction, length: maxDistance, query: .nearest,
                mask: .sceneUnderstanding, relativeTo: nil)
            guard let hit = hits.first else { return nil }
            return MeshHit(position: hit.position, distance: hit.distance, cameraPosition: camera)
        }

        /// Raycasts through the centre of the view.
        public func raycastCenter(maxDistance: Float = 10) -> MeshHit? {
            raycast(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY), maxDistance: maxDistance)
        }

        /// The reconstructed mesh within `radius` metres of `point`, in world coordinates, plus the heights of
        /// nearby vertices ARKit classified as floor.
        public func meshSnapshot(around point: SIMD3<Float>, radius: Float) -> (mesh: Mesh, floorHeights: [Float]) {
            var mesh = Mesh.empty
            var floor: [Float] = []
            let anchors = view.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
            for anchor in anchors {
                let origin = anchor.transform.columns.3
                // Mesh anchors cover a few metres; skip ones that cannot reach the crop.
                guard simd_distance(SIMD3(origin.x, origin.y, origin.z), point) < radius + 5 else { continue }
                let (part, partFloor) = Self.extract(anchor)
                mesh.append(part)
                floor += partFloor
            }
            return (mesh, floor)
        }

        /// Copies an anchor's geometry out of its Metal buffers into world coordinates.
        static func extract(_ anchor: ARMeshAnchor) -> (Mesh, [Float]) {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let vertices = geometry.vertices
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            var positions: [SIMD3<Float>] = []
            positions.reserveCapacity(vertices.count)
            for i in 0..<vertices.count {
                let local = vertexBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let world = transform * SIMD4(local[0], local[1], local[2], 1)
                positions.append(SIMD3(world.x, world.y, world.z))
            }

            let faces = geometry.faces
            let indexCount = faces.count * faces.indexCountPerPrimitive
            let faceBase = faces.buffer.contents()
            var indices: [UInt32] = []
            indices.reserveCapacity(indexCount)
            for i in 0..<indexCount {
                if faces.bytesPerIndex == 2 {
                    indices.append(UInt32(faceBase.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee))
                } else {
                    indices.append(faceBase.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee)
                }
            }

            var floor: [Float] = []
            if let classification = geometry.classification {
                let base = classification.buffer.contents().advanced(by: classification.offset)
                for face in 0..<faces.count {
                    let value = base.advanced(by: face * classification.stride).assumingMemoryBound(to: UInt8.self)
                        .pointee
                    guard value == UInt8(ARMeshClassification.floor.rawValue) else { continue }
                    let first = Int(indices[face * 3])
                    floor.append(positions[first].y)
                }
            }
            return (Mesh(positions: positions, indices: indices), floor)
        }
    }

    /// The result of measuring a trunk: the analysis, the cropped evidence mesh and its GLB bytes.
    public struct TrunkCapture: Sendable {
        public var analysis: TrunkAnalysis.Result
        /// Cropped mesh, centred on the hit point.
        public var evidence: Mesh
        public var glb: Data
        public var cropRadius: Double
        /// World position of the trunk centre at ground level.
        public var trunkBase: SIMD3<Float>
        public var cameraPosition: SIMD3<Float>
    }

    extension CaptureSession {
        public nonisolated static let trunkCropRadius: Float = 1.5

        /// Measures the trunk at the centre of the view: raycast, snapshot, crop, fit, encode.
        public func measureTrunk(northAligned: Bool? = nil) async throws -> TrunkCapture {
            guard let hit = raycastCenter(maxDistance: 6) else { throw CaptureError.noSurface }
            let (world, floorHeights) = meshSnapshot(around: hit.position, radius: Self.trunkCropRadius + 0.5)
            let aligned = northAligned ?? isNorthAligned
            return try await Task.detached(priority: .userInitiated) {
                try Self.analyse(world: world, floorHeights: floorHeights, hit: hit, northAligned: aligned)
            }.value
        }

        nonisolated static func analyse(
            world: Mesh, floorHeights: [Float], hit: MeshHit, northAligned: Bool
        ) throws
            -> TrunkCapture
        {
            let radius = trunkCropRadius
            let cropped = world.cropped(around: hit.position, radius: radius, below: 3, above: 4)
            guard cropped.triangleCount > 50 else { throw CaptureError.notEnoughMesh }
            let ground: Double
            if !floorHeights.isEmpty {
                let sorted = floorHeights.map { Double($0 - hit.position.y) }.sorted()
                ground = sorted[sorted.count / 2]
            } else if let estimate = cropped.groundHeight(near: .zero, radius: 1.0) {
                ground = estimate
            } else {
                throw CaptureError.noGround
            }
            let analysis = try TrunkAnalysis().measure(cropped, groundHeight: ground, northAligned: northAligned)
            let base = hit.position + SIMD3(Float(analysis.center.x), Float(ground), Float(analysis.center.y))
            return TrunkCapture(
                analysis: analysis,
                evidence: cropped,
                glb: try GLB.data(for: cropped),
                cropRadius: Double(radius),
                trunkBase: base,
                cameraPosition: hit.cameraPosition
            )
        }

        /// The mesh around a point (for limb evidence), cropped and encoded.
        public func captureLimb(at hit: MeshHit, radius: Float = 1.0) throws -> (mesh: Mesh, glb: Data) {
            let (world, _) = meshSnapshot(around: hit.position, radius: radius)
            let cropped = world.cropped(around: hit.position, radius: radius, below: radius, above: radius)
            guard !cropped.isEmpty else { throw CaptureError.notEnoughMesh }
            return (cropped, try GLB.data(for: cropped))
        }

        /// Ground height under a world point, from floor-classified mesh or the low vertices nearby.
        public func groundHeight(under point: SIMD3<Float>) -> Float? {
            let (world, floor) = meshSnapshot(around: point, radius: 3)
            let nearbyFloor = floor.filter { $0 < point.y }
            if !nearbyFloor.isEmpty {
                return nearbyFloor.sorted()[nearbyFloor.count / 2]
            }
            return world.groundHeight(near: SIMD2(point.x, point.z), radius: 2).map(Float.init)
        }
    }

    public enum CaptureError: Error, Equatable {
        /// Nothing in the mesh under the centre of the view.
        case noSurface
        case notEnoughMesh
        case noGround
    }
#endif
