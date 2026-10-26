import CanopyModel
import Foundation

/// Converts between a site frame (metres east, north and up from the centre of the site's L16 tile, on NAD83(2011)
/// and NAVD88) and WGS 84 latitude and longitude.
///
/// Rather than reimplementing the server's projection and datum transformation, it asks the server: `PoseFromHint`
/// takes a WGS 84 position and returns the site-frame position, so a handful of hints around the site give an
/// affine map between local east-north metres and the site frame. Across a 450 m bundle the projection's curvature
/// is far below a millimetre, so the affine fit is exact for Canopy's purposes; `rms` reports the fit residual.
public struct SiteGeoreference: Sendable {
    /// Local tangent frame the fit works in, at the site origin.
    public let frame: LocalFrame
    /// site = matrix · (east, north) + offset
    public let matrix: (a: Double, b: Double, c: Double, d: Double)
    public let offset: SIMD2<Double>
    /// RMS residual of the fit, metres.
    public let rms: Double
    /// What it was fitted from: WGS 84 points and their site-frame x and y.
    public let samples: [(geo: GeoPoint, site: SIMD2<Double>)]

    public enum FitError: Error, Equatable, LocalizedError {
        case tooFewSamples
        case degenerate

        public var errorDescription: String? {
            switch self {
            case .tooFewSamples: "The server could not place enough points in this area on its ground model."
            case .degenerate: "The server placed points in this area in a line, so they cannot be fitted."
            }
        }
    }

    /// Fits from pairs of (WGS 84 point, site-frame x and y).
    public init(origin: GeoPoint, samples: [(geo: GeoPoint, site: SIMD2<Double>)]) throws {
        guard samples.count >= 3 else { throw FitError.tooFewSamples }
        let frame = LocalFrame(origin: origin)
        let local = samples.map { sample -> SIMD2<Double> in
            let enu = frame.enu(of: sample.geo)
            return SIMD2(enu.east, enu.north)
        }
        // Least squares for x = a·e + b·n + tx and y = c·e + d·n + ty: normal equations over [e n 1].
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var rx = [0.0, 0.0, 0.0]
        var ry = [0.0, 0.0, 0.0]
        for (p, sample) in zip(local, samples) {
            let row = [p.x, p.y, 1]
            for i in 0..<3 {
                rx[i] += row[i] * sample.site.x
                ry[i] += row[i] * sample.site.y
                for j in 0..<3 { m[i][j] += row[i] * row[j] }
            }
        }
        guard let solveX = Self.solve3(m, rx), let solveY = Self.solve3(m, ry) else { throw FitError.degenerate }
        let matrix = (a: solveX[0], b: solveX[1], c: solveY[0], d: solveY[1])
        let offset = SIMD2(solveX[2], solveY[2])
        guard abs(matrix.a * matrix.d - matrix.b * matrix.c) > 1e-6 else { throw FitError.degenerate }
        var sum = 0.0
        for (p, sample) in zip(local, samples) {
            let fitted = SIMD2(matrix.a * p.x + matrix.b * p.y, matrix.c * p.x + matrix.d * p.y) + offset
            let r = fitted - sample.site
            sum += (r * r).sum()
        }
        self.frame = frame
        self.matrix = matrix
        self.offset = offset
        self.rms = (sum / Double(samples.count)).squareRoot()
        self.samples = samples
    }

    /// Site-frame x and y of a WGS 84 point.
    public func site(of point: GeoPoint) -> SIMD2<Double> {
        let enu = frame.enu(of: point)
        return SIMD2(matrix.a * enu.east + matrix.b * enu.north, matrix.c * enu.east + matrix.d * enu.north) + offset
    }

    /// WGS 84 point of a site-frame x and y.
    public func geo(x: Double, y: Double) -> GeoPoint {
        let det = matrix.a * matrix.d - matrix.b * matrix.c
        let u = x - offset.x
        let v = y - offset.y
        let east = (matrix.d * u - matrix.b * v) / det
        let north = (-matrix.c * u + matrix.a * v) / det
        return frame.geoPoint(of: ENU(east: east, north: north, up: 0)).point
    }

    /// Asks the server for the site positions of points around the origin and fits. Points where the site has no
    /// ground model (water, gaps) are skipped; at least three, not in a line, must answer. The first six that answer,
    /// in order, are used; they are asked for six at a time, so it takes a round trip or two rather than six. With a
    /// `cache`, a site's georeference is fitted once: it depends only on the site frame.
    public static func fetch(
        for site: Site, client: AlignClient, sensorID: String = "canopy-georef", cache: ReferenceCache? = nil
    ) async throws
        -> SiteGeoreference
    {
        if let kept = cache?.georeference(for: site) { return kept }
        guard let origin = site.frame?.origin else { throw FitError.tooFewSamples }
        let centre = GeoPoint(latitude: origin.latitude, longitude: origin.longitude)
        let frame = LocalFrame(origin: centre)
        var offsets: [(Double, Double)] = [(0, 0)]
        for radius in [150.0, 75] {
            for k in 0..<8 {
                let angle = Double(k) * .pi / 4
                offsets.append((radius * cos(angle), radius * sin(angle)))
            }
        }
        let wanted = 6
        var answers: [(index: Int, geo: GeoPoint, site: SIMD2<Double>)] = []
        for start in stride(from: 0, to: offsets.count, by: wanted) {
            let batch = Array(offsets.enumerated())[start..<min(offsets.count, start + wanted)]
            try await withThrowingTaskGroup(of: (Int, GeoPoint, SIMD2<Double>)?.self) { group in
                for (index, (east, north)) in batch {
                    let geo = frame.geoPoint(of: ENU(east: east, north: north, up: 0)).point
                    group.addTask {
                        do {
                            let (pose, _) = try await client.poseFromHint(
                                l16Token: site.l16Token, sensorID: sensorID,
                                hint: PoseHint(
                                    position: GeodeticPosition(latitude: geo.latitude, longitude: geo.longitude)))
                            return (index, geo, SIMD2(pose.translation.x, pose.translation.y))
                        } catch let error as GRPCStatusError where error.code == 9 {
                            return nil  // FAILED_PRECONDITION: no ground height there
                        }
                    }
                }
                for try await answer in group {
                    if let answer { answers.append((answer.0, answer.1, answer.2)) }
                }
            }
            if answers.count >= wanted { break }
        }
        let samples = answers.sorted { $0.index < $1.index }.prefix(wanted).map { (geo: $0.geo, site: $0.site) }
        let georeference = try SiteGeoreference(origin: centre, samples: Array(samples))
        cache?.store(georeference, for: site)
        return georeference
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let det =
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
            + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        guard abs(det) > 1e-12 else { return nil }
        func replaced(_ column: Int) -> Double {
            var m = a
            for row in 0..<3 { m[row][column] = b[row] }
            return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        return (0..<3).map { replaced($0) / det }
    }
}
