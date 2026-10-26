import Foundation

// Swift versions of the gerardus.align.v1alpha1 messages Canopy uses. Field numbers follow the server's
// align.proto (read by gRPC reflection), as of Gerardus commit 5f565a9 (FEATURE_KIND_WALL_SURFACE); unknown fields
// are skipped, so newer servers stay compatible.

// MARK: - Geometry

public struct Vector3: Equatable, Sendable, ProtoDecodable, ProtoEncodable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public init(fields: [ProtoField]) {
        self.init(x: 0, y: 0, z: 0)
        for f in fields {
            switch f.number {
            case 1: x = f.double
            case 2: y = f.double
            case 3: z = f.double
            default: break
            }
        }
    }

    public func encode(to w: inout ProtoWriter) {
        w.double(1, x)
        w.double(2, y)
        w.double(3, z)
    }
}

/// Unit quaternion, Hamilton convention: rotates child-frame (sensor) vectors into the parent (site) frame.
public struct Quaternion: Equatable, Sendable, ProtoDecodable, ProtoEncodable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    /// A rotation of `radians` about the site's up axis (counter-clockwise seen from above).
    public static func yaw(_ radians: Double) -> Quaternion {
        Quaternion(w: cos(radians / 2), x: 0, y: 0, z: sin(radians / 2))
    }

    public init(fields: [ProtoField]) {
        self.init(w: 0, x: 0, y: 0, z: 0)
        for f in fields {
            switch f.number {
            case 1: w = f.double
            case 2: x = f.double
            case 3: y = f.double
            case 4: z = f.double
            default: break
            }
        }
    }

    public func encode(to e: inout ProtoWriter) {
        e.double(1, w)
        e.double(2, x)
        e.double(3, y)
        e.double(4, z)
    }

    /// Rotates a vector.
    public func rotate(_ v: Vector3) -> Vector3 {
        // v' = v + 2w(q × v) + 2 q × (q × v)
        let qx = x
        let qy = y
        let qz = z
        let tx = 2 * (qy * v.z - qz * v.y)
        let ty = 2 * (qz * v.x - qx * v.z)
        let tz = 2 * (qx * v.y - qy * v.x)
        return Vector3(
            x: v.x + w * tx + (qy * tz - qz * ty),
            y: v.y + w * ty + (qz * tx - qx * tz),
            z: v.z + w * tz + (qx * ty - qy * tx)
        )
    }
}

public struct GeodeticPosition: Equatable, Sendable, ProtoDecodable, ProtoEncodable {
    public var latitude: Double
    public var longitude: Double
    public var ellipsoidalHeight: Double?
    /// NAVD88 height.
    public var orthometricHeight: Double?

    public init(latitude: Double, longitude: Double, ellipsoidalHeight: Double? = nil, orthometricHeight: Double? = nil)
    {
        self.latitude = latitude
        self.longitude = longitude
        self.ellipsoidalHeight = ellipsoidalHeight
        self.orthometricHeight = orthometricHeight
    }

    public init(fields: [ProtoField]) {
        self.init(latitude: 0, longitude: 0)
        for f in fields {
            switch f.number {
            case 1: latitude = f.double
            case 2: longitude = f.double
            case 3: ellipsoidalHeight = f.double
            case 4: orthometricHeight = f.double
            default: break
            }
        }
    }

    public func encode(to w: inout ProtoWriter) {
        w.double(1, latitude, always: true)
        w.double(2, longitude, always: true)
        if let ellipsoidalHeight { w.double(3, ellipsoidalHeight, always: true) }
        if let orthometricHeight { w.double(4, orthometricHeight, always: true) }
    }
}

/// Points as parallel arrays. `classification` is the ASPRS LAS class for reference points (2 ground, 6
/// building, 9 water, ...); empty for scans.
public struct PointBlock: Equatable, Sendable, ProtoDecodable, ProtoEncodable {
    public var x: [Float]
    public var y: [Float]
    public var z: [Float]
    public var classification: [UInt32]
    public var intensity: [UInt32]
    public var confidence: [UInt32]

    public init(
        x: [Float] = [], y: [Float] = [], z: [Float] = [], classification: [UInt32] = [], intensity: [UInt32] = [],
        confidence: [UInt32] = []
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.classification = classification
        self.intensity = intensity
        self.confidence = confidence
    }

    public var count: Int { x.count }

