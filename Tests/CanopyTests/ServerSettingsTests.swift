import CanopyModel
import CanopyStore
import CanopySync
import Foundation
import Testing

@testable import Canopy

@MainActor
@Suite struct ServerSettingsTests {
    let suite = "canopy.tests.\(UUID().uuidString)"

    func defaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func savesTheAddressWhereTheGerardusClientReadsIt() throws {
        let defaults = try defaults()
        let settings = ServerSettings(defaults: defaults)
        #expect(settings.endpoint == nil)

        settings.save(GerardusEndpoint("gerardus.local"))
        #expect(defaults.string(forKey: "canopy.gerardusURL") == "http://gerardus.local:50061")
        #expect(ServerSettings(defaults: defaults).endpoint == GerardusEndpoint("http://gerardus.local:50061"))

        settings.save(nil)
        #expect(defaults.string(forKey: "canopy.gerardusURL") == nil)
        #expect(ServerSettings(defaults: defaults).endpoint == nil)
    }

    @Test func aConnectionTestShowsTheServersStatus() async throws {
        let host = "gerardus-\(UUID().uuidString).test"
        let page = #"{"status":"ok","service":"gerardus","server_version":"0.1.0","git_sha":"9a82cd5","uptime_s":42}"#
        let settings = ServerSettings(defaults: try defaults(), session: StubStatus.session(host: host, body: page))
        settings.save(GerardusEndpoint(host))
        await settings.testConnection()
        guard case .connected(let status, _, _) = settings.check else {
            Issue.record("expected a connection, got \(settings.check)")
            return
        }
        #expect(status.serverVersion == "0.1.0")
        #expect(status.commit == "9a82cd5")
        #expect(status.uptimeSeconds == 42)

        settings.save(GerardusEndpoint("other.local"))
        #expect(settings.check == .notRun)
    }

    @Test func aFailedTestSaysWhy() async throws {
        let host = "web-\(UUID().uuidString).test"
        let settings = ServerSettings(
            defaults: try defaults(), session: StubStatus.session(host: host, body: "<html>hello</html>"))
        settings.save(GerardusEndpoint(host))
        await settings.testConnection()
        #expect(settings.check == .failed("Something answered, but it is not a Gerardus server."))

        let endpoint = try #require(GerardusEndpoint("gerardus.example.ts.net"))
        #expect(
            ServerSettings.describe(URLError(.cannotConnectToHost), endpoint: endpoint)
                == "Nothing is answering at gerardus.example.ts.net:50061.")
        #expect(
            ServerSettings.describe(URLError(.cannotFindHost), endpoint: endpoint).contains("Tailscale"))
    }

    @Test func theAerialActionsUseOnlyTheServerFromSettings() async throws {
        let model = AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter))
        #expect(model.gerardusURL == nil)
        #expect(model.alignClient == nil)
        await model.loadAerialTrees(around: GeoPoint(latitude: 37.7694, longitude: -122.4862))
        #expect(model.aerial == .failed("Set the Gerardus server in Me → Settings."))

        model.serverSettings.save(GerardusEndpoint("gerardus.local"))
        #expect(model.gerardusURL?.absoluteString == "http://gerardus.local:50061")
        #expect(model.alignClient != nil)
    }
}

/// Answers every request to one host with a fixed body.
final class StubStatus: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: String] = [:]

    static func session(host: String, body: String) -> URLSession {
        lock.withLock { bodies[host] = body }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubStatus.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.lock.withLock { Self.bodies[request.url?.host ?? ""] }
        guard let body, let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
