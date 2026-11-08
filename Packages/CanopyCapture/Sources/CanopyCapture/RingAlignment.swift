import Foundation
import simd

/// A camera frame's geometry: ARKit's intrinsics at the captured image's resolution, and the camera-to-world
/// transform. The camera looks down its −z with +y up in the sensor's landscape-right frame, which is how the image
/// is laid out; pixel (0, 0) is the centre of the top-left pixel, as `DepthFrame` takes it.
public struct CameraPose: Equatable, Sendable {
    public var intrinsics: simd_float3x3
    public var transform: simd_float4x4
    public var imageSize: SIMD2<Int>

    public init(intrinsics: simd_float3x3, transform: simd_float4x4, imageSize: SIMD2<Int>) {
        self.intrinsics = intrinsics
        self.transform = transform
        self.imageSize = imageSize
    }

    public var position: SIMD3<Double> {
        let t = transform.columns.3
        return SIMD3(Double(t.x), Double(t.y), Double(t.z))
    }

    var focalLength: Double { Double(intrinsics[0][0]) }

    /// The pixel a world point falls on; nil behind the camera or within 5 cm of it.
    public func project(_ point: SIMD3<Double>) -> SIMD2<Double>? {
        let world = Self.double(transform)
        let local = world.inverse * SIMD4(point, 1)
        let depth = -local.z
        guard depth > 0.05 else { return nil }
        let fx = Double(intrinsics[0][0])
        let fy = Double(intrinsics[1][1])
        let cx = Double(intrinsics[2][0])
        let cy = Double(intrinsics[2][1])
        return SIMD2(cx + fx * local.x / depth, cy - fy * local.y / depth)
    }

    /// The world direction (a unit vector) of the ray from the camera through a pixel.
    public func ray(through pixel: SIMD2<Double>) -> SIMD3<Double> {
        let fx = Double(intrinsics[0][0])
        let fy = Double(intrinsics[1][1])
        let cx = Double(intrinsics[2][0])
        let cy = Double(intrinsics[2][1])
        let local = SIMD4((pixel.x - cx) / fx, -(pixel.y - cy) / fy, -1, 0)
        let world = Self.double(transform) * local
        return simd_normalize(SIMD3(world.x, world.y, world.z))
    }

    /// Whether a pixel is inside the image by at least `margin` pixels.
    func contains(_ pixel: SIMD2<Double>, margin: Double) -> Bool {
        pixel.x >= margin && pixel.y >= margin && pixel.x <= Double(imageSize.x - 1) - margin
            && pixel.y <= Double(imageSize.y - 1) - margin
    }

    static func double(_ m: simd_float4x4) -> simd_double4x4 {
        simd_double4x4(
            columns: (
                SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1), SIMD4<Double>(m.columns.2),
                SIMD4<Double>(m.columns.3)
            ))
    }
}

/// The brightness of a camera image, 0 to 255 a pixel: on the phone, the luma plane of ARKit's captured image,
/// read in place while its buffer is locked and never copied out.
public protocol LumaSource {
    var width: Int { get }
    var height: Int { get }
    func luma(x: Int, y: Int) -> UInt8
}

