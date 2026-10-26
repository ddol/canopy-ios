import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import CanopyHarness

/// Kept and pieced-together loads against a real Gerardus server and real 3DEP points: each must find exactly the
/// trees a download does. Read-only. Opt in with a server:
/// `CANOPY_GERARDUS_URL=http://host:50061 swift test --filter LiveCacheTests` in `Packages/CanopyHarness`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"] != nil), .serialized)
struct LiveCacheTests {
    let server = URL(string: ProcessInfo.processInfo.environment["CANOPY_GERARDUS_URL"] ?? "http://localhost")!
    /// The L16 tile at Stow Lake, Golden Gate Park.
    let tile = S2CellID(token: "8085876c1")!

    func area(_ east: Double, _ north: Double, _ radius: Double) -> AerialTrees.Area {
        let centre = LocalFrame(origin: tile.center).geoPoint(of: ENU(east: east, north: north, up: 0)).point
        return AerialTrees.Area(centre: centre, radius: radius)
    }

    func load(_ area: AerialTrees.Area, cache: ReferenceCache?) async throws -> AerialTrees.SiteResult {
        try await AerialTrees.load(
            tile: tile, area: area, label: "ggp-stow-lake", client: AlignClient(baseURL: server), cache: cache)
    }

    /// The same trees: every id, height, crown and confidence, and positions to a millimetre. Positions are not
    /// compared exactly: the server's PoseFromHint uses today's date in its datum transformation, so two fits of the
    /// georeference a minute apart differ by nanometres, and a kept fit is the one made when it was kept.
    func same(_ a: AerialTrees.SiteResult, _ b: AerialTrees.SiteResult) {
        #expect(a.pointCount == b.pointCount)
        #expect(a.candidates.map(\.id) == b.candidates.map(\.id))
        for (x, y) in zip(a.candidates, b.candidates) {
            #expect(x.height == y.height && x.crownRadius == y.crownRadius && x.confidence == y.confidence)
            #expect(LocalFrame(origin: x.location).enu(of: y.location).horizontalDistance < 0.001)
        }
        #expect(a.canopy?.heights == b.canopy?.heights)
        #expect(Set(a.lines.map(\.featureID)) == Set(b.lines.map(\.featureID)))
    }

    @Test func keptNudgedAndPiecedTogetherLoadsFindWhatADownloadDoes() async throws {
        let cache = ReferenceCache(
            directory: FileManager.default.temporaryDirectory.appending(path: "live-cache-\(UUID().uuidString)"))
        defer { cache.removeAll() }

        let first = try await load(area(0, 0, 120), cache: cache)
        #expect(!first.fromCache)
        let kept = try await load(area(0, 0, 120), cache: cache)
        #expect(kept.fromCache)
        same(kept, try await load(area(0, 0, 120), cache: nil))

        let nudged = try await load(area(6, -4, 120), cache: cache)
        #expect(nudged.fromCache)
        same(nudged, try await load(area(6, -4, 120), cache: nil))

        let panned = try await load(area(40, 0, 120), cache: cache)
        #expect(!panned.fromCache)
        same(panned, try await load(area(40, 0, 120), cache: nil))
        print(
            "LIVE \(first.candidates.count) trees, \(first.pointCount) points; panned \(panned.candidates.count) trees, "
                + "\(cache.streamBytes) bytes kept")
    }
}
