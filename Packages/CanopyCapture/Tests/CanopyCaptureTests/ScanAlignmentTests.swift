import CanopyModel
import CanopyReference
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct ScanAlignmentTests {
    /// Where the scan started: on the near side of a trunk of radius 0.3 m standing at the origin.
    let center = SIMD3<Float>(0, 1.37, -0.3)

    /// A trunk measured in AR, walked all the way round, with no raw depth points: what a saved scan holds.
    func capture() throws -> TrunkCapture {
        var world = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0, visibleDegrees: 200, facingDegrees: -90)
        world.append(
            Synthetic.scannedTrunk(
                radius: 0.3, leanDegrees: 0, visibleDegrees: 200, seed: 8, facingDegrees: 90, includeGround: false))
        return try TrunkScan.analyse(
            world: world, floorHeights: [], center: center, camera: SIMD3(0, 1.5, -2), northAligned: true)
    }

    @Test func aSavedScanReadsBackFromItsGLBWithItsGround() throws {
        let capture = try capture()
        let scan = try SavedScan(glb: capture.glb)
        #expect(scan.mesh == capture.evidence)
        // The evidence's origin is where the scan started, 1.37 m up; the ground is found again from the mesh alone.
        let ground = try #require(scan.estimatedGroundHeight)
        #expect(abs(ground - capture.groundHeight) < 0.01, "\(ground) against \(capture.groundHeight)")
        #expect(abs(ground + 1.37) < 0.02)
        #expect(abs(try #require(scan.top(groundHeight: ground)) - 3) < 0.05)
        #expect(throws: GLB.Error.notGLB) { try SavedScan(glb: Data(count: 64)) }
    }

    @Test func aRingSnapsToTheSavedScansSliceAtItsHeight() throws {
        let capture = try capture()
        let scan = try SavedScan(glb: capture.glb)
        let ground = capture.groundHeight
        let ring = try scan.snapping(TreeSection(part: .trunk, height: 2.0, radius: 0.1), groundHeight: ground)
        #expect(abs(ring.radius - 0.3) < 0.01, "\(ring.radius)")
        #expect(ring.source == .scan)
        #expect(simd_length(try #require(ring.offset)) < 0.01)
        #expect(try #require(ring.radiusUncertainty) < 0.01)
        // The same circle the AR session fits from the evidence mesh where it has no depth points.
        #expect(try scan.fitSection(at: 2.0, groundHeight: ground) == capture.fitSection(at: 2.0))
        // It stands on the trunk's axis, at its height above the scan's ground.
        let centre = WireframeTree.centre(of: ring, at: SIMD3(0, Float(ground), 0))
        #expect(abs(centre.y - Float(ground + 2.0)) < 1e-5)
        #expect(simd_length(SIMD2(centre.x, centre.z)) < 0.01)
        // Above the scan there is nothing to fit.
        #expect(throws: TrunkAnalysisError.self) {
            try scan.fitSection(at: 6, groundHeight: ground)
        }
    }

    @Test func snappingTheTrunkLeavesConfirmedRingsAndRingsAboveTheScan() throws {
        let capture = try capture()
        let scan = SavedScan(mesh: capture.evidence)
        let confirmed = TreeSection(part: .trunk, height: 1.37, radius: 0.25, source: .confirmed)
        let high = TreeSection(part: .trunk, height: 6, radius: 0.2)
        let crown = TreeSection(part: .crown, height: 7, radius: 3)
        let profile = TreeProfile(sections: [
            TreeSection(part: .trunk, height: 1, radius: 0.1), confirmed,
            TreeSection(part: .trunk, height: 2, radius: 0.5),
            high, crown,
        ])
        let (snapped, count, stems) = scan.snappingTrunk(profile, groundHeight: capture.groundHeight)
        #expect(stems == 0)
        #expect(count == 2)
        #expect(snapped.section(confirmed.id) == confirmed)
        #expect(snapped.section(high.id) == high)
        #expect(snapped.section(crown.id) == crown)
        let fitted = snapped.trunk.filter { $0.source == .scan }
        #expect(fitted.map(\.height) == [1, 2])
        #expect(fitted.allSatisfy { abs($0.radius - 0.3) < 0.01 })
    }

    @Test func anAlignmentRoundTripsThroughTheStoresJSON() throws {
        var profile = TreeProfile(form: TreeForm(trunkDiameter: 0.6, height: 12, crownHeight: 8, crownWidth: 7))
        let breast = try #require(profile.trunk.first { $0.height == 1 })
        profile[breast.id] = TreeSection(
            id: breast.id, part: .trunk, height: DBH.standardHeight, radius: 0.31, source: .scan,
            offset: SIMD2(0.012, -0.004), radiusUncertainty: 0.002)
        let alignment = ScanAlignment(
            scan: BlobRef(rawValue: String(repeating: "ab", count: 32))!, treeID: UUID(), profile: profile,
            groundHeight: -1.31,
            vectorTree: VectorTreePlacement(id: "gerardus:tree/7", drawn: SIMD2(2.5, -1), placed: SIMD2(0.1, 0)),
            correctedPosition: GeoPoint(latitude: 37.77, longitude: -122.48))
        let data = try CanopyJSON.encoder.encode(alignment)
        #expect(try CanopyJSON.decoder.decode(ScanAlignment.self, from: data) == alignment)
        #expect(alignment.trunkBase == SIMD3(0, -1.31, 0))
    }

    /// The record as the store keeps it, written out: a later version must still read rows saved by this one, so
    /// renaming a property or a case is a change to this format, not a refactor.
    @Test func anAlignmentKeepsItsStoredFormat() throws {
        let stored = """
            {"correctedPosition":{"latitude":37.77,"longitude":-122.48},"groundHeight":-1.31,\
            "profile":{"sections":[{"height":1.37,"id":"6F1C7F5A-8B11-4C1E-9C55-0D6E3A1B2C3D","offset":[0.012,-0.004],\
            "part":"trunk","radius":0.31,"radiusUncertainty":0.002,"source":"scan"},\
            {"height":4,"id":"0B6A2C1D-3E4F-4A5B-8C7D-9E0F1A2B3C4D","part":"crown","radius":3.5,"source":"eye"}]},\
            "savedAt":1800000000123,"scan":"\(String(repeating: "ab", count: 32))",\
            "treeID":"9A8B7C6D-5E4F-4321-8765-0FEDCBA98765",\
            "vectorTree":{"drawn":[2.5,-1],"id":"gerardus:tree/7","placed":[0.1,0]}}
            """
        let expected = ScanAlignment(
            scan: try #require(BlobRef(rawValue: String(repeating: "ab", count: 32))),
            treeID: try #require(UUID(uuidString: "9A8B7C6D-5E4F-4321-8765-0FEDCBA98765")),
            profile: TreeProfile(sections: [
                TreeSection(
                    id: try #require(UUID(uuidString: "6F1C7F5A-8B11-4C1E-9C55-0D6E3A1B2C3D")), part: .trunk,
                    height: 1.37, radius: 0.31, source: .scan, offset: SIMD2(0.012, -0.004), radiusUncertainty: 0.002),
                TreeSection(
                    id: try #require(UUID(uuidString: "0B6A2C1D-3E4F-4A5B-8C7D-9E0F1A2B3C4D")), part: .crown,
                    height: 4, radius: 3.5),
            ]),
            groundHeight: -1.31,
            vectorTree: VectorTreePlacement(id: "gerardus:tree/7", drawn: SIMD2(2.5, -1), placed: SIMD2(0.1, 0)),
            correctedPosition: GeoPoint(latitude: 37.77, longitude: -122.48),
            savedAt: Date(timeIntervalSince1970: 1_800_000_000.123))
        #expect(try CanopyJSON.decoder.decode(ScanAlignment.self, from: Data(stored.utf8)) == expected)
        // And this version writes the same document.
        let written = try JSONSerialization.jsonObject(with: CanopyJSON.encoder.encode(expected)) as? NSDictionary
        #expect(written == (try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? NSDictionary))
    }

    @Test func movingGerardusTreeOntoTheTrunkCorrectsTheTreesPosition() throws {
        let census = GeoPoint(latitude: 37.7700, longitude: -122.4800)
        var placement = VectorTreePlacement(id: "gerardus:tree/7", drawn: SIMD2(3, 4))
        #expect(!placement.isMoved)
        #expect(placement.correction == .zero)
        #expect(placement.base(groundHeight: -1.2) == SIMD3(3, -1.2, -4))

        // Onto the trunk: the census tree is where Gerardus's tree is, 3 m east and 4 m north of where it was.
        placement.placed = .zero
        #expect(placement.isMoved)
        let corrected = LocalFrame(origin: census).enu(of: placement.corrected(census))
        #expect(abs(corrected.east - 3) < 0.001)
        #expect(abs(corrected.north - 4) < 0.001)

        // Half a metre east of the trunk: Gerardus's base is off the trunk, so the correction is half a metre less.
        placement.placed = SIMD2(0.5, 0)
        #expect(placement.correction == SIMD2(2.5, 4))
        #expect(placement.base(groundHeight: 0) == SIMD3(0.5, 0, 0))
    }

    @Test func nearbyVectorTreesComeNearestFirstAndOnceEach() throws {
        let origin = GeoPoint(latitude: 37.7650, longitude: -122.4690)
        let georeference = SiteOverlayTests.georeference(about: origin)
        func feature(_ id: String, _ x: Float, _ y: Float) throws -> VectorReference.Feature {
            var line = try LineFeature(fields: [])
            line.featureID = id
            line.kind = .tree
            line.xyz = [x, y, 50, x, y, 54]
            line.tags = ["height_m": "12", "crown_radius_m": "3"]
            return VectorReference.Feature(layer: .trees, line: line)
        }
        let features = [
            try feature("far", 40, 20), try feature("five", 13, 24), try feature("one", 10, 21),
        ]
        let census = LocalFrame(origin: origin).geoPoint(of: ENU(east: 10, north: 20, up: 0)).point
        // Two overlapping sites send the same trees.
        let found = GerardusTree.near(
            census, in: [(features, georeference), (features, georeference)], within: 15)
        #expect(found.map(\.tree.id) == ["one", "five"])
        #expect(simd_distance(found[0].offset, SIMD2(0, 1)) < 0.001)
        #expect(simd_distance(found[1].offset, SIMD2(3, 4)) < 0.001)
        #expect(abs(found[1].distance - 5) < 0.001)
        #expect(found[0].tree.form.height == 12)
        #expect(GerardusTree.near(census, in: [], within: 15).isEmpty)
    }
}
