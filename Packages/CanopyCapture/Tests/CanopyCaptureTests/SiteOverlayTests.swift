import CanopyModel
import CanopyReference
import Foundation
import Testing
import simd

@testable import CanopyCapture

@Suite struct SiteOverlayTests {
    /// A site frame that is exactly ENU about `origin`, with no datum shift: enough to check the plumbing.
    static func georeference(about origin: GeoPoint) -> SiteGeoreference {
        let frame = LocalFrame(origin: origin)
        let samples = [(0.0, 0.0), (100.0, 0.0), (0.0, 100.0), (100.0, 100.0), (-50.0, 30.0), (20.0, -80.0)].map {
            (geo: frame.geoPoint(of: ENU(east: $0.0, north: $0.1, up: 0)).point, site: SIMD2($0.0, $0.1))
        }
        return try! SiteGeoreference(origin: origin, samples: samples)
    }

    let siteOrigin = GeoPoint(latitude: 37.7650, longitude: -122.4690)

    func tree(
        _ tags: [String: String], base: SIMD3<Float> = SIMD3(10, 20, 50), top: SIMD3<Float>? = nil
    )
        -> LineFeature
    {
        var line = try! LineFeature(fields: [])
        line.featureID = "datasf:tkzw-k3nq/1"
        line.kind = .tree
        let t = top ?? base
        line.xyz = [base.x, base.y, base.z, t.x, t.y, t.z]
        line.tags = tags
        return line
    }

    @Test func aStreetTreeWithNoHeightsGetsTheMacDefaults() throws {
        let tree = try #require(GerardusTree(self.tree(["dbh_m": "0.45", "species": "Quercus agrifolia"])))
        #expect(tree.form.trunkDiameter == 0.45)
        #expect(tree.form.crownWidth == 4)
        #expect(tree.form.crownBase == 0)
        #expect(tree.form.height == 4)
        #expect(tree.species == "Quercus agrifolia")
        #expect(tree.measured == ["dbh_m"])
    }

