import CanopyModel
import Foundation
import Testing

@testable import CanopyCapture

@Suite struct GeoReferenceTests {
    let device = GeoPoint(latitude: 37.7699, longitude: -122.4757)

    @Test func northAlignedOffsetsMoveThePoint() {
        // 3 m east (+x) and 4 m north (−z) of the camera.
        let position = GeoReference.position(
            of: SIMD3(3, 0.5, -4), camera: .zero, device: device, horizontalAccuracy: 5, northAligned: true)
        let enu = LocalFrame(origin: device).enu(of: position.geo)
        #expect(abs(enu.east - 3) < 0.01)
        #expect(abs(enu.north - 4) < 0.01)
        #expect(abs(position.covariance.horizontalSigma - (25 + 0.01).squareRoot()) < 1e-9)
    }

    @Test func withoutNorthAlignmentThePointStaysAtTheDeviceWithMoreUncertainty() {
        let position = GeoReference.position(
            of: SIMD3(3, 0, -4), camera: .zero, device: device, horizontalAccuracy: 5, northAligned: false)
        #expect(position.geo == device)
        #expect(position.covariance.horizontalSigma > 7)
    }
}