    public init(fields: [ProtoField]) throws {
        self.init()
        for f in fields {
            switch f.number {
            case 1: x += f.floats()
            case 2: y += f.floats()
            case 3: z += f.floats()
            case 4: classification += try f.varints().map { UInt32(truncatingIfNeeded: $0) }
            case 5: intensity += try f.varints().map { UInt32(truncatingIfNeeded: $0) }
            case 6: confidence += try f.varints().map { UInt32(truncatingIfNeeded: $0) }
            default: break
            }
        }
    }

    public func encode(to w: inout ProtoWriter) {
        w.packedFloats(1, x)
        w.packedFloats(2, y)
        w.packedFloats(3, z)
        w.packedVarints(4, classification.map(UInt64.init))
        w.packedVarints(5, intensity.map(UInt64.init))
        w.packedVarints(6, confidence.map(UInt64.init))
    }
}

/// A ground surface on a regular grid: `z[j * nx + i]` is the height of the cell centre at
/// `origin + (i * cellSize, j * cellSize)`, NaN where there is no ground.
public struct Heightfield: Equatable, Sendable, ProtoDecodable {
    public var origin: Vector3
    public var cellSize: Double
    public var nx: Int
    public var ny: Int
    public var z: [Float]

    public init(origin: Vector3, cellSize: Double, nx: Int, ny: Int, z: [Float]) {
        self.origin = origin
        self.cellSize = cellSize
        self.nx = nx
        self.ny = ny
        self.z = z
    }

    public init(fields: [ProtoField]) throws {
        self.init(origin: .zero, cellSize: 1, nx: 0, ny: 0, z: [])
        for f in fields {
            switch f.number {
            case 1: origin = Vector3(fields: try ProtoReader.fields(f.bytes))
            case 2: cellSize = Double(f.float)
            case 3: nx = f.int
            case 4: ny = f.int
            case 5: z += f.floats()
            default: break
            }
        }
    }

    /// Ground height at a site-frame point, bilinear between cell centres; nil outside the grid or over a gap.
    public func height(x: Double, y: Double) -> Double? {
        guard nx > 0, ny > 0, z.count == nx * ny else { return nil }
        let fx = (x - origin.x) / cellSize
        let fy = (y - origin.y) / cellSize
        guard fx >= -0.5, fy >= -0.5, fx <= Double(nx) - 0.5, fy <= Double(ny) - 0.5 else { return nil }
        let i0 = max(0, min(nx - 1, Int(fx.rounded(.down))))
        let j0 = max(0, min(ny - 1, Int(fy.rounded(.down))))
        let i1 = min(nx - 1, i0 + 1)
        let j1 = min(ny - 1, j0 + 1)
        let tx = max(0, min(1, fx - Double(i0)))
        let ty = max(0, min(1, fy - Double(j0)))
        let corners = [
            (i0, j0, (1 - tx) * (1 - ty)), (i1, j0, tx * (1 - ty)), (i0, j1, (1 - tx) * ty), (i1, j1, tx * ty),
        ]
        var total = 0.0
        var weight = 0.0
        for (i, j, w) in corners where w > 0 {
            let value = z[j * nx + i]
            guard value.isFinite else { continue }
            total += Double(value) * w
            weight += w
        }
        return weight > 0.25 ? total / weight : nil
    }
}

// MARK: - Sites

public enum ReferenceLayer: Int, Sendable, CaseIterable {
    case unspecified = 0
    case aerialPoints = 1
    case osm = 2
    case footprints = 3
    case intersections = 4
    case registeredScans = 5
    case observed = 6
    case groundMesh = 7
    case boxes = 8
    case cityStreets = 9
    case cityIntersections = 10
    case kerbs = 11
    case streetUse = 12
    case buildings = 13
    case laneMarkings = 14
    case streetFurniture = 15
    case trees = 16
}

public enum FeatureKind: Int, Sendable {
    case unspecified = 0
    case road = 1
    case path = 2
    case kerb = 3
    case rail = 4
    case building = 5
    case sensor = 6
    case correction = 7
    case facade = 8
    case pole = 9
    case wallPlane = 10
    case driveway = 11
    case parkingSpace = 12
    case travelLane = 13
    case island = 14
    case other = 15
    case surface = 16
    case roofPlane = 17
    case buildingPart = 18
    case laneMarking = 19
    case sign = 20
    case tree = 21
    /// A vertical wall of a building part up to its roofline (BUILDINGS); its vertices carry their z.
    case wallSurface = 22
}

