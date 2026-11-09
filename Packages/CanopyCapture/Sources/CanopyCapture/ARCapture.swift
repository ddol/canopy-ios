#if os(iOS)
    import ARKit
    import CanopyModel
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
    /// mesh, trunk scans, aligning trunk rings to the camera, and mesh snapshots for evidence. Camera frames stay
    /// inside ARKit except while rings are being aligned (`startAligning`): then the brightness along short lines
    /// across each ring's edges is read from the frame in place, and only the edges' lines are kept. Nothing here
    /// copies, stores or sends an image.
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
        /// Raw depth points round the trunk while a scan runs; nil on a device without scene depth.
        @ObservationIgnored private var depth: DepthAccumulator?
        @ObservationIgnored private var lastDepthIngest: TimeInterval = 0
        @ObservationIgnored private var refreshTask: Task<Void, Never>?
        @ObservationIgnored private let overlayAnchor = AnchorEntity(world: .zero)
        @ObservationIgnored private let overlay = ModelEntity()
        @ObservationIgnored private var wireLayers: [String: Entity] = [:]
        @ObservationIgnored private var pickable: [String: (entity: ModelEntity, material: UnlitMaterial)] = [:]
        @ObservationIgnored private var highlighted: String?
        /// Where the wireframe tree being fitted stands (trunk base, on the ground), while one is shown.
        public private(set) var treeBase: SIMD3<Float>?
        /// Whether trunk rings are being aligned to the camera image.
        public private(set) var isAligning = false
        /// The rings being aligned.
        public private(set) var aligningRings: Set<UUID> = []
        /// The latest fit of each ring being aligned that the camera has found the edges of.
        public private(set) var ringFits: [UUID: RingAligner.Fit] = [:]
        @ObservationIgnored private var aligner: RingAligner?
        @ObservationIgnored private var lastAlignment: TimeInterval = 0

        /// Minimum time between two ingests of the same mesh anchor, in seconds.
        static let ingestInterval: TimeInterval = 0.3
        /// Minimum time between two depth frames taken into a scan, in seconds.
        static let depthInterval: TimeInterval = 0.2
        /// Minimum time between two camera frames read for ring edges, in seconds.
        static let alignmentInterval: TimeInterval = 0.25

        public override init() {
            view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
            super.init()
            view.renderOptions.insert(.disableMotionBlur)
            view.environment.sceneUnderstanding.options = [.collision, .occlusion]
            view.debugOptions.insert(.showSceneUnderstanding)
            view.session.delegate = self
            overlayAnchor.addChild(overlay)
            view.scene.addAnchor(overlayAnchor)
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
            pan.addTarget(self, action: #selector(handlePan))
            pan.maximumNumberOfTouches = 1
            pan.isEnabled = false
            view.addGestureRecognizer(pan)
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
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
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

        /// The camera's pose in world coordinates, if tracking.
        public var cameraTransform: simd_float4x4? {
            guard let frame = view.session.currentFrame, case .normal = frame.camera.trackingState else { return nil }
            return frame.camera.transform
        }

        /// Where a world point is in the view, in points; nil when it is not in front of the camera.
        public func project(_ point: SIMD3<Float>) -> CGPoint? {
            view.project(point)
        }

        /// The view's bounds, the frame `project` answers in.
        public var viewBounds: CGRect { view.bounds }

        /// The ray from the camera through a point in the view, in world coordinates.
        public func ray(through point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
            view.ray(through: point)
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
            depth = DepthAccumulator(
                center: hit.position, radius: TrunkScan.radius, below: TrunkScan.below, above: TrunkScan.above)
            lastDepthIngest = 0
            scan = Scan(center: hit.position, progress: ScanProgress(triangleCount: 0))
            for anchor in view.session.currentFrame?.anchors ?? [] {
                if let mesh = anchor as? ARMeshAnchor {
                    ingest(mesh, force: true)
                }
            }
            if let frame = view.session.currentFrame { ingestDepth(frame) }
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
            depth = nil
            scan = nil
            overlay.model = nil
        }

        /// Measures the trunk from everything the scan has captured. The scan keeps running, so the player can carry
        /// on and measure again; call `cancelScan()` when done.
        public func finishScan() async throws -> TrunkCapture {
            guard let accumulator, let scan else { throw CaptureError.notScanning }
            let camera = cameraPosition ?? scan.center
            let aligned = isNorthAligned
            let depth = self.depth
            return try await Task.detached(priority: .userInitiated) {
                try TrunkScan.analyse(
                    world: accumulator.mesh(), points: depth?.points() ?? [], floorHeights: accumulator.floorHeights(),
                    center: scan.center, camera: camera, northAligned: aligned)
            }.value
        }

        /// Recomputes the overlay and the progress from the accumulated mesh, off the main actor.
        private func refresh() async {
            guard let accumulator, let center = scan?.center else { return }
            let depth = self.depth
            let (mesh, progress) = await Task.detached(priority: .utility) {
                let mesh = accumulator.mesh()
                return (
                    mesh,
                    TrunkScan.progress(
                        world: mesh, points: depth?.points() ?? [], floorHeights: accumulator.floorHeights(),
                        center: center)
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

        // MARK: Wireframes

        /// Draws a layer of wireframes in the world, replacing the layer of that name. Items with a pick box can be
        /// found with `pickWireframe(at:)`; the rest are batched into one model.
        public func showWireframes(_ layer: WireframeLayer) {
            hideWireframes(named: layer.name)
            let root = Entity()
            root.name = layer.name
            let color = UIColor(
                red: CGFloat(layer.color.x), green: CGFloat(layer.color.y), blue: CGFloat(layer.color.z),
                alpha: CGFloat(layer.color.w))
            let material = Self.wireMaterial(color, throughWalls: layer.throughWalls)
            var batched: [Wireframe.Segment] = []
            for item in layer.items {
                guard let box = item.pickBox else {
                    batched += item.segments
                    continue
                }
                guard let model = Self.wireModel(item.segments, width: layer.lineWidth, material: material) else {
                    continue
                }
                let entity = ModelEntity()
                entity.name = item.id
                entity.model = model
                entity.collision = CollisionComponent(
                    shapes: [.generateBox(size: box.size).offsetBy(translation: box.centre)],
                    filter: CollisionFilter(group: Self.pickGroup, mask: .all))
                root.addChild(entity)
                pickable[item.id] = (entity, material)
            }
            if let model = Self.wireModel(batched, width: layer.lineWidth, material: material) {
                let entity = ModelEntity()
                entity.model = model
                root.addChild(entity)
            }
            overlayAnchor.addChild(root)
            wireLayers[layer.name] = root
            if let highlighted, pickable[highlighted] != nil { highlightWireframe(id: highlighted) }
        }

        /// Takes a layer down.
        public func hideWireframes(named name: String) {
            guard let root = wireLayers.removeValue(forKey: name) else { return }
            for child in root.children {
                guard !child.name.isEmpty, pickable[child.name]?.entity == child else { continue }
                pickable[child.name] = nil
            }
            root.removeFromParent()
        }

        /// The pickable wireframe item under a point in the view, nearest first.
        public func pickWireframe(at point: CGPoint) -> String? {
            guard let ray = view.ray(through: point) else { return nil }
            let hits = view.scene.raycast(
                origin: ray.origin, direction: ray.direction, length: 300, query: .all, mask: Self.pickGroup,
                relativeTo: nil)
            return hits.sorted { $0.distance < $1.distance }.lazy.compactMap { hit -> String? in
                let name = hit.entity.name
                return self.pickable[name]?.entity == hit.entity ? name : nil
            }.first
        }

        /// Draws one pickable item in the selection colour (orange), and the one before as it was.
        public func highlightWireframe(id: String?) {
            if let previous = highlighted, previous != id, let (entity, material) = pickable[previous] {
                entity.model?.materials = [material]
            }
            highlighted = id
            guard let id, let (entity, _) = pickable[id] else { return }
            entity.model?.materials = [
                Self.wireMaterial(UIColor(red: 0.94, green: 0.54, blue: 0.14, alpha: 1), throughWalls: true)
            ]
        }

        /// A tap in the view. Each tap is a new value, so observers see taps on the same spot.
        public struct Tap: Equatable, Sendable {
            public var point: CGPoint
            public var sequence: Int
        }

        /// The last tap in the view, for the screen to pick wireframes with.
        public private(set) var lastTap: Tap?

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            lastTap = Tap(point: gesture.location(in: view), sequence: (lastTap?.sequence ?? 0) + 1)
        }

        /// A one-finger drag in the view, while `acceptsDrags` is on. Each step is a new value.
        public struct Drag: Equatable, Sendable {
            public var point: CGPoint
            public var sequence: Int
            /// The finger has lifted (or the drag was cancelled).
            public var ended: Bool
        }

        /// The last step of a drag in the view, for moving a tree with a finger.
        public private(set) var lastDrag: Drag?

        /// Whether drags in the view are reported in `lastDrag`: only while a tree is being moved, so taps pick
        /// wireframes as before.
        @ObservationIgnored public var acceptsDrags = false {
            didSet { pan.isEnabled = acceptsDrags }
        }

        @ObservationIgnored private let pan = UIPanGestureRecognizer()

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed, .ended, .cancelled:
                lastDrag = Drag(
                    point: gesture.location(in: view), sequence: (lastDrag?.sequence ?? 0) + 1,
                    ended: gesture.state == .ended || gesture.state == .cancelled)
            default:
                break
            }
        }

        static let pickGroup = CollisionGroup(rawValue: 1 << 8)

        private static func wireMaterial(_ color: UIColor, throughWalls: Bool) -> UnlitMaterial {
            var material = UnlitMaterial(color: color)
            material.faceCulling = .none
            if throughWalls {
                material.blending = .transparent(opacity: 0.9)
                material.readsDepth = false
            }
            return material
        }

        private static func wireModel(
            _ segments: [Wireframe.Segment], width: Float, material: UnlitMaterial
        ) -> ModelComponent? {
            let mesh = Wireframe.mesh(segments, width: width)
            guard !mesh.isEmpty else { return nil }
            var descriptor = MeshDescriptor(name: "wireframe")
            descriptor.positions = MeshBuffer(mesh.positions)
            descriptor.primitives = .triangles(mesh.indices)
            guard let resource = try? MeshResource.generate(from: [descriptor]) else { return nil }
            return ModelComponent(mesh: resource, materials: [material])
        }

        // MARK: Fitted tree

        /// Stands the wireframe tree being fitted with its trunk base at `base` (a world point on the ground),
        /// replacing any shown before. Trunk brown and crown green, as the Mac visualiser draws them, through whatever
        /// is in front.
        public func showTree(_ form: TreeForm, lean: Lean? = nil, at base: SIMD3<Float>) {
            showTree(TreeProfile(form: form), lean: lean, at: base)
        }

        /// The fitted tree as a profile of rings, with the ring being edited drawn in the highlight colour.
        public func showTree(
            _ profile: TreeProfile, lean: Lean? = nil, at base: SIMD3<Float>, highlight: TreeSection.ID? = nil
        ) {
            let figure = WireframeTree.figure(profile, lean: lean, at: base, highlight: highlight, marking: true)
            showWireframes(
                WireframeLayer(
                    name: Self.fitTrunkLayer, items: [WireframeItem(id: "fit-trunk", segments: figure.trunk)],
                    color: Self.trunkColor, throughWalls: true))
            showWireframes(
                WireframeLayer(
                    name: Self.fitCrownLayer, items: [WireframeItem(id: "fit-crown", segments: figure.crown)],
                    color: Self.crownColor, throughWalls: true))
            for source in TreeSection.Source.allCases where source != .eye {
                let name = Self.fitMarkLayer + source.rawValue
                guard let segments = figure.marked[source], !segments.isEmpty else {
                    hideWireframes(named: name)
                    continue
                }
                showWireframes(
                    WireframeLayer(
                        name: name, items: [WireframeItem(id: name, segments: segments)],
                        color: Self.color(for: source), throughWalls: true))
            }
            if figure.highlighted.isEmpty {
                hideWireframes(named: Self.fitHighlightLayer)
            } else {
                showWireframes(
                    WireframeLayer(
                        name: Self.fitHighlightLayer,
                        items: [WireframeItem(id: "fit-highlight", segments: figure.highlighted)],
                        color: Self.highlightColor, lineWidth: WireframeTree.lineWidth * 2, throughWalls: true))
            }
            treeBase = base
        }

        /// Takes the fitted tree down.
        public func hideTree() {
            hideWireframes(named: Self.fitTrunkLayer)
            hideWireframes(named: Self.fitCrownLayer)
            hideWireframes(named: Self.fitHighlightLayer)
            for source in TreeSection.Source.allCases {
                hideWireframes(named: Self.fitMarkLayer + source.rawValue)
            }
            treeBase = nil
        }

        static let fitTrunkLayer = "fit-trunk"
        static let fitCrownLayer = "fit-crown"
        static let fitHighlightLayer = "fit-highlight"
        static let fitMarkLayer = "fit-ring-"
        /// The ring being edited: the survey orange.
        public static let highlightColor = SIMD4<Float>(1.0, 0.62, 0.25, 1)
        /// The Mac visualiser's tree colours.
        public static let trunkColor = SIMD4<Float>(0.70, 0.48, 0.28, 1)
        public static let crownColor = SIMD4<Float>(0.55, 0.95, 0.30, 1)
        /// Rings fitted to the scan: the scan's lime. Aligned to the camera: blue. Confirmed: the brand green.
        public static let scanRingColor = SIMD4<Float>(0.61, 0.82, 0.29, 1)
        public static let cameraRingColor = SIMD4<Float>(0.50, 0.70, 1.0, 1)
        public static let confirmedRingColor = SIMD4<Float>(0.44, 0.75, 0.50, 1)

        static func color(for source: TreeSection.Source) -> SIMD4<Float> {
            switch source {
            case .eye: trunkColor
            case .scan: scanRingColor
            case .camera: cameraRingColor
            case .confirmed: confirmedRingColor
            }
        }

        // MARK: Aligning rings to the camera

        /// Starts aligning rings to the trunk's edges in the camera image. A few times a second, while tracking is
        /// good, each ring's edges are looked for in the frame near where they should fall, from the brightness
        /// along short lines across them, read in place; only the lines past the edges are kept (`RingAligner`).
        /// `ringFits` follows as the player walks round.
        public func startAligning(_ aligner: RingAligner) {
            self.aligner = aligner
            aligningRings = Set(aligner.targets.map(\.id))
            ringFits = [:]
            lastAlignment = 0
            isAligning = true
        }

        public func stopAligning() {
            aligner = nil
            aligningRings = []
            ringFits = [:]
            isAligning = false
        }

        /// Stops aligning one ring, as when it is moved by hand.
        public func stopAligning(ring id: UUID) {
            guard var aligner, aligningRings.contains(id) else { return }
            aligner.remove(id)
            guard !aligner.targets.isEmpty else { return stopAligning() }
            self.aligner = aligner
            aligningRings.remove(id)
            ringFits[id] = nil
        }

        /// Reads a frame for the edges of the rings being aligned.
        private func align(_ frame: ARFrame) {
            guard var aligner, frame.timestamp - lastAlignment >= Self.alignmentInterval else { return }
            guard case .normal = frame.camera.trackingState else { return }
            lastAlignment = frame.timestamp
            let resolution = frame.camera.imageResolution
            let camera = CameraPose(
                intrinsics: frame.camera.intrinsics, transform: frame.camera.transform,
                imageSize: SIMD2(Int(resolution.width), Int(resolution.height)))
            let found = LumaPlane.read(frame.capturedImage) { aligner.add(camera, image: $0) } ?? 0
            self.aligner = aligner
            if found > 0 { ringFits = aligner.fits }
        }

        // MARK: Session delegate

        public nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            MainActor.assumeIsolated { receive(anchors) }
        }

        public nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            MainActor.assumeIsolated { receive(anchors) }
        }

        public nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            MainActor.assumeIsolated {
                ingestDepth(frame)
                align(frame)
            }
        }

        /// Adds a frame's LiDAR depth to the scan, a few times a second, while tracking is good.
        private func ingestDepth(_ frame: ARFrame) {
            guard var depth, let sceneDepth = frame.sceneDepth else { return }
            guard frame.timestamp - lastDepthIngest >= Self.depthInterval else { return }
            guard case .normal = frame.camera.trackingState else { return }
            lastDepthIngest = frame.timestamp
            let (values, width, height) = Self.floats(sceneDepth.depthMap)
            guard width > 0 else { return }
            let confidence = sceneDepth.confidenceMap.map { Self.bytes($0).0 }
            let image = frame.camera.imageResolution
            let intrinsics = DepthFrame.intrinsics(
                frame.camera.intrinsics, from: SIMD2(Float(image.width), Float(image.height)),
                to: SIMD2(Float(width), Float(height)))
            depth.add(
                DepthFrame.unproject(
                    depth: values, confidence: confidence, width: width, height: height, intrinsics: intrinsics,
                    cameraTransform: frame.camera.transform))
            self.depth = depth
        }

        /// A 32-bit float pixel buffer's values, row-major, with its size.
        static func floats(_ buffer: CVPixelBuffer) -> ([Float], Int, Int) {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return ([], 0, 0) }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return ([], 0, 0) }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var values = [Float](repeating: 0, count: width * height)
            for row in 0..<height {
                let source = base.advanced(by: row * stride).assumingMemoryBound(to: Float.self)
                for column in 0..<width { values[row * width + column] = source[column] }
            }
            return (values, width, height)
        }

        /// The luma (brightness) plane of a captured image, read in place while its buffer is locked: never copied.
        struct LumaPlane: LumaSource {
            let base: UnsafeRawPointer
            let width: Int
            let height: Int
            let bytesPerRow: Int

            func luma(x: Int, y: Int) -> UInt8 {
                base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)
            }

            /// Runs `body` on a bi-planar YCbCr image's luma plane while the buffer is locked; nil for another
            /// format.
            static func read<T>(_ buffer: CVPixelBuffer, _ body: (LumaPlane) -> T) -> T? {
                let format = CVPixelBufferGetPixelFormatType(buffer)
                guard
                    format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                        || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    CVPixelBufferGetPlaneCount(buffer) >= 1
                else { return nil }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
                return body(
                    LumaPlane(
                        base: UnsafeRawPointer(base), width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                        height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                        bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)))
            }
        }

        /// An 8-bit pixel buffer's values, row-major, with its size.
        static func bytes(_ buffer: CVPixelBuffer) -> ([UInt8], Int, Int) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return ([], 0, 0) }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var values = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                let source = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<width { values[row * width + column] = source[column] }
            }
            return (values, width, height)
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

        /// Every vertex of the reconstructed mesh within `range` metres (horizontally) of the session origin, in world
        /// coordinates: the surroundings to register against aerial data. Geometry only.
        public func worldPoints(range: Float = 60) -> [SIMD3<Float>] {
            let anchors = view.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
            var points: [SIMD3<Float>] = []
            for anchor in anchors {
                let transform = anchor.transform
                let origin = transform.columns.3
                guard origin.x * origin.x + origin.z * origin.z < (range + 5) * (range + 5) else { continue }
                let (local, _) = Self.extractLocal(anchor)
                for p in local.positions {
                    let w = transform * SIMD4(p, 1)
                    guard w.x * w.x + w.z * w.z <= range * range else { continue }
                    points.append(SIMD3(w.x, w.y, w.z))
                }
            }
            return points
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