extension LumaSource {
    /// The brightness at a point between pixel centres, interpolated; nil outside the image.
    public func sample(_ point: SIMD2<Double>) -> Double? {
        let x0 = Int(point.x.rounded(.down))
        let y0 = Int(point.y.rounded(.down))
        guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return nil }
        let fx = point.x - Double(x0)
        let fy = point.y - Double(y0)
        let top = Double(luma(x: x0, y: y0)) * (1 - fx) + Double(luma(x: x0 + 1, y: y0)) * fx
        let bottom = Double(luma(x: x0, y: y0 + 1)) * (1 - fx) + Double(luma(x: x0 + 1, y: y0 + 1)) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// A brightness image held in memory, for tests.
public struct GrayImage: LumaSource, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func luma(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}

/// Finding a brightness edge along a short line across it.
enum EdgeSearch {
    /// The strongest brightness edge within `reach` pixels either side of `predicted` along `direction` (a unit
    /// vector in pixels), from the mean of `lines` parallel lines spread `across` pixels either side of it. Edges
    /// nearer the prediction count for more. Nil when nothing stands out: a step of less than `minimumContrast`
    /// grey levels a pixel, or less than 2.5 times the window's median, or a window off the image.
    static func find(
        in image: some LumaSource, near predicted: SIMD2<Double>, along direction: SIMD2<Double>, reach: Int,
        across: Double, lines: Int = 5, minimumContrast: Double = 3
    ) -> SIMD2<Double>? {
        let count = 2 * reach + 1
        guard reach >= 2, lines >= 1 else { return nil }
        let normal = SIMD2(-direction.y, direction.x)
        let spacing = lines == 1 ? 0 : 2 * across / Double(lines - 1)
        let offsets: [Double] = (0..<lines).map { i -> Double in Double(i) * spacing - (lines == 1 ? 0 : across) }
        var profile = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let along = predicted + direction * Double(i - reach)
            var total = 0.0
            for offset in offsets {
                guard let value = image.sample(along + normal * offset) else { return nil }
                total += value
            }
            profile[i] = total / Double(offsets.count)
        }
        var smooth = profile
        for i in 1..<(count - 1) {
            smooth[i] = (profile[i - 1] + 2 * profile[i] + profile[i + 1]) / 4
        }
        var gradient = [Double](repeating: 0, count: count)
        for i in 1..<(count - 1) {
            gradient[i] = abs(smooth[i + 1] - smooth[i - 1]) / 2
        }
        let width = Double(reach) * 0.6
        var best = 1
        var bestScore = -1.0
        for i in 1..<(count - 1) {
            let t = Double(i - reach) / width
            let score = gradient[i] * exp(-0.5 * t * t)
            if score > bestScore {
                bestScore = score
                best = i
            }
        }
        let peak = gradient[best]
        let median = gradient[1..<(count - 1)].sorted()[(count - 2) / 2]
        guard peak >= minimumContrast, peak >= 2.5 * median else { return nil }
        // A parabola through the peak and its neighbours places the edge between pixels.
        var shift = 0.0
        if best > 1, best < count - 2 {
            let a = gradient[best - 1]
            let c = gradient[best + 1]
            let curvature = a - 2 * peak + c
            if curvature < 0 { shift = min(max(0.5 * (a - c) / curvature, -0.5), 0.5) }
        }
        return predicted + direction * (Double(best - reach) + shift)
    }
}

/// Aligns trunk rings above the reach of the depth points to the trunk's edges in camera frames.
///
/// Each frame with a ring's silhouette in view gives two lines: from the camera past the trunk's left and right
/// edges at the ring's height, which the ring must touch. Each line is the trace, at that height, of the plane
/// through the camera, the edge and the trunk's axis, so a leaning trunk is handled. Gathered from viewpoints round
/// the trunk, the lines fix the ring's centre and radius by least squares, with lines far off the rest dropped. From
/// a single viewpoint the prior (the axis and taper of the rings below, `TrunkSteps.aligner`) holds the ring's
/// distance from the camera, and the edges set its width and its place across the view.
///
/// Only the lines are kept: a frame is read for the edges and let go.
public struct RingAligner: Sendable {
    /// A ring to align and what the rings below predict for it.
    public struct Target: Equatable, Sendable, Identifiable {
        public var id: UUID
        /// The ring's predicted centre in the world, at its height.
        public var centre: SIMD3<Double>
        public var radius: Double
        /// Standard uncertainty of the prediction: of each horizontal coordinate of the centre, and of the radius.
        public var centreSigma: Double
        public var radiusSigma: Double

        public init(id: UUID, centre: SIMD3<Double>, radius: Double, centreSigma: Double, radiusSigma: Double) {
            self.id = id
            self.centre = centre
            self.radius = radius
            self.centreSigma = centreSigma
            self.radiusSigma = radiusSigma
        }
    }

    /// A ring as the camera sees it.
    public struct Fit: Equatable, Sendable {
        /// The centre in the world, x and z.
        public var centre: SIMD2<Double>
        public var radius: Double
        /// Standard uncertainty of the radius.
        public var radiusUncertainty: Double
        /// Viewpoints round the trunk whose edges were used.
        public var views: Int
        /// Edge lines used, after dropping those far off the rest.
        public var lines: Int
    }

    /// One edge's line in the ring's horizontal plane: the points x with `normal · x = offset`, with `normal`
    /// towards the ring's centre.
    struct Line: Equatable, Sendable {
        var normal: SIMD2<Double>
        var offset: Double
        /// Standard uncertainty of the line's place, in metres.
        var sigma: Double
    }

    public private(set) var targets: [Target]
    /// A unit vector up the trunk.
    public var axis: SIMD3<Double>
    /// The lines from each viewpoint, by ring and by bearing from the ring (in `bearingStep` bins): a later frame
    /// from the same bearing replaces the earlier one, so standing still adds nothing.
    private var views: [UUID: [Int: [Line]]] = [:]