public struct SiteFrame: Equatable, Sendable, ProtoDecodable {
    /// "site/<l16 token>"
    public var frameID = ""
    public var l16Token = ""
    /// Centre of the L16 cell at NAVD88 height 0, on `horizontalDatum`.
    public var origin = GeodeticPosition(latitude: 0, longitude: 0)
    public var horizontalDatum = ""
    public var verticalDatum = ""
    public var geoidModel = ""
    public var geoidUndulation = 0.0
    public var workingCRS = ""

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: frameID = f.string
            case 2: l16Token = f.string
            case 3: origin = GeodeticPosition(fields: try ProtoReader.fields(f.bytes))
            case 4: horizontalDatum = f.string
            case 5: verticalDatum = f.string
            case 6: geoidModel = f.string
            case 7: geoidUndulation = f.double
            case 8: workingCRS = f.string
            default: break
            }
        }
    }
}

/// One input to a site bundle and the terms it came under. Show `attribution` wherever the data is shown.
public struct SourceInfo: Equatable, Sendable, ProtoDecodable {
    public var layer = ReferenceLayer.unspecified
    public var name = ""
    public var uri = ""
    public var version = ""
    public var licence = ""
    public var attribution = ""
    public var sha256 = ""

    public init(fields: [ProtoField]) {
        for f in fields {
            switch f.number {
            case 1: layer = ReferenceLayer(rawValue: f.int) ?? .unspecified
            case 2: name = f.string
            case 3: uri = f.string
            case 4: version = f.string
            case 5: licence = f.string
            case 6: attribution = f.string
            case 8: sha256 = f.string
            default: break
            }
        }
    }
}

/// A prepared reference bundle for an L16 tile and its 8 neighbours.
public struct Site: Equatable, Sendable, ProtoDecodable {
    public var l16Token = ""
    public var label = ""
    public var frame: SiteFrame?
    public var coveringL16Tokens: [String] = []
    public var layerCounts: [ReferenceLayer: UInt64] = [:]
    public var sources: [SourceInfo] = []
    /// "sha256:<hex>" of the bundle manifest; changes whenever any input changes.
    public var bundleID = ""

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: l16Token = f.string
            case 2: label = f.string
            case 3: frame = try SiteFrame(f)
            case 4: coveringL16Tokens.append(f.string)
            case 5:
                var layer = ReferenceLayer.unspecified
                var count: UInt64 = 0
                for g in try ProtoReader.fields(f.bytes) {
                    if g.number == 1 { layer = ReferenceLayer(rawValue: g.int) ?? .unspecified }
                    if g.number == 2 { count = g.uint }
                }
                layerCounts[layer] = count
            case 6: sources.append(try SourceInfo(f))
            case 7: bundleID = f.string
            default: break
            }
        }
    }
}

public struct LineFeature: Equatable, Sendable, ProtoDecodable {
    public var featureID = ""
    public var kind = FeatureKind.unspecified
    /// Site-frame vertices, interleaved x, y, z.
    public var xyz: [Float] = []
    public var closed = false
    public var height: Float = 0
    public var tags: [String: String] = [:]
    public var sourceVersion = ""

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: featureID = f.string
            case 2: kind = FeatureKind(rawValue: f.int) ?? .other
            case 3: xyz += f.floats()
            case 4: closed = f.bool
            case 5: height = f.float
            case 6:
                var key = ""
                var value = ""
                for g in try ProtoReader.fields(f.bytes) {
                    if g.number == 1 { key = g.string }
                    if g.number == 2 { value = g.string }
                }
                tags[key] = value
            case 7: sourceVersion = f.string
            default: break
            }
        }
    }

    /// The vertices as (x, y) pairs.
    public var points: [SIMD2<Double>] {
        vertices.map { SIMD2(Double($0.x), Double($0.y)) }
    }

    /// Full ENU geometry, including NAVD88 elevation. Ignore a trailing incomplete vertex.
    public var vertices: [SIMD3<Float>] {
        stride(from: 0, to: xyz.count / 3 * 3, by: 3).map { SIMD3(xyz[$0], xyz[$0 + 1], xyz[$0 + 2]) }
    }
}

