import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import CanopyHarness

/// Loading through `ReferenceCache` against the stand-in: what goes over the wire, and that kept data gives exactly
/// what the server would have sent.
@Suite struct CacheTests {
    let site = Shared.site
    var tile: S2CellID { S2CellID(token: site.token)! }

    func temporaryCache() -> ReferenceCache {
        ReferenceCache(directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"))
    }

    func area(_ x: Double, _ y: Double, _ radius: Double) -> AerialTrees.Area {
        AerialTrees.Area(centre: site.geo(SIMD2(x, y)), radius: radius)
    }

    @Test func aLoadFromTheCacheFindsTheSameTreesAsADownload() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }

        let first = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)
        #expect(!first.fromCache)
        #expect(server.stats.calls("StreamReference") == 1)

        // Smaller and off-centre, but inside: from the cache, cut as the server would cut it.
        let inner = area(80, -20, 90)
        server.resetStats()
        let kept = try await AerialTrees.load(tile: tile, area: inner, label: "test", client: client, cache: cache)
        #expect(kept.fromCache)
        #expect(server.stats.calls == ["GetSite": 1])
        let fresh = try await AerialTrees.load(tile: tile, area: inner, label: "test", client: client)
        #expect(!fresh.fromCache)
        #expect(kept.pointCount == fresh.pointCount)
        #expect(kept.candidates == fresh.candidates)
        #expect(kept.canopy?.heights == fresh.canopy?.heights)
        #expect(kept.lines == fresh.lines)
    }

    @Test func eachLoadAsksOnlyForWhatItHasNot() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let cache = temporaryCache()
        defer { cache.removeAll() }
        var client = AlignClient(baseURL: server.url)

        _ = try await AerialTrees.load(tile: tile, area: area(0, 0, 150), label: "test", client: client, cache: cache)
        let first = server.stats
        #expect(first.calls("GetSite") == 1)
        #expect(first.calls("PoseFromHint") >= 6)
        #expect(first.calls("StreamReference") == 1)

        // The same area again: the site is checked, nothing else.
        server.resetStats()
        _ = try await AerialTrees.load(tile: tile, area: area(0, 0, 150), label: "test", client: client, cache: cache)
        #expect(server.stats.calls == ["GetSite": 1])
        #expect(server.stats.totalBytes < 2_000)

        // After a relaunch: a new client and a new cache object on the same folder.
        client = AlignClient(baseURL: server.url)
        let relaunched = ReferenceCache(directory: cache.directory)
        server.resetStats()
        let again = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 100), label: "test", client: client, cache: relaunched)
        #expect(again.fromCache)
        #expect(server.stats.calls == ["GetSite": 1])

        // Somewhere it has not been: points again, but not the georeference.
        server.resetStats()
        let moved = try await AerialTrees.load(
            tile: tile, area: area(-100, 80, 120), label: "test", client: client, cache: relaunched)
        #expect(!moved.fromCache)
        #expect(server.stats.calls == ["GetSite": 1, "StreamReference": 1])

        // The whole site answers for every area after it.
        _ = try await AerialTrees.load(tile: tile, label: "test", client: client, cache: relaunched)
        server.resetStats()
        let anywhere = try await AerialTrees.load(
            tile: tile, area: area(150, 150, 60), label: "test", client: client, cache: relaunched)
        #expect(anywhere.fromCache)
        #expect(server.stats.calls == ["GetSite": 1])
    }

    @Test func aLoadAFewMetresAwayUsesTheKeptPoints() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }
        _ = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)
        // The first load asked for a little more than its area and margin, and kept it.
        #expect(server.stats.calls("StreamReference") == 1)

        // The map settled 8 m away: still inside, and the same trees as a download there would find.
        let nudged = area(66, -35, 150)
        server.resetStats()
        let kept = try await AerialTrees.load(tile: tile, area: nudged, label: "test", client: client, cache: cache)
        #expect(kept.fromCache)
        #expect(server.stats.calls == ["GetSite": 1])
        let fresh = try await AerialTrees.load(tile: tile, area: nudged, label: "test", client: client)
        #expect(kept.candidates == fresh.candidates)
        #expect(kept.pointCount == fresh.pointCount)

        // 40 m away is not.
        server.resetStats()
        let moved = try await AerialTrees.load(
            tile: tile, area: area(100, -40, 150), label: "test", client: client, cache: cache)
        #expect(!moved.fromCache)
    }

    @Test func aNewBundleIsDownloadedAgain() async throws {
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        _ = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 100), label: "test", client: AlignClient(baseURL: server.url), cache: cache)
        server.stop()

        // The server prepared the site again from new inputs: same tile, new bundle.
        let rebuilt = SyntheticSite(seed: 2)
        let next = StandInServer(align: StandInAlign(site: rebuilt))
        try await next.start()
        defer { next.stop() }
        let result = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 100), label: "test", client: AlignClient(baseURL: next.url), cache: cache)
        #expect(!result.fromCache)
        #expect(next.stats.calls("StreamReference") == 1)
        #expect(result.site.bundleID == rebuilt.bundleID)
    }

    @Test func keptAreasLoadWithoutTheServer() async throws {
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        let url = server.url
        let online = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 150), label: "test", client: AlignClient(baseURL: url), cache: cache)
        server.stop()

        let offline = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 150), label: "test", client: AlignClient(baseURL: url), cache: cache)
        #expect(offline.fromCache)
        #expect(offline.candidates == online.candidates)

        // Somewhere not kept still fails, with the connection error.
        await #expect(throws: (any Error).self) {
            _ = try await AerialTrees.load(
                tile: tile, area: area(-150, 150, 60), label: "test", client: AlignClient(baseURL: url), cache: cache)
        }
    }

    @Test func oldStreamsAreEvicted() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let areas = [area(-120, 0, 60), area(0, 0, 60), area(120, 0, 60)]
        // How big each area's stream is.
        var sizes: [Int] = []
        for a in areas {
            let measure = temporaryCache()
            _ = try await AerialTrees.load(tile: tile, area: a, label: "test", client: client, cache: measure)
            sizes.append(measure.streamBytes)
            measure.removeAll()
        }
        // Room for the last two, not all three: the first, least recently used, goes.
        let limit = sizes[1] + sizes[2] + 1
        let cache = ReferenceCache(
            directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"),
            byteLimit: limit)
        defer { cache.removeAll() }
        for a in areas {
            _ = try await AerialTrees.load(tile: tile, area: a, label: "test", client: client, cache: cache)
        }
        #expect(cache.streamBytes == sizes[1] + sizes[2])
        server.resetStats()
        _ = try await AerialTrees.load(tile: tile, area: areas[2], label: "test", client: client, cache: cache)
        #expect(server.stats.calls("StreamReference") == 0)
        _ = try await AerialTrees.load(tile: tile, area: areas[0], label: "test", client: client, cache: cache)
        #expect(server.stats.calls("StreamReference") == 1)
    }
}