    /// Degrees of bearing round the trunk that count as one viewpoint.
    public static let bearingStep = 5.0
    /// Edge noise, in pixels.
    static let edgeNoise = 1.5
    /// Edges are looked for across this height band either side of the ring, in metres.
    static let band = 0.03

    public init(targets: [Target], axis: SIMD3<Double> = SIMD3(0, 1, 0)) {
        self.targets = targets
        self.axis = simd_normalize(axis)
    }

    /// Stops aligning one ring.
    public mutating func remove(_ id: UUID) {
        targets.removeAll { $0.id == id }
        views[id] = nil
    }

    /// Reads one frame: for each ring whose silhouette is in view, looks for the trunk's edges near where it falls
    /// and keeps the lines past them, in place of any from the same bearing. Returns how many rings had both edges
    /// found.
    @discardableResult
    public mutating func add(_ camera: CameraPose, image: some LumaSource) -> Int {
        var found = 0
        for target in targets {
            // Look where the ring is now thought to be, once a few viewpoints agree on it; else where predicted.
            var centre = target.centre
            var radius = target.radius
            if let fit = fit(target.id), fit.views >= 2 {
                centre = SIMD3(fit.centre.x, target.centre.y, fit.centre.y)
                radius = fit.radius
            }
            guard let edges = Self.edges(of: centre, radius: radius, camera: camera, image: image) else { continue }
            let lines = edges.compactMap { line(through: $0, camera: camera, target: target) }
            guard lines.count == 2 else { continue }
            let toCamera = camera.position - target.centre
            let bearing = atan2(toCamera.z, toCamera.x) * 180 / .pi
            views[target.id, default: [:]][Int(((bearing + 180) / Self.bearingStep).rounded(.down))] = lines
            found += 1
        }
        return found
    }

    /// The ring's fit from the viewpoints so far; nil before any.
    public func fit(_ id: UUID) -> Fit? {
        guard let target = targets.first(where: { $0.id == id }), let byBearing = views[id], !byBearing.isEmpty
        else { return nil }
        let bins = byBearing.keys.sorted()
        let lines = bins.flatMap { byBearing[$0] ?? [] }
        let owners = bins.flatMap { bin in Array(repeating: bin, count: byBearing[bin]?.count ?? 0) }
        guard let solution = Self.solve(lines, prior: target) else { return nil }
        let used = Set(zip(owners, solution.kept).filter { $0.1 }.map { $0.0 })
        return Fit(
            centre: solution.centre, radius: solution.radius, radiusUncertainty: solution.radiusUncertainty,
            views: used.count, lines: solution.kept.filter { $0 }.count)
    }

    /// Every ring's fit so far.
    public var fits: [UUID: Fit] {
        var fits: [UUID: Fit] = [:]
        for target in targets {
            if let fit = fit(target.id) { fits[target.id] = fit }
        }
        return fits
    }

    /// Where a ring's left and right edges are in the image: the trunk's brightness edges found near the points
    /// where lines from the camera graze the ring. Nil when the ring is out of view, too small in it (under 4
    /// pixels across each side of the centre), or an edge is not found or makes the trunk implausibly narrow or
    /// wide (under 0.4 or over 2.5 times the prediction).
    static func edges(
        of centre: SIMD3<Double>, radius: Double, camera: CameraPose, image: some LumaSource
    ) -> [SIMD2<Double>]? {
        let eye = camera.position
        let toEye = SIMD2(eye.x - centre.x, eye.z - centre.z)
        let distance = simd_length(toEye)
        guard distance > radius * 1.15 else { return nil }
        let towards = toEye / distance
        let across = SIMD2(-towards.y, towards.x)
        let cosine = radius / distance
        let sine = (1 - cosine * cosine).squareRoot()
        let grazing = [-1.0, 1.0].map { side -> SIMD3<Double> in
            let offset = radius * (cosine * towards + side * sine * across)
            return SIMD3(centre.x + offset.x, centre.y, centre.z + offset.y)
        }
        guard let a = camera.project(grazing[0]), let b = camera.project(grazing[1]) else { return nil }
        let halfWidth = simd_length(b - a) / 2
        guard halfWidth >= 4 else { return nil }
        let direction = (b - a) / (2 * halfWidth)
        let reach = Int(max(6, 0.6 * halfWidth).rounded())
        let band = min(max(Self.band * camera.focalLength / simd_distance(eye, centre), 1), 6)
        guard camera.contains(a, margin: Double(reach) + band + 2), camera.contains(b, margin: Double(reach) + band + 2)
        else { return nil }
        guard let left = EdgeSearch.find(in: image, near: a, along: direction, reach: reach, across: band),
            let right = EdgeSearch.find(in: image, near: b, along: direction, reach: reach, across: band)
        else { return nil }
        let found = simd_dot(right - left, direction) / 2
        guard found >= 0.4 * halfWidth, found <= 2.5 * halfWidth else { return nil }
        return [left, right]
    }

