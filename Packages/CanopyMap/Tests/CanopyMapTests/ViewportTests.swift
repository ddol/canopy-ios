import CanopyModel
import Foundation
import Testing

@testable import CanopyMap

/// Regions the map reports that are not places on it are not passed on (`CanopyMapView.onViewportChange`): drawing
/// one in full, or asking which tiles it spans, would stop the app on a number that is not one.
@Suite struct ViewportTests {
    let park = MapViewport.goldenGatePark

    @Test func aRegionOnTheMapIsUsable() {
        #expect(park.isUsable)
        #expect(MapViewport.sanFrancisco.isUsable)
        #expect(MapViewport(center: park.center, latitudeDelta: 150, longitudeDelta: 360).isUsable)
    }

    @Test func aRegionThatIsNotAPlaceIsNot() {
        let nowhere = GeoPoint(latitude: .nan, longitude: .nan)
        #expect(!MapViewport(center: nowhere, latitudeDelta: 0.01, longitudeDelta: 0.01).isUsable)
        #expect(!MapViewport(center: park.center, latitudeDelta: .nan, longitudeDelta: .nan).isUsable)
        #expect(!MapViewport(center: park.center, latitudeDelta: .infinity, longitudeDelta: 0.01).isUsable)
        #expect(!MapViewport(center: park.center, latitudeDelta: 0, longitudeDelta: 0).isUsable)
        let offTheEarth = GeoPoint(latitude: 120, longitude: 0)
        #expect(!MapViewport(center: offTheEarth, latitudeDelta: 1, longitudeDelta: 1).isUsable)
    }
}
