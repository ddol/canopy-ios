import Foundation

/// A JSON value, used for the `fields` of a change operation.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Encodes any `Encodable` value with Canopy's JSON settings and reads it back as a `JSONValue`.
    public init(encoding value: some Encodable) throws {
        let data = try CanopyJSON.encoder.encode(value)
        self = try CanopyJSON.decoder.decode(JSONValue.self, from: data)
    }

    /// Decodes this value as `T` with Canopy's JSON settings.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try CanopyJSON.decoder.decode(type, from: CanopyJSON.encoder.encode(self))
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { object } else { nil }
    }

    public var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Canopy's JSON settings: sorted keys (so encodings are stable) and dates as integer milliseconds since 1970.
public enum CanopyJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let milliseconds = try decoder.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        return decoder
    }
}
