import Foundation

/// An S2 cell id: a 64-bit position on the S2 Hilbert curve that names a cell at some level (0…30).
///
/// Gerardus uses L16 for map tiles (about 150 m across in San Francisco) and L19 for chunks (about 20 m).
///
/// Canopy follows the S2 style guide shared with velocity.report
/// (banshee-data/velocity.report, docs/lidar/architecture/geographic-indexing.md):
/// - the **canonical token** (`token`, lower-case hex with trailing zeros removed) is the only identifier, and
///   the only form that is stored, keyed or sent: the L16 tile around the Conservatory of Flowers is
///   `80858745b`;
/// - the **family display** (`familyDisplay`) is for people only: one hyphen after the family prefix, so that
///   tile reads `80858-745b`. For Canopy's levels this is the 5+n form;
/// - parents come from `parent(level:)`, never from cutting or editing token text.
///
/// This is a minimal port of the parts of Google's S2 library that Canopy needs (lat/lng → cell, parent,
/// token, centre and corners), following the reference implementations' maths exactly so that tokens match.
public struct S2CellID: Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public static let maxLevel = 30
    /// Gerardus map tile level.
    public static let tileLevel = 16
    /// Gerardus chunk level.
    public static let chunkLevel = 19

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The leaf cell (level 30) containing a point.
    public init(_ point: GeoPoint) {
        let xyz = S2Math.xyz(latitude: point.latitude, longitude: point.longitude)
        let (face, u, v) = S2Math.faceUV(xyz)
        let i = S2Math.stToIJ(S2Math.uvToST(u))
        let j = S2Math.stToIJ(S2Math.uvToST(v))
        self.init(face: face, i: i, j: j)
    }

    /// The cell at `level` containing a point.
    public init(_ point: GeoPoint, level: Int) {
        self = S2CellID(point).parent(level: level)
    }

    /// Parses a canonical token. Returns nil for anything else: invalid cell ids, upper case, trailing zeros, or
    /// a family display (use `init?(familyDisplay:)` for text a person typed).
    public init?(token: String) {
        guard !token.isEmpty, token.count <= 16, token != "X",
            token.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        let padded = token + String(repeating: "0", count: 16 - token.count)
        guard let value = UInt64(padded, radix: 16) else { return nil }
        let id = S2CellID(rawValue: value)
        guard id.isValid, id.token == token else { return nil }
        self = id
    }

    /// Parses what a person typed or pasted: a canonical token or a family display. The single presentation
    /// hyphen must sit at the family boundary; it is removed and the canonical token validated.
    public init?(familyDisplay text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2, let id = S2CellID(token: parts.joined()) else { return nil }
        if parts.count == 2, parts[0].count != id.familyPrefixLength { return nil }
        self = id
    }

    init(face: Int, i: Int, j: Int) {
        var n = UInt64(face) << (S2Math.posBits - 1)
        var bits = face & S2Math.swapMask
        let mask = (1 << S2Math.lookupBits) - 1
        for k in stride(from: 7, through: 0, by: -1) {
            bits += ((i >> (k * S2Math.lookupBits)) & mask) << (S2Math.lookupBits + 2)
            bits += ((j >> (k * S2Math.lookupBits)) & mask) << 2
            bits = S2Lookup.shared.pos[bits]
            n |= UInt64(bits >> 2) << (UInt64(k) * 2 * UInt64(S2Math.lookupBits))
            bits &= S2Math.swapMask | S2Math.invertMask
        }
        self.init(rawValue: n * 2 + 1)
    }

    /// The cube face, 0…5.
    public var face: Int { Int(rawValue >> UInt64(S2Math.posBits)) }

    /// The lowest set bit, which encodes the level.
    var lsb: UInt64 { rawValue & (~rawValue &+ 1) }

    public var level: Int { S2CellID.maxLevel - rawValue.trailingZeroBitCount / 2 }

    public var isValid: Bool {
        face < 6 && (lsb & 0x1555_5555_5555_5555) != 0
    }

    public var isLeaf: Bool { rawValue & 1 != 0 }

    /// The ancestor at `level`. `level` must not be greater than this cell's level.
    public func parent(level: Int) -> S2CellID {
        precondition(level >= 0 && level <= self.level, "parent level \(level) is below cell level \(self.level)")
        let newLSB = UInt64(1) << UInt64(2 * (S2CellID.maxLevel - level))
        return S2CellID(rawValue: (rawValue & (~newLSB &+ 1)) | newLSB)
    }

    /// The Gerardus tile (L16) containing this cell.
    public var tile: S2CellID { parent(level: S2CellID.tileLevel) }

    /// The Gerardus chunk (L19) containing this cell.
    public var chunk: S2CellID { parent(level: S2CellID.chunkLevel) }

    public func contains(_ other: S2CellID) -> Bool {
        other.level >= level && other.parent(level: level) == self
    }

    /// Hex characters in the family prefix: the complete nibbles of the hierarchy bits of L10, or of the cell's
    /// own level if it is coarser. Cells at L10 or finer that share an L10 ancestor always share these 5
    /// characters; an L8 cell's own prefix is 4 (`8085-9`).
    public var familyPrefixLength: Int { (3 + 2 * min(level, 10)) / 4 }

    /// The canonical token with one hyphen after the family prefix, for people: `80858-745b` for the canonical
    /// token `80858745b`. Presentation only: removing the hyphen gives the canonical token back. Never store,
    /// key, send or parse hierarchy from it.
    public var familyDisplay: String {
        let token = self.token
        let prefix = familyPrefixLength
        guard prefix > 0, token.count > prefix else { return token }
        return token.prefix(prefix) + "-" + token.dropFirst(prefix)
    }

    /// The canonical token: the S2 CellID as lower-case hex with trailing zeros removed. The identifier for
    /// storage, keys and interchange.
    public var token: String {
        guard rawValue != 0 else { return "X" }
        let hex = String(rawValue, radix: 16)
        let full = String(repeating: "0", count: 16 - hex.count) + hex
        return String(full.reversed().drop(while: { $0 == "0" }).reversed())
    }

    /// The centre of the cell (S2's cell centre, which is the centre in (s, t) space).
    public var center: GeoPoint {
        let (face, i, j) = faceIJ
        let size = 1 << (S2CellID.maxLevel - level)
        let iLo = i & -size
        let jLo = j & -size
        let s = (Double(iLo) + Double(size) / 2) / Double(S2Math.maxSize)
        let t = (Double(jLo) + Double(size) / 2) / Double(S2Math.maxSize)
        return S2Math.geoPoint(S2Math.faceUVToXYZ(face, S2Math.stToUV(s), S2Math.stToUV(t)))
    }

    /// The four corners, counter-clockwise, in the same order as S2's `Cell.Vertex(0…3)`.
    public var vertices: [GeoPoint] {
        let (face, i, j) = faceIJ
        let size = 1 << (S2CellID.maxLevel - level)
        let iLo = i & -size
        let jLo = j & -size
        let u0 = S2Math.stToUV(Double(iLo) / Double(S2Math.maxSize))
        let u1 = S2Math.stToUV(Double(iLo + size) / Double(S2Math.maxSize))
        let v0 = S2Math.stToUV(Double(jLo) / Double(S2Math.maxSize))
        let v1 = S2Math.stToUV(Double(jLo + size) / Double(S2Math.maxSize))
        return [(u0, v0), (u1, v0), (u1, v1), (u0, v1)].map { u, v in
            S2Math.geoPoint(S2Math.faceUVToXYZ(face, u, v))
        }
    }

    /// The face and leaf-cell (i, j) coordinates of a leaf inside this cell.
    var faceIJ: (face: Int, i: Int, j: Int) {
        let face = self.face
        var orientation = face & S2Math.swapMask
        var i = 0
        var j = 0
        var nbits = S2CellID.maxLevel - 7 * S2Math.lookupBits
        for k in stride(from: 7, through: 0, by: -1) {
            let shift = UInt64(k * 2 * S2Math.lookupBits + 1)
            orientation += Int((rawValue >> shift) & ((1 << UInt64(2 * nbits)) - 1)) << 2
            orientation = S2Lookup.shared.ij[orientation]
            i += (orientation >> (S2Math.lookupBits + 2)) << (k * S2Math.lookupBits)
            j += ((orientation >> 2) & ((1 << S2Math.lookupBits) - 1)) << (k * S2Math.lookupBits)
            orientation &= S2Math.swapMask | S2Math.invertMask
            nbits = S2Math.lookupBits
        }
        return (face, i, j)
    }

    public static func < (lhs: S2CellID, rhs: S2CellID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// String interpolation (logs, debugging, messages) shows the family display; anything stored, keyed or sent must
/// use `token`.
extension S2CellID: CustomStringConvertible {
    public var description: String { familyDisplay }
}

extension S2CellID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let token = try container.decode(String.self)
        guard let id = S2CellID(token: token) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid S2 token \(token)")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

// MARK: - Maths

enum S2Math {
    static let lookupBits = 4
    static let swapMask = 0x01
    static let invertMask = 0x02
    static let posBits = 2 * S2CellID.maxLevel + 1
    static let maxSize = 1 << S2CellID.maxLevel

    static func xyz(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let lat = latitude * (Double.pi / 180)
        let lng = longitude * (Double.pi / 180)
        let phi = cos(lat)
        return SIMD3(cos(lng) * phi, sin(lng) * phi, sin(lat))
    }

    static func geoPoint(_ p: SIMD3<Double>) -> GeoPoint {
        let lat = atan2(p.z, (p.x * p.x + p.y * p.y).squareRoot())
        let lng = atan2(p.y, p.x)
        return GeoPoint(latitude: lat * (180 / Double.pi), longitude: lng * (180 / Double.pi))
    }

    /// The face a point projects onto, and its (u, v) coordinates on that face.
    static func faceUV(_ p: SIMD3<Double>) -> (face: Int, u: Double, v: Double) {
        let a = SIMD3(abs(p.x), abs(p.y), abs(p.z))
        var face: Int
        if a.x > a.y {
            face = a.x > a.z ? 0 : 2
        } else {
            face = a.y > a.z ? 1 : 2
        }
        if p[face] < 0 {
            face += 3
        }
        switch face {
        case 0: return (face, p.y / p.x, p.z / p.x)
        case 1: return (face, -p.x / p.y, p.z / p.y)
        case 2: return (face, -p.x / p.z, -p.y / p.z)
        case 3: return (face, p.z / p.x, p.y / p.x)
        case 4: return (face, p.z / p.y, -p.x / p.y)
        default: return (face, -p.y / p.z, -p.x / p.z)
        }
    }

    static func faceUVToXYZ(_ face: Int, _ u: Double, _ v: Double) -> SIMD3<Double> {
        switch face {
        case 0: return SIMD3(1, u, v)
        case 1: return SIMD3(-u, 1, v)
        case 2: return SIMD3(-u, -v, 1)
        case 3: return SIMD3(-1, -v, -u)
        case 4: return SIMD3(v, -1, -u)
        default: return SIMD3(v, u, -1)
        }
    }

    /// S2's quadratic projection from u (−1…1) to s (0…1).
    static func uvToST(_ u: Double) -> Double {
        u >= 0 ? 0.5 * (1 + 3 * u).squareRoot() : 1 - 0.5 * (1 - 3 * u).squareRoot()
    }

    static func stToUV(_ s: Double) -> Double {
        s >= 0.5 ? (1.0 / 3.0) * (4 * s * s - 1) : (1.0 / 3.0) * (1 - 4 * (1 - s) * (1 - s))
    }

    static func stToIJ(_ s: Double) -> Int {
        max(0, min(maxSize - 1, Int((Double(maxSize) * s).rounded(.down))))
    }
}

/// The Hilbert-curve lookup tables, built once.
final class S2Lookup: Sendable {
    static let shared = S2Lookup()

    let pos: [Int]
    let ij: [Int]

    private init() {
        let size = 1 << (2 * S2Math.lookupBits + 2)
        var pos = [Int](repeating: 0, count: size)
        var ij = [Int](repeating: 0, count: size)
        // posToIJ[orientation][position] gives the (i, j) quadrant, as i << 1 | j.
        let posToIJ = [[0, 1, 3, 2], [0, 2, 3, 1], [3, 2, 0, 1], [3, 1, 0, 2]]
        let posToOrientation = [S2Math.swapMask, 0, 0, S2Math.invertMask | S2Math.swapMask]

        func fill(level: Int, i: Int, j: Int, origOrientation: Int, pos position: Int, orientation: Int) {
            if level == S2Math.lookupBits {
                let ijIndex = (i << S2Math.lookupBits) + j
                pos[(ijIndex << 2) + origOrientation] = (position << 2) + orientation
                ij[(position << 2) + origOrientation] = (ijIndex << 2) + orientation
                return
            }
            let quadrants = posToIJ[orientation]
            for k in 0..<4 {
                fill(
                    level: level + 1,
                    i: (i << 1) + (quadrants[k] >> 1),
                    j: (j << 1) + (quadrants[k] & 1),
                    origOrientation: origOrientation,
                    pos: (position << 2) + k,
                    orientation: orientation ^ posToOrientation[k]
                )
            }
        }

        for orientation in [0, S2Math.swapMask, S2Math.invertMask, S2Math.swapMask | S2Math.invertMask] {
            fill(level: 0, i: 0, j: 0, origOrientation: orientation, pos: 0, orientation: orientation)
        }
        self.pos = pos
        self.ij = ij
    }
}
