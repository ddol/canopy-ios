import CanopySync
import Foundation
import Observation

/// Which Gerardus server Canopy talks to, and the last connection test. The address is kept in user defaults under
/// `canopy.gerardusURL` as scheme, host and port (`http://gerardus.local:50061`), where the Gerardus client reads it.
@Observable
final class ServerSettings {
    static let urlKey = "canopy.gerardusURL"

    enum Check: Equatable {
        case notRun
        case checking
        case connected(GerardusStatus, roundTrip: Duration, at: Date)
        case failed(String)
    }

    private(set) var endpoint: GerardusEndpoint?
    private(set) var check: Check = .notRun

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession?

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        self.session = session
        endpoint = defaults.string(forKey: Self.urlKey).flatMap(GerardusEndpoint.init)
    }

    /// Settings that are forgotten when the app quits, for tests. They start empty, or with the server a UI test
    /// passes as a launch argument (`-canopy.gerardusURL <url>`).
    static func volatile(session: URLSession? = nil) -> ServerSettings {
        let name = "canopy.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let server = arguments[urlKey] as? String, let endpoint = GerardusEndpoint(server) {
            defaults.set(endpoint.url.absoluteString, forKey: urlKey)
        }
        return ServerSettings(defaults: defaults, session: session)
    }

    /// Saves the server address, or forgets it with nil. A different address clears the last test.
    func save(_ endpoint: GerardusEndpoint?) {
        guard endpoint != self.endpoint else { return }
        self.endpoint = endpoint
        check = .notRun
        if let endpoint {
            defaults.set(endpoint.url.absoluteString, forKey: Self.urlKey)
        } else {
            defaults.removeObject(forKey: Self.urlKey)
        }
    }

    /// Reads the server's status page. The result is dropped if the address changes in the meantime.
    func testConnection() async {
        guard let endpoint else { return }
        check = .checking
        let result: Check
        do {
            let (status, roundTrip) = try await GerardusStatusClient(endpoint: endpoint, session: session).status()
            result = .connected(status, roundTrip: roundTrip, at: .now)
        } catch {
            result = .failed(Self.describe(error, endpoint: endpoint))
        }
        if endpoint == self.endpoint {
            check = result
        }
    }

    /// Why a connection test failed, in words a player can act on.
    static func describe(_ error: Error, endpoint: GerardusEndpoint) -> String {
        guard let error = error as? URLError else { return error.localizedDescription }
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS allows plain http:// only to .local and tailnet (.ts.net) names and IP addresses. "
                + "Use https:// for this server."
        case .cannotFindHost, .dnsLookupFailed:
            return "Can’t find \(endpoint.url.host() ?? "that host"). "
                + "For a tailnet name, check that Tailscale is connected on this device."
        case .cannotConnectToHost:
            return "Nothing is answering at \(endpoint.hostAndPort)."
        case .timedOut:
            return "\(endpoint.hostAndPort) did not answer in time."
        case .notConnectedToInternet:
            return "This device is offline."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "The secure connection to \(endpoint.hostAndPort) failed; check its certificate."
        default:
            return error.localizedDescription
        }
    }
}
