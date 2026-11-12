import Foundation
import Network

/// Offline first: the census, scans and alignments all work with no connection, and the server is talked to
/// quietly when there is one. While the phone is offline nothing is asked of the server; when it comes back, the
/// changes made meanwhile sync on their own. A sync or a load that fails for want of a connection says nothing.
extension AppModel {
    /// Starts watching whether the phone has a network path; once, at launch.
    func watchConnectivity() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.connectivityChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.ddol.canopy.connectivity"))
        pathMonitor = monitor
    }

    private func connectivityChanged(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online { syncSoon(after: .seconds(3)) }
    }

    /// Whether an error is the network being out of reach, not the server saying no: offline, no route, the server
    /// not answering or not found (a tailnet name off the tailnet). Such an error is not shown; the work is tried
    /// again when the phone is back online.
    nonisolated static func isOffline(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
        return underlying.map(isOffline) ?? false
    }
}
