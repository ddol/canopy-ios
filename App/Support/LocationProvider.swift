import CanopyModel
import CoreLocation
import Observation

/// The device's position while a screen that needs it is open. Uses Core Location's async updates and a
/// service session, which asks for when-in-use permission the first time.
@Observable
final class LocationProvider {
    private(set) var location: CLLocation?
    private(set) var isDenied = false
    private var updates: Task<Void, Never>?
    private var session: CLServiceSession?

    var geoPoint: GeoPoint? {
        location.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    /// Horizontal accuracy (one standard deviation, roughly) in metres.
    var accuracy: Double? {
        location.map { max($0.horizontalAccuracy, 0) }
    }

    func start() {
        guard updates == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self else { return }
                    self.isDenied = update.authorizationDenied || update.authorizationDeniedGlobally
                    if let location = update.location {
                        self.location = location
                    }
                }
            } catch {
                self?.location = nil
            }
        }
    }

    func stop() {
        updates?.cancel()
        updates = nil
        session?.invalidate()
        session = nil
    }
}

extension CensusState {
    /// Trees that are not removed, nearest first, with their distance in metres.
    func trees(near point: GeoPoint, within radius: Double = .infinity, limit: Int = 20) -> [(Tree, Double)] {
        let frame = LocalFrame(origin: point)
        return trees.values
            .filter { $0.effectiveStatus != .removed }
            .map { ($0, frame.enu(of: $0.position.geo).horizontalDistance) }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0 }
    }
}
