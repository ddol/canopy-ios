import Foundation

/// Where a Gerardus server is, from what a person typed: `gerardus.example.ts.net:50061`,
/// `http://10.0.0.5:50061` or `https://gerardus.example.org`. A missing scheme means `http`, and a plain-HTTP
/// address without a port gets Gerardus's default, 50061.
public struct GerardusEndpoint: Hashable, Sendable, CustomStringConvertible {
    public static let defaultPort = 50061

    /// Scheme, host and port only, such as `http://gerardus.example.ts.net:50061`.
    public let url: URL

    public init?(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            components.path.isEmpty || components.path == "/",
            components.query == nil, components.fragment == nil, components.user == nil
        else { return nil }
        components.scheme = scheme
        components.path = ""
        if components.port == nil, scheme == "http" {
            components.port = Self.defaultPort
        }
        guard let url = components.url else { return nil }
        self.url = url
    }

    /// The host and port, for showing to people.
    public var hostAndPort: String {
        let host = url.host() ?? ""
        return url.port.map { "\(host):\($0)" } ?? host
    }

    public var description: String { url.absoluteString }
}

/// What `GET /` on a Gerardus server answers. Only `status` is required; a field the server leaves out or sends
/// in an unexpected shape reads as nil, so a newer server still passes the connection test.
public struct GerardusStatus: Equatable, Sendable, Decodable {
    public var status: String
    public var service: String?
    public var serverVersion: String?
    /// The build's commit (`git_sha`, or `commit` or `sha` from other builds).
    public var commit: String?
    public var apiVersion: String?
    /// Whether the server accepts scan uploads.
    public var servesScans: Bool?
    /// RFC 3339, as the server wrote it.
    public var startedAt: String?
    public var uptimeSeconds: UInt64?
    /// Reference layer names as in the proto, such as `REFERENCE_LAYER_AERIAL_POINTS`.
    public var availableLayers: [String]

    public init(
        status: String, service: String? = nil, serverVersion: String? = nil, commit: String? = nil,
        apiVersion: String? = nil, servesScans: Bool? = nil, startedAt: String? = nil,
        uptimeSeconds: UInt64? = nil, availableLayers: [String] = []
    ) {
        self.status = status
        self.service = service
        self.serverVersion = serverVersion
        self.commit = commit
        self.apiVersion = apiVersion
        self.servesScans = servesScans
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.availableLayers = availableLayers
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case service
        case serverVersion = "server_version"
        case gitSHA = "git_sha"
        case commit
        case sha
        case apiVersion = "api_version"
        case serveScans = "serve_scans"
        case startedAt = "started_at"
        case uptimeSeconds = "uptime_s"
        case availableLayers = "available_layers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        status = try c.decode(String.self, forKey: .status)
        service = optional(String.self, .service)
        serverVersion = optional(String.self, .serverVersion)
        commit = optional(String.self, .gitSHA) ?? optional(String.self, .commit) ?? optional(String.self, .sha)
        apiVersion = optional(String.self, .apiVersion)
        servesScans = optional(Bool.self, .serveScans)
        startedAt = optional(String.self, .startedAt)
        uptimeSeconds = optional(UInt64.self, .uptimeSeconds)
        availableLayers = optional([String].self, .availableLayers) ?? []
    }

    public var isOK: Bool { status == "ok" }

    /// When the server started, parsed from `startedAt` (with or without fractional seconds).
    public var startDate: Date? {
        guard let startedAt else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: startedAt) ?? ISO8601DateFormatter().date(from: startedAt)
    }

    /// A reference layer's name for people: `REFERENCE_LAYER_AERIAL_POINTS` → "Aerial points".
    public static func layerName(_ name: String) -> String {
        let known = [
            "REFERENCE_LAYER_AERIAL_POINTS": "Aerial points (USGS 3DEP)",
            "REFERENCE_LAYER_OSM": "OpenStreetMap",
            "REFERENCE_LAYER_FOOTPRINTS": "Building footprints",
            "REFERENCE_LAYER_INTERSECTIONS": "Intersections",
        ]
        if let label = known[name] { return label }
        let words = name.replacingOccurrences(of: "REFERENCE_LAYER_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

public enum GerardusConnectionError: Error, Equatable, LocalizedError {
    case http(Int)
    /// Something answered, but not with a Gerardus status page.
    case notGerardus

    public var errorDescription: String? {
        switch self {
        case .http(let code): "The server answered HTTP \(code)."
        case .notGerardus: "Something answered, but it is not a Gerardus server."
        }
    }
}

/// Reads a Gerardus server's status page over plain HTTP.
public struct GerardusStatusClient: Sendable {
    public let endpoint: GerardusEndpoint
    let session: URLSession

    public init(endpoint: GerardusEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.session =
            session
            ?? {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 10
                configuration.waitsForConnectivity = false
                return URLSession(configuration: configuration)
            }()
    }

    /// `GET /`: the status page, and how long the request took.
    public func status() async throws -> (status: GerardusStatus, roundTrip: Duration) {
        var request = URLRequest(url: endpoint.url.appending(path: "/"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: request)
        let roundTrip = clock.now - start
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GerardusConnectionError.http(code) }
        guard let status = try? JSONDecoder().decode(GerardusStatus.self, from: data),
            status.service == nil || status.service == "gerardus"
        else { throw GerardusConnectionError.notGerardus }
        return (status, roundTrip)
    }
}
