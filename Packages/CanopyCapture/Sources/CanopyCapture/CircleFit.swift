import Foundation

/// A circle fitted to 2D points, with the uncertainty of its radius.
public struct FittedCircle: Equatable, Sendable {
    public var center: SIMD2<Double>
    public var radius: Double
    /// Standard uncertainty of `radius`, from the residuals and the geometry of the fit.
    public var radiusUncertainty: Double
    /// Standard uncertainty of each coordinate of `center`.
    public var centerUncertainty: Double
    /// Root mean square distance of the points from the circle.
    public var rmsResidual: Double
    /// How much of the circle the points cover, in radians (2π for all the way round).
    public var arc: Double
    public var pointCount: Int
}

public enum CircleFitError: Error, Equatable {
    case tooFewPoints(Int)
    case degenerate
}

/// Least-squares circle fitting: an algebraic (Kåsa) fit for a starting point, then a geometric fit
/// (Levenberg–Marquardt on the orthogonal distances), which stays unbiased on the partial arcs a LiDAR scan of
/// one side of a trunk gives.
public enum CircleFit {
    public static let minimumPoints = 5

    public static func fit(_ points: [SIMD2<Double>]) throws -> FittedCircle {
        guard points.count >= minimumPoints else { throw CircleFitError.tooFewPoints(points.count) }
        var (center, radius) = try algebraic(points)

        var lambda = 1e-3
        var cost = sumOfSquares(points, center, radius)
        for _ in 0..<100 {
            // Normal equations for residual_i = |p_i - c| - r, parameters (cx, cy, r).
            var jtj = [[Double]](repeating: [0, 0, 0], count: 3)
            var jtr = [0.0, 0.0, 0.0]
            for p in points {
                let d = p - center
                let distance = max((d * d).sum().squareRoot(), 1e-12)
                let residual = distance - radius
                let j = [-d.x / distance, -d.y / distance, -1.0]
                for row in 0..<3 {
                    jtr[row] += j[row] * residual
                    for column in 0..<3 {
                        jtj[row][column] += j[row] * j[column]
                    }
                }
            }
            var damped = jtj
            for k in 0..<3 {
                damped[k][k] *= 1 + lambda
            }
            guard let step = solve3(damped, jtr.map { -$0 }) else { throw CircleFitError.degenerate }
            let candidateCenter = center + SIMD2(step[0], step[1])
            let candidateRadius = radius + step[2]
            let candidateCost = sumOfSquares(points, candidateCenter, candidateRadius)
            if candidateCost < cost {
                center = candidateCenter
                radius = candidateRadius
                let improvement = cost - candidateCost
                cost = candidateCost
                lambda = max(lambda / 10, 1e-12)
                if improvement < 1e-14 * max(cost, 1e-30) || abs(step[2]) < 1e-12 { break }
            } else {
                lambda *= 10
                if lambda > 1e12 { break }
            }
        }
        guard radius > 0, radius.isFinite else { throw CircleFitError.degenerate }

        // Covariance of the parameters: s² (JᵀJ)⁻¹ with s² = RSS / (n − 3).
        var jtj = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in points {
            let d = p - center
            let distance = max((d * d).sum().squareRoot(), 1e-12)
            let j = [-d.x / distance, -d.y / distance, -1.0]
            for row in 0..<3 {
                for column in 0..<3 {
                    jtj[row][column] += j[row] * j[column]
                }
            }
        }
        let dof = Double(max(points.count - 3, 1))
        let variance = cost / dof
        guard let inverse = invert3(jtj) else { throw CircleFitError.degenerate }
        return FittedCircle(
            center: center,
            radius: radius,
            radiusUncertainty: (variance * inverse[2][2]).squareRoot(),
            centerUncertainty: (variance * max(inverse[0][0], inverse[1][1])).squareRoot(),
            rmsResidual: (cost / Double(points.count)).squareRoot(),
            arc: arcCovered(points, around: center),
            pointCount: points.count
        )
    }

    /// Fits, then drops points more than `threshold` standard deviations (at least 1 mm) off the circle and
    /// fits again, up to `rounds` times. Removes stray points from branches, bark flakes or other stems.
    public static func robustFit(
        _ points: [SIMD2<Double>], threshold: Double = 3, rounds: Int = 3
    ) throws
        -> FittedCircle
    {
        var kept = points
        var circle = try fit(kept)
        for _ in 0..<rounds {
            let limit = max(threshold * circle.rmsResidual, 0.001)
            let inliers = kept.filter { abs(distance($0, circle.center) - circle.radius) <= limit }
            guard inliers.count < kept.count, inliers.count >= minimumPoints else { break }
            kept = inliers
            circle = try fit(kept)
        }
        return circle
    }

    /// Kåsa's algebraic fit: solves x² + y² + D x + E y + F = 0 in the least-squares sense.
    static func algebraic(_ points: [SIMD2<Double>]) throws -> (SIMD2<Double>, Double) {
        // Centre the data for numerical stability.
        let mean = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        var b = [0.0, 0.0, 0.0]
        for p in points {
            let q = p - mean
            let row = [q.x, q.y, 1.0]
            let z = -(q.x * q.x + q.y * q.y)
            for i in 0..<3 {
                b[i] += row[i] * z
                for j in 0..<3 {
                    a[i][j] += row[i] * row[j]
                }
            }
        }
        guard let solution = solve3(a, b) else { throw CircleFitError.degenerate }
        let center = SIMD2(-solution[0] / 2, -solution[1] / 2)
        let r2 = (center * center).sum() - solution[2]
        guard r2 > 0 else { throw CircleFitError.degenerate }
        return (center + mean, r2.squareRoot())
    }

    static func sumOfSquares(_ points: [SIMD2<Double>], _ center: SIMD2<Double>, _ radius: Double) -> Double {
        points.reduce(0) { total, p in
            let residual = distance(p, center) - radius
            return total + residual * residual
        }
    }

    static func distance(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
        let d = p - q
        return (d * d).sum().squareRoot()
    }

    /// 2π minus the largest angular gap between consecutive points around the centre.
    static func arcCovered(_ points: [SIMD2<Double>], around center: SIMD2<Double>) -> Double {
        let angles = points.map { atan2($0.y - center.y, $0.x - center.x) }.sorted()
        guard let first = angles.first, let last = angles.last else { return 0 }
        var largestGap = first + 2 * .pi - last
        for (a, b) in zip(angles, angles.dropFirst()) {
            largestGap = max(largestGap, b - a)
        }
        return 2 * .pi - largestGap
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        guard let inverse = invert3(a) else { return nil }
        return (0..<3).map { row in (0..<3).reduce(0) { $0 + inverse[row][$1] * b[$1] } }
    }

    static func invert3(_ m: [[Double]]) -> [[Double]]? {
        let c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1]
        let c01 = m[1][2] * m[2][0] - m[1][0] * m[2][2]
        let c02 = m[1][0] * m[2][1] - m[1][1] * m[2][0]
        let determinant = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02
        let scale = m.flatMap { $0 }.map(abs).max() ?? 0
        guard abs(determinant) > 1e-18 * max(scale * scale * scale, 1e-300) else { return nil }
        let inverseDeterminant = 1 / determinant
        return [
            [c00, m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[0][2] * m[1][1]],
            [c01, m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][2] * m[1][0] - m[0][0] * m[1][2]],
            [c02, m[0][1] * m[2][0] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[0][1] * m[1][0]],
        ].map { $0.map { $0 * inverseDeterminant } }
    }
}