public struct ServerInfo: Equatable, Sendable, ProtoDecodable {
    public var serverVersion = ""
    public var apiVersion = ""
    public var availableLayers: [ReferenceLayer] = []

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: serverVersion = f.string
            case 2: apiVersion = f.string
            case 3: availableLayers += try f.varints().compactMap { ReferenceLayer(rawValue: Int($0)) }
            default: break
            }
        }
    }
}

public struct Progress: Equatable, Sendable, ProtoDecodable {
    /// "aerial", "osm", "footprints", "intersections", "coarse", "icp", "gates", ...
    public var stage = ""
    /// 0…1 within the stage; negative when unknown.
    public var fraction: Float = -1
    public var message = ""

    public init(stage: String, fraction: Float, message: String) {
        self.stage = stage
        self.fraction = fraction
        self.message = message
    }

    public init(fields: [ProtoField]) {
        fraction = 0
        for f in fields {
            switch f.number {
            case 1: stage = f.string
            case 2: fraction = f.float
            case 3: message = f.string
            default: break
            }
        }
    }
}

/// What the reference stream sends.
public enum ReferenceChunk: Sendable {
    case points(ReferenceLayer, PointBlock)
    case lines(ReferenceLayer, [LineFeature])
    case groundMesh(Heightfield)
    case other(ReferenceLayer)
    case layerComplete(ReferenceLayer)
}

public struct StreamReferenceRequest: Sendable, ProtoEncodable {
    public var l16Token: String
    public var layers: [ReferenceLayer]
    /// Site frame; nil: the origin.
    public var centre: Vector3?
    /// Horizontal; 0: the whole bundle.
    public var radius: Float
    /// Aerial thinning; 0: the server default (0.5 m).
    public var voxelSize: Float
    /// ASPRS classes to send; empty: all but noise.
    public var aerialClasses: [UInt32]
    public var maxPointsPerMessage: UInt32

    public init(
        l16Token: String, layers: [ReferenceLayer], centre: Vector3? = nil, radius: Float = 0, voxelSize: Float = 0,
        aerialClasses: [UInt32] = [], maxPointsPerMessage: UInt32 = 0
    ) {
        self.l16Token = l16Token
        self.layers = layers
        self.centre = centre
        self.radius = radius
        self.voxelSize = voxelSize
        self.aerialClasses = aerialClasses
        self.maxPointsPerMessage = maxPointsPerMessage
    }

    public func encode(to w: inout ProtoWriter) {
        w.string(1, l16Token)
        w.packedVarints(2, layers.map { UInt64($0.rawValue) })
        if let centre { w.message(3, centre) }
        w.float(4, radius)
        w.float(5, voxelSize)
        w.packedVarints(6, aerialClasses.map(UInt64.init))
        w.uint(7, UInt64(maxPointsPerMessage))
    }
}

// MARK: - Poses and registration

public enum PoseSource: Int, Sendable {
    case unspecified = 0
    case hint = 1
    case manual = 2
    case tiePoints = 3
    case icp = 4
    case joint = 5
}

/// Places a sensor frame in a site frame: `site = rotation · sensor + translation`.
public struct SensorPose: Equatable, Sendable, ProtoDecodable, ProtoEncodable {
    public var siteFrameID = ""
    public var sensorFrameID = ""
    public var translation = Vector3.zero
    public var rotation = Quaternion.identity
    /// 6 × 6 row-major: tx, ty, tz (m), then rx, ry, rz (rad). Empty when unknown.
    public var covariance: [Double] = []
    public var source = PoseSource.unspecified

    public init(translation: Vector3, rotation: Quaternion) {
        self.translation = translation
        self.rotation = rotation
    }

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: siteFrameID = f.string
            case 2: sensorFrameID = f.string
            case 3: translation = Vector3(fields: try ProtoReader.fields(f.bytes))
            case 4: rotation = Quaternion(fields: try ProtoReader.fields(f.bytes))
            case 5: covariance += f.doubles()
            case 6: source = PoseSource(rawValue: f.int) ?? .unspecified
            default: break
            }
        }
    }

    public func encode(to w: inout ProtoWriter) {
        w.string(1, siteFrameID)
        w.string(2, sensorFrameID)
        w.message(3, translation)
        w.message(4, rotation)
        w.packedDoubles(5, covariance)
        w.enumValue(6, source.rawValue)
    }

    /// A sensor-frame point in the site frame.
    public func apply(_ point: Vector3) -> Vector3 {
        let r = rotation.rotate(point)
        return Vector3(x: r.x + translation.x, y: r.y + translation.y, z: r.z + translation.z)
    }

    /// One-sigma horizontal position uncertainty from the covariance, if known.
    public var horizontalSigma: Double? {
        guard covariance.count == 36 else { return nil }
        return ((covariance[0] + covariance[7]) / 2).squareRoot()
    }
}