    @Test func anObservedTreeUsesItsTags() throws {
        let tree = try #require(
            GerardusTree(
                self.tree(
                    ["height_m": "14", "crown_base_m": "5", "crown_radius_m": "3.5"], base: SIMD3(1, 2, 30),
                    top: SIMD3(1, 2, 35))))
        #expect(tree.form.height == 14)
        #expect(tree.form.crownBase == 5)
        #expect(tree.form.crownHeight == 9)
        #expect(tree.form.crownWidth == 7)
        #expect(tree.form.trunkDiameter == GerardusTree.defaultTrunkDiameter)
        #expect(tree.base == SIMD3(1, 2, 30))
    }

    @Test func aGPSFrameTurnsSiteENUIntoARKitEastUpSouth() {
        let georeference = Self.georeference(about: siteOrigin)
        // The session started 30 m east and 40 m north of the site origin, with the ground 1.6 m below the origin in
        // ARKit and at site height 52 there.
        let sessionOrigin = LocalFrame(origin: siteOrigin).geoPoint(of: ENU(east: 30, north: 40, up: 0)).point
        let frame = ARSiteFrame(
            origin: sessionOrigin, georeference: georeference, arGroundAtOrigin: -1.6, siteGroundAtOrigin: 52)
        let p = frame.arkit(SIMD3<Double>(40, 50, 55))
        #expect(abs(p.x - 10) < 0.01)
        #expect(abs(p.z + 10) < 0.01)
        #expect(abs(p.y - 1.4) < 0.001)
        let back = frame.site(ofARKit: p)
        #expect(abs(back.x - 40) < 0.01)
        #expect(abs(back.y - 50) < 0.01)
        #expect(!frame.isRegistered)
    }

    @Test func aRegisteredFrameInvertsThePose() {
        let georeference = Self.georeference(about: siteOrigin)
        // The sensor frame sits at site (100, 200, 10), turned 90° anticlockwise: sensor +y points site −x.
        let pose = SensorPose(translation: Vector3(x: 100, y: 200, z: 10), rotation: .yaw(.pi / 2))
        let scan = RegisteredScan(
            pose: pose, georeference: georeference, sigma: 0.1, registrationID: "r", passedGates: true)
        let frame = ARSiteFrame(registered: scan)
        // The point 5 m along sensor +y is at site (95, 200, 10): back in ARKit it is 5 m north, so z = −5.
        let p = frame.arkit(SIMD3<Double>(95, 200, 12))
        #expect(abs(p.x) < 0.01)
        #expect(abs(p.z + 5) < 0.01)
        #expect(abs(p.y - 2) < 0.01)
        #expect(frame.isRegistered)
        let back = frame.site(ofARKit: p)
        #expect(abs(back.x - 95) < 0.01)
        #expect(abs(back.y - 200) < 0.01)
    }

    @Test func siteItemsAreBuiltPerLayerWithinTheRadius() throws {
        let georeference = Self.georeference(about: siteOrigin)
        let frame = ARSiteFrame(
            origin: siteOrigin, georeference: georeference, arGroundAtOrigin: 0, siteGroundAtOrigin: 0)
        var wall = try LineFeature(fields: [])
        wall.featureID = "wall"
        wall.kind = .wallSurface
        wall.closed = true
        wall.xyz = [0, 0, 0, 4, 0, 0, 4, 0, 6, 0, 0, 6]
        var road = try LineFeature(fields: [])
        road.featureID = "road"
        road.kind = .road
        road.xyz = [0, 5, 0, 50, 5, 0, 100, 5, 0]
        var far = tree(["dbh_m": "0.3"], base: SIMD3(500, 0, 0))
        far.featureID = "far"
        let features = [
            VectorReference.Feature(layer: .trees, line: tree(["dbh_m": "0.3"], base: SIMD3(3, 4, 0))),
            VectorReference.Feature(layer: .trees, line: far),
            VectorReference.Feature(layer: .buildings, line: wall),
            VectorReference.Feature(layer: .cityStreets, line: road),
        ]
        let trees = SiteWireframes.items(features, layer: .trees, frame: frame, centre: .zero, radius: 150)
        #expect(trees.map(\.id) == ["datasf:tkzw-k3nq/1"])
        let pick = try #require(trees[0].pickBox)
        #expect(abs(pick.centre.x - 3) < 0.01)
        #expect(abs(pick.centre.z + 4) < 0.01)
        let buildings = SiteWireframes.items(features, layer: .buildings, frame: frame, centre: .zero)
        #expect(buildings.count == 1)
        #expect(buildings[0].segments.count == 4)
        #expect(buildings[0].pickBox == nil)
        let streets = SiteWireframes.items(features, layer: .streets, frame: frame, centre: .zero)
        #expect(streets.count == 1)
        #expect(streets[0].segments.count == 2)
    }

    /// A closed ring 10 m square at the origin, `height` metres tall.
    private func ring(_ id: String, kind: FeatureKind, height: Float = 0) throws -> LineFeature {
        var line = try LineFeature(fields: [])
        line.featureID = id
        line.kind = kind
        line.closed = true
        line.height = height
        line.xyz = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
        return line
    }

    @Test func onlyTheReconstructedBuildingsAreDrawnNeverDataSFsBoxes() throws {
        let frame = ARSiteFrame(
            origin: siteOrigin, georeference: Self.georeference(about: siteOrigin), arGroundAtOrigin: 0,
            siteGroundAtOrigin: 0)
        let box = VectorReference.Feature(layer: .boxes, line: try ring("box", kind: .building, height: 9))
        let footprint = VectorReference.Feature(
            layer: .footprints, line: try ring("footprint", kind: .building, height: 9))
        let facade = VectorReference.Feature(layer: .observed, line: try ring("facade", kind: .wallPlane))
        let roof = VectorReference.Feature(layer: .buildings, line: try ring("roof", kind: .roofPlane))
        let reconstructed = SiteWireframes.items(
            [box, footprint, facade, roof], layer: .buildings, frame: frame, centre: .zero)
        #expect(reconstructed.map(\.id) == ["roof"])

        // Without reconstructed buildings, a footprint is its outline on the ground: four sides, nothing raised.
        let flat = SiteWireframes.items([box, footprint], layer: .buildings, frame: frame, centre: .zero)
        #expect(flat.map(\.id) == ["footprint"])
        #expect(flat[0].segments.count == 4)
        #expect(flat[0].segments.allSatisfy { abs($0.from.y) < 0.01 && abs($0.to.y) < 0.01 })
    }

    @Test func anAdjustedFormReplacesTheServersShape() {
        let georeference = Self.georeference(about: siteOrigin)
        let frame = ARSiteFrame(
            origin: siteOrigin, georeference: georeference, arGroundAtOrigin: 0, siteGroundAtOrigin: 0)
        let features = [VectorReference.Feature(layer: .trees, line: tree(["dbh_m": "0.3"], base: .zero))]
        let tall = TreeForm(trunkDiameter: 0.3, height: 30, crownHeight: 10, crownWidth: 8)
        let items = SiteWireframes.items(
            features, layer: .trees, frame: frame, centre: .zero, forms: ["datasf:tkzw-k3nq/1": tall])
        let top = items[0].segments.map(\.to.y).max() ?? 0
        #expect(abs(top - 30) < 0.01)
    }
}

@Suite struct CellWireframeTests {
    @Test func theCellsRoundAPointAreItsTileAndNeighboursWithTheirParents() {
        let here = GeoPoint(latitude: 37.7694, longitude: -122.4770)
        let cells = SiteWireframes.cells(around: here, radius: 250)
        #expect(cells.level16.contains(here.tile))
        #expect(cells.level16.count >= 9)
        #expect(cells.level13.contains(here.tile.parent(level: 13)))
        #expect(cells.level13.count <= 4)
        #expect(cells.level16.allSatisfy { $0.level == 16 })
    }

    @Test func aCellItemIsItsOutlineLiftedWithAPostAtEachCorner() {
        let cell = GeoPoint(latitude: 37.7694, longitude: -122.4770).tile
        let frame = LocalFrame(origin: cell.center)
        let item = SiteWireframes.cellItem(cell) { geo in
            let enu = frame.enu(of: geo)
            return SIMD3(Float(enu.east), 0, Float(-enu.north))
        }
        #expect(item.id == "cell:" + cell.token)
        #expect(item.segments.count == 8)
        let posts = item.segments.filter { $0.from.x == $0.to.x && $0.from.z == $0.to.z }
        #expect(posts.count == 4)
        #expect(posts.allSatisfy { abs(($0.to.y - $0.from.y) - 1.5) < 1e-5 })
        #expect(item.segments.allSatisfy { abs($0.from.y - 0.15) < 1e-5 })
        let l13 = SiteWireframes.cellItem(cell.parent(level: 13)) { _ in .zero }
        #expect(l13.segments.contains { abs($0.to.y - 6.15) < 1e-5 })
    }
}
