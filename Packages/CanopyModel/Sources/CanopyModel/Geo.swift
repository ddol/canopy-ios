import Foundation

/// A WGS 84 latitude and longitude in degrees.
public struct GeoPoint: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The level-19 S2 chunk containing this point.
    public var chunk: S2CellID { S2CellID(self, level: S2CellID.chunkLevel) }

    /// The level-16 S2 tile containing this point.
    public var tile: S2CellID { S2CellID(self, level: S2CellID.tileLevel) }
}

/// East, north, up offsets in metres within a local tangent frame.
public struct ENU: Hashable, Codable, Sendable {
    public var east: Double
    public var north: Double
    public var up: Double

    public init(east: Double, north: Double, up: Double) {
        self.east = east
        self.north = north
        self.up = up
    }

    public static let zero = ENU(east: 0, north: 0, up: 0)

    /// Horizontal distance from the frame origin, in metres.
    public var horizontalDistance: Double { (east * east + north * north).squareRoot() }
}

/// A symmetric 3 × 3 covariance of an ENU position, in square metres.
public struct Covariance3: Hashable, Codable, Sendable {
    public var ee: Double
    public var en: Double
    public var eu: Double
    public var nn: Double
    public var nu: Double
    public var uu: Double

    public init(ee: Double, en: Double = 0, eu: Double = 0, nn: Double, nu: Double = 0, uu: Double) {
        self.ee = ee
        self.en = en
        self.eu = eu
        self.nn = nn
        self.nu = nu
        self.uu = uu
    }

    /// Independent horizontal and vertical standard deviations, in metres.
    public static func isotropic(horizontal: Double, vertical: Double) -> Covariance3 {
        Covariance3(ee: horizontal * horizontal, nn: horizontal * horizontal, uu: vertical * vertical)
    }

    /// A single horizontal standard deviation, in metres (the root mean of the east and north variances).
    public var horizontalSigma: Double { ((ee + nn) / 2).squareRoot() }
}

/// A position as Gerardus records it: geographic coordinates, plus the same point as ENU metres from the
/// centre of its level-16 tile, with the uncertainty of the ENU offsets.
public struct Position: Hashable, Codable, Sendable {
    public var geo: GeoPoint
    /// Ellipsoidal height in metres, when known.
    public var altitude: Double?
    /// Offset from the centre of `tile`, in metres.
    public var enu: ENU
    public var covariance: Covariance3

    public init(geo: GeoPoint, altitude: Double? = nil, covariance: Covariance3) {
        self.geo = geo
        self.altitude = altitude
        self.covariance = covariance
        self.enu = LocalFrame(origin: geo.tile.center).enu(of: geo, altitude: altitude ?? 0)
    }

    /// The level-16 tile whose centre is the ENU origin.
    public var tile: S2CellID { geo.tile }

    /// The level-19 chunk containing the position.
    public var chunk: S2CellID { geo.chunk }
}

/// A local east-north-up tangent frame on the WGS 84 ellipsoid.
public struct LocalFrame: Sendable {
    public let origin: GeoPoint
    public let originAltitude: Double

    private let originECEF: SIMD3<Double>
    private let rotation: (east: SIMD3<Double>, north: SIMD3<Double>, up: SIMD3<Double>)

    public init(origin: GeoPoint, altitude: Double = 0) {
        self.origin = origin
        self.originAltitude = altitude
        self.originECEF = WGS84.ecef(origin, altitude: altitude)
        let lat = origin.latitude * .pi / 180
        let lng = origin.longitude * .pi / 180
        rotation = (
            east: SIMD3(-sin(lng), cos(lng), 0),
            north: SIMD3(-sin(lat) * cos(lng), -sin(lat) * sin(lng), cos(lat)),
            up: SIMD3(cos(lat) * cos(lng), cos(lat) * sin(lng), sin(lat))
        )
    }

    public func enu(of point: GeoPoint, altitude: Double = 0) -> ENU {
        let d = WGS84.ecef(point, altitude: altitude) - originECEF
        return ENU(
            east: (d * rotation.east).sum(),
            north: (d * rotation.north).sum(),
            up: (d * rotation.up).sum()
        )
    }

    public func geoPoint(of enu: ENU) -> (point: GeoPoint, altitude: Double) {
        let ecef = originECEF + rotation.east * enu.east + rotation.north * enu.north + rotation.up * enu.up
        return WGS84.geodetic(ecef)
    }
}

enum WGS84 {
    static let a = 6_378_137.0
    static let f = 1 / 298.257223563
    static let e2 = f * (2 - f)

    static func ecef(_ point: GeoPoint, altitude: Double) -> SIMD3<Double> {
        let lat = point.latitude * .pi / 180
        let lng = point.longitude * .pi / 180
        let n = a / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
        return SIMD3(
            (n + altitude) * cos(lat) * cos(lng),
            (n + altitude) * cos(lat) * sin(lng),
            (n * (1 - e2) + altitude) * sin(lat)
        )
    }

    /// ECEF to geodetic by fixed-point iteration; converges to well under a millimetre in a few steps.
    static func geodetic(_ p: SIMD3<Double>) -> (point: GeoPoint, altitude: Double) {
        let lng = atan2(p.y, p.x)
        let r = (p.x * p.x + p.y * p.y).squareRoot()
        var lat = atan2(p.z, r * (1 - e2))
        var h = 0.0
        for _ in 0..<6 {
            let n = a / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
            h = r / cos(lat) - n
            lat = atan2(p.z, r * (1 - e2 * n / (n + h)))
        }
        return (GeoPoint(latitude: lat * 180 / .pi, longitude: lng * 180 / .pi), h)
    }
}
