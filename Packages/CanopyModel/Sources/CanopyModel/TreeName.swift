/// Deterministic names for trees, such as "Mossy Elowen Sylvatica", so a tree nobody has named yet is still easy to
/// talk about. A name comes from the S2 L22 cell the tree stands in (about 2 m square), and no two L22 cells in the
/// naming region share one. The rubric is in docs/DATA-MODEL.md, *Tree names*.
///
/// 1. The region is a fixed list of L16 tiles covering the park (`regionTokens`, up to 512).
/// 2. A cell's index is its tile's position in that list (9 bits) followed by the cell's place inside the tile: the six
///    child positions from L17 to L22 (12 bits). Distinct cells in the region get distinct indices below 2²¹.
/// 3. `scramble` permutes those 2²¹ indices, so neighbouring trees get unrelated names. It is a bijection, so names stay
///    distinct.
/// 4. The scrambled index, read as three base-128 digits, picks an adjective, a name and a Latin word:
///    128 × 128 × 128 = 2²¹ names.
public enum TreeName {
    /// The occupancy level: one tree per L22 cell.
    public static let level = 22

    static let region: [S2CellID] = regionTokens.split(whereSeparator: \.isWhitespace).map {
        S2CellID(token: String($0))!
    }
    static let rank = Dictionary(uniqueKeysWithValues: region.enumerated().map { ($1, $0) })

    /// The generated name for the tree at `point`, or nil outside the naming region.
    public static func name(for point: GeoPoint) -> String? {
        name(for: S2CellID(point, level: level))
    }

    /// The generated name for an L22 cell (a finer cell uses its L22 parent), or nil outside the naming region.
    public static func name(for cell: S2CellID) -> String? {
        guard let index = index(of: cell) else { return nil }
        let n = Int(scramble(index))
        return "\(adjectives[n & 127]) \(names[(n >> 7) & 127]) \(latin[n >> 14])"
    }

    /// The cell's position in the region: tile rank, then the L17 to L22 child positions.
    static func index(of cell: S2CellID) -> UInt32? {
        guard cell.level >= level, let tileRank = rank[cell.parent(level: S2CellID.tileLevel)] else { return nil }
        let leaf = cell.parent(level: level)
        // A level-22 id ends in a 1 bit at position 16; the twelve bits above it are the six child positions.
        let place = UInt32((leaf.rawValue >> 17) & 0xFFF)
        return UInt32(tileRank) << 12 | place
    }

    static let mask: UInt32 = 1 << 21 - 1

    /// A fixed permutation of 0..<2²¹: multiplications by odd numbers and right xor-shifts, each a bijection on 21 bits.
    static func scramble(_ index: UInt32) -> UInt32 {
        var x = index & mask
        x = (x &* 0x15_A4E5 &+ 0x0B_7F31) & mask
        x ^= x >> 11
        x = (x &* 0x1C_6D2B) & mask
        x ^= x >> 10
        x = (x &* 0x0A_3B97) & mask
        x ^= x >> 11
        return x
    }
}

extension Tree {
    /// What to call the tree: the name players gave it, else its generated name.
    public var name: String {
        localName ?? TreeName.name(for: position.geo) ?? "Unnamed tree"
    }
}
