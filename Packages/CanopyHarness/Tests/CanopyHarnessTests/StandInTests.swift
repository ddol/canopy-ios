import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import CanopyHarness

/// The synthetic site is built once per test run: it is a million points.
enum Shared {
    static let site = SyntheticSite()
}

@Suite struct SyntheticSiteTests {
    @Test func isDeterministicAndParkLike() {
        let site = Shared.site
        let again = SyntheticSite()
        #expect(site.bundleID == again.bundleID)
        #expect(site.points.count == again.points.count)
        #expect(site.trees == again.trees)
        print("SITE \(site.trees.count) trees, \(site.points.count) points, \(site.covering.count) tiles")
        #expect(site.covering.count == 9)
        #expect(site.covering.first == site.token || site.covering.contains(site.token))
        #expect((1500...6000).contains(site.trees.count))
        #expect((500_000...1_500_000).contains(site.points.count))
        // The datum round-trips.
        let probe = SIMD2(37.0, -91.0)
        let back = site.site(site.geo(probe))
        #expect(abs(back.x - probe.x) < 1e-6 && abs(back.y - probe.y) < 1e-6)
    }
}

@Suite struct StandInTests {
    @Test func answersTheAlignServiceOverHTTP() async throws {
        let align = StandInAlign(site: Shared.site)
        let server = StandInServer(align: align)
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)

        let info = try await client.serverInfo()
        #expect(info.apiVersion == "gerardus.align.v1alpha1")
        let site = try #require(try await client.site(Shared.site.token))
        #expect(site.bundleID == Shared.site.bundleID)
        #expect(site.coveringL16Tokens.count == 9)
        #expect(try await client.site("80858f") == nil)

        let georeference = try await SiteGeoreference.fetch(for: site, client: client)
        #expect(georeference.rms < 0.001)
        let probe = Shared.site.geo(SIMD2(40, -60))
        let back = georeference.site(of: probe)
        #expect(abs(back.x - 40) < 0.01 && abs(back.y + 60) < 0.01)

        // OpenStreetMap is refused before any message, as the real server refuses it to non-admins.
        await #expect(throws: GRPCStatusError.self) {
            for try await _ in client.reference(StreamReferenceRequest(l16Token: site.l16Token, layers: [.osm])) {}
        }
        #expect(server.stats.calls("GetSite") == 2)
    }

    @Test func loadsAndFindsTheTrees() async throws {
        let truth = Shared.site
        let server = StandInServer(align: StandInAlign(site: truth))
        try await server.start()
        defer { server.stop() }
        let tile = try #require(S2CellID(token: truth.token))
        let area = AerialTrees.Area(centre: truth.geo(SIMD2(60, -40)), radius: 150)
        let result = try await AerialTrees.load(
            tile: tile, area: area, label: "test", client: AlignClient(baseURL: server.url))
        let score = DetectionScore(candidates: result.candidates, site: truth, covers: result.covers)
        print("LOAD \(result.pointCount) points; \(score); \(server.stats)")
        #expect(score.recall > 0.7)
        #expect(score.precision > 0.7)
        #expect(result.attribution.contains { $0.contains("3D Elevation Program") })
    }

    @Test func preparesASiteFirst() async throws {
        let align = StandInAlign(site: Shared.site, prepared: false, preparation: .milliseconds(300))
        let server = StandInServer(align: align)
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        #expect(try await client.site(Shared.site.token) == nil)
        let site = try await client.preparedSite(Shared.site.token, label: "test")
        #expect(site.bundleID == Shared.site.bundleID)
        #expect(try await client.site(Shared.site.token) != nil)
    }

    @Test func shapesTheLink() async throws {
        let server = StandInServer(
            align: StandInAlign(site: Shared.site),
            profile: NetworkProfile(name: "slow", rtt: .milliseconds(100), bytesPerSecond: 1_000_000))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let start = ContinuousClock.now
        _ = try await client.serverInfo()
        // A new connection: handshake and request, two round trips.
        #expect(ContinuousClock.now - start >= .milliseconds(190))
        let request = StreamReferenceRequest(
            l16Token: Shared.site.token, layers: [.aerialPoints], radius: 60, voxelSize: 1, aerialClasses: [1])
        let streamStart = ContinuousClock.now
        var points = 0
        for try await chunk in client.reference(request) {
            if case .points(_, let block) = chunk { points += block.count }
        }
        let elapsed = (ContinuousClock.now - streamStart).timeInterval
        let bytes = server.stats.bytes("StreamReference")
        print("SHAPED \(points) points, \(bytes) bytes in \(elapsed) s")
        #expect(elapsed >= Double(bytes) / 1_000_000 * 0.9)
    }
}