    /// The line in the ring's horizontal plane that an edge at `pixel` puts the ring against: the trace of the
    /// plane through the camera containing the ray to the edge and the trunk's axis.
    func line(through pixel: SIMD2<Double>, camera: CameraPose, target: Target) -> Line? {
        let eye = camera.position
        let normal3 = simd_cross(camera.ray(through: pixel), axis)
        let horizontal = SIMD2(normal3.x, normal3.z)
        let length = simd_length(horizontal)
        guard length > 1e-6 else { return nil }
        var normal = horizontal / length
        var offset = (simd_dot(normal3, eye) - normal3.y * target.centre.y) / length
        if simd_dot(normal, SIMD2(target.centre.x, target.centre.z)) - offset < 0 {
            normal = -normal
            offset = -offset
        }
        let sigma = max(0.003, simd_distance(eye, target.centre) * Self.edgeNoise / camera.focalLength)
        return Line(normal: normal, offset: offset, sigma: sigma)
    }

    /// The ring touching the lines, by weighted least squares with the prediction as a prior. The line furthest
    /// off, when more than three standard deviations, is dropped and the rest fitted again, until none is or half
    /// are gone. The ring touches a line when its centre is its radius from it: `normal · c − r = offset`, linear
    /// in the centre and the radius.
    static func solve(
        _ lines: [Line], prior: Target
    ) -> (centre: SIMD2<Double>, radius: Double, radiusUncertainty: Double, kept: [Bool])? {
        let origin = SIMD2(prior.centre.x, prior.centre.z)
        var kept = [Bool](repeating: true, count: lines.count)
        var result: (SIMD3<Double>, [[Double]])?
        for _ in 0...(lines.count / 2) {
            // Unknowns: the centre's offset from the prior's and the radius.
            var m = [[Double]](repeating: [0, 0, 0], count: 3)
            var v = [0.0, 0.0, 0.0]
            func add(_ row: SIMD3<Double>, _ value: Double, _ sigma: Double) {
                let w = 1 / (sigma * sigma)
                let a = [row.x, row.y, row.z]
                for i in 0..<3 {
                    v[i] += w * a[i] * value
                    for j in 0..<3 { m[i][j] += w * a[i] * a[j] }
                }
            }
            add(SIMD3(1, 0, 0), 0, prior.centreSigma)
            add(SIMD3(0, 1, 0), 0, prior.centreSigma)
            add(SIMD3(0, 0, 1), prior.radius, prior.radiusSigma)
            for (line, use) in zip(lines, kept) where use {
                add(SIMD3(line.normal.x, line.normal.y, -1), line.offset - simd_dot(line.normal, origin), line.sigma)
            }
            guard let inverse = CircleFit.invert3(m) else { return nil }
            let solution = SIMD3((0..<3).map { row in (0..<3).reduce(0) { $0 + inverse[row][$1] * v[$1] } })
            result = (solution, inverse)
            let residuals = lines.map { line in
                abs(simd_dot(line.normal, origin + SIMD2(solution.x, solution.y)) - solution.z - line.offset)
                    / line.sigma
            }
            let worst = residuals.indices.filter { kept[$0] }.max { residuals[$0] < residuals[$1] }
            guard let worst, residuals[worst] > 3, kept.filter({ $0 }).count > max(2, (lines.count + 1) / 2)
            else { break }
            kept[worst] = false
        }
        guard let (solution, inverse) = result, TreeProfile.radii.contains(solution.z) else { return nil }
        // Scale the covariance up when the lines scatter more than their uncertainties say.
        let used = zip(lines, kept).filter { $0.1 }.map { $0.0 }
        let chi2 = used.reduce(0.0) { total, line in
            let residual =
                (simd_dot(line.normal, origin + SIMD2(solution.x, solution.y)) - solution.z - line.offset) / line.sigma
            return total + residual * residual
        }
        let scale = used.count > 3 ? max(1, chi2 / Double(used.count - 3)) : 1
        return (
            origin + SIMD2(solution.x, solution.y), solution.z, (inverse[2][2] * scale).squareRoot(), kept
        )
    }
}
