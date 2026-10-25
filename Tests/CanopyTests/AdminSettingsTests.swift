import CanopyMap
import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import Canopy

@MainActor
@Suite struct AdminSettingsTests {
    func defaults() -> UserDefaults {
        let name = "canopy.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    let admin = Player(id: PlayerID(rawValue: "T:_admin"), alias: "Admin", source: .gameCenter)
    let other = Player(id: PlayerID(rawValue: "T:_other"), alias: "Other", source: .gameCenter)

    @Test func onlyAllowlistedGameCenterPlayersAreAdmins() {
        let settings = AdminSettings(
            allowlist: AdminSettings.allowlist(from: "T:_admin, T:_second"), everyoneIsAdmin: false,
            defaults: defaults())
        #expect(settings.allowlist == ["T:_admin", "T:_second"])
        #expect(settings.isAdmin(admin))
        #expect(!settings.isAdmin(other))
        // A local id that happens to match is not a Game Center player.
        #expect(!settings.isAdmin(Player(id: PlayerID(rawValue: "T:_admin"), alias: "You", source: .local)))
        #expect(AdminSettings(allowlist: [], everyoneIsAdmin: true, defaults: defaults()).isAdmin(other))
        #expect(AdminSettings.allowlist(from: "").isEmpty)
    }

    @Test func flagsAreOffUntilTurnedOnAndRemembered() {
        let store = defaults()
        let settings = AdminSettings(allowlist: ["T:_admin"], everyoneIsAdmin: false, defaults: store)
        #expect(!settings.useOSM)
        settings.useOSM = true
        #expect(AdminSettings(allowlist: ["T:_admin"], everyoneIsAdmin: false, defaults: store).useOSM)
    }

    @Test func theAerialReferenceIsPlacedOnTheMap() throws {
        let origin = GeoPoint(latitude: 37.7705, longitude: -122.4760)
        let frame = LocalFrame(origin: origin)
        let samples = [(0.0, 0.0), (100, 0), (0, 100)].map { e, n in
            (geo: frame.geoPoint(of: ENU(east: e, north: n, up: 0)).point, site: SIMD2(e, n))
        }
        var road = try LineFeature(fields: [])
        road.kind = .road
        road.xyz = [0, 0, 80, 50, 0, 80]
        let result = AerialTrees.SiteResult(
            site: try Site(fields: []), candidates: [], tiles: [], attribution: [], pointCount: 0,
            georeference: try SiteGeoreference(origin: origin, samples: samples),
            canopy: TreeDetector.CanopyHeightModel(
                origin: SIMD2(-10, -20), cellSize: 0.5, nx: 40, ny: 80, heights: Array(repeating: 12, count: 3200)),
            lines: [road])
        let reference = try #require(AppModel.reference(result))
        let canopy = try #require(reference.canopies.first)
        #expect(canopy.nx == 20 && canopy.ny == 40)
        #expect(abs(frame.enu(of: canopy.southWest).east + 10) < 0.01)
        #expect(abs(frame.enu(of: canopy.northEast).north - 20) < 0.01)  // −20 m + 40 × 1 m, pooled from 0.5 m
        #expect(reference.lines.count == 1)
        #expect(reference.lines[0].kind == .road)
        #expect(abs(frame.enu(of: reference.lines[0].points[1]).east - 50) < 0.01)
    }
}
