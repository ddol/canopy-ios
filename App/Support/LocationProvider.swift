import CanopyMap
import CanopyModel
import CoreLocation
import Observation

/// The device's position while a screen that needs it is open. Uses Core Location's async updates and a
/// service session, which asks for when-in-use permission the first time.
@Observable
final class LocationProvider {
    private(set) var location: CLLocation?
    private(set) var isDenied = false
    /// The compass's true heading, degrees clockwise from north, while asked for; nil without a compass or a fix.
    private(set) var heading: Double?
    private var updates: Task<Void, Never>?
    private var session: CLServiceSession?
    @ObservationIgnored private var headingManager: CLLocationManager?
    @ObservationIgnored private let headingDelegate = HeadingDelegate()

    var geoPoint: GeoPoint? {
        location.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    /// Horizontal accuracy (one standard deviation, roughly) in metres.
    var accuracy: Double? {
        location.map { max($0.horizontalAccuracy, 0) }
    }

    /// Starts location updates and, with `heading`, the compass too.
    func start(heading wantsHeading: Bool = false) {
        if wantsHeading, headingManager == nil, CLLocationManager.headingAvailable() {
            let manager = CLLocationManager()
            headingDelegate.onHeading = { [weak self] heading in self?.heading = heading }
            manager.delegate = headingDelegate
            manager.headingFilter = 2
            manager.startUpdatingHeading()
            headingManager = manager
        }
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
        headingManager?.stopUpdatingHeading()
        headingManager = nil
        heading = nil
        updates?.cancel()
        updates = nil
        session?.invalidate()
        session = nil
    }
}

/// Passes compass headings on from Core Location, which calls back on the main thread it was started from.
private final class HeadingDelegate: NSObject, CLLocationManagerDelegate {
    /// The true heading, or nil while it is not valid.
    var onHeading: (Double?) -> Void = { _ in }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading =
            newHeading.trueHeading >= 0 && newHeading.headingAccuracy >= 0 ? newHeading.trueHeading : nil
        MainActor.assumeIsolated { onHeading(heading) }
    }
}

extension CensusState {
    /// Trees that are not removed, nearest first, with their distance in metres.
    ///
    /// The AR view asks this several times an update, and with the whole city loaded (tens of thousands of trees)
    /// placing every tree in metres took the main thread a fifth of a second or more each time. So within a radius only
    /// some trees are placed: those in the tiles round it when `tiles` (the census by tile) is given, and of those, or
    /// of every tree without it, the ones inside a box of latitude and longitude round the circle. Nonisolated, as plain
    /// arithmetic on values: the app's main-actor default would make its closures check that they run on the main
    /// thread.
    nonisolated func trees(
        near point: GeoPoint, within radius: Double = .infinity, limit: Int = 20, tiles: CensusTiles? = nil
    ) -> [(Tree, Double)] {
        let frame = LocalFrame(origin: point)
        let box = Self.box(around: point, radius: radius)
        func nearby(_ tree: Tree) -> (Tree, Double)? {
            guard tree.effectiveStatus != .removed, box?.contains(tree.position.geo) != false else { return nil }
            let distance = frame.enu(of: tree.position.geo).horizontalDistance
            return distance <= radius ? (tree, distance) : nil
        }
        let found: [(Tree, Double)]
        // A tree within the radius is in a tile whose centre is within the radius and the tile's size of the point.
        if let tiles, let reach = Self.box(around: point, radius: radius + Self.tileReach(at: point)) {
            found = tiles.trees.filter { reach.contains($0.key.center) }.values.joined()
                .compactMap { self.trees[$0].flatMap(nearby) }
        } else {
            found = trees.values.compactMap(nearby)
        }
        return Array(found.sorted { $0.1 < $1.1 }.prefix(limit))
    }

    /// A box of latitude and longitude holding everything within `radius` metres of `point`, with a tenth to spare;
    /// nil for an unlimited radius, or one reaching a pole or the antimeridian.
    nonisolated static func box(around point: GeoPoint, radius: Double) -> MapViewport? {
        guard radius.isFinite, radius >= 0 else { return nil }
        let box = MapViewport(center: point, radius: radius * 1.1 + 1)
        guard abs(point.latitude) + box.latitudeDelta / 2 < 89, abs(point.longitude) + box.longitudeDelta / 2 < 180
        else { return nil }
        return box
    }

    /// Half again the farthest a level-16 tile reaches from its centre, from the tile at `point`: tiles change size
    /// only slowly across the Earth, so the ones round it reach no farther.
    nonisolated static func tileReach(at point: GeoPoint) -> Double {
        let tile = point.tile
        let frame = LocalFrame(origin: tile.center)
        return 1.5 * (tile.vertices.map { frame.enu(of: $0).horizontalDistance }.max() ?? 0)
    }
}
