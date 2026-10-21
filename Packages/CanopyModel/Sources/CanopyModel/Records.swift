import Foundation

/// A Game Center player id, or a local pseudonymous id used until the player signs in.
public struct PlayerID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A device-local id for a player who has not signed in to Game Center.
    public static func local(_ id: UUID) -> PlayerID {
        PlayerID(rawValue: "local:" + id.uuidString.lowercased())
    }

    /// The author of records that come from the aerial LiDAR survey rather than a player.
    public static let aerialSurvey = PlayerID(rawValue: "gerardus:aerial")

    public var isLocal: Bool { rawValue.hasPrefix("local:") }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A player as the app knows them. The alias and trusted flag come from Game Center and, later, the server.
public struct Player: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case gameCenter
        case local
    }

    public var id: PlayerID
    public var alias: String
    public var isTrusted: Bool
    public var source: Source

    public init(id: PlayerID, alias: String, isTrusted: Bool = false, source: Source) {
        self.id = id
        self.alias = alias
        self.isTrusted = isTrusted
        self.source = source
    }
}

/// Fields every record carries.
///
/// `version` is the entity version for mutable entities (trees, tags, routes): it starts at 1 and goes up by
/// one with every change, and changesets use it as `baseVersion`. Immutable records (observations, evidence,
/// changesets) keep `version` at 1.
public struct RecordMeta: Hashable, Codable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var playerID: PlayerID
    /// The level-19 chunk the record belongs to.
    public var cell: S2CellID
    public var version: Int

    public init(id: UUID = UUID(), createdAt: Date = .now, playerID: PlayerID, cell: S2CellID, version: Int = 1) {
        self.id = id
        self.createdAt = createdAt.roundedToMilliseconds
        self.playerID = playerID
        self.cell = cell
        self.version = version
    }
}

/// A measured value and its standard uncertainty (one standard deviation), in the SI unit the property names.
public struct Quantity: Hashable, Codable, Sendable {
    public var value: Double
    public var uncertainty: Double

    public init(_ value: Double, uncertainty: Double) {
        self.value = value
        self.uncertainty = uncertainty
    }
}

/// A content address: the lower-case hex SHA-256 of a blob.
public struct BlobRef: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 64, rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let ref = BlobRef(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a SHA-256 hex digest")
        }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Date {
    /// Canopy stores times as whole milliseconds since 1970; rounding on creation keeps round trips exact.
    public var roundedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
