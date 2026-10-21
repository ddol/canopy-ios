import Foundation
import Testing

@testable import CanopyModel

@Suite struct GeoTests {
    let origin = GeoPoint(latitude: 37.7699, longitude: -122.4757)

    @Test func enuRoundTripsWithinAMillimetre() {
        let frame = LocalFrame(origin: origin)
        let offset = ENU(east: 123.4, north: -56.7, up: 8.9)
        let (point, altitude) = frame.geoPoint(of: offset)
        let back = frame.enu(of: point, altitude: altitude)
        #expect(abs(back.east - offset.east) < 0.001)
        #expect(abs(back.north - offset.north) < 0.001)
        #expect(abs(back.up - offset.up) < 0.001)
    }

    @Test func oneThousandthOfADegreeOfLatitudeIsAboutOneHundredElevenMetres() {
        let frame = LocalFrame(origin: origin)
        let north = frame.enu(of: GeoPoint(latitude: origin.latitude + 0.001, longitude: origin.longitude))
        #expect(abs(north.north - 111.0) < 0.5)
        #expect(abs(north.east) < 0.01)
    }

    @Test func positionIsRelativeToItsTileCentre() {
        let position = Position(geo: origin, covariance: .isotropic(horizontal: 3, vertical: 5))
        #expect(position.tile == origin.tile)
        #expect(position.chunk == origin.chunk)
        // Inside a ~150 m tile, the offset from its centre is well under 150 m.
        #expect(position.enu.horizontalDistance < 150)
        #expect(abs(position.covariance.horizontalSigma - 3) < 1e-12)
        let back = LocalFrame(origin: position.tile.center).geoPoint(of: position.enu).point
        #expect(abs(back.latitude - origin.latitude) < 1e-8)
        #expect(abs(back.longitude - origin.longitude) < 1e-8)
    }
}
