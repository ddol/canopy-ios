import CanopyModel
import CanopyReference
import Foundation
import Testing
import simd

@testable import CanopyMap

@Suite struct WireframeRendererTests {
    let origin = GeoPoint(latitude: 37.7650, longitude: -122.4690)

    /// A site frame that is exactly ENU about `origin`.
    func georeference(about origin: GeoPoint) throws -> SiteGeoreference {
        let frame = LocalFrame(origin: origin)
        let samples = [(0.0, 0.0), (100.0, 0.0), (0.0, 100.0), (100.0, 100.0), (-50.0, 30.0), (20.0, -80.0)].map {
            (geo: frame.geoPoint(of: ENU(east: $0.0, north: $0.1, up: 0)).point, site: SIMD2($0.0, $0.1))
        }
        return try SiteGeoreference(origin: origin, samples: samples)
    }

    @Test func siteMetresLandInSceneMetresAboutTheAnchor() throws {
        // The scene is anchored 200 m east and 100 m north of the site origin, at elevation 40.
        let anchor = LocalFrame(origin: origin).geoPoint(of: ENU(east: 200, north: 100, up: 0)).point
        let transform = SiteToScene(
            georeference: try georeference(about: origin), scene: LocalFrame(origin: anchor), elevation: 40)
        let p = transform.place(SIMD3(250, 100, 45))
        #expect(abs(p.x - 50) < 0.02)
        #expect(abs(p.z) < 0.02)
        #expect(abs(p.y - 5) < 0.001)
        let q = transform.place(SIMD3(200, 400, 40))
        #expect(abs(q.x) < 0.02)
        #expect(abs(q.z + 300) < 0.05)
    }

    @Test func aMeasuredTreeTakesItsFigureFromTheMeasurements() {
        let marker = MapLayers.TreeMarker(
            id: UUID(), location: origin, status: .verified, hazardCount: 0, dbh: 0.6, height: 20)
        let form = WireframeTrees.form(marker)
        #expect(form.trunkDiameter == 0.6)
        #expect(form.height == 20)
        #expect(abs(form.crownBase - 20 / 3) < 1e-9)
        let unmeasured = WireframeTrees.form(
            MapLayers.TreeMarker(id: UUID(), location: origin, status: .detected, hazardCount: 0))
        #expect(unmeasured.height == 8)
        #expect(unmeasured.trunkDiameter == 0.3)
    }

    @Test func theReferenceCarriesItsSitesWhenMerged() throws {
        let a = MapLayers.Reference(canopies: [], lines: [])
        let b = MapLayers.Reference(canopies: [], lines: [])
        #expect(MapLayers.Reference.merged([a, b])?.sites.isEmpty == true)
        #expect(a.sites.isEmpty)
    }
}
