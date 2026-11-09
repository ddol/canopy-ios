import CanopyCapture
import CanopyMap
import CanopyModel
import CanopyStore
import Foundation

/// A tree's rings aligned against its scans after the AR session (`ScanAlignmentScreen`): kept on the phone by scan
/// (`LocalStore.saveScanAlignment`), and drawn as the tree's shape in AR and on the 3D map.
extension AppModel {
    /// The launch argument that records a synthetic trunk scan on the first tree, for UI tests of the alignment screen
    /// on a simulator, which cannot scan.
    static let seedScanArgument = "-canopy.seedScan"

    /// Draws every tree with saved rings in them, the latest saved for each tree.
    func loadAlignments() async {
        guard let saved = try? await store.scanAlignments(ScanAlignment.self) else { return }
        for alignment in saved {
            treeProfiles[MapLayers.censusWireframeID(alignment.treeID)] = alignment.profile
        }
    }

    /// What was saved for a scan, if anything.
    func alignment(for scan: BlobRef) async -> ScanAlignment? {
        try? await store.scanAlignment(ScanAlignment.self, scan: scan)
    }

    /// Saves an alignment, replacing what was saved for its scan, and draws the tree in its rings from now on.
    @discardableResult
    func saveAlignment(_ alignment: ScanAlignment) async -> Bool {
        do {
            try await store.saveScanAlignment(
                alignment, scan: alignment.scan, subject: alignment.treeID, savedAt: alignment.savedAt)
            treeProfiles[MapLayers.censusWireframeID(alignment.treeID)] = alignment.profile
            return true
        } catch {
            self.error = "Could not save the rings: \(error.localizedDescription)"
            return false
        }
    }

    /// Gerardus's trees in the loaded sites within `radius` metres of a census tree, nearest first.
    func vectorTrees(near tree: Tree, within radius: Double = 15) -> [NearbyVectorTree] {
        let sites = loadedVectors.keys.sorted().compactMap { token in
            loadedVectors[token].map { (features: $0.vectors.features, georeference: $0.georeference) }
        }
        return GerardusTree.near(tree.position.geo, in: sites, within: radius)
    }

    /// The shape the census knows of a tree, to start its rings from when none were fitted: its DBH and height when
    /// measured, a middling tree otherwise (or when the tree is no longer on the map).
    static func knownForm(_ tree: Tree?) -> TreeForm {
        var form =
            tree?.dbh.map(TreeForm.init(dbh:)) ?? TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5)
        if let height = tree?.height?.height.value {
            form.height = height
            form.crownHeight = height * 2 / 3
        }
        return form.clamped
    }

    #if DEBUG || TESTING_TOOLS
        /// Under UI tests with `seedScanArgument`, measures the first tree with a synthetic trunk scan, once.
        func seedScanIfAsked(arguments: [String] = ProcessInfo.processInfo.arguments) async {
            guard Self.isTesting(arguments), arguments.contains(Self.seedScanArgument), scanCount == 0,
                let tree = census.trees.values.min(by: { $0.id.uuidString < $1.id.uuidString })
            else { return }
            let mesh = Self.syntheticTrunkScan()
            guard let glb = try? GLB.data(for: mesh) else { return }
            await saveTrunkMeasurement(
                dbh: DBH(diameter: Quantity(0.5, uncertainty: 0.006), method: .lidarCircleFit), lean: nil, glb: glb,
                evidenceMesh: (mesh.vertexCount, mesh.triangleCount), cropRadius: 0.85, tree: tree,
                position: tree.position)
        }

        /// A trunk 0.5 m across scanned most of the way round, standing on flat ground 1.3 m below where the scan
        /// started, as `TrunkScan` crops evidence.
        static func syntheticTrunkScan(radius: Double = 0.25, ground: Double = -1.3, top: Double = 2.7) -> Mesh {
            var mesh = Mesh.empty
            let spacing = 0.04
            let rows = Int((top - ground) / spacing)
            let columns = Int(1.6 * .pi * radius / spacing)
            for row in 0...rows {
                let y = ground + Double(row) * spacing
                for column in 0...columns {
                    // 290° of the trunk, from the north-west round by the south.
                    let angle = (-35 + 290 * Double(column) / Double(columns)) * .pi / 180
                    mesh.positions.append(SIMD3(Float(cos(angle) * radius), Float(y), Float(sin(angle) * radius)))
                }
            }
            let width = UInt32(columns + 1)
            for row in 0..<UInt32(rows) {
                for column in 0..<UInt32(columns) {
                    let a = row * width + column
                    mesh.indices += [a, a + width, a + 1, a + 1, a + width, a + width + 1]
                }
            }
            var floor = Mesh.empty
            let cells = 10
            for i in 0...cells {
                for j in 0...cells {
                    let x = -0.85 + 1.7 * Double(i) / Double(cells)
                    let z = -0.85 + 1.7 * Double(j) / Double(cells)
                    floor.positions.append(SIMD3(Float(x), Float(ground), Float(z)))
                }
            }
            let side = UInt32(cells + 1)
            for i in 0..<UInt32(cells) {
                for j in 0..<UInt32(cells) {
                    let a = i * side + j
                    floor.indices += [a, a + 1, a + side, a + 1, a + side + 1, a + side]
                }
            }
            mesh.append(floor)
            return mesh
        }
    #endif
}