/// A pose restated for people.
public struct PoseSummary: Equatable, Sendable, ProtoDecodable {
    /// Azimuth of sensor +Y, clockwise from true north.
    public var heading = 0.0
    public var pitch = 0.0
    public var roll = 0.0
    public var heightAboveGround = 0.0
    public var position = GeodeticPosition(latitude: 0, longitude: 0)
    public var sigmaHorizontal = 0.0
    public var sigmaHeading = 0.0

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: heading = f.double
            case 2: pitch = f.double
            case 3: roll = f.double
            case 4: heightAboveGround = f.double
            case 5: position = GeodeticPosition(fields: try ProtoReader.fields(f.bytes))
            case 6: sigmaHorizontal = f.double
            case 7: sigmaHeading = f.double
            default: break
            }
        }
    }
}

/// An approximate placement before registration.
public struct PoseHint: Equatable, Sendable, ProtoEncodable {
    /// WGS 84; the height is ignored.
    public var position: GeodeticPosition
    /// Azimuth of sensor +Y, clockwise from true north.
    public var heading: Double?
    /// Sensor above ground; the server's default when nil.
    public var mountHeight: Double?

    public init(position: GeodeticPosition, heading: Double? = nil, mountHeight: Double? = nil) {
        self.position = position
        self.heading = heading
        self.mountHeight = mountHeight
    }

    public func encode(to w: inout ProtoWriter) {
        w.message(1, position)
        if let heading { w.double(2, heading, always: true) }
        if let mountHeight { w.double(3, mountHeight, always: true) }
    }
}

public enum ScanKind: Int, Sendable {
    case unspecified = 0
    case background = 1
    case accumulated = 2
    case map = 3
}

public struct ScanHeader: Equatable, Sendable, ProtoEncodable {
    public var l16Token: String
    /// The sensor frame is "sensor/<sensorID>".
    public var sensorID: String
    public var sensorModel: String
    public var kind: ScanKind
    public var captureRef: String
    public var capturedAt: Date

    public init(
        l16Token: String, sensorID: String, sensorModel: String, kind: ScanKind, captureRef: String, capturedAt: Date
    ) {
        self.l16Token = l16Token
        self.sensorID = sensorID
        self.sensorModel = sensorModel
        self.kind = kind
        self.captureRef = captureRef
        self.capturedAt = capturedAt
    }

    public func encode(to w: inout ProtoWriter) {
        w.string(1, l16Token)
        w.string(2, sensorID)
        w.string(3, sensorModel)
        w.enumValue(4, kind.rawValue)
        w.string(5, captureRef)
        w.message(6) { t in
            let seconds = capturedAt.timeIntervalSince1970.rounded(.down)
            t.uint(1, UInt64(max(0, seconds)))
            t.uint(2, UInt64(max(0, (capturedAt.timeIntervalSince1970 - seconds) * 1e9)))
        }
    }
}

public struct Scan: Equatable, Sendable, ProtoDecodable {
    /// "sha256:<hex>" over the header and points.
    public var scanID = ""
    public var pointCount: UInt64 = 0

    public init(fields: [ProtoField]) {
        for f in fields {
            switch f.number {
            case 1: scanID = f.string
            case 3: pointCount = f.uint
            default: break
            }
        }
    }
}

public struct RegistrationOptions: Equatable, Sendable, ProtoEncodable {
    public var seedCount: UInt32 = 0
    public var seedTranslation: Float = 0
    public var seedYaw: Float = 0
    public var maxCorrespondence: Float = 0
    public var randomSeed: UInt64 = 0

    public init(
        seedCount: UInt32 = 0, seedTranslation: Float = 0, seedYaw: Float = 0, maxCorrespondence: Float = 0,
        randomSeed: UInt64 = 0
    ) {
        self.seedCount = seedCount
        self.seedTranslation = seedTranslation
        self.seedYaw = seedYaw
        self.maxCorrespondence = maxCorrespondence
        self.randomSeed = randomSeed
    }

