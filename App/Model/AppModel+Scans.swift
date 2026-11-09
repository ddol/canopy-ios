import CanopyCapture
import CanopyMap
import CanopyModel
import Foundation

extension AppModel {
    /// The picture of an evidence mesh for the lists of scans (`ScanPreview`: the colourless geometry from a fixed
    /// three-quarter view), rendered off the main actor the first time it is asked for and kept by the blob's hash.
    /// Nil while the mesh is not on this device: a scan from another device until it is downloaded.
    func scanPreview(_ ref: BlobRef) async throws -> URL? {
        if let cached = scanPreviews.cached(ref) { return cached }
        let blobs = store.blobs
        guard blobs.contains(ref) else { return nil }
        return try await scanPreviews.preview(for: ref) { try blobs.data(for: ref) }
    }

    /// Goes to the Map tab, where `MapScreen` centres on the tree and selects it.
    func showOnMap(_ tree: Tree) {
        mapTarget = tree.id
        section = .map
    }
}

extension MapViewport {
    /// How close the map comes to show one tree: its tile is drawn in full, with the trees round it.
    static let treeRadius = 80.0
    /// How far north of the region's middle the tree is put. The map centres the region below the summary bar, and the
    /// tree's sheet opens over the lower half, so on a phone this puts the tree in the open map between them.
    static let treeOffset = 60.0

    /// The region that shows `point` above the middle, where the tree sheet that opens on it leaves it in view.
    static func showing(_ point: GeoPoint) -> MapViewport {
        let frame = LocalFrame(origin: point)
        let centre = frame.geoPoint(of: ENU(east: 0, north: -treeOffset, up: 0)).point
        return MapViewport(center: centre, radius: treeRadius)
    }
}

#if DEBUG || TESTING_TOOLS
    extension AppModel {
        /// Records a synthetic trunk scan of the first fixture tree, for UI tests and for trying the scans in the
        /// simulator, which cannot scan. Your scans calls it when launched with `-canopy.sampleScan YES` and there are
        /// no scans yet.
        func addSampleScan() async {
            guard let id = try? ParkFixtures.candidates().first?.id, let tree = tree(id) else { return }
            let mesh = Self.sampleTrunk()
            guard let glb = try? GLB.data(for: mesh) else { return }
            await saveTrunkMeasurement(
                dbh: DBH(diameter: Quantity(0.6, uncertainty: 0.01), method: .lidarCircleFit), lean: nil, glb: glb,
                evidenceMesh: (mesh.vertexCount, mesh.triangleCount), cropRadius: 1.2, tree: tree,
                position: tree.position)
        }

        /// A trunk 0.6 m across and 2.5 m tall, standing on a square of ground 2.4 m across.
        static func sampleTrunk() -> Mesh {
            var mesh = Mesh.empty
            let segments = 48
            let rings = 25
            for ring in 0...rings {
                for segment in 0..<segments {
                    let angle = 2 * Float.pi * Float(segment) / Float(segments)
                    mesh.positions.append(SIMD3(0.3 * cos(angle), 0.1 * Float(ring), 0.3 * sin(angle)))
                }
            }
            for ring in 0..<rings {
                for segment in 0..<segments {
                    let a = UInt32(ring * segments + segment)
                    let b = UInt32(ring * segments + (segment + 1) % segments)
                    let (c, d) = (a + UInt32(segments), b + UInt32(segments))
                    mesh.indices += [a, c, b, b, c, d]
                }
            }
            let ground = UInt32(mesh.positions.count)
            mesh.positions += [SIMD3(-1.2, 0, -1.2), SIMD3(1.2, 0, -1.2), SIMD3(1.2, 0, 1.2), SIMD3(-1.2, 0, 1.2)]
            mesh.indices += [0, 2, 1, 0, 3, 2].map { ground + $0 }
            return mesh
        }
    }
#endif
