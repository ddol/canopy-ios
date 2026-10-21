import Foundation

/// The small part of GeoJSON (RFC 7946) Canopy reads: feature collections of points, lines and polygons.
public enum GeoJSON {
    public struct FeatureCollection: Decodable, Sendable {
        public var name: String?
        public var features: [Feature]
    }

    public struct Feature: Decodable, Sendable {
        public var id: String?
        public var geometry: Geometry?
        public var properties: [String: JSONValue]

        private enum CodingKeys: String, CodingKey {
            case id
            case geometry
            case properties
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try? container.decodeIfPresent(String.self, forKey: .id) {
                id = string
            } else if let number = try? container.decodeIfPresent(Double.self, forKey: .id) {
                id = number.rounded() == number ? String(Int64(number)) : String(number)
            } else {
                id = nil
            }
            geometry = try container.decodeIfPresent(Geometry.self, forKey: .geometry)
            properties = try container.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        }

        public func number(_ key: String) -> Double? {
            if case .number(let value)? = properties[key] { value } else { nil }
        }

        public func bool(_ key: String) -> Bool? {
            if case .bool(let value)? = properties[key] { value } else { nil }
        }
    }

    public enum Geometry: Decodable, Sendable, Equatable {
        case point(GeoPoint)
        case lineString([GeoPoint])
        case polygon([[GeoPoint]])
        case multiPolygon([[[GeoPoint]]])

        private enum CodingKeys: String, CodingKey {
            case type
            case coordinates
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "Point":
                self = .point(try Self.point(container.decode([Double].self, forKey: .coordinates), in: container))
            case "LineString":
                self = .lineString(
                    try container.decode([[Double]].self, forKey: .coordinates).map {
                        try Self.point($0, in: container)
                    })
            case "Polygon":
                self = .polygon(
                    try container.decode([[[Double]]].self, forKey: .coordinates).map { ring in
                        try ring.map { try Self.point($0, in: container) }
                    })
            case "MultiPolygon":
                self = .multiPolygon(
                    try container.decode([[[[Double]]]].self, forKey: .coordinates).map { polygon in
                        try polygon.map { ring in try ring.map { try Self.point($0, in: container) } }
                    })
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "unsupported geometry \(type)")
            }
        }

        private static func point(
            _ position: [Double], in container: KeyedDecodingContainer<CodingKeys>
        ) throws
            -> GeoPoint
        {
            guard position.count >= 2, (-180...180).contains(position[0]), (-90...90).contains(position[1]) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .coordinates, in: container, debugDescription: "bad position \(position)")
            }
            return GeoPoint(latitude: position[1], longitude: position[0])
        }

        /// Polygon rings (outer ring first) for polygons and multipolygons.
        public var polygons: [[[GeoPoint]]] {
            switch self {
            case .polygon(let rings): [rings]
            case .multiPolygon(let polygons): polygons
            case .point, .lineString: []
            }
        }
    }

    public static func decode(_ data: Data) throws -> FeatureCollection {
        try JSONDecoder().decode(FeatureCollection.self, from: data)
    }
}

public enum GeoJSONImportError: Error, Equatable {
    case badCandidate(index: Int, reason: String)
}

extension TreeCandidate {
    /// Reads aerial candidates from point features with a UUID `id` and `height_m`, `crown_radius_m`,
    /// `confidence` and `synthetic` properties.
    public static func candidates(from collection: GeoJSON.FeatureCollection) throws -> [TreeCandidate] {
        try collection.features.enumerated().map { index, feature in
            guard let id = feature.id.flatMap(UUID.init(uuidString:)) else {
                throw GeoJSONImportError.badCandidate(index: index, reason: "id is not a UUID")
            }
            guard case .point(let location)? = feature.geometry else {
                throw GeoJSONImportError.badCandidate(index: index, reason: "geometry is not a point")
            }
            return TreeCandidate(
                id: id,
                location: location,
                height: feature.number("height_m"),
                crownRadius: feature.number("crown_radius_m"),
                confidence: feature.number("confidence") ?? 0.5,
                isSynthetic: feature.bool("synthetic") ?? false
            )
        }
    }
}
