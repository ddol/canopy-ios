import Foundation
import Testing

@testable import CanopySync

@Suite struct GerardusEndpointTests {
    @Test(arguments: [
        ("hydra.example.ts.net:50061", "http://hydra.example.ts.net:50061"),
        ("hydra.example.ts.net", "http://hydra.example.ts.net:50061"),
        ("  http://10.0.0.5:50061/ ", "http://10.0.0.5:50061"),
        ("https://gerardus.example.org", "https://gerardus.example.org"),
        ("HTTP://Host.example:8080", "http://Host.example:8080"),
    ])
    func acceptsWhatPeopleType(input: String, url: String) throws {
        #expect(try #require(GerardusEndpoint(input)).url.absoluteString == url)
    }

    @Test(arguments: ["", "   ", "ftp://host", "http://", "http://host/path", "http://host?x=1", "http://user@host"])
    func refusesWhatIsNotAServerAddress(input: String) {
        #expect(GerardusEndpoint(input) == nil)
    }

    @Test func showsHostAndPort() throws {
        #expect(try #require(GerardusEndpoint("gerardus.local")).hostAndPort == "gerardus.local:50061")
        #expect(try #require(GerardusEndpoint("https://gerardus.example.org")).hostAndPort == "gerardus.example.org")
    }
}

@Suite struct GerardusStatusTests {
    /// The page `gerardus serve` answers on `GET /`.
    static let page = """
        {
          "status": "ok",
          "service": "gerardus",
          "server_version": "0.1.0",
          "git_sha": "9a82cd5e41",
          "api_version": "gerardus.align.v1alpha1",
          "serve_scans": true,
          "started_at": "2026-10-21T10:04:33.123456789Z",
          "uptime_s": 93784,
          "available_layers": ["REFERENCE_LAYER_AERIAL_POINTS", "REFERENCE_LAYER_OSM"]
        }
        """

    @Test func decodesTheStatusPage() throws {
        let status = try JSONDecoder().decode(GerardusStatus.self, from: Data(Self.page.utf8))
        #expect(status.isOK)
        #expect(status.service == "gerardus")
        #expect(status.serverVersion == "0.1.0")
        #expect(status.commit == "9a82cd5e41")
        #expect(status.apiVersion == "gerardus.align.v1alpha1")
        #expect(status.servesScans == true)
        #expect(status.uptimeSeconds == 93_784)
        #expect(status.availableLayers.map(GerardusStatus.layerName) == ["Aerial points (USGS 3DEP)", "OpenStreetMap"])
        let start = try #require(status.startDate)
        #expect(abs(start.timeIntervalSince1970 - 1_792_577_073.123) < 0.01)
    }

    @Test(arguments: ["commit", "sha"])
    func picksUpTheCommitUnderOtherNames(key: String) throws {
        let json = #"{"status":"ok","\#(key)":"9a82cd5"}"#
        #expect(try JSONDecoder().decode(GerardusStatus.self, from: Data(json.utf8)).commit == "9a82cd5")
    }

    @Test func toleratesMissingAndOddlyShapedFields() throws {
        let json = #"{"status":"ok","uptime_s":"soon","serve_scans":"yes","started_at":"2026-10-21T10:04:33Z"}"#
        let status = try JSONDecoder().decode(GerardusStatus.self, from: Data(json.utf8))
        #expect(status.uptimeSeconds == nil)
        #expect(status.servesScans == nil)
        #expect(status.availableLayers.isEmpty)
        #expect(status.startDate == Date(timeIntervalSince1970: 1_792_577_073))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GerardusStatus.self, from: Data("{}".utf8)) }
    }

    @Test func namesUnknownLayers() {
        #expect(GerardusStatus.layerName("REFERENCE_LAYER_GROUND_MODEL") == "Ground model")
    }
}

@Suite struct GerardusStatusClientTests {
    typealias Stubbed = (client: GerardusStatusClient, host: String)

    func client(_ reply: @escaping @Sendable (StubServer.Received) -> StubServer.Reply) throws -> Stubbed {
        let host = "status-\(UUID().uuidString).test"
        let session = StubServer.session(host: host, reply: reply)
        return (GerardusStatusClient(endpoint: try #require(GerardusEndpoint(host)), session: session), host)
    }

    @Test func getsTheRootPage() async throws {
        let (client, host) = try client { _ in .init(body: Data(GerardusStatusTests.page.utf8)) }
        let (status, roundTrip) = try await client.status()
        #expect(status.serverVersion == "0.1.0")
        #expect(roundTrip >= .zero)
        let request = try #require(StubServer.requests(to: host).first)
        #expect(request.method == "GET")
        #expect(request.path == "/")
        #expect(request.headers["Accept"] == "application/json")
    }

    @Test func saysWhenSomethingElseAnswers() async throws {
        let (html, _) = try client { _ in
            .init(headers: ["Content-Type": "text/html"], body: Data("<html>hello</html>".utf8))
        }
        await #expect(throws: GerardusConnectionError.notGerardus) { try await html.status() }

        let (otherService, _) = try client { _ in .init(body: Data(#"{"status":"ok","service":"velocity"}"#.utf8)) }
        await #expect(throws: GerardusConnectionError.notGerardus) { try await otherService.status() }

        let (missing, _) = try client { _ in .init(status: 404) }
        await #expect(throws: GerardusConnectionError.http(404)) { try await missing.status() }
    }
}
