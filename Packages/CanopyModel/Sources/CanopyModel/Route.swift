import Foundation

/// A labelled path through the park.
public struct Route: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case path
        case trail
        case road
        case bridleway
        case cycleway
    }

    public enum Status: String, Codable, Sendable {
        case proposed
        case confirmed
    }

    public var meta: RecordMeta
    public var name: String
    public var kind: Kind
    public var points: [GeoPoint]
    public var status: Status

    public init(meta: RecordMeta, name: String, kind: Kind, points: [GeoPoint], status: Status = .proposed) {
        self.meta = meta
        self.name = name
        self.kind = kind
        self.points = points
        self.status = status
    }

    public var id: UUID { meta.id }
}
