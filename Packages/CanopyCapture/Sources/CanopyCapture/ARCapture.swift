#if os(iOS)
    import ARKit
    import Foundation
    import Observation
    import RealityKit
    import UIKit
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
    /// mesh, trunk scans, and mesh snapshots for evidence. Camera frames stay inside ARKit; nothing here reads or
    /// keeps an image.
    @MainActor
    @Observable
    public final class CaptureSession: NSObject, ARSessionDelegate {
        /// A trunk scan in progress.
        public struct Scan: Equatable, Sendable {
            /// The point on the trunk where the scan started.
            public var center: SIMD3<Float>
            public var progress: ScanProgress
        }

        @ObservationIgnored public let view: ARView
        /// True once the session runs with gravity-and-heading alignment (−z is true north).
        public private(set) var isNorthAligned = false
        /// The trunk scan in progress, if any.
        public private(set) var scan: Scan?

        @ObservationIgnored private var hasRun = false
        @ObservationIgnored private var accumulator: MeshAccumulator?
        @ObservationIgnored private var lastIngest: [UUID: TimeInterval] = [:]
        @ObservationIgnored private var refreshTask: Task<Void, Never>?
        @ObservationIgnored private let overlayAnchor = AnchorEntity(world: .zero)
        @ObservationIgnored private let overlay = ModelEntity()

        /// Minimum time between two ingests of the same mesh anchor, in seconds.
        static let ingestInterval: TimeInterval = 0.3

        public override init() {
            view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
            super.init()
            view.renderOptions.insert(.disableMotionBlur)
            view.environment.sceneUnderstanding.options = [.collision, .occlusion]
            view.debugOptions.insert(.showSceneUnderstanding)
            view.session.delegate = self
            overlayAnchor.addChild(overlay)
            view.scene.addAnchor(overlayAnchor)
        }

        /// Starts the session, or resumes it with the mesh and any scan it already has.
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
            view.session.run(configuration, options: hasRun ? [] : [.resetTracking, .removeExistingAnchors])
            hasRun = true
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

        // MARK: Trunk scans

        /// Starts scanning the trunk under the centre of the view (within 6 m). While the scan runs, the most
        /// detailed version of every part of the mesh around the trunk is kept and drawn in lime, and `scan.progress`
        /// says how much of the circumference is covered.
        public func startScan() throws {
            guard let hit = raycastCenter(maxDistance: 6) else { throw CaptureError.noSurface }
            accumulator = MeshAccumulator(
                center: hit.position, radius: TrunkScan.radius, below: TrunkScan.below, above: TrunkScan.above)
            lastIngest = [:]
            scan = Scan(center: hit.position, progress: ScanProgress(triangleCount: 0))
            for anchor in view.session.currentFrame?.anchors ?? [] {
                if let mesh = anchor as? ARMeshAnchor {
                    ingest(mesh, force: true)
                }
            }
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        /// Stops the scan and forgets what it captured.
        public func cancelScan() {
            refreshTask?.cancel()
            refreshTask = nil
            accumulator = nil
            scan = nil
            overlay.model = nil
        }

        /// Measures the trunk from everything the scan has captured. The scan keeps running, so the player can carry
        /// on and measure again; call `cancelScan()` when done.
        public func finishScan() async throws -> TrunkCapture {
            guard let accumulator, let scan else { throw CaptureError.notScanning }
            let camera = cameraPosition ?? scan.center
            let aligned = isNorthAligned
            return try await Task.detached(priority: .userInitiated) {
                try TrunkScan.analyse(
                    world: accumulator.mesh(), floorHeights: accumulator.floorHeights(), center: scan.center,
                    camera: camera, northAligned: aligned)
            }.value
        }

        /// Recomputes the overlay and the progress from the accumulated mesh, off the main actor.
        private func refresh() async {
            guard let accumulator, let center = scan?.center else { return }
            let (mesh, progress) = await Task.detached(priority: .utility) {
                let mesh = accumulator.mesh()
                return (
                    mesh,
                    TrunkScan.progress(world: mesh, floorHeights: accumulator.floorHeights(), center: center)
                )
            }.value
            guard self.scan?.center == center else { return }  // cancelled or restarted meanwhile
            self.scan?.progress = progress
            drawOverlay(mesh)
        }

        private func drawOverlay(_ mesh: Mesh) {
            guard !mesh.isEmpty, mesh.triangleCount <= 150_000 else { return }
            var descriptor = MeshDescriptor(name: "scan")
            descriptor.positions = MeshBuffer(mesh.positions)
            descriptor.primitives = .triangles(mesh.indices)
            guard let resource = try? MeshResource.generate(from: [descriptor]) else { return }
            var material = UnlitMaterial(color: UIColor(red: 0.61, green: 0.82, blue: 0.29, alpha: 1))
            material.blending = .transparent(opacity: 0.45)
            material.faceCulling = .none
            overlay.model = ModelComponent(mesh: resource, materials: [material])
        }

        // MARK: Session delegate

        public nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            MainActor.assumeIsolated { receive(anchors) }
        }

        public nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            MainActor.assumeIsolated { receive(anchors) }
        }

        private func receive(_ anchors: [ARAnchor]) {
            guard accumulator != nil else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    ingest(mesh, force: false)
                }
            }
        }

        /// Adds an anchor's current geometry to the scan, if it can reach the scan region.
        private func ingest(_ anchor: ARMeshAnchor, force: Bool) {
            guard var accumulator, let center = scan?.center else { return }
            let origin = anchor.transform.columns.3
            // Mesh anchors cover a few metres; skip ones that cannot reach the region.
            guard simd_distance(SIMD3(origin.x, origin.y, origin.z), center) < TrunkScan.radius + 5 else { return }
            let now = Date.timeIntervalSinceReferenceDate
            if !force, let last = lastIngest[anchor.identifier], now - last < Self.ingestInterval { return }
            lastIngest[anchor.identifier] = now
            let (mesh, floor) = Self.extractLocal(anchor)
            accumulator.add(mesh, anchor: anchor.identifier, transform: anchor.transform, floor: floor)
            self.accumulator = accumulator
        }

        // MARK: Snapshots

        /// The reconstructed mesh from the anchors near `point`, in world coordinates, plus the heights of the
        /// faces ARKit classified as floor within `radius` metres of `point` horizontally.
        public func meshSnapshot(around point: SIMD3<Float>, radius: Float) -> (mesh: Mesh, floorHeights: [Float]) {
            var mesh = Mesh.empty
            var floor: [Float] = []
            let anchors = view.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
            for anchor in anchors {
                let origin = anchor.transform.columns.3
                guard simd_distance(SIMD3(origin.x, origin.y, origin.z), point) < radius + 5 else { continue }
                let (local, localFloor) = Self.extractLocal(anchor)
                let transform = anchor.transform
                func world(_ p: SIMD3<Float>) -> SIMD3<Float> {
                    let w = transform * SIMD4(p, 1)
                    return SIMD3(w.x, w.y, w.z)
                }
                mesh.append(Mesh(positions: local.positions.map(world), indices: local.indices))
                floor += localFloor.map(world)
                    .filter { simd_distance(SIMD2($0.x, $0.z), SIMD2(point.x, point.z)) <= radius }
                    .map(\.y)
            }
            return (mesh, floor)
        }

        /// Copies an anchor's geometry out of its Metal buffers, in anchor coordinates, with one corner of each
        /// floor-classified face.
        static func extractLocal(_ anchor: ARMeshAnchor) -> (Mesh, [SIMD3<Float>]) {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            var positions: [SIMD3<Float>] = []
            positions.reserveCapacity(vertices.count)
            for i in 0..<vertices.count {
                let local = vertexBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                positions.append(SIMD3(local[0], local[1], local[2]))
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

            var floor: [SIMD3<Float>] = []
            if let classification = geometry.classification {
                let base = classification.buffer.contents().advanced(by: classification.offset)
                for face in 0..<faces.count {
                    let value = base.advanced(by: face * classification.stride).assumingMemoryBound(to: UInt8.self)
                        .pointee
                    guard value == UInt8(ARMeshClassification.floor.rawValue) else { continue }
                    floor.append(positions[Int(indices[face * 3])])
                }
            }
            return (Mesh(positions: positions, indices: indices), floor)
        }

        // MARK: Limbs

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
#endif