    public func encode(to w: inout ProtoWriter) {
        w.uint(1, UInt64(seedCount))
        w.float(2, seedTranslation)
        w.float(3, seedYaw)
        w.float(4, maxCorrespondence)
        w.uint(5, randomSeed)
    }
}

/// How well a pose fits the reference. Residuals are point-to-plane distances on held-out points.
public struct FitQuality: Equatable, Sendable, ProtoDecodable {
    public var pointsUsed: UInt32 = 0
    public var inlierFraction: Float = 0
    public var groundP50: Float = 0
    public var groundP95: Float = 0
    public var facadeP50: Float = 0
    public var facadeP75: Float = 0
    public var facadeP95: Float = 0
    public var rmse: Float = 0
    /// Eigenvalues above the server's threshold; 6 is fully constrained.
    public var constraintRank: UInt32 = 0
    public var weakDirections: [String] = []

    public init(fields: [ProtoField]) {
        for f in fields {
            switch f.number {
            case 1: pointsUsed = UInt32(truncatingIfNeeded: f.uint)
            case 2: inlierFraction = f.float
            case 3: groundP50 = f.float
            case 4: groundP95 = f.float
            case 5: facadeP50 = f.float
            case 6: facadeP95 = f.float
            case 7: rmse = f.float
            case 9: constraintRank = UInt32(truncatingIfNeeded: f.uint)
            case 10: weakDirections.append(f.string)
            case 11: facadeP75 = f.float
            default: break
            }
        }
    }
}

public struct Hypothesis: Equatable, Sendable, ProtoDecodable {
    public var hypothesisID = ""
    public var pose: SensorPose?
    public var summary: PoseSummary?
    public var quality: FitQuality?
    public var seedsConverged: UInt32 = 0
    public var seedsTotal: UInt32 = 0

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: hypothesisID = f.string
            case 2: pose = try SensorPose(f)
            case 3: summary = try PoseSummary(f)
            case 4: quality = try FitQuality(f)
            case 5: seedsConverged = UInt32(truncatingIfNeeded: f.uint)
            case 6: seedsTotal = UInt32(truncatingIfNeeded: f.uint)
            default: break
            }
        }
    }
}

public struct GateResult: Equatable, Sendable, ProtoDecodable {
    public var name = ""
    public var value = 0.0
    public var threshold = 0.0
    public var passed = false

    public init(fields: [ProtoField]) {
        for f in fields {
            switch f.number {
            case 1: name = f.string
            case 2: value = f.double
            case 3: threshold = f.double
            case 4: passed = f.bool
            default: break
            }
        }
    }
}

public enum RegistrationState: Int, Sendable {
    case unspecified = 0
    case running = 1
    /// Every gate passed; an operator can accept it.
    case candidate = 2
    /// A gate failed, or there was nothing to fit against.
    case failed = 3
    case registered = 4
    case manuallyPlaced = 5
    case rejected = 6
}

public struct Registration: Equatable, Sendable, ProtoDecodable {
    public var registrationID = ""
    public var l16Token = ""
    public var scanID = ""
    public var bundleID = ""
    public var state = RegistrationState.unspecified
    /// Ranked, best first.
    public var hypotheses: [Hypothesis] = []
    /// Evaluated on the best hypothesis.
    public var gates: [GateResult] = []
    public var failureReason = ""
    public var initialPose: SensorPose?

    public init(fields: [ProtoField]) throws {
        for f in fields {
            switch f.number {
            case 1: registrationID = f.string
            case 2: l16Token = f.string
            case 3: scanID = f.string
            case 4: bundleID = f.string
            case 5: state = RegistrationState(rawValue: f.int) ?? .unspecified
            case 6: hypotheses.append(try Hypothesis(f))
            case 7: gates.append(try GateResult(f))
            case 8: failureReason = f.string
            case 10: initialPose = try SensorPose(f)
            default: break
            }
        }
    }

    public var best: Hypothesis? { hypotheses.first }
}

/// Events from `Register`.
public enum RegisterEvent: Sendable {
    case progress(Progress)
    case hypothesis(Hypothesis)
    case finished(Registration)
}

/// Events from `PrepareSite`.
public enum PrepareEvent: Sendable {
    case progress(Progress)
    case ready(Site)
}
